const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const themes = @import("theme.zig");
const Buffer = @import("buffer.zig").Buffer;
const Tree = @import("tree.zig").Tree;
const Term = @import("term.zig").Term;

/// Modal (vim-style) editor widget multiplexing several buffers.
/// Layout: tabline on top, text area, status line at the bottom.
/// NvChad-style keys: Tab / Shift-Tab cycle buffers, Space is the leader
/// (Space b = buffer picker, Space t = theme picker, Space x = close buffer).
pub const Editor = struct {
    alloc: std.mem.Allocator,
    buffers: std.ArrayListUnmanaged(Buffer) = .{},
    active: usize = 0,
    theme: *const themes.Theme = &themes.list[0],

    mode: Mode = .normal,
    pending: Pending = .none,
    last_height: u16 = 24,
    cmd: std.ArrayListUnmanaged(u8) = .{},
    /// Last committed `/` search pattern (used by n/N and match highlighting).
    search: std.ArrayListUnmanaged(u8) = .{},
    /// True while the command line is a `/` search prompt rather than `:`.
    cmd_is_search: bool = false,
    status_buf: [256]u8 = undefined,
    status_len: usize = 0,
    popup: Popup = .{},
    files: std.ArrayListUnmanaged([]u8) = .{},
    grep_hits: std.ArrayListUnmanaged(GrepHit) = .{},
    tree: Tree,
    tree_open: bool = false,
    focus: Focus = .editor,
    git_branch: [64]u8 = undefined,
    git_branch_len: usize = 0,
    /// Macro registers: `q{a-z}` records raw key events, `@{a-z}` replays.
    macros: [26]std.ArrayListUnmanaged(vaxis.Key) = [_]std.ArrayListUnmanaged(vaxis.Key){.{}} ** 26,
    /// Register char ('a'..'z') currently being recorded into, if any.
    recording: ?u8 = null,
    /// Last register replayed with `@`, reused by `@@`.
    last_macro: ?u8 = null,
    /// Replay re-entrancy depth; guards runaway recursive macros.
    replay_depth: u8 = 0,
    /// Dot-repeat: keys of the last completed change (`.` replays them).
    dot: std.ArrayListUnmanaged(vaxis.Key) = .{},
    /// In-progress change capture (from change-starting key until normal mode).
    dot_rec: std.ArrayListUnmanaged(vaxis.Key) = .{},
    dot_capturing: bool = false,
    /// Pending count prefix for normal-mode commands (0 = none).
    count: u32 = 0,
    /// Visual-mode anchor (the end of the selection that does not move).
    vis_row: usize = 0,
    vis_col: usize = 0,
    /// Double-click detection: time + position of the previous text-area click.
    last_click_ms: i64 = 0,
    last_click_row: usize = 0,
    last_click_col: usize = 0,
    /// Last visual selection, for `gv` reselect: mode + anchor + cursor.
    last_vis: ?struct { mode: Mode, ar: usize, ac: usize, cr: usize, cc: usize } = null,
    /// Jumplist for Ctrl-o / Ctrl-i (vim `:jumps`): positions before big jumps.
    jumps: std.ArrayListUnmanaged(Jump) = .{},
    jump_idx: usize = 0,
    /// Unnamed yank register; `reg_linewise` mirrors vim's charwise/linewise put.
    reg: std.ArrayListUnmanaged(u8) = .{},
    reg_linewise: bool = false,
    /// NvTerm-style bottom terminal split (Alt-h toggles it).
    term: ?Term = null,
    /// Which view shows the shared shell: Alt-h split, Alt-v vertical, Alt-i float.
    term_view: TermView = .none,
    term_h: u16 = 10,
    term_cols: u16 = 80,
    /// mouse=a: layout snapshot + tabline hit spans from the last draw.
    mlay: MouseLayout = .{},
    tab_spans: [32]TabSpan = undefined,
    tab_span_count: usize = 0,

    const TermView = enum { none, split, vert, float };

    /// Geometry captured during draw so mouse clicks can be hit-tested.
    const MouseLayout = struct {
        tree_w: u16 = 0,
        gutter: u16 = 0,
        text_top: u16 = 1,
        text_rows: u16 = 0,
        text_right: u16 = 0,
        valid: bool = false,
    };
    const TabSpan = struct { start: u16, end: u16, close: u16, idx: usize };

    pub const Mode = enum { normal, insert, command, visual, visual_line };
    const Pending = enum { none, g, d, leader, leader_f, leader_c, bracket_f, bracket_b, mark_set, mark_exact, mark_line, macro_rec, macro_play, replace_char };

    const Jump = struct { buf: usize, row: usize, col: usize };
    const Focus = enum { editor, tree, term };
    const tree_width_max: u16 = 30;

    /// Floating picker overlay (buffers / themes), telescope-flavored:
    /// typing filters, arrows or C-j/C-k move, Enter picks, Esc closes.
    const Popup = struct {
        kind: Kind = .none,
        filter: std.ArrayListUnmanaged(u8) = .{},
        selected: usize = 0,

        const Kind = enum { none, buffers, themes, files, keys, grep };
        const max_items = 64;
        const max_files = 2000;
        const max_file_size = 1024 * 1024;
    };

    /// One live-grep result: owned path + owned "path:line: text" display row.
    const GrepHit = struct {
        path: []u8,
        line: usize,
        disp: []u8,
    };

    /// NvCheatsheet-style keybinding reference, shown via `Space c h`.
    const cheats = [_][]const u8{
        "Tab          next buffer",
        "Shift-Tab    prev buffer",
        "Space /      toggle comment",
        "Space b      buffer picker",
        "Space c h    cheatsheet",
        "Space e      focus/toggle tree",
        "Space f f    find files",
        "Space f w    live grep",
        "Space t      theme picker",
        "Space x      close buffer",
        "Alt-h        terminal split",
        "Alt-v        vertical terminal",
        "Alt-i        floating terminal",
        "Ctrl-n       toggle tree",
        "Ctrl-h       focus tree",
        "Ctrl-l       focus editor",
        "Ctrl-o/i     jumplist back/fwd",
        "Ctrl-d/u     half-page down/up",
        "/ then n/N   search / next/prev",
        "]c / [c      next/prev git hunk",
        "gg / G       top / bottom",
        "v / V        visual / line select",
        "y d p        yank / delete / put",
        "dd           delete line",
        "i / Esc      insert / normal mode",
        ":w :q :wq    write / quit",
    };

    pub fn init(alloc: std.mem.Allocator) Editor {
        var self: Editor = .{ .alloc = alloc, .tree = Tree.init(alloc) };
        self.loadGitBranch();
        return self;
    }

    /// Read the current branch from .git/HEAD (NvChad statusline segment).
    fn loadGitBranch(self: *Editor) void {
        var buf: [512]u8 = undefined;
        const head = std.fs.cwd().readFile(".git/HEAD", &buf) catch return;
        const trimmed = std.mem.trimRight(u8, head, "\r\n");
        const name = if (std.mem.startsWith(u8, trimmed, "ref: "))
            std.fs.path.basename(trimmed[5..])
        else if (trimmed.len >= 7)
            trimmed[0..7] // detached HEAD: short hash
        else
            return;
        const n = @min(name.len, self.git_branch.len);
        @memcpy(self.git_branch[0..n], name[0..n]);
        self.git_branch_len = n;
    }

    /// Rebuild per-line git signs for `b` by parsing `git diff -U0 HEAD -- file`
    /// hunk headers (gitsigns-style). Silently no-ops outside a repo or for
    /// untracked files (diff exits non-zero / prints nothing useful).
    fn refreshGitSigns(self: *Editor, b: *Buffer) void {
        b.git_signs.clearRetainingCapacity();
        const res = std.process.Child.run(.{
            .allocator = self.alloc,
            .argv = &.{ "git", "diff", "--no-color", "-U0", "HEAD", "--", b.file_name },
            .max_output_bytes = 1 << 20,
        }) catch return;
        defer self.alloc.free(res.stdout);
        defer self.alloc.free(res.stderr);
        if (res.term != .Exited or res.term.Exited != 0) return;

        b.git_signs.appendNTimes(self.alloc, .none, b.lines.items.len) catch return;
        var it = std.mem.tokenizeScalar(u8, res.stdout, '\n');
        while (it.next()) |line| {
            // @@ -old_start[,old_count] +new_start[,new_count] @@
            if (!std.mem.startsWith(u8, line, "@@ ")) continue;
            const plus = std.mem.indexOfScalar(u8, line, '+') orelse continue;
            const rest = line[plus + 1 ..];
            const end = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
            const spec = rest[0..end];
            var new_start: usize = 0;
            var new_count: usize = 1;
            if (std.mem.indexOfScalar(u8, spec, ',')) |comma| {
                new_start = std.fmt.parseInt(usize, spec[0..comma], 10) catch continue;
                new_count = std.fmt.parseInt(usize, spec[comma + 1 ..], 10) catch continue;
            } else {
                new_start = std.fmt.parseInt(usize, spec, 10) catch continue;
            }
            const minus_spec = blk: { // old side, to tell adds from changes
                const sp = std.mem.indexOfScalar(u8, line[3..], ' ') orelse break :blk line[4..];
                break :blk line[4 .. 3 + sp];
            };
            var old_count: usize = 1;
            if (std.mem.indexOfScalar(u8, minus_spec, ',')) |comma|
                old_count = std.fmt.parseInt(usize, minus_spec[comma + 1 ..], 10) catch 1;

            if (new_count == 0) {
                // pure deletion: mark the line the hunk lands after
                const row = if (new_start > 0) new_start - 1 else 0;
                if (row < b.git_signs.items.len) b.git_signs.items[row] = .delete;
                continue;
            }
            const sign: Buffer.Sign = if (old_count == 0) .add else .change;
            var i: usize = new_start - 1;
            const stop = @min(i + new_count, b.git_signs.items.len);
            while (i < stop) : (i += 1) b.git_signs.items[i] = sign;
        }
    }

    pub fn deinit(self: *Editor) void {
        for (self.buffers.items) |*b| b.deinit();
        self.buffers.deinit(self.alloc);
        self.jumps.deinit(self.alloc);
        self.reg.deinit(self.alloc);
        self.cmd.deinit(self.alloc);
        self.search.deinit(self.alloc);
        self.popup.filter.deinit(self.alloc);
        self.clearFiles();
        self.files.deinit(self.alloc);
        self.clearGrep();
        self.grep_hits.deinit(self.alloc);
        self.tree.deinit();
        for (&self.macros) |*m| m.deinit(self.alloc);
        self.dot.deinit(self.alloc);
        self.dot_rec.deinit(self.alloc);
        if (self.term) |*t| t.deinit();
    }

    pub fn widget(self: *Editor) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn cur(self: *Editor) *Buffer {
        return &self.buffers.items[self.active];
    }

    // ---- buffer management ------------------------------------------------

    /// Open `path` (or focus it if already open). Missing files start empty.
    pub fn openFile(self: *Editor, path: []const u8) !void {
        for (self.buffers.items, 0..) |*b, i| {
            if (std.mem.eql(u8, b.file_name, path)) {
                if (i != self.active) self.pushJump();
                self.active = i;
                return;
            }
        }
        self.pushJump();
        const contents = std.fs.cwd().readFileAlloc(self.alloc, path, 64 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => try self.alloc.dupe(u8, ""),
            else => {
                self.setStatus("could not read '{s}': {s}", .{ path, @errorName(err) });
                return;
            },
        };
        defer self.alloc.free(contents);
        const buffer = try Buffer.init(self.alloc, path, contents, self.theme);
        try self.buffers.append(self.alloc, buffer);
        self.active = self.buffers.items.len - 1;
        self.refreshGitSigns(self.cur());
    }

    fn cycleBuffer(self: *Editor, delta: isize) void {
        const n = self.buffers.items.len;
        if (n < 2) return;
        const i: isize = @intCast(self.active);
        self.active = @intCast(@mod(i + delta, @as(isize, @intCast(n))));
    }

    /// Close the active buffer; quits when it was the last one.
    fn closeBuffer(self: *Editor, ctx: *vxfw.EventContext, force: bool) void {
        if (self.buffers.items.len == 0) {
            ctx.quit = true; // :q on the dashboard quits
            return;
        }
        const b = self.cur();
        if (b.dirty and !force) {
            self.setStatus("unsaved changes in {s} (add ! to discard)", .{b.displayName()});
            return;
        }
        var removed = self.buffers.orderedRemove(self.active);
        removed.deinit();
        if (self.buffers.items.len == 0) {
            self.active = 0; // back to the dashboard; :q there quits
            self.mode = .normal;
            return;
        }
        self.active = @min(self.active, self.buffers.items.len - 1);
    }

    fn switchTheme(self: *Editor, arg: ?[]const u8) !void {
        const t = if (arg) |name|
            themes.find(name) orelse return self.setStatus("no theme '{s}' ({s})", .{ name, themes.names })
        else
            themes.next(self.theme);
        try self.setTheme(t);
    }

    fn setTheme(self: *Editor, t: *const themes.Theme) !void {
        self.theme = t;
        for (self.buffers.items) |*b| try b.hl.setTheme(t, b.buf.items);
        self.setStatus("theme: {s}", .{t.name});
    }

    // ---- status line ------------------------------------------------------

    fn setStatus(self: *Editor, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.bufPrint(&self.status_buf, fmt, args) catch return;
        self.status_len = msg.len;
    }

    fn save(self: *Editor) void {
        const b = self.cur();
        b.save() catch |err| {
            self.setStatus("write failed: {s}", .{@errorName(err)});
            return;
        };
        self.setStatus("\"{s}\" {d}L, {d}B written", .{ b.file_name, b.lines.items.len, b.buf.items.len });
        self.refreshGitSigns(b);
    }

    // ---- popup ------------------------------------------------------------

    fn openPopup(self: *Editor, kind: Popup.Kind) void {
        if (kind == .files or kind == .grep) self.refreshFiles();
        if (kind == .grep) self.clearGrep();
        self.popup.kind = kind;
        self.popup.selected = 0;
        self.popup.filter.clearRetainingCapacity();
    }

    fn clearFiles(self: *Editor) void {
        for (self.files.items) |p| self.alloc.free(p);
        self.files.clearRetainingCapacity();
    }

    fn refreshFiles(self: *Editor) void {
        self.clearFiles();
        Tree.listFiles(self.alloc, &self.files, Popup.max_files) catch {};
    }

    fn closePopup(self: *Editor) void {
        self.popup.kind = .none;
    }

    fn clearGrep(self: *Editor) void {
        for (self.grep_hits.items) |h| {
            self.alloc.free(h.path);
            self.alloc.free(h.disp);
        }
        self.grep_hits.clearRetainingCapacity();
    }

    /// Re-run the project-wide search for the current popup filter.
    /// Case-insensitive substring match, first Popup.max_items hits win.
    fn refreshGrep(self: *Editor) void {
        self.clearGrep();
        const q = self.popup.filter.items;
        self.popup.selected = 0;
        if (q.len < 2) return; // avoid scanning everything on 1 char
        outer: for (self.files.items) |path| {
            const data = std.fs.cwd().readFileAlloc(self.alloc, path, Popup.max_file_size) catch continue;
            defer self.alloc.free(data);
            if (std.mem.indexOfScalar(u8, data, 0) != null) continue; // binary
            var it = std.mem.splitScalar(u8, data, '\n');
            var ln: usize = 1;
            while (it.next()) |raw| : (ln += 1) {
                const line = std.mem.trim(u8, raw, " \t\r");
                if (!containsIgnoreCase(line, q)) continue;
                var end: usize = @min(line.len, 80);
                while (end > 0 and line[end - 1] >= 0x80 and line[end - 1] < 0xC0) end -= 1; // utf-8 boundary
                if (end > 0 and end < line.len and line[end - 1] >= 0xC0) end -= 1;
                const disp = std.fmt.allocPrint(self.alloc, "{s}:{d}: {s}", .{ path, ln, line[0..end] }) catch continue;
                const p = self.alloc.dupe(u8, path) catch {
                    self.alloc.free(disp);
                    continue;
                };
                self.grep_hits.append(self.alloc, .{ .path = p, .line = ln, .disp = disp }) catch {
                    self.alloc.free(p);
                    self.alloc.free(disp);
                    return;
                };
                if (self.grep_hits.items.len >= Popup.max_items) break :outer;
            }
        }
    }

    /// Open `path` and place the cursor on `line` (1-based), roughly centered.
    fn jumpTo(self: *Editor, path: []const u8, line: usize) void {
        self.openFile(path) catch {
            self.setStatus("could not open {s}", .{path});
            return;
        };
        if (self.buffers.items.len == 0) return; // open failed softly
        const b = self.cur();
        b.row = @min(line -| 1, b.lines.items.len -| 1);
        b.col = b.firstNonWs(b.row);
        b.goal_col = b.col;
        b.clampCol(false);
        b.scroll = b.row -| (self.last_height / 2);
    }

    fn popupTitle(self: *const Editor) []const u8 {
        return switch (self.popup.kind) {
            .buffers => " Buffers ",
            .themes => " Themes ",
            .files => " Find Files ",
            .keys => " Cheatsheet ",
            .grep => " Live Grep ",
            .none => "",
        };
    }

    fn popupItemCount(self: *const Editor) usize {
        return switch (self.popup.kind) {
            .buffers => self.buffers.items.len,
            .themes => themes.list.len,
            .files => self.files.items.len,
            .keys => cheats.len,
            .grep => self.grep_hits.items.len,
            .none => 0,
        };
    }

    fn popupItemName(self: *const Editor, i: usize) []const u8 {
        return switch (self.popup.kind) {
            .buffers => self.buffers.items[i].displayName(),
            .themes => themes.list[i].name,
            .files => self.files.items[i],
            .keys => cheats[i],
            .grep => self.grep_hits.items[i].disp,
            .none => "",
        };
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;
        var i: usize = 0;
        outer: while (i + needle.len <= haystack.len) : (i += 1) {
            for (needle, 0..) |nb, j| {
                if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nb)) continue :outer;
            }
            return true;
        }
        return false;
    }

    /// Indices of items matching the filter, capped at Popup.max_items.
    fn popupMatches(self: *const Editor, out: *[Popup.max_items]usize) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.popupItemCount() and n < out.len) : (i += 1) {
            if (containsIgnoreCase(self.popupItemName(i), self.popup.filter.items)) {
                out[n] = i;
                n += 1;
            }
        }
        return n;
    }

    fn handlePopup(self: *Editor, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        var matches: [Popup.max_items]usize = undefined;
        const n = self.popupMatches(&matches);

        if (key.matches(vaxis.Key.escape, .{})) {
            self.closePopup();
        } else if (key.matches(vaxis.Key.enter, .{})) {
            if (n > 0) {
                const idx = matches[@min(self.popup.selected, n - 1)];
                const kind = self.popup.kind;
                self.closePopup();
                switch (kind) {
                    .buffers => self.active = idx,
                    .themes => try self.setTheme(&themes.list[idx]),
                    .files => self.openFile(self.files.items[idx]) catch {
                        self.setStatus("could not open {s}", .{self.files.items[idx]});
                    },
                    .grep => {
                        const h = self.grep_hits.items[idx];
                        self.jumpTo(h.path, h.line);
                    },
                    .keys => {},
                    .none => {},
                }
            } else self.closePopup();
        } else if (key.matches(vaxis.Key.down, .{}) or
            key.matches('n', .{ .ctrl = true }) or key.matches('j', .{ .ctrl = true }))
        {
            if (n > 0) self.popup.selected = @min(self.popup.selected + 1, n - 1);
        } else if (key.matches(vaxis.Key.up, .{}) or
            key.matches('p', .{ .ctrl = true }) or key.matches('k', .{ .ctrl = true }))
        {
            self.popup.selected -|= 1;
        } else if (key.matches(vaxis.Key.backspace, .{})) {
            _ = self.popup.filter.pop();
            self.popup.selected = 0;
            if (self.popup.kind == .grep) self.refreshGrep();
        } else if (!key.mods.ctrl and !key.mods.alt) {
            const text = key.text orelse return;
            try self.popup.filter.appendSlice(self.alloc, text);
            self.popup.selected = 0;
            if (self.popup.kind == .grep) self.refreshGrep();
        }
        ctx.consumeAndRedraw();
    }

    // ---- events -----------------------------------------------------------

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => return ctx.requestFocus(self.widget()),
            .tick => {
                if (self.term_view != .none) {
                    if (self.term) |*t| {
                        if (t.poll()) ctx.redraw = true;
                    }
                    try ctx.tick(80, self.widget());
                }
                return;
            },
            .mouse => |m| return self.handleMouse(ctx, m),
            .key_press => |key| {
                self.status_len = 0;
                // Record live keys into the active macro register. The `q`
                // that stops recording is popped again in handleNormal.
                if (self.recording != null and self.replay_depth == 0)
                    try self.macros[self.recording.? - 'a'].append(self.alloc, key);
                if (self.replay_depth == 0) self.dotWatch(key);
                try self.dispatchKey(ctx, key);
                if (self.replay_depth == 0) self.dotSettle();
            },
            else => {},
        }
    }

    /// Route one key press by focus/mode; shared by live input and macro replay.
    fn dispatchKey(self: *Editor, ctx: *vxfw.EventContext, key: vaxis.Key) anyerror!void {
        {
                if (self.popup.kind != .none) return self.handlePopup(ctx, key);
                // NvTerm: Alt-h bottom split, Alt-v vertical split, Alt-i float.
                if (key.mods.alt and (key.codepoint == 'h' or key.codepoint == 'H'))
                    return self.toggleTerm(ctx, .split);
                if (key.mods.alt and (key.codepoint == 'v' or key.codepoint == 'V'))
                    return self.toggleTerm(ctx, .vert);
                if (key.mods.alt and (key.codepoint == 'i' or key.codepoint == 'I'))
                    return self.toggleTerm(ctx, .float);
                if (self.focus == .term)
                    return self.handleTerm(ctx, key);
                if (self.focus == .tree and self.mode != .command)
                    return self.handleTree(ctx, key);
                if (self.buffers.items.len == 0 and self.mode != .command)
                    return self.handleDash(ctx, key);
                switch (self.mode) {
                    .normal => try self.handleNormal(ctx, key),
                    .insert => try self.handleInsert(ctx, key),
                    .command => try self.handleCommand(ctx, key),
                    .visual, .visual_line => try self.handleVisual(ctx, key),
                }
        }
    }

    /// Record the current position before a "big" jump (G/gg, n/N, marks,
    /// file switches). Truncates any forward (Ctrl-i) history, vim-style.
    fn pushJump(self: *Editor) void {
        if (self.buffers.items.len == 0) return;
        const b = self.cur();
        self.jumps.shrinkRetainingCapacity(self.jump_idx);
        if (self.jumps.items.len > 0) {
            const last = self.jumps.items[self.jumps.items.len - 1];
            if (last.buf == self.active and last.row == b.row) {
                self.jump_idx = self.jumps.items.len;
                return;
            }
        }
        if (self.jumps.items.len >= 100) _ = self.jumps.orderedRemove(0);
        self.jumps.append(self.alloc, .{ .buf = self.active, .row = b.row, .col = b.col }) catch {};
        self.jump_idx = self.jumps.items.len;
    }

    /// Ctrl-o: walk back through the jumplist.
    fn jumpBack(self: *Editor) void {
        if (self.jump_idx == 0) return;
        // First step back: pin the current spot so Ctrl-i can return to it.
        if (self.jump_idx == self.jumps.items.len) {
            const b = self.cur();
            self.jumps.append(self.alloc, .{ .buf = self.active, .row = b.row, .col = b.col }) catch return;
        }
        self.jump_idx -= 1;
        self.gotoJump(self.jumps.items[self.jump_idx]);
    }

    /// Ctrl-i: walk forward again.
    fn jumpFwd(self: *Editor) void {
        if (self.jump_idx + 1 >= self.jumps.items.len) return;
        self.jump_idx += 1;
        self.gotoJump(self.jumps.items[self.jump_idx]);
    }

    fn gotoJump(self: *Editor, j: Jump) void {
        if (j.buf < self.buffers.items.len) self.active = j.buf;
        const b = self.cur();
        b.row = @min(j.row, b.lastRow());
        b.col = j.col;
        b.clampCol(false);
        b.goal_col = @intCast(b.col);
    }

    /// `%`: jump to the matching bracket. Vim-style: scan right from the
    /// cursor to the first bracket on the line, then walk the buffer with a
    /// nesting depth counter. Pushes the jumplist on success.
    fn matchPair(self: *Editor) void {
        const b = self.cur();
        const text = b.buf.items;
        const pairs = "()[]{}";
        const line_start = b.lines.items[b.row].start;
        const line_end = line_start + b.lineLen(b.row);
        var pos = line_start + @min(b.col, b.lineLen(b.row));
        while (pos < line_end and std.mem.indexOfScalar(u8, pairs, text[pos]) == null) pos += 1;
        if (pos >= line_end) return self.setStatus("no matching pair", .{});
        const c = text[pos];
        const idx = std.mem.indexOfScalar(u8, pairs, c).?;
        const fwd = idx % 2 == 0;
        const other = if (fwd) pairs[idx + 1] else pairs[idx - 1];
        var depth: u32 = 0;
        var p = pos;
        while (true) {
            if (text[p] == c) depth += 1 else if (text[p] == other) {
                depth -= 1;
                if (depth == 0) break;
            }
            if (fwd) {
                p += 1;
                if (p >= text.len) return self.setStatus("no matching pair", .{});
            } else {
                if (p == 0) return self.setStatus("no matching pair", .{});
                p -= 1;
            }
        }
        self.pushJump();
        b.setCursorFromByte(p);
    }

    /// Consume the pending count prefix (defaults to 1).
    fn takeCount(self: *Editor) u32 {
        const n = if (self.count == 0) 1 else self.count;
        self.count = 0;
        return n;
    }

    /// Dot-repeat capture: when a change-starting key arrives in plain normal
    /// mode, start recording keys until the editor settles back into normal
    /// mode (covers single-key edits and whole insert sessions alike).
    fn dotWatch(self: *Editor, key: vaxis.Key) void {
        if (!self.dot_capturing) {
            if (self.focus != .editor or self.mode != .normal) return;
            if (self.pending != .none or self.popup.kind != .none) return;
            if (self.buffers.items.len == 0) return;
            if (key.mods.ctrl or key.mods.alt) return;
            const cp = key.shifted_codepoint orelse key.codepoint;
            switch (cp) {
                'x', 'r', '~', 'J', 'p', 'o', 'O', 'i', 'a', 'A', 'I', 'd' => {},
                else => return,
            }
            self.dot_capturing = true;
            self.dot_rec.clearRetainingCapacity();
            // Fold an active count prefix into the capture so `.` repeats
            // e.g. `3x` in full.
            if (self.count > 0) {
                var digits: [8]u8 = undefined;
                const s = std.fmt.bufPrint(&digits, "{d}", .{self.count}) catch "";
                for (s) |c| self.dot_rec.append(
                    self.alloc,
                    .{ .codepoint = c },
                ) catch {};
            }
        }
        self.dot_rec.append(self.alloc, key) catch {};
    }

    /// Commit the in-progress dot capture once a change has completed.
    fn dotSettle(self: *Editor) void {
        if (!self.dot_capturing) return;
        if (self.mode != .normal or self.pending != .none) return;
        self.dot_capturing = false;
        std.mem.swap(std.ArrayListUnmanaged(vaxis.Key), &self.dot, &self.dot_rec);
    }

    /// Replay the last change (`.`).
    fn playDot(self: *Editor, ctx: *vxfw.EventContext) !void {
        if (self.dot.items.len == 0 or self.replay_depth >= 8) return;
        self.replay_depth += 1;
        defer self.replay_depth -= 1;
        const keys = try self.alloc.dupe(vaxis.Key, self.dot.items);
        defer self.alloc.free(keys);
        for (keys) |k| try self.dispatchKey(ctx, k);
    }

    /// Replay a recorded macro register through the normal key dispatch path.
    fn playMacro(self: *Editor, ctx: *vxfw.EventContext, idx: u8) !void {
        if (self.replay_depth >= 8) return; // recursion guard for @-in-macro
        self.replay_depth += 1;
        defer self.replay_depth -= 1;
        // Replay a copy: dispatched keys could start a re-record (`q`) that
        // clears the very register we are iterating.
        const keys = try self.alloc.dupe(vaxis.Key, self.macros[idx].items);
        defer self.alloc.free(keys);
        for (keys) |k| try self.dispatchKey(ctx, k);
    }

    /// Keys on the NvDash-style start screen (no buffers open).
    fn handleDash(self: *Editor, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        const cp = key.shifted_codepoint orelse key.codepoint;
        if (key.mods.ctrl) {
            switch (cp) {
                'c' => ctx.quit = true,
                'n' => self.toggleTree(),
                else => return,
            }
            return ctx.consumeAndRedraw();
        }
        switch (cp) {
            'f' => self.openPopup(.files),
            'w', 'g' => self.openPopup(.grep),
            't' => self.openPopup(.themes),
            'h' => self.openPopup(.keys),
            'e' => self.toggleTree(),
            'q' => ctx.quit = true,
            ':' => {
                self.mode = .command;
                self.cmd_is_search = false;
                self.cmd.clearRetainingCapacity();
            },
            else => return,
        }
        ctx.consumeAndRedraw();
    }

    /// Display width of a line's leading whitespace, or null for blank lines.
    fn lineIndentWidth(b: *const Buffer, li: usize) ?u16 {
        const line = b.lines.items[li];
        const text = b.buf.items[line.start..line.end];
        var w: u16 = 0;
        for (text) |ch| {
            switch (ch) {
                ' ' => w += 1,
                '\t' => w = (w / 4 + 1) * 4,
                else => return w,
            }
        }
        return null; // empty or whitespace-only
    }

    /// Guide depth for a row: its own indent, or for blank lines the indent
    /// of the surrounding block so guides continue through gaps
    /// (indent-blankline behavior).
    fn guideWidthFor(b: *const Buffer, li: usize) u16 {
        if (lineIndentWidth(b, li)) |w| return w;
        var prev: u16 = 0;
        var next: u16 = 0;
        var i = li;
        while (i > 0) {
            i -= 1;
            if (lineIndentWidth(b, i)) |w| {
                prev = w;
                break;
            }
        }
        var j = li + 1;
        while (j < b.lines.items.len) : (j += 1) {
            if (lineIndentWidth(b, j)) |w| {
                next = w;
                break;
            }
        }
        return @min(prev, next);
    }

    /// gitsigns-style `]c` / `[c`: jump to the next/previous hunk start, wrapping.
    fn jumpHunk(self: *Editor, dir: i2) void {
        const b = self.cur();
        const signs = b.git_signs.items;
        var total: usize = 0;
        var target: ?usize = null;
        var target_n: usize = 0;
        var first: usize = 0;
        var last: usize = 0;
        var row: usize = 0;
        while (row < signs.len) : (row += 1) {
            if (signs[row] == .none) continue;
            if (row > 0 and signs[row - 1] != .none) continue; // not a hunk start
            total += 1;
            if (total == 1) first = row;
            last = row;
            if (dir > 0) {
                if (row > b.row and target == null) {
                    target = row;
                    target_n = total;
                }
            } else if (row < b.row) {
                target = row;
                target_n = total;
            }
        }
        if (total == 0) {
            self.setStatus("no hunks", .{});
            return;
        }
        var n = target_n;
        const dest = target orelse blk: {
            // Wrap around, like gitsigns nav_hunk.
            if (dir > 0) {
                n = 1;
                break :blk first;
            }
            n = total;
            break :blk last;
        };
        b.row = dest;
        b.clampCol(false);
        self.setStatus("hunk {d}/{d}", .{ n, total });
    }

    fn handleNormal(self: *Editor, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        const b = self.cur();
        // Effective character: kitty reports 'g'+shift with shifted 'G',
        // legacy terminals report 'G' directly.
        const cp = key.shifted_codepoint orelse key.codepoint;

        switch (self.pending) {
            .none => {},
            .g => {
                self.pending = .none;
                if (cp == 'g') {
                    self.pushJump();
                    b.row = 0;
                    b.col = 0;
                    b.goal_col = 0;
                } else if (cp == 'v') {
                    self.reselectVisual();
                }
                return ctx.consumeAndRedraw();
            },
            .d => {
                self.pending = .none;
                const n = self.takeCount();
                if (cp == 'd') for (0..n) |_| try b.deleteLine();
                return ctx.consumeAndRedraw();
            },
            .mark_set => {
                self.pending = .none;
                if (cp >= 'a' and cp <= 'z')
                    b.marks[@intCast(cp - 'a')] = .{ .row = b.row, .col = b.col };
                return ctx.consumeAndRedraw();
            },
            .mark_exact, .mark_line => {
                const line_only = self.pending == .mark_line;
                self.pending = .none;
                if (cp >= 'a' and cp <= 'z') {
                    if (b.marks[@intCast(cp - 'a')]) |mk| {
                        self.pushJump();
                        b.row = @min(mk.row, b.lastRow());
                        b.col = mk.col;
                        b.clampCol(false);
                        if (line_only) b.col = b.firstNonWs(b.row);
                        b.goal_col = b.col;
                    } else self.setStatus("mark not set", .{});
                }
                return ctx.consumeAndRedraw();
            },
            .macro_rec => {
                self.pending = .none;
                if (cp >= 'a' and cp <= 'z') {
                    self.recording = @intCast(cp);
                    self.macros[@intCast(cp - 'a')].clearRetainingCapacity();
                }
                return ctx.consumeAndRedraw();
            },
            .macro_play => {
                self.pending = .none;
                const reg: u21 = if (cp == '@') (self.last_macro orelse {
                    self.setStatus("no previous macro", .{});
                    return ctx.consumeAndRedraw();
                }) else cp;
                if (reg >= 'a' and reg <= 'z') {
                    self.last_macro = @intCast(reg);
                    try self.playMacro(ctx, @intCast(reg - 'a'));
                }
                return ctx.consumeAndRedraw();
            },
            .replace_char => {
                self.pending = .none;
                if (cp != vaxis.Key.escape and cp >= 0x20) {
                    var utf8_buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(@intCast(cp), &utf8_buf) catch
                        return ctx.consumeAndRedraw();
                    try b.replaceCharAtCursor(utf8_buf[0..n]);
                }
                return ctx.consumeAndRedraw();
            },
            .leader => {
                self.pending = .none;
                switch (cp) {
                    'b' => self.openPopup(.buffers),
                    'c' => self.pending = .leader_c,
                    'e' => self.toggleTree(),
                    'f' => self.pending = .leader_f,
                    't' => self.openPopup(.themes),
                    'x' => self.closeBuffer(ctx, false),
                    '/' => b.toggleComment() catch {},
                    else => {},
                }
                return ctx.consumeAndRedraw();
            },
            .leader_f => {
                self.pending = .none;
                switch (cp) {
                    'f' => self.openPopup(.files),
                    'w' => self.openPopup(.grep),
                    else => {},
                }
                return ctx.consumeAndRedraw();
            },
            .leader_c => {
                self.pending = .none;
                switch (cp) {
                    'h' => self.openPopup(.keys),
                    else => {},
                }
                return ctx.consumeAndRedraw();
            },
            .bracket_f => {
                self.pending = .none;
                if (cp == 'c') self.jumpHunk(1);
                return ctx.consumeAndRedraw();
            },
            .bracket_b => {
                self.pending = .none;
                if (cp == 'c') self.jumpHunk(-1);
                return ctx.consumeAndRedraw();
            },
        }

        if (key.mods.alt) return;
        const half: i64 = @max(1, self.last_height / 2);

        if (key.mods.ctrl) {
            switch (cp) {
                'c' => ctx.quit = true,
                'd' => b.moveVert(half, false),
                'u' => b.moveVert(-half, false),
                'n' => self.toggleTree(),
                'o' => self.jumpBack(),
                'i' => self.jumpFwd(),
                'h' => if (self.tree_open) {
                    self.focus = .tree;
                },
                else => return,
            }
            return ctx.consumeAndRedraw();
        }

        // Count prefix: accumulate digits ('0' only extends an existing count,
        // otherwise it stays the line-start motion).
        if (!key.mods.ctrl and !key.mods.alt and
            cp >= '0' and cp <= '9' and (cp != '0' or self.count > 0))
        {
            self.count = @min(self.count * 10 + @as(u32, @intCast(cp - '0')), 99999);
            return ctx.consumeAndRedraw();
        }
        const n: u32 = @max(self.count, 1);

        switch (cp) {
            vaxis.Key.tab => if (key.mods.shift) self.cycleBuffer(-1) else self.cycleBuffer(1),
            ' ' => self.pending = .leader,
            'h', vaxis.Key.left => for (0..n) |_| b.moveLeft(),
            'l', vaxis.Key.right => for (0..n) |_| b.moveRight(false),
            'j', vaxis.Key.down => b.moveVert(n, false),
            'k', vaxis.Key.up => b.moveVert(-@as(i64, n), false),
            vaxis.Key.page_down => b.moveVert(half, false),
            vaxis.Key.page_up => b.moveVert(-half, false),
            'w' => for (0..n) |_| b.wordForward(),
            'b' => for (0..n) |_| b.wordBackward(),
            'e' => for (0..n) |_| b.wordEnd(),
            '0', vaxis.Key.home => {
                b.col = 0;
                b.goal_col = 0;
            },
            '^' => {
                b.col = b.firstNonWs(b.row);
                b.goal_col = b.col;
            },
            '%' => self.matchPair(),
            '$', vaxis.Key.end => {
                const len = b.lineLen(b.row);
                b.col = if (len == 0) 0 else Buffer.snapToCp(b.lineText(b.row), len - 1);
                b.goal_col = std.math.maxInt(u32);
            },
            'g' => self.pending = .g,
            'G' => {
                // `nG` jumps to line n; bare G goes to the last line.
                self.pushJump();
                b.row = if (self.count > 0) @min(self.count - 1, b.lastRow()) else b.lastRow();
                b.clampCol(false);
            },
            'J' => {
                // `nJ` joins n lines (= n-1 joins, minimum one).
                for (0..@max(n -| 1, 1)) |_| {
                    if (try b.joinLines(b.row)) |jc| {
                        b.col = if (jc > 0) Buffer.snapToCp(b.lineText(b.row), jc) else 0;
                        b.goal_col = @intCast(b.col);
                    } else break;
                }
            },
            'd' => self.pending = .d,
            ']' => self.pending = .bracket_f,
            '[' => self.pending = .bracket_b,
            'm' => self.pending = .mark_set,
            '`' => self.pending = .mark_exact,
            '\'' => self.pending = .mark_line,
            'q' => {
                if (self.recording) |r| {
                    // Drop the just-recorded stop key, then finish.
                    _ = self.macros[r - 'a'].pop();
                    self.recording = null;
                    self.setStatus("recorded @{c}", .{r});
                } else self.pending = .macro_rec;
            },
            '@' => self.pending = .macro_play,
            '/' => {
                self.mode = .command;
                self.cmd_is_search = true;
                self.cmd.clearRetainingCapacity();
            },
            'n' => self.findNext(1),
            'N' => self.findNext(-1),
            '*' => self.searchWord(1),
            '#' => self.searchWord(-1),
            'x' => for (0..n) |_| try b.deleteCharAtCursor(),
            'r' => self.pending = .replace_char,
            '~' => for (0..n) |_| try b.toggleCaseAtCursor(),
            '.' => try self.playDot(ctx),
            'v' => self.enterVisual(.visual),
            'V' => self.enterVisual(.visual_line),
            'p' => for (0..n) |_| try self.pasteAfter(),
            'i' => self.mode = .insert,
            'a' => {
                self.mode = .insert;
                const len = b.lineLen(b.row);
                if (len > 0) b.col = @min(b.col + b.cpLenAt(b.row, b.col), len);
            },
            'A' => {
                self.mode = .insert;
                b.col = b.lineLen(b.row);
            },
            'I' => {
                self.mode = .insert;
                b.col = b.firstNonWs(b.row);
            },
            'o' => {
                const pos = b.lines.items[b.row].end;
                try b.replaceRange(pos, pos, "\n");
                b.row += 1;
                b.col = 0;
                b.goal_col = 0;
                self.mode = .insert;
            },
            'O' => {
                const pos = b.lines.items[b.row].start;
                try b.replaceRange(pos, pos, "\n");
                b.col = 0;
                b.goal_col = 0;
                self.mode = .insert;
            },
            ':' => {
                self.mode = .command;
                self.cmd_is_search = false;
                self.cmd.clearRetainingCapacity();
            },
            vaxis.Key.escape => self.pending = .none,
            else => return,
        }
        // Non-digit key handled: a still-unset pending consumes the count later
        // (e.g. `2dd`); otherwise it is spent now.
        if (self.pending == .none) self.count = 0;
        ctx.consumeAndRedraw();
    }

    // ---- visual mode ------------------------------------------------------

    fn enterVisual(self: *Editor, m: Mode) void {
        const b = self.cur();
        self.vis_row = b.row;
        self.vis_col = b.col;
        self.mode = m;
    }

    /// Leave visual mode, remembering the selection for `gv`.
    fn exitVisual(self: *Editor) void {
        const b = self.cur();
        self.last_vis = .{
            .mode = self.mode,
            .ar = self.vis_row,
            .ac = self.vis_col,
            .cr = b.row,
            .cc = b.col,
        };
        self.mode = .normal;
    }

    /// `gv`: restore the last visual selection.
    fn reselectVisual(self: *Editor) void {
        const lv = self.last_vis orelse return;
        if (self.buffers.items.len == 0) return;
        const b = self.cur();
        const last = b.lines.items.len - 1;
        self.vis_row = @min(lv.ar, last);
        self.vis_col = @min(lv.ac, b.lineLen(self.vis_row));
        b.row = @min(lv.cr, last);
        b.col = lv.cc;
        b.clampCol(false);
        b.goal_col = @intCast(b.col);
        self.mode = lv.mode;
    }

    /// Byte range [start, end) of the current selection, or null.
    fn selRange(self: *Editor) ?[2]usize {
        if (self.mode != .visual and self.mode != .visual_line) return null;
        if (self.buffers.items.len == 0) return null;
        const b = self.cur();
        const ar = @min(self.vis_row, b.lines.items.len - 1);
        const ac = @min(self.vis_col, b.lineLen(ar));
        if (self.mode == .visual_line) {
            const lo = @min(ar, b.row);
            const hi = @max(ar, b.row);
            const end = b.lines.items[hi].end;
            return .{ b.lines.items[lo].start, @min(end + 1, b.buf.items.len) };
        }
        const a_first = ar < b.row or (ar == b.row and ac <= b.col);
        const sr = if (a_first) ar else b.row;
        const sc = if (a_first) ac else b.col;
        const er = if (a_first) b.row else ar;
        const ec = if (a_first) b.col else ac;
        const start = b.lines.items[sr].start + sc;
        const end = b.lines.items[er].start + ec + b.cpLenAt(er, ec);
        return .{ start, @min(end, b.buf.items.len) };
    }

    /// Copy the selection into the unnamed register.
    fn yankSel(self: *Editor, range: [2]usize) !void {
        const b = self.cur();
        self.reg.clearRetainingCapacity();
        try self.reg.appendSlice(self.alloc, b.buf.items[range[0]..range[1]]);
        self.reg_linewise = self.mode == .visual_line;
        // Linewise registers always carry a trailing newline (yank of the
        // last line has none in the buffer).
        if (self.reg_linewise and (self.reg.items.len == 0 or
            self.reg.items[self.reg.items.len - 1] != '\n'))
            try self.reg.append(self.alloc, '\n');
    }

    fn handleVisual(self: *Editor, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        const b = self.cur();
        const cp = key.shifted_codepoint orelse key.codepoint;
        const half: i64 = @max(1, self.last_height / 2);

        if (self.pending == .leader) {
            self.pending = .none;
            if (cp == '/') {
                const lo = @min(self.vis_row, b.row);
                const hi = @max(@min(self.vis_row, b.lines.items.len - 1), b.row);
                b.toggleCommentRows(lo, hi) catch {};
                self.exitVisual();
                b.row = @min(lo, b.lines.items.len - 1);
                b.col = b.firstNonWs(b.row);
                b.goal_col = @intCast(b.col);
            }
            return ctx.consumeAndRedraw();
        }

        if (key.mods.ctrl) {
            switch (cp) {
                'c' => ctx.quit = true,
                'd' => b.moveVert(half, false),
                'u' => b.moveVert(-half, false),
                else => return,
            }
            return ctx.consumeAndRedraw();
        }

        switch (cp) {
            vaxis.Key.escape => self.exitVisual(),
            ' ' => self.pending = .leader,
            'v' => if (self.mode == .visual) {
                self.exitVisual();
            } else {
                self.mode = .visual;
            },
            'V' => if (self.mode == .visual_line) {
                self.exitVisual();
            } else {
                self.mode = .visual_line;
            },
            'J' => {
                const lo = @min(self.vis_row, b.row);
                const hi = @max(@min(self.vis_row, b.lines.items.len - 1), b.row);
                var n = hi - lo;
                if (n == 0) n = 1; // single-line selection joins with the next
                var jc: ?usize = null;
                while (n > 0) : (n -= 1) {
                    jc = (try b.joinLines(lo)) orelse break;
                }
                self.exitVisual();
                b.row = @min(lo, b.lines.items.len - 1);
                if (jc) |c| b.col = if (c > 0) Buffer.snapToCp(b.lineText(b.row), c) else 0;
                b.goal_col = @intCast(b.col);
            },
            '<', '>' => {
                const lo = @min(self.vis_row, b.row);
                const hi = @max(@min(self.vis_row, b.lines.items.len - 1), b.row);
                b.indentRows(lo, hi, cp == '<') catch {};
                self.exitVisual();
                b.row = @min(lo, b.lines.items.len - 1);
                b.col = b.firstNonWs(b.row);
                b.goal_col = @intCast(b.col);
            },
            'o' => {
                // Swap anchor and cursor.
                const r = b.row;
                const c2 = b.col;
                b.row = @min(self.vis_row, b.lines.items.len - 1);
                b.col = @min(self.vis_col, b.lineLen(b.row));
                b.goal_col = @intCast(b.col);
                self.vis_row = r;
                self.vis_col = c2;
            },
            'y' => {
                if (self.selRange()) |r| {
                    try self.yankSel(r);
                    // Vim leaves the cursor at the start of the yanked text.
                    if (self.mode == .visual) {
                        if (self.vis_row < b.row or
                            (self.vis_row == b.row and self.vis_col < b.col))
                        {
                            b.row = self.vis_row;
                            b.col = self.vis_col;
                        }
                    } else {
                        b.row = @min(self.vis_row, b.row);
                    }
                    b.clampCol(false);
                }
                self.exitVisual();
            },
            'd', 'x' => {
                if (self.selRange()) |r| {
                    try self.yankSel(r);
                    const lo_row = @min(self.vis_row, b.row);
                    const lo_col = if (self.mode == .visual_line)
                        0
                    else if (self.vis_row < b.row or
                        (self.vis_row == b.row and self.vis_col < b.col))
                        self.vis_col
                    else
                        b.col;
                    try b.replaceRange(r[0], r[1], "");
                    b.row = @min(lo_row, b.lines.items.len - 1);
                    b.col = lo_col;
                    b.clampCol(false);
                    b.goal_col = @intCast(b.col);
                }
                self.exitVisual();
            },
            'h', vaxis.Key.left => b.moveLeft(),
            'l', vaxis.Key.right => b.moveRight(false),
            'j', vaxis.Key.down => b.moveVert(1, false),
            'k', vaxis.Key.up => b.moveVert(-1, false),
            'w' => b.wordForward(),
            'b' => b.wordBackward(),
            'e' => b.wordEnd(),
            '0', vaxis.Key.home => {
                b.col = 0;
                b.goal_col = 0;
            },
            '^' => {
                b.col = b.firstNonWs(b.row);
                b.goal_col = @intCast(b.col);
            },
            '%' => self.matchPair(),
            '$', vaxis.Key.end => {
                const len = b.lineLen(b.row);
                b.col = if (len == 0) 0 else Buffer.snapToCp(b.lineText(b.row), len - 1);
                b.goal_col = std.math.maxInt(u32);
            },
            'g' => {
                b.row = 0;
                b.col = 0;
                b.goal_col = 0;
            },
            'G' => {
                b.row = b.lastRow();
                b.clampCol(false);
            },
            else => return,
        }
        ctx.consumeAndRedraw();
    }

    /// `p` in normal mode: put the unnamed register after the cursor
    /// (charwise) or on a new line below (linewise).
    fn pasteAfter(self: *Editor) !void {
        if (self.reg.items.len == 0) return;
        const b = self.cur();
        if (self.reg_linewise) {
            const line = b.lines.items[b.row];
            if (line.end < b.buf.items.len) {
                try b.replaceRange(line.end + 1, line.end + 1, self.reg.items);
            } else {
                // Last line without trailing newline: lead with one, drop ours.
                const body = self.reg.items[0 .. self.reg.items.len - 1];
                const tmp = try std.mem.concat(self.alloc, u8, &.{ "\n", body });
                defer self.alloc.free(tmp);
                try b.replaceRange(line.end, line.end, tmp);
            }
            b.row += 1;
            b.col = b.firstNonWs(b.row);
            b.goal_col = @intCast(b.col);
        } else {
            const len = b.lineLen(b.row);
            const pos = b.lines.items[b.row].start +
                (if (len == 0) b.col else b.col + b.cpLenAt(b.row, b.col));
            try b.replaceRange(pos, pos, self.reg.items);
            if (std.mem.indexOfScalar(u8, self.reg.items, '\n') == null) {
                b.col = pos - b.lines.items[b.row].start + self.reg.items.len;
                b.col = Buffer.snapToCp(b.lineText(b.row), b.col -| 1);
                b.goal_col = @intCast(b.col);
            }
        }
    }

    fn handleInsert(self: *Editor, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        const b = self.cur();
        switch (key.codepoint) {
            vaxis.Key.escape => {
                self.mode = .normal;
                if (b.col > 0) b.col = Buffer.snapToCp(b.lineText(b.row), b.col - 1);
                b.clampCol(false);
                b.goal_col = b.col;
            },
            vaxis.Key.enter => try b.insertText("\n"),
            vaxis.Key.backspace => try b.backspace(),
            vaxis.Key.tab => try b.insertText("    "),
            else => {
                if (key.mods.ctrl or key.mods.alt) return;
                const text = key.text orelse return;
                try b.insertText(text);
            },
        }
        ctx.consumeAndRedraw();
    }

    fn handleCommand(self: *Editor, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        switch (key.codepoint) {
            vaxis.Key.escape => self.mode = .normal,
            vaxis.Key.enter => if (self.cmd_is_search) {
                self.mode = .normal;
                self.search.clearRetainingCapacity();
                try self.search.appendSlice(self.alloc, self.cmd.items);
                self.findNext(1);
            } else try self.execCommand(ctx),
            vaxis.Key.backspace => {
                if (self.cmd.items.len == 0) self.mode = .normal else _ = self.cmd.pop();
            },
            else => {
                const text = key.text orelse return;
                try self.cmd.appendSlice(self.alloc, text);
            },
        }
        ctx.consumeAndRedraw();
    }

    fn execCommand(self: *Editor, ctx: *vxfw.EventContext) !void {
        const s = self.cmd.items;
        self.mode = .normal;
        if (s.len == 0) return;

        if (try self.trySubstitute(s)) return;

        var it = std.mem.tokenizeScalar(u8, s, ' ');
        const head = it.next() orelse return;

        const Cmd = enum {
            q,
            @"q!",
            qa,
            @"qa!",
            w,
            wq,
            x,
            e,
            bn,
            bp,
            bd,
            @"bd!",
            ls,
            theme,
            themes,
        };
        if (std.meta.stringToEnum(Cmd, head)) |cmd| switch (cmd) {
            // :q closes the current buffer (quits when it is the last one).
            .q => self.closeBuffer(ctx, false),
            .@"q!" => self.closeBuffer(ctx, true),
            .qa => {
                for (self.buffers.items) |*b| {
                    if (b.dirty) return self.setStatus("unsaved changes in {s} (:qa! to discard)", .{b.displayName()});
                }
                ctx.quit = true;
            },
            .@"qa!" => ctx.quit = true,
            .w => {
                if (self.buffers.items.len == 0) return self.setStatus("no open buffer", .{});
                self.save();
            },
            .wq, .x => {
                if (self.buffers.items.len == 0) return self.setStatus("no open buffer", .{});
                self.save();
                if (!self.cur().dirty) self.closeBuffer(ctx, false);
            },
            .e => {
                const path = it.next() orelse return self.setStatus("usage: :e <path>", .{});
                try self.openFile(path);
            },
            .bn => self.cycleBuffer(1),
            .bp => self.cycleBuffer(-1),
            .bd => self.closeBuffer(ctx, false),
            .@"bd!" => self.closeBuffer(ctx, true),
            .ls => self.openPopup(.buffers),
            .theme => try self.switchTheme(it.next()),
            .themes => self.setStatus("themes: {s}", .{themes.names}),
        } else if (std.fmt.parseInt(usize, s, 10) catch null) |n| {
            if (self.buffers.items.len == 0) return;
            const b = self.cur();
            b.row = std.math.clamp(n -| 1, 0, b.lines.items.len - 1);
            b.clampCol(false);
        } else {
            self.setStatus("not an editor command: {s}", .{s});
        }
    }

    /// `:[range]s/pat/rep/[g]` — plain-text substitute (vim staple). Ranges:
    /// none (current line), `%` (whole file), `N,M` (1-based inclusive).
    /// Returns false when `s` is not a substitute command at all.
    fn trySubstitute(self: *Editor, s: []const u8) !bool {
        if (self.buffers.items.len == 0) return false;
        const b = self.cur();
        var i: usize = 0;
        var lo: usize = b.row;
        var hi: usize = b.row;
        if (i < s.len and s[i] == '%') {
            lo = 0;
            hi = b.lines.items.len - 1;
            i += 1;
        } else if (i < s.len and std.ascii.isDigit(s[i])) {
            var j = i;
            while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
            if (j >= s.len or s[j] != ',') return false;
            var k = j + 1;
            while (k < s.len and std.ascii.isDigit(s[k])) k += 1;
            if (k == j + 1) return false;
            const a = std.fmt.parseInt(usize, s[i..j], 10) catch return false;
            const c = std.fmt.parseInt(usize, s[j + 1 .. k], 10) catch return false;
            lo = @min(a -| 1, b.lines.items.len - 1);
            hi = @min(c -| 1, b.lines.items.len - 1);
            if (lo > hi) std.mem.swap(usize, &lo, &hi);
            i = k;
        }
        if (i + 1 >= s.len or s[i] != 's' or s[i + 1] != '/') return false;

        var parts = std.mem.splitScalar(u8, s[i + 2 ..], '/');
        const pat_raw = parts.next() orelse return false;
        if (pat_raw.len == 0) {
            self.setStatus("empty substitute pattern", .{});
            return true;
        }
        const rep_raw = parts.next() orelse "";
        const flags = parts.next() orelse "";
        const global = std.mem.indexOfScalar(u8, flags, 'g') != null;
        // Own the pattern/replacement: edits below invalidate `self.cmd` slices? No —
        // `s` aliases self.cmd which buffer edits never touch, so slices stay valid.
        const pat = pat_raw;
        const rep = rep_raw;

        var count: usize = 0;
        var last_hit: ?usize = null;
        var row = lo;
        while (row <= hi and row < b.lines.items.len) : (row += 1) {
            const text = self.alloc.dupe(u8, b.lineText(row)) catch return true;
            defer self.alloc.free(text);
            var scratch: std.ArrayListUnmanaged(u8) = .{};
            defer scratch.deinit(self.alloc);
            var pos: usize = 0;
            var line_hits: usize = 0;
            while (std.mem.indexOfPos(u8, text, pos, pat)) |p| {
                try scratch.appendSlice(self.alloc, text[pos..p]);
                try scratch.appendSlice(self.alloc, rep);
                pos = p + pat.len;
                line_hits += 1;
                if (!global) break;
            }
            if (line_hits == 0) continue;
            try scratch.appendSlice(self.alloc, text[pos..]);
            const line = b.lines.items[row];
            try b.replaceRange(line.start, line.end, scratch.items);
            count += line_hits;
            last_hit = row;
        }
        if (last_hit) |r| {
            b.row = r;
            b.clampCol(false);
            b.goal_col = b.col;
            self.setStatus("{d} substitution{s}", .{ count, if (count == 1) "" else "s" });
        } else {
            self.setStatus("pattern not found: {s}", .{pat});
        }
        return true;
    }

    /// Jump to the next/previous occurrence of the last `/` pattern, wrapping
    /// around the buffer like vim (with a "search hit BOTTOM/TOP" status).
    /// True when the match at `p` is a whole word (vim `\<pat\>` semantics).
    fn wordBounded(text: []const u8, p: usize, len: usize) bool {
        if (p > 0 and Buffer.wordClass(text[p - 1]) == 1) return false;
        const e = p + len;
        if (e < text.len and Buffer.wordClass(text[e]) == 1) return false;
        return true;
    }

    /// Next whole-word occurrence of `pat`, wrapping. Terminates because the
    /// word under the cursor is itself always a bounded match.
    fn findWordHit(text: []const u8, pat: []const u8, start: usize, dir: i2) ?usize {
        if (dir > 0) {
            var i = start + 1;
            var wrapped = false;
            while (true) {
                if (std.mem.indexOfPos(u8, text, @min(i, text.len), pat)) |p| {
                    if (wordBounded(text, p, pat.len)) return p;
                    i = p + 1;
                    continue;
                }
                if (wrapped) return null;
                wrapped = true;
                i = 0;
            }
        } else {
            var end = start;
            var wrapped = false;
            while (true) {
                if (std.mem.lastIndexOf(u8, text[0..end], pat)) |p| {
                    if (wordBounded(text, p, pat.len)) return p;
                    end = p;
                    continue;
                }
                if (wrapped) return null;
                wrapped = true;
                end = text.len;
            }
        }
    }

    /// `*` / `#`: whole-word search for the identifier under (or right of)
    /// the cursor. Loads the search register so n/N continue the hunt.
    fn searchWord(self: *Editor, dir: i2) void {
        if (self.buffers.items.len == 0) return;
        const b = self.cur();
        const text = b.buf.items;
        const line_start = b.lines.items[b.row].start;
        const line_end = line_start + b.lineLen(b.row);
        var pos = line_start + @min(b.col, b.lineLen(b.row));
        while (pos < line_end and Buffer.wordClass(text[pos]) != 1) pos += 1;
        if (pos >= line_end) return self.setStatus("no word under cursor", .{});
        var lo = pos;
        while (lo > 0 and Buffer.wordClass(text[lo - 1]) == 1) lo -= 1;
        var hi = pos;
        while (hi < text.len and Buffer.wordClass(text[hi]) == 1) hi += 1;
        const word = text[lo..hi];
        self.search.clearRetainingCapacity();
        self.search.appendSlice(self.alloc, word) catch return;
        const hit = findWordHit(text, self.search.items, lo, dir) orelse
            return self.setStatus("pattern not found: {s}", .{self.search.items});
        self.pushJump();
        b.setCursorFromByte(hit);
        self.setStatus("/{s}", .{self.search.items});
    }

    fn findNext(self: *Editor, dir: i2) void {
        const pat = self.search.items;
        if (pat.len == 0) return self.setStatus("no previous search", .{});
        if (self.buffers.items.len == 0) return;
        const b = self.cur();
        const text = b.buf.items;
        if (pat.len > text.len) return self.setStatus("pattern not found: {s}", .{pat});

        const cur_pos = b.lines.items[b.row].start + @min(b.col, b.lineLen(b.row));
        var wrapped = false;
        const hit: ?usize = if (dir > 0) blk: {
            if (std.mem.indexOfPos(u8, text, @min(cur_pos + 1, text.len), pat)) |p| break :blk p;
            wrapped = true;
            break :blk std.mem.indexOf(u8, text, pat);
        } else blk: {
            if (std.mem.lastIndexOf(u8, text[0..cur_pos], pat)) |p| break :blk p;
            wrapped = true;
            break :blk std.mem.lastIndexOf(u8, text, pat);
        };

        if (hit) |pos| {
            self.pushJump();
            b.setCursorFromByte(pos);
            if (wrapped)
                self.setStatus("search hit {s}, continuing at {s}", .{
                    if (dir > 0) "BOTTOM" else "TOP",
                    if (dir > 0) "TOP" else "BOTTOM",
                })
            else
                self.setStatus("/{s}", .{pat});
        } else {
            self.setStatus("pattern not found: {s}", .{pat});
        }
    }

    // ---- integrated terminal (NvTerm-style) -------------------------------

    /// Alt-h (split) / Alt-v (vertical) / Alt-i (float): show/hide the
    /// terminal, spawning the shell lazily. All views share one PTY session.
    fn toggleTerm(self: *Editor, ctx: *vxfw.EventContext, view: TermView) !void {
        if (self.term_view == view) {
            self.term_view = .none;
            if (self.focus == .term) self.focus = .editor;
            ctx.consumeAndRedraw();
            return;
        }
        if (self.term == null) {
            self.term = Term.spawn(self.alloc, self.term_cols, self.term_h) catch {
                self.setStatus("terminal: failed to spawn shell", .{});
                ctx.consumeAndRedraw();
                return;
            };
        } else if (self.term.?.exited) {
            self.term.?.deinit();
            self.term = Term.spawn(self.alloc, self.term_cols, self.term_h) catch {
                self.term = null;
                self.setStatus("terminal: failed to spawn shell", .{});
                ctx.consumeAndRedraw();
                return;
            };
        }
        self.term_view = view;
        self.focus = .term;
        try ctx.tick(80, self.widget());
        ctx.consumeAndRedraw();
    }

    /// Keys while the terminal owns focus: everything is forwarded to the
    /// shell except Ctrl-x (back to the editor, NvChad's terminal escape).
    fn handleTerm(self: *Editor, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        if (self.term == null) return;
        const t = &self.term.?;
        if (key.mods.ctrl and key.codepoint == 'x') {
            self.focus = .editor;
            ctx.consumeAndRedraw();
            return;
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            t.write("\r");
        } else if (key.matches(vaxis.Key.backspace, .{})) {
            t.write("\x7f");
        } else if (key.matches(vaxis.Key.tab, .{})) {
            t.write("\t");
        } else if (key.matches(vaxis.Key.escape, .{})) {
            t.write("\x1b");
        } else if (key.matches(vaxis.Key.up, .{})) {
            t.write("\x1b[A");
        } else if (key.matches(vaxis.Key.down, .{})) {
            t.write("\x1b[B");
        } else if (key.matches(vaxis.Key.right, .{})) {
            t.write("\x1b[C");
        } else if (key.matches(vaxis.Key.left, .{})) {
            t.write("\x1b[D");
        } else if (key.mods.ctrl and key.codepoint >= 'a' and key.codepoint <= 'z') {
            t.write(&[_]u8{@intCast(key.codepoint - 'a' + 1)});
        } else if (key.text) |txt| {
            t.write(txt);
        } else if (key.codepoint >= 0x20 and key.codepoint < 0x110000) {
            var utf8: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(@intCast(key.codepoint), &utf8) catch return;
            t.write(utf8[0..n]);
        }
        _ = t.poll();
        ctx.consumeAndRedraw();
    }

    /// Terminal pane: title row + the last N output lines. `x0` lets the
    /// same renderer back both the bottom split and the Alt-i float.
    fn drawTerm(self: *Editor, surface: vxfw.Surface, ctx: vxfw.DrawContext, x0: u16, top: u16, rows: u16, width: u16) void {
        const th = self.theme.p;
        if (self.term == null) return;
        const t = &self.term.?;
        if (t.exited and self.focus == .term) self.focus = .editor;

        if (self.term_cols != width) {
            self.term_cols = width;
            t.resize(width, rows);
        }

        // Title bar.
        const bar_style: vaxis.Style = .{ .fg = th.fg, .bg = th.bar_bg, .bold = true };
        var c: u16 = 0;
        while (c < width) : (c += 1) surface.writeCell(x0 + c, top, .{ .style = bar_style });
        // NOTE: must be static strings — surface cells keep grapheme slices
        // alive until render, so stack-formatted labels would dangle.
        const label = if (self.focus == .term) switch (self.term_view) {
            .float => "  Terminal — Ctrl-x: editor · Alt-i: hide ",
            .vert => "  Terminal — Ctrl-x: editor · Alt-v: hide ",
            else => "  Terminal — Ctrl-x: editor · Alt-h: hide ",
        } else if (t.exited) switch (self.term_view) {
            .float => "  Terminal [exited] — Alt-i: hide ",
            .vert => "  Terminal [exited] — Alt-v: hide ",
            else => "  Terminal [exited] — Alt-h: hide ",
        } else switch (self.term_view) {
            .float => "  Terminal — Alt-i: focus/hide ",
            .vert => "  Terminal — Alt-v: focus/hide ",
            else => "  Terminal — Alt-h: focus/hide ",
        };
        _ = writeText(surface, ctx, x0, top, label[0..@min(label.len, width)], bar_style);

        // Output: last `rows` lines, cursor line last.
        const base: vaxis.Style = .{ .fg = th.fg, .bg = th.bg };
        const total = t.lines.items.len;
        const first = total -| rows;
        var r: u16 = 0;
        while (r < rows) : (r += 1) {
            var fc: u16 = 0;
            while (fc < width) : (fc += 1) surface.writeCell(x0 + fc, top + 1 + r, .{ .style = base });
            const li = first + r;
            if (li >= total) break;
            const line = t.lines.items[li].items;
            _ = writeText(surface, ctx, x0, top + 1 + r, line[0..@min(line.len, width)], base);
        }
    }

    const FloatRect = struct { x0: u16, y0: u16, w: u16, h: u16 };

    /// Geometry of the Alt-i float: centered, 80% wide, 60% tall.
    fn termFloatRect(max_w: u16, max_h: u16) ?FloatRect {
        if (max_w < 20 or max_h < 8) return null;
        const w: u16 = @max(20, max_w * 4 / 5);
        const h: u16 = @max(6, max_h * 3 / 5);
        return .{ .x0 = (max_w - w) / 2, .y0 = (max_h - h) / 2, .w = w, .h = h };
    }

    /// Alt-i: centered floating terminal (NvChad float style), drawn as an
    /// overlay on top of everything with a one-cell border frame.
    fn drawTermFloat(self: *Editor, surface: vxfw.Surface, ctx: vxfw.DrawContext, max_w: u16, max_h: u16) void {
        const th = self.theme.p;
        const rect = termFloatRect(max_w, max_h) orelse return;
        const x0 = rect.x0;
        const y0 = rect.y0;
        const w = rect.w;
        const h = rect.h;

        // Border frame around the float.
        const border: vaxis.Style = .{ .fg = th.blue, .bg = th.bg };
        var bx: u16 = 0;
        while (bx < w + 2) : (bx += 1) {
            surface.writeCell(x0 - 1 + bx, y0 - 1, .{ .char = .{ .grapheme = "─" }, .style = border });
            surface.writeCell(x0 - 1 + bx, y0 + h, .{ .char = .{ .grapheme = "─" }, .style = border });
        }
        var by: u16 = 0;
        while (by < h) : (by += 1) {
            surface.writeCell(x0 - 1, y0 + by, .{ .char = .{ .grapheme = "│" }, .style = border });
            surface.writeCell(x0 + w, y0 + by, .{ .char = .{ .grapheme = "│" }, .style = border });
        }
        surface.writeCell(x0 - 1, y0 - 1, .{ .char = .{ .grapheme = "╭" }, .style = border });
        surface.writeCell(x0 + w, y0 - 1, .{ .char = .{ .grapheme = "╮" }, .style = border });
        surface.writeCell(x0 - 1, y0 + h, .{ .char = .{ .grapheme = "╰" }, .style = border });
        surface.writeCell(x0 + w, y0 + h, .{ .char = .{ .grapheme = "╯" }, .style = border });

        self.drawTerm(surface, ctx, x0, y0, h - 1, w);
    }

    // ---- file tree --------------------------------------------------------

    fn toggleTree(self: *Editor) void {
        if (self.tree_open) {
            self.tree_open = false;
            self.focus = .editor;
            return;
        }
        self.tree.refresh() catch {
            self.setStatus("file tree: scan failed", .{});
            return;
        };
        self.tree_open = true;
        self.focus = .tree;
    }

    /// NvimTree-ish keys: j/k move, Enter/l open or toggle dir, h collapse /
    /// jump to parent, R refresh, q or C-n close, C-l back to the editor.
    /// mouse=a: clicks focus panes / place the cursor, tab clicks switch
    /// (and close on the ×), tree clicks select then open, wheel scrolls.
    fn handleMouse(self: *Editor, ctx: *vxfw.EventContext, m: vaxis.Mouse) !void {
        if (!self.mlay.valid) return;
        if (self.popup.kind != .none) return; // popups stay keyboard-driven
        if (self.buffers.items.len == 0) return;
        const L = self.mlay;
        const b = self.cur();

        // Wheel: scroll whichever pane is under the pointer.
        if (m.button == .wheel_up or m.button == .wheel_down) {
            const down = m.button == .wheel_down;
            if (L.tree_w > 0 and m.col < L.tree_w) {
                const t = &self.tree;
                if (down) {
                    t.selected = @min(t.selected + 3, t.entries.items.len -| 1);
                } else {
                    t.selected -|= 3;
                }
            } else {
                const rows: usize = @max(1, L.text_rows);
                if (down) {
                    b.scroll = @min(b.scroll + 3, b.lines.items.len -| 1);
                } else {
                    b.scroll -|= 3;
                }
                // vim-style: the cursor trails the viewport
                if (b.row < b.scroll) b.row = b.scroll;
                if (b.row >= b.scroll + rows) b.row = b.scroll + rows - 1;
                b.row = @min(b.row, b.lines.items.len -| 1);
                b.col = @min(b.col, b.lineLen(b.row));
            }
            return ctx.consumeAndRedraw();
        }

        // Drag with the left button: extend a (charwise) visual selection.
        if (m.type == .drag and m.button == .left) {
            if (self.focus != .editor) return;
            if (m.row >= L.text_top and m.row < L.text_top + L.text_rows and
                m.col >= L.tree_w and m.col < L.text_right)
            {
                if (self.mode != .visual and self.mode != .visual_line)
                    self.enterVisual(.visual);
                const li = @min(b.scroll + (m.row - L.text_top), b.lines.items.len -| 1);
                b.row = li;
                b.col = byteColForWidth(b.lineText(li), m.col -| (L.tree_w + L.gutter));
                return ctx.consumeAndRedraw();
            }
            return;
        }

        if (m.type != .press or m.button != .left) return;

        // Tabline: click switches, click on the active tab's × closes.
        if (m.row == 0) {
            for (self.tab_spans[0..self.tab_span_count]) |sp| {
                if (m.col >= sp.start and m.col < sp.end) {
                    if (m.col == sp.close and sp.idx == self.active) {
                        self.closeBuffer(ctx, false);
                    } else {
                        self.active = sp.idx;
                        self.focus = .editor;
                    }
                    return ctx.consumeAndRedraw();
                }
            }
            return;
        }

        // File tree: first click selects, click on the selection activates.
        if (L.tree_w > 0 and m.col < L.tree_w and
            m.row >= L.text_top and m.row < L.text_top + L.text_rows)
        {
            const t = &self.tree;
            const idx = t.scroll + (m.row - L.text_top);
            if (idx < t.entries.items.len) {
                const again = self.focus == .tree and idx == t.selected;
                self.focus = .tree;
                t.selected = idx;
                if (again) {
                    const e = t.entries.items[idx];
                    if (e.is_dir) {
                        t.toggle(idx) catch {};
                    } else {
                        self.openFile(e.path) catch {
                            self.setStatus("could not open {s}", .{e.path});
                            return ctx.consumeAndRedraw();
                        };
                        self.focus = .editor;
                    }
                }
            }
            return ctx.consumeAndRedraw();
        }

        // Text area: focus + place the cursor.
        if (m.row >= L.text_top and m.row < L.text_top + L.text_rows and
            m.col >= L.tree_w and m.col < L.text_right)
        {
            self.focus = .editor;
            // A plain click cancels any active visual selection (vim mouse=a).
            if (self.mode == .visual or self.mode == .visual_line)
                self.exitVisual();
            const li = b.scroll + (m.row - L.text_top);
            if (li < b.lines.items.len) {
                b.row = li;
                const want: u16 = m.col -| (L.tree_w + L.gutter);
                b.col = byteColForWidth(b.lineText(li), want);
                b.goal_col = b.col;
                // Double-click on the same spot selects the word under it.
                const now = std.time.milliTimestamp();
                if (now - self.last_click_ms < 400 and
                    b.row == self.last_click_row and b.col == self.last_click_col)
                {
                    self.selectWordAt(b);
                    self.last_click_ms = 0; // triple-click starts over
                } else {
                    self.last_click_ms = now;
                    self.last_click_row = b.row;
                    self.last_click_col = b.col;
                }
            }
            return ctx.consumeAndRedraw();
        }
    }

    /// Double-click: visually select the word (or symbol run) under the cursor.
    fn selectWordAt(self: *Editor, b: *Buffer) void {
        const line = b.lineText(b.row);
        if (line.len == 0) return;
        const at = @min(b.col, line.len - 1);
        const cls = Buffer.wordClass(line[at]);
        if (cls == 0) return; // whitespace: nothing to select
        var s = at;
        var e = at;
        while (s > 0 and Buffer.wordClass(line[s - 1]) == cls) s -= 1;
        while (e + 1 < line.len and Buffer.wordClass(line[e + 1]) == cls) e += 1;
        self.mode = .visual;
        self.vis_row = b.row;
        self.vis_col = s;
        b.col = Buffer.snapToCp(line, e);
    }

    /// Inverse of displayCol: byte offset whose display column reaches `want`.
    fn byteColForWidth(text: []const u8, want: u16) usize {
        var disp: u16 = 0;
        var i: usize = 0;
        while (i < text.len and disp < want) {
            const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            const end = @min(i + cp_len, text.len);
            if (text[i] == '\t') {
                disp = (disp / 4 + 1) * 4;
            } else {
                disp += 1;
            }
            i = end;
        }
        return i;
    }

    fn handleTree(self: *Editor, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        const t = &self.tree;
        const cp = key.shifted_codepoint orelse key.codepoint;

        if (key.mods.ctrl) {
            switch (cp) {
                'c' => ctx.quit = true,
                'n' => self.toggleTree(),
                'l' => self.focus = .editor,
                else => return,
            }
            return ctx.consumeAndRedraw();
        }

        const len = t.entries.items.len;
        switch (cp) {
            'j', vaxis.Key.down => if (t.selected + 1 < len) {
                t.selected += 1;
            },
            'k', vaxis.Key.up => t.selected -|= 1,
            'G' => t.selected = len -| 1,
            vaxis.Key.enter, 'l', 'o' => if (len > 0) {
                const e = t.entries.items[t.selected];
                if (e.is_dir) {
                    t.toggle(t.selected) catch {};
                } else {
                    self.openFile(e.path) catch {
                        self.setStatus("could not open {s}", .{e.path});
                        return ctx.consumeAndRedraw();
                    };
                    self.focus = .editor;
                }
            },
            'h' => if (len > 0) {
                const e = t.entries.items[t.selected];
                if (e.is_dir and e.expanded) {
                    t.toggle(t.selected) catch {};
                } else if (t.parentOf(t.selected)) |p| {
                    t.selected = p;
                }
            },
            'R' => t.refresh() catch {},
            'q', vaxis.Key.escape => {
                self.tree_open = false;
                self.focus = .editor;
            },
            else => return,
        }
        ctx.consumeAndRedraw();
    }

    // ---- drawing ----------------------------------------------------------

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), max);
        self.mlay.valid = false;
        self.tab_span_count = 0;
        if (max.width == 0 or max.height < 3) return surface;
        if (self.buffers.items.len == 0) return self.drawDash(surface, ctx, max);

        const b = self.cur();
        const th = self.theme.p;
        const text_top: u16 = 1; // row 0 is the tabline
        // Reserve the bottom split (title row + term_h) when the terminal is open.
        const term_rows: u16 = if (self.term_view == .split) @min(self.term_h, (max.height - 3) -| 1) else 0;
        const term_total: u16 = if (self.term_view == .split and term_rows > 0) term_rows + 1 else 0;
        const text_rows: u16 = max.height - 2 - term_total;
        // Alt-v: vertical terminal pane on the right edge of the text area.
        const term_w: u16 = if (self.term_view == .vert and max.width > 40)
            @min(max.width * 2 / 5, max.width - 30)
        else
            0;
        const text_right: u16 = max.width - term_w;
        self.last_height = text_rows;

        // Keep the cursor visible.
        if (b.row < b.scroll) b.scroll = b.row;
        if (b.row >= b.scroll + text_rows) b.scroll = b.row - text_rows + 1;

        const tree_w: u16 = if (self.tree_open) @min(tree_width_max, max.width / 3) else 0;
        const x0 = tree_w; // text area starts right of the sidebar
        const gutter: u16 = @intCast(std.fmt.count("{d}", .{b.lines.items.len}) + 3); // sign col + digits + pad
        const gutter_style: vaxis.Style = .{ .fg = th.gutter, .bg = th.bg };
        const cursor_ln_style: vaxis.Style = .{ .fg = th.gutter_active, .bg = th.bg };

        self.mlay = .{
            .tree_w = tree_w,
            .gutter = gutter,
            .text_top = text_top,
            .text_rows = text_rows,
            .text_right = text_right,
            .valid = true,
        };

        self.drawTabline(surface, ctx, max.width);

        // Paint the theme background over the whole text area first.
        const base = b.hl.baseStyle();
        var fill_row: u16 = text_top;
        while (fill_row < text_top + text_rows) : (fill_row += 1) {
            var fill_col: u16 = 0;
            while (fill_col < text_right) : (fill_col += 1) {
                surface.writeCell(fill_col, fill_row, .{ .style = base });
            }
        }

        var row: u16 = 0;
        while (row < text_rows) : (row += 1) {
            const li = b.scroll + row;
            if (li >= b.lines.items.len) break;
            const line = b.lines.items[li];
            const draw_row = text_top + row;

            const num = try std.fmt.allocPrint(ctx.arena, "{d}", .{li + 1});
            _ = writeText(surface, ctx, @intCast(x0 + gutter - 1 - num.len), draw_row, num, if (li == b.row) cursor_ln_style else gutter_style);

            // gitsigns-style hunk marker in the leftmost gutter column
            switch (b.signFor(li)) {
                .none => {},
                .add => _ = writeText(surface, ctx, x0, draw_row, "▎", .{ .fg = th.green, .bg = th.bg }),
                .change => _ = writeText(surface, ctx, x0, draw_row, "▎", .{ .fg = th.orange, .bg = th.bg }),
                .delete => _ = writeText(surface, ctx, x0, draw_row, "▁", .{ .fg = th.red, .bg = th.bg }),
            }

            const text = b.buf.items[line.start..line.end];
            const pat = self.search.items;
            const search_style: vaxis.Style = .{ .fg = th.bg, .bg = th.yellow };
            const sel = self.selRange();
            var match: ?usize = if (pat.len > 0) std.mem.indexOf(u8, text, pat) else null;
            var col: u16 = x0 + gutter;
            var i: usize = 0;
            while (i < text.len and col < text_right) {
                const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
                const end = @min(i + cp_len, text.len);
                const slice = text[i..end];
                var style = b.hl.styleAt(line.start + i);
                if (match) |m| {
                    if (i >= m + pat.len) match = std.mem.indexOfPos(u8, text, i, pat);
                }
                if (match) |m| {
                    if (i >= m and i < m + pat.len) style = search_style;
                }
                if (sel) |s| {
                    const abs = line.start + i;
                    if (abs >= s[0] and abs < s[1]) style.bg = th.bar_bg;
                }
                if (slice[0] == '\t') {
                    const stop = x0 + gutter + (((col - x0 - gutter) / 4) + 1) * 4;
                    while (col < stop and col < text_right) : (col += 1) {
                        surface.writeCell(col, draw_row, .{ .style = style });
                    }
                } else {
                    const w: u16 = @intCast(@min(ctx.stringWidth(slice), 4));
                    if (w > 0) {
                        if (col + w > text_right) break;
                        surface.writeCell(col, draw_row, .{
                            .char = .{ .grapheme = slice, .width = @intCast(w) },
                            .style = style,
                        });
                        col += w;
                    }
                }
                i = end;
            }

            // indent-blankline style guides at each indent step, drawn over
            // the leading-whitespace cells (and through blank lines).
            var gstyle = base;
            gstyle.fg = th.gutter;
            var g: u16 = 0;
            const guide_w = guideWidthFor(b, li);
            while (g < guide_w) : (g += 4) {
                const cx = x0 + gutter + g;
                if (cx >= text_right) break;
                surface.writeCell(cx, draw_row, .{
                    .char = .{ .grapheme = "▏", .width = 1 },
                    .style = gstyle,
                });
            }
        }

        if (tree_w > 0) self.drawTree(surface, ctx, text_top, text_rows, tree_w);
        if (term_total > 0) self.drawTerm(surface, ctx, 0, text_top + text_rows, term_rows, max.width);
        if (term_w > 0) self.drawTerm(surface, ctx, text_right, text_top, text_rows - 1, term_w);
        self.drawStatus(surface, ctx, max.height - 1, max.width);
        if (self.term_view == .float) self.drawTermFloat(surface, ctx, max.width, max.height - 1);
        if (self.popup.kind != .none) {
            try self.drawPopup(&surface, ctx, max);
            return surface;
        }

        // Terminal cursor placement.
        if (self.mode == .command) {
            surface.cursor = .{
                .row = max.height - 1,
                .col = @intCast(@min(1 + self.cmd.items.len, max.width - 1)),
                .shape = .beam,
            };
        } else if (self.focus == .term and term_total > 0) {
            if (self.term) |*t| {
                const cur_row: u16 = @intCast(@min(t.lines.items.len -| 1, term_rows - 1));
                surface.cursor = .{
                    .row = text_top + text_rows + 1 + cur_row,
                    .col = @intCast(@min(t.col, max.width - 1)),
                    .shape = .block,
                };
            }
        } else if (self.focus == .term and term_w > 0) {
            if (self.term) |*t| {
                const rows = text_rows - 1;
                const cur_row: u16 = @intCast(@min(t.lines.items.len -| 1, rows -| 1));
                surface.cursor = .{
                    .row = text_top + 1 + cur_row,
                    .col = @intCast(@min(text_right + t.col, max.width - 1)),
                    .shape = .block,
                };
            }
        } else if (self.focus == .term and self.term_view == .float) {
            if (self.term) |*t| {
                if (termFloatRect(max.width, max.height - 1)) |rect| {
                    const rows = rect.h - 1;
                    const cur_row: u16 = @intCast(@min(t.lines.items.len -| 1, rows - 1));
                    surface.cursor = .{
                        .row = rect.y0 + 1 + cur_row,
                        .col = @intCast(@min(rect.x0 + t.col, max.width - 1)),
                        .shape = .block,
                    };
                }
            }
        } else if (self.focus == .editor and b.row >= b.scroll and b.row < b.scroll + text_rows) {
            surface.cursor = .{
                .row = @intCast(text_top + b.row - b.scroll),
                .col = @intCast(@min(x0 + gutter + self.displayCol(ctx), max.width - 1)),
                .shape = if (self.mode == .insert) .beam else .block,
            };
        }
        return surface;
    }

    /// NvDash-style start screen: logo + shortcut buttons, shown whenever no
    /// buffer is open. Popups, the file tree and `:` commands still work.
    fn drawDash(self: *Editor, surface_in: vxfw.Surface, ctx: vxfw.DrawContext, max: vxfw.Size) std.mem.Allocator.Error!vxfw.Surface {
        var surface = surface_in;
        const th = self.theme.p;
        self.last_height = max.height -| 1;

        // Theme background everywhere.
        var fr: u16 = 0;
        while (fr < max.height) : (fr += 1) {
            var fc: u16 = 0;
            while (fc < max.width) : (fc += 1) {
                surface.writeCell(fc, fr, .{ .style = .{ .fg = th.fg, .bg = th.bg } });
            }
        }

        const tree_w: u16 = if (self.tree_open) @min(tree_width_max, max.width / 3) else 0;
        const x_off = tree_w;
        const area_w = max.width - tree_w;

        const logo = [_][]const u8{
            "███████╗ ██╗ ██████╗  ███████╗",
            "╚══███╔╝ ██║ ██╔══██╗ ██╔════╝",
            "  ███╔╝  ██║ ██║  ██║ █████╗  ",
            " ███╔╝   ██║ ██║  ██║ ██╔══╝  ",
            "███████╗ ██║ ██████╔╝ ███████╗",
            "╚══════╝ ╚═╝ ╚═════╝  ╚══════╝",
        };
        const logo_w: u16 = 30;
        const Btn = struct { icon: []const u8, label: []const u8, key: []const u8 };
        const btns = [_]Btn{
            .{ .icon = "\u{f002}", .label = "Find File", .key = "f" },
            .{ .icon = "\u{f0c5}", .label = "Live Grep", .key = "w" },
            .{ .icon = "\u{f114}", .label = "File Tree", .key = "e" },
            .{ .icon = "\u{f043}", .label = "Themes", .key = "t" },
            .{ .icon = "\u{f128}", .label = "Cheatsheet", .key = "h" },
            .{ .icon = "\u{f011}", .label = "Quit", .key = "q" },
        };
        const btn_w: u16 = 26;
        const total_h: u16 = logo.len + 1 + (@as(u16, btns.len) * 2 - 1) + 2;
        var y: u16 = if (max.height > total_h + 1) (max.height - 1 - total_h) / 2 else 0;

        // Logo.
        for (logo) |line| {
            if (y >= max.height -| 1) break;
            const lx: u16 = x_off + (area_w -| logo_w) / 2;
            _ = writeText(surface, ctx, lx, y, line, .{ .fg = th.blue, .bold = true });
            y += 1;
        }
        y += 1;

        // Buttons.
        for (btns) |btn| {
            if (y >= max.height -| 1) break;
            const bx: u16 = x_off + (area_w -| btn_w) / 2;
            var col = bx;
            var pad: u16 = 0;
            while (pad < btn_w) : (pad += 1)
                surface.writeCell(bx + pad, y, .{ .style = .{ .bg = th.bar_bg } });
            col = writeText(surface, ctx, col, y, "  ", .{ .bg = th.bar_bg });
            col = writeText(surface, ctx, col, y, btn.icon, .{ .fg = th.green, .bg = th.bar_bg });
            col = writeText(surface, ctx, col, y, "  ", .{ .bg = th.bar_bg });
            col = writeText(surface, ctx, col, y, btn.label, .{ .fg = th.fg, .bg = th.bar_bg });
            _ = writeText(surface, ctx, bx + btn_w - 3, y, btn.key, .{ .fg = th.yellow, .bg = th.bar_bg, .bold = true });
            y += 2;
        }
        if (y < max.height -| 1) {
            const hint = "zide — :e <path> to open a file";
            const hx: u16 = x_off + (area_w -| @as(u16, @intCast(ctx.stringWidth(hint)))) / 2;
            _ = writeText(surface, ctx, hx, y, hint, .{ .fg = th.gray });
        }

        if (tree_w > 0) self.drawTree(surface, ctx, 0, max.height - 1, tree_w);
        self.drawStatus(surface, ctx, max.height - 1, max.width);
        if (self.popup.kind != .none) {
            try self.drawPopup(&surface, ctx, max);
            return surface;
        }
        if (self.mode == .command) {
            surface.cursor = .{
                .row = max.height - 1,
                .col = @intCast(@min(1 + self.cmd.items.len, max.width - 1)),
                .shape = .beam,
            };
        }
        return surface;
    }

    /// Nerd-font devicon + accent color for a file name (NvChad-style).
    fn fileIcon(name: []const u8, th: *const themes.Palette) struct { glyph: []const u8, color: vaxis.Color } {
        const Ext = enum { zig, zon, js, mjs, ts, jsx, tsx, css, html, json, md, lua, py, c, h, cpp, go, rs, sh, toml, yml, yaml, vue };
        const ext = std.fs.path.extension(name);
        const e = if (ext.len > 1) std.meta.stringToEnum(Ext, ext[1..]) else null;
        if (e == null) return .{ .glyph = "\u{f016}", .color = th.gray }; //
        return switch (e.?) {
            .zig, .zon => .{ .glyph = "\u{e6a9}", .color = th.orange }, //
            .js, .mjs => .{ .glyph = "\u{e74e}", .color = th.yellow }, //
            .ts => .{ .glyph = "\u{e628}", .color = th.blue },
            .jsx, .tsx => .{ .glyph = "\u{e7ba}", .color = th.cyan }, //
            .css => .{ .glyph = "\u{e749}", .color = th.blue }, //
            .html => .{ .glyph = "\u{e736}", .color = th.orange },
            .json => .{ .glyph = "\u{e60b}", .color = th.yellow }, //
            .md => .{ .glyph = "\u{e73e}", .color = th.fg },
            .lua => .{ .glyph = "\u{e620}", .color = th.blue },
            .py => .{ .glyph = "\u{e606}", .color = th.yellow },
            .c, .h => .{ .glyph = "\u{e61e}", .color = th.blue },
            .cpp => .{ .glyph = "\u{e61d}", .color = th.blue },
            .go => .{ .glyph = "\u{e626}", .color = th.cyan },
            .rs => .{ .glyph = "\u{e7a8}", .color = th.orange },
            .sh => .{ .glyph = "\u{f489}", .color = th.green },
            .toml, .yml, .yaml => .{ .glyph = "\u{e615}", .color = th.gray },
            .vue => .{ .glyph = "\u{fd42}", .color = th.green },
        };
    }

    /// One tab cell: ` <icon> name <●|×> ` — active tab shares the editor bg
    /// so it visually merges with the text area (like NvChad/base46).
    fn drawTabline(self: *Editor, surface: vxfw.Surface, ctx: vxfw.DrawContext, width: u16) void {
        const th = &self.theme.p;
        const line_style: vaxis.Style = .{ .fg = th.bar_fg, .bg = th.bar_bg };
        var col: u16 = 0;
        while (col < width) : (col += 1) {
            surface.writeCell(col, 0, .{ .style = line_style });
        }

        // Right-aligned tab-count badge, reserve its room first.
        const badge = std.fmt.allocPrint(ctx.arena, " {d} ", .{self.buffers.items.len}) catch return;
        const badge_w: u16 = @intCast(ctx.stringWidth(badge));
        const avail: u16 = width -| badge_w;

        // Tab widths: pad + icon + sp + name + sp + indicator + pad.
        const n = self.buffers.items.len;
        var widths = ctx.arena.alloc(u16, n) catch return;
        for (self.buffers.items, 0..) |*b, i|
            widths[i] = 6 + @as(u16, @intCast(ctx.stringWidth(b.displayName())));

        // Scroll the strip so the active tab is always fully visible.
        var first: usize = 0;
        while (first < self.active) {
            var w: u16 = 0;
            for (widths[first .. self.active + 1]) |tw| w += tw;
            if (w <= avail) break;
            first += 1;
        }

        col = 0;
        for (self.buffers.items[first..], first..) |*b, i| {
            if (col >= avail) break;
            if (self.tab_span_count < self.tab_spans.len) {
                const tab_end = @min(col + widths[i], avail);
                self.tab_spans[self.tab_span_count] = .{
                    .start = col,
                    .end = tab_end,
                    .close = tab_end -| 2,
                    .idx = i,
                };
                self.tab_span_count += 1;
            }
            const is_active = i == self.active;
            const bg = if (is_active) th.bg else th.bar_bg;
            const icon = fileIcon(b.file_name, th);

            col = writeText(surface, ctx, col, 0, " ", .{ .bg = bg });
            col = writeText(surface, ctx, col, 0, icon.glyph, .{
                .fg = if (is_active) icon.color else th.gutter_active,
                .bg = bg,
            });
            const name = std.fmt.allocPrint(ctx.arena, " {s} ", .{b.displayName()}) catch return;
            col = writeText(surface, ctx, col, 0, name, .{
                .fg = if (is_active) th.fg else th.gutter_active,
                .bg = bg,
                .bold = is_active,
            });
            col = writeText(
                surface,
                ctx,
                col,
                0,
                if (b.dirty) "\u{25cf}" else "\u{00d7}", // ● / ×
                .{ .fg = if (b.dirty) th.green else if (is_active) th.red else th.gutter_active, .bg = bg },
            );
            col = writeText(surface, ctx, col, 0, " ", .{ .bg = bg });
        }

        _ = writeText(surface, ctx, width -| badge_w, 0, badge, .{
            .fg = th.badge_fg,
            .bg = th.blue,
            .bold = true,
        });
    }

    /// Display column of the cursor within its line (tabs expand to 4-stops).
    fn displayCol(self: *Editor, ctx: vxfw.DrawContext) u16 {
        const b = self.cur();
        const text = b.lineText(b.row);
        var disp: u16 = 0;
        var i: usize = 0;
        while (i < text.len and i < b.col) {
            const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            const end = @min(i + cp_len, text.len);
            if (text[i] == '\t') {
                disp = (disp / 4 + 1) * 4;
            } else {
                disp += @intCast(@min(ctx.stringWidth(text[i..end]), 4));
            }
            i = end;
        }
        return disp;
    }

    fn drawStatus(self: *Editor, surface: vxfw.Surface, ctx: vxfw.DrawContext, status_row: u16, width: u16) void {
        const b: ?*Buffer = if (self.buffers.items.len > 0) self.cur() else null;
        const th = self.theme.p;
        const bar_style: vaxis.Style = .{ .fg = th.bar_fg, .bg = th.bar_bg };
        var col: u16 = 0;
        while (col < width) : (col += 1) {
            surface.writeCell(col, status_row, .{ .style = bar_style });
        }

        if (self.mode == .command) {
            const prefix: []const u8 = if (self.cmd_is_search) "/" else ":";
            const cmdline = std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ prefix, self.cmd.items }) catch return;
            _ = writeText(surface, ctx, 0, status_row, cmdline, bar_style);
            return;
        }

        const mode_style: vaxis.Style = switch (self.mode) {
            .normal => .{ .fg = th.badge_fg, .bg = th.green, .bold = true },
            .insert => .{ .fg = th.badge_fg, .bg = th.blue, .bold = true },
            .visual, .visual_line => .{ .fg = th.badge_fg, .bg = th.purple, .bold = true },
            .command => unreachable,
        };
        const mode_txt = switch (self.mode) {
            .normal => " NORMAL ",
            .insert => " INSERT ",
            .visual => " VISUAL ",
            .visual_line => " V-LINE ",
            .command => unreachable,
        };
        var end = writeText(surface, ctx, 0, status_row, mode_txt, mode_style);

        if (self.recording) |r| {
            const seg = std.fmt.allocPrint(ctx.arena, " REC @{c} ", .{r}) catch return;
            const rec_style: vaxis.Style = .{ .fg = th.badge_fg, .bg = th.red, .bold = true };
            end = writeText(surface, ctx, end, status_row, seg, rec_style);
        }

        if (self.git_branch_len > 0) {
            const seg = std.fmt.allocPrint(ctx.arena, "  {s} ", .{
                self.git_branch[0..self.git_branch_len],
            }) catch return;
            const branch_style: vaxis.Style = .{ .fg = th.blue, .bg = th.bar_bg, .bold = true };
            end = writeText(surface, ctx, end, status_row, seg, branch_style);
        }

        const left = if (self.status_len > 0)
            std.fmt.allocPrint(ctx.arena, " {s}", .{self.status_buf[0..self.status_len]}) catch return
        else if (b) |buf|
            std.fmt.allocPrint(ctx.arena, " {s}{s}", .{
                buf.file_name,
                if (buf.dirty) " [+]" else "",
            }) catch return
        else
            " dashboard";
        end = writeText(surface, ctx, end, status_row, left, bar_style);

        if (b) |buf| {
            const right = std.fmt.allocPrint(ctx.arena, " {d}/{d}  {d}:{d} ", .{
                self.active + 1, self.buffers.items.len, buf.row + 1, buf.col + 1,
            }) catch return;
            if (right.len < width) {
                _ = writeText(surface, ctx, @intCast(width - right.len), status_row, right, mode_style);
            }
        }
    }

    fn drawPopup(self: *Editor, surface: *vxfw.Surface, ctx: vxfw.DrawContext, max: vxfw.Size) !void {
        const th = self.theme.p;
        var matches: [Popup.max_items]usize = undefined;
        const n = self.popupMatches(&matches);
        const selected = if (n == 0) 0 else @min(self.popup.selected, n - 1);

        const w: u16 = @min(46, max.width -| 4);
        if (w < 8 or max.height < 7) return;
        const visible: u16 = @intCast(@min(n, 10));
        const h: u16 = visible + 3; // top border, filter row, items, bottom border
        const x0: u16 = (max.width - w) / 2;
        const y0: u16 = (max.height -| h) / 3;

        const body: vaxis.Style = .{ .fg = th.fg, .bg = th.bg };
        const border: vaxis.Style = .{ .fg = th.blue, .bg = th.bg };
        const title_style: vaxis.Style = .{ .fg = th.badge_fg, .bg = th.blue, .bold = true };
        const sel_style: vaxis.Style = .{ .fg = th.fg, .bg = th.bar_bg, .bold = true };

        // Frame + fill.
        var row: u16 = 0;
        while (row < h) : (row += 1) {
            var col: u16 = 0;
            while (col < w) : (col += 1) {
                const cell: vaxis.Cell = if (row == 0 or row == h - 1) blk: {
                    const g: []const u8 = if (row == 0 and col == 0) "╭" else if (row == 0 and col == w - 1) "╮" else if (row == h - 1 and col == 0) "╰" else if (row == h - 1 and col == w - 1) "╯" else "─";
                    break :blk .{ .char = .{ .grapheme = g, .width = 1 }, .style = border };
                } else if (col == 0 or col == w - 1)
                    .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border }
                else
                    .{ .style = body };
                surface.writeCell(x0 + col, y0 + row, cell);
            }
        }
        _ = writeText(surface.*, ctx, x0 + 2, y0, self.popupTitle(), title_style);

        // Filter line.
        const prompt = std.fmt.allocPrint(ctx.arena, "> {s}", .{self.popup.filter.items}) catch return;
        _ = writeText(surface.*, ctx, x0 + 2, y0 + 1, prompt, body);

        // Items (scroll window keeps the selection visible).
        const start = if (selected >= visible) selected - visible + 1 else 0;
        var vi: u16 = 0;
        while (vi < visible) : (vi += 1) {
            const mi = start + vi;
            if (mi >= n) break;
            const idx = matches[mi];
            const is_sel = mi == selected;
            const item_row = y0 + 2 + vi;
            if (is_sel) {
                var col: u16 = x0 + 1;
                while (col < x0 + w - 1) : (col += 1) {
                    surface.writeCell(col, item_row, .{ .style = sel_style });
                }
            }
            const marker = if (self.popup.kind == .buffers and idx == self.active) "● " else if (self.popup.kind == .themes and &themes.list[idx] == self.theme) "● " else "  ";
            const name = std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ marker, self.popupItemName(idx) }) catch return;
            _ = writeText(surface.*, ctx, x0 + 2, item_row, name, if (is_sel) sel_style else body);
        }

        surface.cursor = .{
            .row = y0 + 1,
            .col = @intCast(@min(x0 + 4 + self.popup.filter.items.len, max.width - 1)),
            .shape = .beam,
        };
    }

    /// Sidebar: indented tree with folder/file icons, git-status coloring,
    /// selection bar, and a `│` separator on its right edge.
    fn drawTree(self: *Editor, surface: vxfw.Surface, ctx: vxfw.DrawContext, top: u16, rows: u16, width: u16) void {
        const t = &self.tree;
        const th = self.theme.p;

        // Keep the selection visible.
        if (t.selected < t.scroll) t.scroll = t.selected;
        if (t.selected >= t.scroll + rows) t.scroll = t.selected - rows + 1;

        var r: u16 = 0;
        while (r < rows) : (r += 1) {
            const row = top + r;
            const idx = t.scroll + r;
            const has = idx < t.entries.items.len;
            const selected = has and idx == t.selected;
            const row_bg = if (selected and self.focus == .tree) th.bar_bg else th.bg;

            var c: u16 = 0;
            while (c + 1 < width) : (c += 1) {
                surface.writeCell(c, row, .{ .style = .{ .bg = row_bg } });
            }
            surface.writeCell(width - 1, row, .{
                .char = .{ .grapheme = "│", .width = 1 },
                .style = .{ .fg = th.gutter, .bg = th.bg },
            });
            if (!has) continue;

            const e = t.entries.items[idx];
            var col: u16 = @min(1 + e.depth * 2, width - 1);
            const limit = width - 1;

            var glyph: []const u8 = if (e.expanded) "\u{f07c}" else "\u{f07b}";
            var icon_fg = th.blue;
            if (!e.is_dir) {
                const ic = fileIcon(e.name, &th);
                glyph = ic.glyph;
                icon_fg = ic.color;
            }
            if (col + 2 < limit) {
                surface.writeCell(col, row, .{
                    .char = .{ .grapheme = glyph, .width = 1 },
                    .style = .{ .fg = icon_fg, .bg = row_bg },
                });
                col += 2;
            }

            const name_fg = switch (e.git) {
                .none => if (e.is_dir) th.blue else th.fg,
                .modified => th.yellow,
                .added, .untracked => th.green,
                .deleted => th.red,
            };
            const style: vaxis.Style = .{
                .fg = name_fg,
                .bg = row_bg,
                .bold = e.is_dir,
            };
            var i: usize = 0;
            while (i < e.name.len and col < limit) {
                const cp_len = std.unicode.utf8ByteSequenceLength(e.name[i]) catch 1;
                const end = @min(i + cp_len, e.name.len);
                const slice = e.name[i..end];
                const w: u16 = @intCast(@min(ctx.stringWidth(slice), 4));
                if (w > 0 and col + w <= limit) {
                    surface.writeCell(col, row, .{
                        .char = .{ .grapheme = slice, .width = @intCast(w) },
                        .style = style,
                    });
                    col += w;
                } else if (w > 0) break;
                i = end;
            }
        }
    }

    fn writeText(surface: vxfw.Surface, ctx: vxfw.DrawContext, col_start: u16, row: u16, text: []const u8, style: vaxis.Style) u16 {
        var col = col_start;
        var i: usize = 0;
        while (i < text.len and col < surface.size.width) {
            const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            const end = @min(i + cp_len, text.len);
            const slice = text[i..end];
            const w: u16 = @intCast(@min(ctx.stringWidth(slice), 4));
            if (w > 0) {
                surface.writeCell(col, row, .{
                    .char = .{ .grapheme = slice, .width = @intCast(w) },
                    .style = style,
                });
                col += w;
            }
            i = end;
        }
        return col;
    }
};
