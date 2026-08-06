const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const ts = @import("tree-sitter");
const themes = @import("theme.zig");
const Buffer = @import("buffer.zig").Buffer;
const Tree = @import("tree.zig").Tree;
const Term = @import("term.zig").Term;
const Lsp = @import("lsp.zig").Lsp;

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
    /// Search-match highlighting toggle — `:noh` turns it off until the next search.
    search_hl: bool = true,
    /// Last f/F/t/T target for `;` and `,` repeat (0 = none yet).
    last_find_kind: u8 = 0,
    last_find_cp: u21 = 0,
    /// Operator awaiting a find-char target (`dfx`/`ctx`/`ytx`), else 0.
    find_op: u8 = 0,
    status_buf: [256]u8 = undefined,
    status_len: usize = 0,
    /// `Space g p` hunk preview: raw '\n'-separated rows, cleared on any key.
    preview_buf: [2048]u8 = undefined,
    preview_len: usize = 0,
    popup: Popup = .{},
    files: std.ArrayListUnmanaged([]u8) = .{},
    /// Recently opened files, most recent first (persisted, NvDash "recent").
    oldfiles: std.ArrayListUnmanaged([]u8) = .{},
    grep_hits: std.ArrayListUnmanaged(GrepHit) = .{},
    /// ]q / [q cursor into grep_hits; `qf_seen` makes the first jump land on
    /// the current entry instead of skipping it.
    qf_idx: usize = 0,
    qf_seen: bool = false,
    tree: Tree,
    tree_open: bool = false,
    /// Space n / Space r n: absolute + relative line-number display.
    numbers: bool = true,
    relnum: bool = false,
    focus: Focus = .editor,
    git_branch: [64]u8 = undefined,
    git_branch_len: usize = 0,
    /// Macro registers: `q{a-z}` records raw key events, `@{a-z}` replays.
    macros: [26]std.ArrayListUnmanaged(vaxis.Key) = [_]std.ArrayListUnmanaged(vaxis.Key){.{}} ** 26,
    /// Register char ('a'..'z') currently being recorded into, if any.
    recording: ?u8 = null,
    /// Last register replayed with `@`, reused by `@@`.
    last_macro: ?u8 = null,
    surround_from: u8 = 0,
    obj_op: u8 = 'd',
    /// Replay re-entrancy depth; guards runaway recursive macros.
    replay_depth: u8 = 0,
    /// Dot-repeat: keys of the last completed change (`.` replays them).
    dot: std.ArrayListUnmanaged(vaxis.Key) = .{},
    /// In-progress change capture (from change-starting key until normal mode).
    dot_rec: std.ArrayListUnmanaged(vaxis.Key) = .{},
    dot_capturing: bool = false,
    /// Buffer + its undo_seq at capture start: a settle only commits when
    /// the capture actually edited that buffer.
    dot_buf0: usize = 0,
    dot_seq0: u32 = 0,
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
    /// nvim-cmp-lite: insert-mode Ctrl-n/Ctrl-p word completion.
    cmp: Cmp = .{},
    /// vim highlight.on_yank: the byte range of the last yank, painted with
    /// an accent bg until the flash tick expires.
    yank_flash: ?struct { buf: usize, seq: u32, lo: usize, hi: usize, until_ms: i64 } = null,
    /// A clear-tick is already scheduled for the current flash.
    yank_flash_armed: bool = false,
    /// `Space f z` picker rows (see LineHit); cleared on popup close.
    line_hits: std.ArrayListUnmanaged(LineHit) = .{},
    /// `Space f s` outline rows (see SymbolHit); cleared on popup close.
    symbol_hits: std.ArrayListUnmanaged(SymbolHit) = .{},
    /// zls client; null when never started, spawn-failed, or dead.
    lsp: ?Lsp = null,
    /// A spawn failure or a crash disables LSP for the session — never a
    /// respawn loop.
    lsp_failed: bool = false,
    /// Absolute cwd captured when the client starts, for uri <-> buffer matching.
    lsp_root: ?[]u8 = null,
    /// Where `gd` was pressed. The answer lands a poll tick later, so the
    /// jumplist entry must point here and not at wherever the cursor drifted.
    lsp_req: ?struct { buf: usize, row: usize, col: usize } = null,
    /// Ticks currently in flight. The terminal/LSP poll chain re-arms only at
    /// zero, so overlapping arm sites can never multiply into extra chains.
    ticks: u8 = 0,

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
    const Pending = enum { none, g, g_comment, g_comment_g, g_comment_i, d, leader, leader_f, leader_c, leader_r, leader_g, bracket_f, bracket_b, mark_set, mark_exact, mark_line, macro_rec, macro_play, replace_char, c_op, surround_old, surround_new, surround_del, surround_vis, obj_i, obj_a, y_op, indent_gt, indent_lt, indent_eq, find_f, find_F, find_t, find_T, z };

    const Jump = struct { buf: usize, row: usize, col: usize };
    const Focus = enum { editor, tree, term };
    const tree_width_max: u16 = 30;
    const yank_flash_ms: i64 = 180;

    /// Floating picker overlay (buffers / themes), telescope-flavored:
    /// typing filters, arrows or C-j/C-k move, Enter picks, Esc closes.
    const Popup = struct {
        kind: Kind = .none,
        filter: std.ArrayListUnmanaged(u8) = .{},
        selected: usize = 0,

        const Kind = enum { none, buffers, themes, files, keys, grep, recent, lines, symbols, qf };
        /// Raised from 64: the cheatsheet sits at 64 rows and the
        /// quickfix picker holds up to this many reference hits —
        /// popupMatches silently drops anything past the cap.
        const max_items = 96;
        const max_files = 2000;
        /// Per-buffer cap for the `Space f z` line picker (distinct from
        /// the per-project max_files).
        const max_lines = 10000;
        const max_symbols = 2000;
        const max_file_size = 1024 * 1024;
    };

    /// Insert-mode word completion. `items` are words harvested from every
    /// open buffer; the buffer region [start, start+len) always holds either
    /// the typed prefix (sel == null) or the selected candidate.
    const Cmp = struct {
        active: bool = false,
        items: std.ArrayListUnmanaged([]u8) = .{},
        /// Index of the candidate currently applied in the buffer. Always
        /// set while the menu is active (opening applies a match at once).
        sel: usize = 0,
        /// Byte offset where the completed region starts, and its length.
        start: usize = 0,
        len: usize = 0,
        prefix: std.ArrayListUnmanaged(u8) = .{},

        const max_items = 500;
        const rows = 8;
    };

    /// One live-grep result: owned path + owned "path:line: text" display row.
    const GrepHit = struct {
        path: []u8,
        line: usize,
        disp: []u8,
    };

    /// One current-buffer line for the `Space f z` picker: 0-based row +
    /// owned "NNNN: text" display row.
    const LineHit = struct { row: usize, disp: []u8 };

    /// One outline row for the `Space f s` picker: 0-based row + owned
    /// "kind   name" display row.
    const SymbolHit = struct { row: usize, disp: []u8 };

    /// A declaration's keyword and name; `name` borrows the buffer text and
    /// `kw` is either a literal or a slice of a static tree-sitter kind name.
    const Crumb = struct { kw: []const u8, name: []const u8 };

    fn isContainerKind(kind: []const u8) bool {
        return std.mem.eql(u8, kind, "struct_declaration") or
            std.mem.eql(u8, kind, "enum_declaration") or
            std.mem.eql(u8, kind, "union_declaration") or
            std.mem.eql(u8, kind, "opaque_declaration");
    }

    fn nodeText(src: []const u8, node: ts.Node) []const u8 {
        const s = @min(@as(usize, node.startByte()), src.len);
        const full = @min(@as(usize, node.endByte()), src.len);
        var e = @min(full, s + 64);
        // Back off to the start of a partially-cut codepoint: stopping on
        // continuation bytes alone would leave the dangling lead byte in.
        while (e > s and e < full and (src[e] & 0xC0) == 0x80) e -= 1;
        return src[s..e];
    }

    /// Keyword + name for a declaration node, or null when `node` is not one
    /// we surface. tree-sitter-zig v1.1.2 shapes: `function_declaration` has a
    /// `name` field; `test_declaration` carries a string/identifier child;
    /// `variable_declaration` holds its identifier as the first named child and
    /// (for `const X = struct {…}`) the container node as a later child, since
    /// container declarations are anonymous in this grammar. Only
    /// container-level variable declarations qualify — including locals would
    /// put ~1300 rows in the outline of a file this size.
    fn declCrumb(b: *const Buffer, node: ts.Node) ?Crumb {
        const kind = node.kind();
        const src = b.buf.items;
        if (std.mem.eql(u8, kind, "function_declaration")) {
            const nm = node.childByFieldName("name") orelse return null;
            return .{ .kw = "fn", .name = nodeText(src, nm) };
        }
        if (std.mem.eql(u8, kind, "test_declaration")) {
            const n = node.namedChildCount();
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const ch = node.namedChild(i) orelse continue;
                const ck = ch.kind();
                if (std.mem.eql(u8, ck, "string") or std.mem.eql(u8, ck, "identifier"))
                    return .{ .kw = "test", .name = nodeText(src, ch) };
            }
            return .{ .kw = "test", .name = "" };
        }
        if (!std.mem.eql(u8, kind, "variable_declaration")) return null;
        const pk = (node.parent() orelse return null).kind();
        if (!isContainerKind(pk) and !std.mem.eql(u8, pk, "source_file")) return null;
        var name: ?ts.Node = null;
        var kw: []const u8 = "const";
        const n = node.namedChildCount();
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const ch = node.namedChild(i) orelse continue;
            const ck = ch.kind();
            if (name == null and std.mem.eql(u8, ck, "identifier")) {
                name = ch;
            } else if (isContainerKind(ck)) {
                // "struct_declaration" -> "struct"; kind() is a static string.
                kw = ck[0 .. std.mem.indexOfScalar(u8, ck, '_') orelse ck.len];
            }
        }
        const nm = name orelse return null;
        if (std.mem.eql(u8, kw, "const")) {
            // Whole-word scan: a bare indexOf would hit e.g. the library
            // string in `extern "varlib" const C` and mislabel it `var`.
            const head = src[@min(@as(usize, node.startByte()), src.len)..@min(@as(usize, nm.startByte()), src.len)];
            var scan: usize = 0;
            while (std.mem.indexOfPos(u8, head, scan, "var")) |p| : (scan = p + 1) {
                if (wordBounded(head, p, 3)) {
                    kw = "var";
                    break;
                }
            }
        }
        return .{ .kw = kw, .name = nodeText(src, nm) };
    }

    /// nvim-navic-lite: enclosing declarations at the cursor, innermost first.
    /// O(tree depth); the statusline draws once per frame so no cache is needed.
    fn breadcrumbs(self: *Editor, out: *[4]Crumb) usize {
        if (self.buffers.items.len == 0) return 0;
        const b = self.cur();
        const tree = b.hl.tree orelse return 0;
        // Probe from the first non-blank column when the cursor sits in the
        // leading indentation — otherwise `0` on a fn's signature line makes
        // the crumb flicker from `fn x` to just the enclosing container.
        const fnw = b.lines.items[b.row].start + b.firstNonWs(b.row);
        const byte: u32 = @intCast(@min(@max(b.cursorByte(), fnw), b.buf.items.len));
        var node = tree.rootNode().descendantForByteRange(byte, byte) orelse return 0;
        var n: usize = 0;
        while (true) {
            if (declCrumb(b, node)) |c| {
                if (n < out.len) {
                    out[n] = c;
                    n += 1;
                }
            }
            node = node.parent() orelse break;
        }
        return n;
    }

    /// NvCheatsheet-style keybinding reference, shown via `Space c h`.
    const cheats = [_][]const u8{
        "Tab          next buffer",
        "Shift-Tab    prev buffer",
        "Space /      toggle comment",
        "Space b      buffer picker",
        "Space c h    cheatsheet",
        "Space c r    rename word",
        "Space e      focus/toggle tree",
        "Space f f    find files",
        "Space f w    live grep",
        "Space f o    recent files",
        "Space f s    document symbols",
        "Space f z    buffer lines",
        "Space g b    blame line",
        "Space g p    preview hunk",
        "Space g r    reset hunk",
        "Space g s    stage hunk",
        "Space q      quickfix picker",
        "Space n      toggle line numbers",
        "Space r n    relative numbers",
        "Space t      theme picker",
        "Space x      close buffer",
        "Alt-h        terminal split",
        "Alt-v        vertical terminal",
        "Alt-i        floating terminal",
        "Ctrl-n       toggle tree",
        "Ctrl-h       focus tree",
        "Ctrl-l       focus editor",
        "Ctrl-o/i     jumplist back/fwd",
        "Ctrl-s       save file",
        "Ctrl-n/p     (insert) complete word",
        "Ctrl-Shift-c copy to clipboard",
        "Ctrl-d/u     half-page down/up",
        "Ctrl-e/y     scroll line down/up",
        "zz/zt/zb     center/top/bottom",
        "H / M / L    screen top/mid/bottom",
        "/ then n/N   search / next/prev",
        "]c / [c      next/prev git hunk",
        "]d / [d      next/prev diagnostic",
        "]q / [q      next/prev quickfix",
        "gg / G       top / bottom",
        "gf           goto file under cursor",
        "gd           goto definition",
        "gr           references (LSP)",
        "K            hover (LSP)",
        "gcc / Ngcc   toggle comment",
        "gc (visual)  comment selection",
        "gcj gck gcG  comment motion",
        "gcgg gcip    comment to top / para",
        "v / V        visual / line select",
        "y d p        yank / delete / put",
        "dd           delete line",
        "yiw yi( yy   yank object/line",
        "yw y$ Nyy    yank word/eol/N lines",
        "ciw ci( ca\"  change text object",
        "diw di( da\"  delete text object",
        "cw cc c$     change word/line/eol",
        "dw d$        delete word/eol",
        "cs \" '       change surround",
        "ds ( \" ...   delete surround",
        "S( (visual)  wrap selection",
        "u / Ctrl-r   undo / redo",
        "i / Esc      insert / normal mode",
        ":w :q :wq    write / quit",
        ":LspRestart  restart zls",
        "s (on dash)  restore session",
    };

    /// Which-key: hint rows for a pending prefix, or null for prefixes that
    /// have no hint table (some take arbitrary input like find-char/marks;
    /// others are small but unhinted like obj_i/obj_a/indent ops).
    fn whichKeyRows(p: Pending, visual: bool) ?[]const []const u8 {
        return switch (p) {
            .leader => if (visual) &.{ "/  toggle comment" } else &.{ "b  buffer picker", "c  +cheatsheet", "e  toggle tree", "f  +find", "g  +git", "n  toggle numbers", "q  quickfix list", "r  +relative", "t  theme picker", "x  close buffer", "/  toggle comment" },
            .leader_f => &.{ "f  find files", "w  live grep", "o  recent files", "s  document symbols", "z  buffer lines" },
            .leader_c => &.{ "h  cheatsheet", "r  rename word" },
            .leader_r => &.{ "n  toggle relative numbers" },
            .leader_g => &.{ "b  blame line", "p  preview hunk", "r  reset hunk", "s  stage hunk" },
            .g => if (visual) &.{ "g  goto top", "c  toggle comment" } else &.{ "g  goto top", "v  reselect visual", "f  goto file", "d  goto definition", "r  references", "c  +comment" },
            .g_comment => &.{ "c / 0  this line", "j / k  cursor+N lines", "G  to last line", "g  +to line", "i  +text object" },
            .g_comment_g => &.{ "g  comment to first line" },
            .g_comment_i => &.{ "p  comment paragraph" },
            .z => &.{ "z  center cursor", "t  cursor to top", "b  cursor to bottom" },
            .d => &.{ "d  delete line", "w  delete word", "$  delete to eol", "s  delete surround", "f F t T  find-char", "i  +inner object", "a  +around object" },
            .c_op => &.{ "c  change line", "w  change word", "$  change to eol", "e  change to word end", "f F t T  find-char", "i  +inner object", "a  +around object", "s  change surround" },
            .y_op => &.{ "y  yank line", "w  yank word", "$  yank to eol", "e  yank to word end", "f F t T  find-char", "i  +inner object", "a  +around object" },
            .bracket_f => &.{ "c  next git hunk", "d  next diagnostic", "q  next grep hit" },
            .bracket_b => &.{ "c  prev git hunk", "d  prev diagnostic", "q  prev grep hit" },
            else => null,
        };
    }

    pub fn init(alloc: std.mem.Allocator) Editor {
        var self: Editor = .{ .alloc = alloc, .tree = Tree.init(alloc) };
        self.loadGitBranch();
        self.loadOldfiles();
        return self;
    }

    const oldfiles_max = 20;

    /// `$HOME/.cache/zide/oldfiles` — one absolute path per line.
    fn oldfilesPath(self: *Editor, buf: []u8) ?[]u8 {
        _ = self;
        const home = std.posix.getenv("HOME") orelse return null;
        return std.fmt.bufPrint(buf, "{s}/.cache/zide/oldfiles", .{home}) catch null;
    }

    fn loadOldfiles(self: *Editor) void {
        var pbuf: [512]u8 = undefined;
        const path = self.oldfilesPath(&pbuf) orelse return;
        const data = std.fs.cwd().readFileAlloc(self.alloc, path, 64 * 1024) catch return;
        defer self.alloc.free(data);
        var it = std.mem.tokenizeScalar(u8, data, '\n');
        while (it.next()) |line| {
            if (line.len == 0 or self.oldfiles.items.len >= oldfiles_max) continue;
            const copy = self.alloc.dupe(u8, line) catch return;
            self.oldfiles.append(self.alloc, copy) catch {
                self.alloc.free(copy);
                return;
            };
        }
    }

    fn saveOldfiles(self: *Editor) void {
        var pbuf: [512]u8 = undefined;
        const path = self.oldfilesPath(&pbuf) orelse return;
        if (std.fs.path.dirname(path)) |dir| std.fs.cwd().makePath(dir) catch return;
        var f = std.fs.cwd().createFile(path, .{}) catch return;
        defer f.close();
        for (self.oldfiles.items) |p| {
            f.writeAll(p) catch return;
            f.writeAll("\n") catch return;
        }
    }

    /// Move `path` (as absolute) to the front of the recent-files list.
    fn recordOldfile(self: *Editor, path: []const u8) void {
        var abuf: [std.fs.max_path_bytes]u8 = undefined;
        const abs = std.fs.cwd().realpath(path, &abuf) catch path;
        for (self.oldfiles.items, 0..) |p, i| {
            if (std.mem.eql(u8, p, abs)) {
                const hit = self.oldfiles.orderedRemove(i);
                self.oldfiles.insert(self.alloc, 0, hit) catch {
                    self.alloc.free(hit);
                    return;
                };
                self.saveOldfiles();
                return;
            }
        }
        const copy = self.alloc.dupe(u8, abs) catch return;
        self.oldfiles.insert(self.alloc, 0, copy) catch {
            self.alloc.free(copy);
            return;
        };
        while (self.oldfiles.items.len > oldfiles_max) {
            const last = self.oldfiles.pop() orelse break;
            self.alloc.free(last);
        }
        self.saveOldfiles();
    }

    /// `$HOME/.cache/zide/session` — one `row:col:/abs/path` line per open
    /// buffer, then a final `active:<index>`.
    fn sessionPath(self: *Editor, buf: []u8) ?[]u8 {
        _ = self;
        const home = std.posix.getenv("HOME") orelse return null;
        return std.fmt.bufPrint(buf, "{s}/.cache/zide/session", .{home}) catch null;
    }

    /// Rewrite the session file. Called whenever the buffer set changes and
    /// on save/exit, so a crash still leaves a usable (if slightly stale)
    /// session — cheaper than writing on every cursor move.
    fn saveSession(self: *Editor) void {
        if (self.buffers.items.len == 0) return; // never clobber with nothing
        var pbuf: [512]u8 = undefined;
        const path = self.sessionPath(&pbuf) orelse return;
        if (std.fs.path.dirname(path)) |dir| std.fs.cwd().makePath(dir) catch return;
        var f = std.fs.cwd().createFile(path, .{}) catch return;
        defer f.close();
        // `active` must index the lines actually written, not self.buffers:
        // buffers whose realpath fails (new unsaved file, deleted underneath)
        // are skipped and would shift every later index.
        var written: usize = 0;
        var active_out: usize = 0;
        for (self.buffers.items, 0..) |*b, i| {
            var abuf: [std.fs.max_path_bytes]u8 = undefined;
            const abs = std.fs.cwd().realpath(b.file_name, &abuf) catch continue;
            var lbuf: [std.fs.max_path_bytes + 48]u8 = undefined;
            const line = std.fmt.bufPrint(&lbuf, "{d}:{d}:{s}\n", .{ b.row, b.col, abs }) catch continue;
            if (i == self.active) active_out = written;
            f.writeAll(line) catch return;
            written += 1;
        }
        var abuf: [32]u8 = undefined;
        f.writeAll(std.fmt.bufPrint(&abuf, "active:{d}\n", .{active_out}) catch return) catch return;
    }

    /// Dashboard `s`: reopen every session buffer and restore its cursor.
    fn restoreSession(self: *Editor) void {
        var pbuf: [512]u8 = undefined;
        const path = self.sessionPath(&pbuf) orelse return;
        const data = std.fs.cwd().readFileAlloc(self.alloc, path, 256 * 1024) catch
            return self.setStatus("no saved session", .{});
        defer self.alloc.free(data);

        var want_active: usize = 0;
        var opened: usize = 0;
        var it = std.mem.tokenizeScalar(u8, data, '\n');
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "active:")) {
                want_active = std.fmt.parseInt(usize, line["active:".len..], 10) catch 0;
                continue;
            }
            const c1 = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const rest = line[c1 + 1 ..];
            const c2 = std.mem.indexOfScalar(u8, rest, ':') orelse continue;
            const row = std.fmt.parseInt(usize, line[0..c1], 10) catch continue;
            const col = std.fmt.parseInt(usize, rest[0..c2], 10) catch continue;
            const fpath = rest[c2 + 1 ..];
            if (fpath.len == 0 or !fileExists(fpath)) continue; // openFile would
            const before = self.buffers.items.len; //               fabricate an
            self.openFile(fpath) catch continue; //                 empty buffer
            if (self.buffers.items.len == before) continue;
            const b = self.cur();
            b.row = @min(row, b.lastRow());
            b.col = col;
            b.clampCol(false); // snaps to a codepoint and clamps to line length
            b.goal_col = b.col;
            opened += 1;
        }
        if (opened == 0) return self.setStatus("no session files to restore", .{});
        self.active = @min(want_active, self.buffers.items.len - 1);
        self.saveSession();
        self.setStatus("session restored: {d} file(s)", .{opened});
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

    /// One `@@ -old_start[,old_count] +new_start[,new_count] @@` hunk plus the
    /// byte range of its body (the -/+ lines) inside the diff output.
    const Hunk = struct {
        old_start: usize,
        old_count: usize,
        new_start: usize,
        new_count: usize,
        body_start: usize = 0,
        body_end: usize = 0,

        /// 0-based row the hunk's sign sits on — must match refreshGitSigns
        /// so `]c` always lands somewhere `Space g r/p` accepts.
        fn signRow(h: Hunk) usize {
            if (h.new_count == 0) return if (h.new_start > 0) h.new_start - 1 else 0;
            return h.new_start - 1;
        }
        fn covers(h: Hunk, row: usize) bool {
            if (h.new_count == 0) return row == h.signRow();
            return row >= h.new_start - 1 and row < h.new_start - 1 + h.new_count;
        }
        fn body(h: Hunk, text: []const u8) []const u8 {
            const s = @min(h.body_start, text.len);
            const e = @min(@max(h.body_end, s), text.len);
            return text[s..e];
        }
    };

    fn parseSpec(spec: []const u8) ?[2]usize {
        if (std.mem.indexOfScalar(u8, spec, ',')) |c| return .{
            std.fmt.parseInt(usize, spec[0..c], 10) catch return null,
            std.fmt.parseInt(usize, spec[c + 1 ..], 10) catch return null,
        };
        return .{ std.fmt.parseInt(usize, spec, 10) catch return null, 1 };
    }

    /// Parse a unified-diff hunk header. A missing count means 1
    /// (`@@ -2 +2 @@`); the trailing function-context text is ignored.
    fn parseHunkHeader(line: []const u8) ?Hunk {
        if (!std.mem.startsWith(u8, line, "@@ -")) return null;
        var it = std.mem.tokenizeScalar(u8, line[4..], ' ');
        const old_spec = it.next() orelse return null;
        const new_raw = it.next() orelse return null;
        if (new_raw.len < 2 or new_raw[0] != '+') return null;
        const o = parseSpec(old_spec) orelse return null;
        const n = parseSpec(new_raw[1..]) orelse return null;
        // Git only emits +0 with an explicit 0 count (pure deletions);
        // reject +0 with a nonzero count so covers() can safely compute
        // new_start - 1 instead of trusting that invariant blindly.
        if (n[0] == 0 and n[1] != 0) return null;
        return .{ .old_start = o[0], .old_count = o[1], .new_start = n[0], .new_count = n[1] };
    }

    /// The hunk whose new-side lines contain `row` (0-based), or null.
    fn findHunkAt(text: []const u8, row: usize) ?Hunk {
        var open: ?Hunk = null;
        var it = std.mem.splitScalar(u8, text, '\n');
        var off: usize = 0;
        while (it.next()) |line| : (off += line.len + 1) {
            if (!std.mem.startsWith(u8, line, "@@ ")) continue;
            if (open) |prev| {
                var done = prev;
                done.body_end = off; // body runs up to this next header
                if (done.covers(row)) return done;
            }
            var h = parseHunkHeader(line) orelse continue;
            h.body_start = off + line.len + 1;
            open = h;
        }
        if (open) |prev| {
            var done = prev;
            done.body_end = text.len;
            if (done.covers(row)) return done;
        }
        return null;
    }

    /// The comparison base for a hunk diff: HEAD for display/reset (matches
    /// the gutter signs), the index for staging — `git apply --cached`
    /// targets the index, so a HEAD-based preimage mis-places pure-add
    /// hunks whenever an earlier hunk is not yet staged.
    const DiffBase = enum { head, index };

    /// `git diff --no-color -U0 [HEAD] -- file` stdout (caller frees), or
    /// null outside a repo / for an untracked path.
    fn gitDiffText(self: *Editor, b: *Buffer, base: DiffBase) ?[]u8 {
        const argv_head: []const []const u8 =
            &.{ "git", "diff", "--no-color", "-U0", "HEAD", "--", b.file_name };
        const argv_index: []const []const u8 =
            &.{ "git", "diff", "--no-color", "-U0", "--", b.file_name };
        const res = std.process.Child.run(.{
            .allocator = self.alloc,
            .argv = if (base == .head) argv_head else argv_index,
            .max_output_bytes = 1 << 20,
        }) catch return null;
        self.alloc.free(res.stderr);
        if (res.term != .Exited or res.term.Exited != 0) {
            self.alloc.free(res.stdout);
            return null;
        }
        return res.stdout;
    }

    /// Shared gate for the `Space g` actions: git sees the file ON DISK, so an
    /// unsaved buffer would make every line number lie (and reset would splice
    /// the wrong rows). gitsigns works off the index the same way.
    fn gitTarget(self: *Editor) ?*Buffer {
        if (self.buffers.items.len == 0) return null;
        const b = self.cur();
        if (b.dirty) {
            self.setStatus("save first: git commands read the file on disk", .{});
            return null;
        }
        return b;
    }

    /// `Space g r` (gitsigns reset_hunk): restore the hunk under the cursor to
    /// its HEAD content, as one undo group.
    fn resetHunk(self: *Editor) !void {
        const b = self.gitTarget() orelse return;
        const text = self.gitDiffText(b, .head) orelse
            return self.setStatus("no git diff for this file", .{});
        defer self.alloc.free(text);
        const h = findHunkAt(text, b.row) orelse
            return self.setStatus("no hunk under cursor", .{});

        // Old side of the hunk: the '-' body lines, each re-terminated.
        // A "\ No newline at end of file" marker right after a '-' line
        // means HEAD's side lacked the final newline — trust the marker,
        // not the buffer's EOF state (they differ in exactly the
        // trailing-newline-only hunks that made the old heuristic a no-op).
        var old: std.ArrayListUnmanaged(u8) = .{};
        defer old.deinit(self.alloc);
        var old_no_nl = false;
        var last_sign: u8 = 0;
        var it = std.mem.splitScalar(u8, h.body(text), '\n');
        while (it.next()) |ln| {
            if (ln.len == 0) continue;
            if (ln[0] == '\\') {
                if (last_sign == '-') old_no_nl = true;
                continue;
            }
            last_sign = ln[0];
            if (ln[0] != '-') continue;
            try old.appendSlice(self.alloc, ln[1..]);
            try old.append(self.alloc, '\n');
        }
        if (old_no_nl and old.items.len > 0) _ = old.pop();

        // (Redundant arming — the keypress already did it — kept in case
        // this is ever called outside the key path.)
        b.undo_new_group = true;
        if (h.new_count == 0) {
            // Pure deletion: put the old lines back after row new_start-1
            // (new_start == 0 means they were deleted from the very top).
            const at = if (h.new_start == 0) 0 else @min(
                b.lines.items[@min(h.new_start - 1, b.lines.items.len - 1)].end + 1,
                b.buf.items.len,
            );
            try b.replaceRange(at, at, old.items);
            b.row = @min(if (h.new_start == 0) 0 else h.new_start, b.lastRow());
        } else {
            const first = @min(h.new_start - 1, b.lines.items.len - 1);
            const last = @min(first + h.new_count - 1, b.lines.items.len - 1);
            const start = b.lines.items[first].start;
            var end: usize = b.lines.items[last].end;
            if (end < b.buf.items.len) end += 1; // take the trailing newline
            try b.replaceRange(start, end, old.items); // "" for a pure-add hunk
            b.row = @min(first, b.lastRow());
        }
        b.col = 0;
        b.goal_col = 0;
        b.clampCol(false);
        self.setStatus("hunk reset (:w to save, u to undo)", .{});
    }

    /// `Space g s` (gitsigns stage_hunk): feed just the hunk under the
    /// cursor to `git apply --cached`. The diff's own header block —
    /// everything before the first `@@` — is reused verbatim because its
    /// paths are repo-root-relative, while b.file_name may be cwd-relative
    /// and the cwd need not be the repo root.
    fn stageHunk(self: *Editor) !void {
        const b = self.gitTarget() orelse return;
        // Index-based diff (see DiffBase): line numbers stay valid however
        // many other hunks are staged, and an already-staged hunk simply
        // disappears from the diff instead of staging twice.
        const text = self.gitDiffText(b, .index) orelse
            return self.setStatus("no git diff for this file", .{});
        defer self.alloc.free(text);
        const h = findHunkAt(text, b.row) orelse
            return self.setStatus("no unstaged hunk under cursor", .{});
        const hdr_nl = std.mem.indexOf(u8, text, "\n@@ ") orelse
            return self.setStatus("unexpected diff format", .{});

        var patch: std.ArrayListUnmanaged(u8) = .{};
        defer patch.deinit(self.alloc);
        try patch.appendSlice(self.alloc, text[0 .. hdr_nl + 1]);
        // Rebuilt from the parsed Hunk: git omits a ",1" count and appends
        // function context, both of which apply cleanly when normalized.
        // CRITICAL: the diff's new-side start is worktree-relative, but this
        // single-hunk patch is applied to the index — git seeks pure-add
        // hunks (no '-' anchor lines) from the new-side start, so an earlier
        // unstaged hunk would silently shift the insertion point. Derive the
        // new-side start from the old side, the only index-true base.
        const new_start = if (h.old_count == 0) h.old_start + 1 else h.old_start;
        var hbuf: [80]u8 = undefined;
        try patch.appendSlice(self.alloc, std.fmt.bufPrint(&hbuf, "@@ -{d},{d} +{d},{d} @@\n", .{
            h.old_start, h.old_count, new_start, h.new_count,
        }) catch return self.setStatus("hunk header too long", .{}));
        // Body verbatim, "\ No newline at end of file" markers included.
        try patch.appendSlice(self.alloc, h.body(text));
        if (patch.items.len > 0 and patch.items[patch.items.len - 1] != '\n')
            try patch.append(self.alloc, '\n');

        var child = std.process.Child.init(
            &.{ "git", "apply", "--cached", "--unidiff-zero", "-" },
            self.alloc,
        );
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Pipe;
        child.spawn() catch return self.setStatus("could not run git apply", .{});
        if (child.stdin) |in| {
            in.writeAll(patch.items) catch {};
            in.close();
            child.stdin = null; // wait() would otherwise close it twice
        }
        var ebuf: [256]u8 = undefined;
        var elen: usize = 0;
        if (child.stderr) |errf| {
            elen = errf.readAll(&ebuf) catch 0;
            if (elen == ebuf.len) { // drain, so git never blocks on a full pipe
                var sink: [512]u8 = undefined;
                while ((errf.read(&sink) catch 0) > 0) {}
            }
        }
        const term = child.wait() catch return self.setStatus("git apply failed", .{});
        if (term != .Exited or term.Exited != 0) {
            const out = std.mem.trimRight(u8, ebuf[0..elen], "\n");
            var first = out[0 .. std.mem.indexOfScalar(u8, out, '\n') orelse out.len];
            // Cap so setStatus's 256-byte buffer can't overflow and
            // silently show nothing.
            first = first[0..Buffer.snapToCp(first, @min(first.len, 200))];
            return self.setStatus("git apply: {s}", .{if (first.len > 0) first else "failed"});
        }
        // Signs are diffed against HEAD, not the index, so staging leaves
        // them exactly as they were — nothing to refresh.
        self.setStatus("hunk staged", .{});
    }

    const preview_max_rows = 12;
    const preview_max_cols = 72;

    /// Append one row, truncated on a codepoint boundary. Tabs expand to
    /// 4-space stops first: writeText renders a raw '\t' as zero-width,
    /// which would strip the indentation of previewed code.
    fn appendPreviewLine(self: *Editor, line: []const u8) void {
        var ex: [preview_max_cols + 4]u8 = undefined;
        var n: usize = 0;
        for (line) |ch| {
            if (n >= ex.len) break;
            if (ch == '\t') {
                const stop = @min(((n / 4) + 1) * 4, ex.len);
                while (n < stop) : (n += 1) ex[n] = ' ';
            } else {
                ex[n] = ch;
                n += 1;
            }
        }
        var w = @min(n, preview_max_cols);
        while (w > 0 and w < n and (ex[w] & 0xC0) == 0x80) w -= 1;
        if (self.preview_len + w + 1 > self.preview_buf.len) return;
        @memcpy(self.preview_buf[self.preview_len..][0..w], ex[0..w]);
        self.preview_len += w;
        self.preview_buf[self.preview_len] = '\n';
        self.preview_len += 1;
    }

    /// `Space g p` (gitsigns preview_hunk).
    fn previewHunk(self: *Editor) void {
        self.preview_len = 0;
        const b = self.gitTarget() orelse return;
        const text = self.gitDiffText(b, .head) orelse
            return self.setStatus("no git diff for this file", .{});
        defer self.alloc.free(text);
        const h = findHunkAt(text, b.row) orelse
            return self.setStatus("no hunk under cursor", .{});

        var hbuf: [64]u8 = undefined;
        self.appendPreviewLine(std.fmt.bufPrint(&hbuf, "@@ -{d},{d} +{d},{d} @@", .{
            h.old_start, h.old_count, h.new_start, h.new_count,
        }) catch "@@");
        var rows: usize = 1;
        var it = std.mem.splitScalar(u8, h.body(text), '\n');
        while (it.next()) |ln| {
            if (ln.len == 0 or (ln[0] != '-' and ln[0] != '+')) continue; // skips "\ No newline…"
            if (rows >= preview_max_rows) {
                self.appendPreviewLine("...");
                break;
            }
            self.appendPreviewLine(ln);
            rows += 1;
        }
    }

    /// Hunk preview panel: same geometry as drawWhichKey (right-aligned above
    /// the status line) but per-row colors for +/-.
    fn drawPreview(self: *Editor, surface: vxfw.Surface, ctx: vxfw.DrawContext, max: vxfw.Size) void {
        if (self.preview_len == 0) return;
        const th = self.theme.p;
        const text = self.preview_buf[0..self.preview_len];

        var panel_w: u16 = 0;
        var n_rows: u16 = 0;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |ln| {
            if (ln.len == 0) continue;
            const w: u16 = @intCast(@min(ctx.stringWidth(ln), max.width));
            if (w > panel_w) panel_w = w;
            n_rows += 1;
        }
        if (n_rows == 0) return;
        panel_w += 2;
        if (max.width < panel_w) return;
        const status_row = max.height -| 1;
        if (status_row < n_rows + 1) return; // keep row 0 (tabline) clear
        const x0 = max.width -| panel_w;
        const y0 = status_row -| n_rows;

        const bg: vaxis.Style = .{ .bg = th.bar_bg };
        var r: u16 = 0;
        while (r < n_rows) : (r += 1) {
            var c: u16 = 0;
            while (c < panel_w) : (c += 1) surface.writeCell(x0 + c, y0 + r, .{ .style = bg });
        }
        r = 0;
        it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |ln| {
            if (ln.len == 0) continue;
            const fg = switch (ln[0]) {
                '+' => th.green,
                '-' => th.red,
                else => th.gray,
            };
            _ = writeText(surface, ctx, x0 + 1, y0 + r, ln, .{ .fg = fg, .bg = th.bar_bg });
            r += 1;
        }
    }

    /// UTC `YYYY-MM-DD` for a unix timestamp.
    fn fmtDate(buf: []u8, secs: i64) []const u8 {
        if (secs <= 0) return "?";
        const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
        const yd = es.getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        return std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2}", .{
            yd.year, md.month.numeric(), md.day_index + 1,
        }) catch "?";
    }

    /// `Space g b` (gitsigns blame_line): author, date and summary for the
    /// cursor line, in the status line.
    fn blameLine(self: *Editor) void {
        const b = self.gitTarget() orelse return;
        // A mouse click can park the cursor on the phantom last line; git
        // would answer "file has only N lines".
        const row = @min(b.row, b.lastRow());
        var lbuf: [40]u8 = undefined;
        const spec = std.fmt.bufPrint(&lbuf, "{d},{d}", .{ row + 1, row + 1 }) catch return;
        const res = std.process.Child.run(.{
            .allocator = self.alloc,
            .argv = &.{ "git", "blame", "-L", spec, "--line-porcelain", "--", b.file_name },
            .max_output_bytes = 1 << 16,
        }) catch return self.setStatus("git blame: failed to run", .{});
        defer self.alloc.free(res.stdout);
        defer self.alloc.free(res.stderr);
        if (res.term != .Exited or res.term.Exited != 0) {
            const msg = std.mem.sliceTo(std.mem.trim(u8, res.stderr, " \r\n"), '\n');
            return self.setStatus("git blame: {s}", .{if (msg.len > 0) msg else "not tracked"});
        }
        var author: []const u8 = "";
        var summary: []const u8 = "";
        var when: i64 = 0;
        var it = std.mem.splitScalar(u8, res.stdout, '\n');
        while (it.next()) |ln| {
            if (std.mem.startsWith(u8, ln, "author ")) {
                author = ln["author ".len..];
            } else if (std.mem.startsWith(u8, ln, "author-time ")) {
                when = std.fmt.parseInt(i64, ln["author-time ".len..], 10) catch 0;
            } else if (std.mem.startsWith(u8, ln, "summary ")) {
                summary = ln["summary ".len..];
            } else if (std.mem.startsWith(u8, ln, "\t")) break; // line content ends the header
        }
        if (std.mem.eql(u8, author, "Not Committed Yet"))
            return self.setStatus("line {d}: not committed yet", .{row + 1});
        var dbuf: [16]u8 = undefined;
        const date = fmtDate(&dbuf, when);
        // Codepoint-safe caps keep the total under status_buf's 256 bytes
        // (a too-long line makes setStatus silently show nothing).
        const a = author[0..Buffer.snapToCp(author, @min(author.len, 80))];
        const sum = summary[0..Buffer.snapToCp(summary, @min(summary.len, 120))];
        self.setStatus("{s}, {s}: {s}", .{ a, date, sum });
    }

    pub fn deinit(self: *Editor) void {
        self.saveSession();
        for (self.buffers.items) |*b| b.deinit();
        self.buffers.deinit(self.alloc);
        self.jumps.deinit(self.alloc);
        self.reg.deinit(self.alloc);
        self.cmd.deinit(self.alloc);
        self.search.deinit(self.alloc);
        self.popup.filter.deinit(self.alloc);
        self.clearFiles();
        self.files.deinit(self.alloc);
        for (self.oldfiles.items) |p| self.alloc.free(p);
        self.oldfiles.deinit(self.alloc);
        self.clearGrep();
        self.grep_hits.deinit(self.alloc);
        self.cmpClose();
        self.cmp.items.deinit(self.alloc);
        self.cmp.prefix.deinit(self.alloc);
        self.clearLines();
        self.line_hits.deinit(self.alloc);
        self.clearSymbols();
        self.symbol_hits.deinit(self.alloc);
        self.tree.deinit();
        for (&self.macros) |*m| m.deinit(self.alloc);
        self.dot.deinit(self.alloc);
        self.dot_rec.deinit(self.alloc);
        if (self.term) |*t| t.deinit();
        if (self.lsp) |*l| l.deinit();
        if (self.lsp_root) |r| self.alloc.free(r);
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
        self.lspDidOpen(self.cur());
        self.recordOldfile(path);
        self.saveSession();
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
        // Buffer indices shift: a flash or completion region keyed on the
        // old index/offsets must not survive.
        self.yank_flash = null;
        self.lsp_req = null; // indices shift; a pending gd must not push a stale jump
        if (self.cmp.active) self.cmpClose();
        self.lspDidClose(b);
        var removed = self.buffers.orderedRemove(self.active);
        removed.deinit();
        if (self.buffers.items.len == 0) {
            self.active = 0; // back to the dashboard; :q there quits
            self.mode = .normal;
            return;
        }
        self.active = @min(self.active, self.buffers.items.len - 1);
        self.saveSession();
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

    // ---- LSP --------------------------------------------------------------

    /// Start zls on first use. A failure is permanent for the session.
    fn ensureLsp(self: *Editor) ?*Lsp {
        if (self.lsp) |*l| return if (l.alive) l else null;
        if (self.lsp_failed) return null;
        const root = std.process.getCwdAlloc(self.alloc) catch {
            self.lsp_failed = true;
            return null;
        };
        self.lsp = Lsp.spawn(self.alloc, root) catch {
            self.alloc.free(root);
            self.lsp_failed = true;
            self.setStatus("zls not found — LSP disabled", .{});
            return null;
        };
        self.lsp_root = root; // owned, freed in deinit
        return &self.lsp.?;
    }

    /// `:LspRestart` — tear the client down, dead or alive, and let ensureLsp
    /// spawn a fresh one. Every zig buffer is re-opened by the next poll tick's
    /// deferred-didOpen pass, so nothing here has to send didOpen itself.
    fn lspRestart(self: *Editor) void {
        if (self.lsp) |*l| l.deinit();
        self.lsp = null;
        // ensureLsp allocates a fresh root; overwriting the old pointer leaks it.
        if (self.lsp_root) |r| self.alloc.free(r);
        self.lsp_root = null;
        self.lsp_failed = false; // the whole point: undo the permanent-death flag
        self.lsp_req = null;
        for (self.buffers.items) |*b| {
            for (b.diags.items) |d| self.alloc.free(d.message);
            b.diags.clearRetainingCapacity();
            b.lsp_opened = false;
            b.lsp_dirty = false;
            b.lsp_version = 0;
        }
        if (self.ensureLsp() == null) return; // its own status stands ("zls not found")
        // The poll chain is re-armed by the key_press handler on the way out
        // (it checks lspAlive after dispatchKey, which is what ran this).
        self.setStatus("zls restarted", .{});
    }

    /// Absolute path for a buffer (file_name may be relative to the cwd).
    fn absPath(self: *Editor, b: *const Buffer) ?[]u8 {
        const root = self.lsp_root orelse return null;
        return std.fs.path.resolve(self.alloc, &.{ root, b.file_name }) catch null;
    }

    fn bufUri(self: *Editor, b: *const Buffer) ?[]u8 {
        const abs = self.absPath(b) orelse return null;
        defer self.alloc.free(abs);
        return Lsp.uriFromPath(self.alloc, abs) catch null;
    }

    /// Editor-facing name for an absolute path from the server: the file_name
    /// of an open buffer that resolves to it, else a cwd-relative path, else
    /// the absolute one. Keeps openFile's exact-string match from opening a
    /// second buffer for a file spelled differently. Caller frees.
    fn lspLocalPath(self: *Editor, abs: []const u8) ?[]u8 {
        for (self.buffers.items) |*b| {
            const a = self.absPath(b) orelse continue;
            defer self.alloc.free(a);
            if (std.mem.eql(u8, a, abs)) return self.alloc.dupe(u8, b.file_name) catch null;
        }
        if (self.lsp_root) |root| {
            if (std.fs.path.relative(self.alloc, root, abs) catch null) |rel| {
                if (rel.len > 0 and !std.mem.startsWith(u8, rel, "..")) return rel;
                self.alloc.free(rel); // outside the project: keep it absolute
            }
        }
        return self.alloc.dupe(u8, abs) catch null;
    }

    /// didOpen for a zig buffer, spawning the client if needed. Before the
    /// initialize response lands this is a no-op: lspTick opens it later.
    fn lspDidOpen(self: *Editor, b: *Buffer) void {
        if (!b.isZig()) return;
        const l = self.ensureLsp() orelse return;
        if (!l.initialized or b.lsp_opened) return;
        const uri = self.bufUri(b) orelse return;
        defer self.alloc.free(uri);
        b.lsp_version = 1;
        l.didOpen(uri, b.buf.items, b.lsp_version);
        b.lsp_opened = true;
        b.lsp_dirty = false;
    }

    fn lspDidClose(self: *Editor, b: *Buffer) void {
        const l = if (self.lsp) |*p| p else return;
        if (!l.alive or !b.lsp_opened) return;
        const uri = self.bufUri(b) orelse return;
        defer self.alloc.free(uri);
        l.didClose(uri);
        b.lsp_opened = false;
    }

    fn lspDidSave(self: *Editor, b: *Buffer) void {
        const l = if (self.lsp) |*p| p else return;
        if (!l.alive or !b.lsp_opened) return;
        const uri = self.bufUri(b) orelse return;
        defer self.alloc.free(uri);
        l.didSave(uri);
    }

    /// K: ask zls about the identifier under the cursor. The answer arrives on
    /// a later poll tick and lands in the preview panel.
    fn lspHover(self: *Editor) void {
        const b = self.cur();
        if (!b.isZig()) return self.setStatus("no language server for this file", .{});
        const l = self.ensureLsp() orelse
            return self.setStatus("LSP is not running", .{});
        if (!l.initialized or !b.lsp_opened) return self.setStatus("zls: not ready yet", .{});
        const uri = self.bufUri(b) orelse return;
        defer self.alloc.free(uri);
        // utf-8 position encoding was negotiated: byte columns go over as-is.
        l.hover(uri, b.row, b.col);
    }

    /// `gr`: every reference to the symbol under the cursor, loaded into the
    /// quickfix list (]q / [q) — the same backing store as live grep, so a
    /// later `Space f w` replaces them, vim's single-list rule.
    fn lspReferences(self: *Editor) void {
        if (self.buffers.items.len == 0) return;
        const b = self.cur();
        if (!b.isZig()) return self.setStatus("no language server for this file", .{});
        const l = self.ensureLsp() orelse return self.setStatus("LSP is not running", .{});
        if (!l.initialized or !b.lsp_opened) return self.setStatus("zls: not ready yet", .{});
        const uri = self.bufUri(b) orelse return;
        defer self.alloc.free(uri);
        l.references(uri, b.row, b.col);
        self.setStatus("gr: searching...", .{});
    }

    /// Pump the client from the poll tick: I/O, deferred didOpen, debounced
    /// didChange, diagnostics, hover. Returns true when the screen must repaint.
    fn lspTick(self: *Editor) bool {
        if (self.lsp == null) return false;
        var changed = self.lsp.?.poll();
        if (!self.lsp.?.alive) {
            self.lsp.?.deinit();
            self.lsp = null;
            self.lsp_failed = true; // report once, never respawn
            // Nothing will ever update or clear these again — stale marks
            // would otherwise outlive the server (and the buffer contents).
            for (self.buffers.items) |*b| {
                for (b.diags.items) |d| self.alloc.free(d.message);
                b.diags.clearRetainingCapacity();
                b.lsp_opened = false;
            }
            self.lsp_req = null;
            self.setStatus("zls exited — LSP off", .{});
            return true;
        }
        const l = &self.lsp.?;
        if (l.initialized) {
            for (self.buffers.items) |*b| {
                if (!b.isZig()) continue;
                if (!b.lsp_opened) {
                    self.lspDidOpen(b);
                    continue;
                }
                if (!b.lsp_dirty) continue;
                const uri = self.bufUri(b) orelse continue;
                defer self.alloc.free(uri);
                b.lsp_version += 1;
                l.didChange(uri, b.buf.items, b.lsp_version);
                b.lsp_dirty = false;
            }
        }
        // FIFO: pop() would apply the OLDEST publish last, resurrecting
        // diagnostics that an immediately-following empty publish had
        // already cleared (last publish must win per LSP semantics).
        for (l.publishes.items) |p| {
            var owner: ?*Buffer = null;
            for (self.buffers.items) |*b| {
                const abs = self.absPath(b) orelse continue;
                defer self.alloc.free(abs);
                if (std.mem.eql(u8, abs, p.path)) {
                    owner = b;
                    break;
                }
            }
            if (owner) |b| {
                b.setDiags(self.alloc, p.diags);
                changed = true;
            } else Lsp.freeDiags(self.alloc, p.diags);
            self.alloc.free(p.path);
        }
        l.publishes.clearRetainingCapacity();
        if (l.hover_text) |txt| {
            defer self.alloc.free(txt);
            l.hover_text = null;
            self.preview_len = 0;
            var rows: usize = 0;
            var it = std.mem.splitScalar(u8, txt, '\n');
            while (it.next()) |ln| {
                const t = std.mem.trim(u8, ln, " \t\r");
                if (std.mem.startsWith(u8, t, "```")) continue; // markdown fences
                if (t.len == 0 and rows == 0) continue;
                if (rows >= preview_max_rows) {
                    self.appendPreviewLine("...");
                    break;
                }
                self.appendPreviewLine(ln);
                rows += 1;
            }
            changed = true;
        }
        if (l.def_done) {
            l.def_done = false;
            const loc = l.def_loc;
            l.def_loc = null;
            self.applyDefinition(loc);
            changed = true;
        }
        if (l.refs_done) {
            l.refs_done = false;
            const locs = l.refs;
            l.refs = &.{};
            self.applyReferences(locs);
            changed = true;
        }
        return changed;
    }

    /// The definition answer, ~one poll tick after `gd`. vim semantics: jump
    /// even if the cursor moved meanwhile — but the jumplist entry points at
    /// where `gd` was pressed, so Ctrl-o returns to the request point.
    fn applyDefinition(self: *Editor, loc: ?Lsp.Loc) void {
        const req = self.lsp_req;
        self.lsp_req = null;
        const l = loc orelse {
            // zls had no answer (not on a resolvable symbol). Fall back to the
            // local search, but only while the user is still in the buffer
            // that asked.
            if (req) |r| if (r.buf == self.active) return self.gotoDefLocal();
            return self.setStatus("gd: no definition found", .{});
        };
        defer self.alloc.free(l.path);
        const name = self.lspLocalPath(l.path) orelse return;
        defer self.alloc.free(name);
        if (req) |r| {
            if (r.buf < self.buffers.items.len) self.pushJumpAt(r.buf, r.row, r.col);
        }
        if (!self.jumpTo(name, l.line + 1)) return; // jumpTo is 1-based, LSP is 0-based
        const b = self.cur();
        b.col = @min(l.col, b.lineLen(b.row)); // byte column: utf-8 negotiated
        b.goal_col = b.col;
        b.clampCol(false);
        self.setStatus("{s}:{d}:{d}", .{ name, l.line + 1, l.col + 1 });
    }

    /// Load reference locations into the quickfix list. No jump and no picker:
    /// ]q / [q already walk this list, and opening the grep popup would let the
    /// next filter keystroke re-grep straight over the results.
    fn applyReferences(self: *Editor, locs: []Lsp.Loc) void {
        defer Lsp.freeLocs(self.alloc, locs);
        if (locs.len == 0) return self.setStatus("gr: no references found", .{});
        self.clearGrep();
        // locs are sorted by path, so one cached file read covers each file.
        var cache_path: ?[]u8 = null;
        var cache_data: ?[]u8 = null;
        defer {
            if (cache_path) |p| self.alloc.free(p);
            if (cache_data) |d| self.alloc.free(d);
        }
        for (locs) |loc| {
            if (self.grep_hits.items.len >= Popup.max_items) break;
            const name = self.lspLocalPath(loc.path) orelse continue;
            // Source text: an open buffer wins (it may be newer than disk).
            var text: []const u8 = "";
            var found = false;
            for (self.buffers.items) |*b| {
                if (!std.mem.eql(u8, b.file_name, name)) continue;
                if (loc.line < b.lines.items.len) { text = b.lineText(loc.line); found = true; }
                break;
            }
            if (!found) {
                if (cache_path == null or !std.mem.eql(u8, cache_path.?, name)) {
                    if (cache_path) |p| self.alloc.free(p);
                    if (cache_data) |d| self.alloc.free(d);
                    cache_path = self.alloc.dupe(u8, name) catch null;
                    cache_data = std.fs.cwd().readFileAlloc(self.alloc, name, Popup.max_file_size) catch null;
                }
                if (cache_data) |d| {
                    var it = std.mem.splitScalar(u8, d, '\n');
                    var i: u32 = 0;
                    while (it.next()) |ln| : (i += 1) if (i == loc.line) { text = ln; break; };
                }
            }
            text = std.mem.trim(u8, text, " \t\r");
            var end: usize = @min(text.len, 80);
            while (end > 0 and end < text.len and (text[end] & 0xC0) == 0x80) end -= 1; // utf-8 boundary
            const disp = std.fmt.allocPrint(self.alloc, "{s}:{d}: {s}", .{ name, loc.line + 1, text[0..end] }) catch {
                self.alloc.free(name);
                continue;
            };
            self.grep_hits.append(self.alloc, .{ .path = name, .line = loc.line + 1, .disp = disp }) catch {
                self.alloc.free(name);
                self.alloc.free(disp);
                break;
            };
        }
        const n = self.grep_hits.items.len;
        if (n < locs.len) {
            // The cap is real on big symbols (Editor has 100+ refs):
            // never let "96 references" read as the true total.
            self.setStatus("showing {d} of {d} references", .{ n, locs.len });
        } else {
            self.setStatus("{d} reference{s} - ]q / [q to navigate", .{ n, if (n == 1) "" else "s" });
        }
        // NvChad shows references in a picker immediately; Esc keeps them
        // in the quickfix list for ]q / [q. Guarded: the reply lands on a
        // tick, and opening mid-insert (or over another picker) would
        // reroute in-flight keystrokes into the filter — or worse, let a
        // race-timed Enter jump somewhere the user never chose.
        if (self.popup.kind == .none and self.mode == .normal) self.openPopup(.qf);
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
        self.lspDidSave(b);
        self.saveSession();
    }

    // ---- popup ------------------------------------------------------------

    fn openPopup(self: *Editor, kind: Popup.Kind) void {
        if (kind == .files or kind == .grep) self.refreshFiles();
        if (kind == .grep) self.clearGrep();
        // .qf deliberately refreshes nothing: it is a window onto the
        // current quickfix list (grep or gr results), not a new search.
        if (kind == .lines) self.refreshLines();
        if (kind == .symbols) self.refreshSymbols();
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
        self.qf_idx = 0;
        self.qf_seen = false;
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

    fn clearLines(self: *Editor) void {
        for (self.line_hits.items) |h| self.alloc.free(h.disp);
        self.line_hits.clearRetainingCapacity();
    }

    /// Fill the line picker from the active buffer: every non-blank line of
    /// the first Popup.max_files lines, as "NNNN: text".
    fn refreshLines(self: *Editor) void {
        self.clearLines();
        if (self.buffers.items.len == 0) return;
        const b = self.cur();
        const n = @min(b.lines.items.len, Popup.max_lines);
        if (n < b.lines.items.len)
            self.setStatus("line picker: first {d} of {d} lines", .{ n, b.lines.items.len });
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const raw = std.mem.trim(u8, b.lineText(i), " \t\r");
            if (raw.len == 0) continue;
            var end: usize = @min(raw.len, 80);
            while (end > 0 and end < raw.len and (raw[end] & 0xC0) == 0x80) end -= 1;
            const disp = std.fmt.allocPrint(self.alloc, "{d:>4}: {s}", .{ i + 1, raw[0..end] }) catch continue;
            self.line_hits.append(self.alloc, .{ .row = i, .disp = disp }) catch {
                self.alloc.free(disp);
                return;
            };
        }
    }

    fn clearSymbols(self: *Editor) void {
        for (self.symbol_hits.items) |h| self.alloc.free(h.disp);
        self.symbol_hits.clearRetainingCapacity();
    }

    /// Fill the outline picker by walking the active buffer's syntax tree.
    /// Buffers that are not Zig still parse (one grammar), they just yield no
    /// declarations — hence the empty-result status.
    fn refreshSymbols(self: *Editor) void {
        self.clearSymbols();
        if (self.buffers.items.len == 0) return;
        const b = self.cur();
        const tree = b.hl.tree orelse return;
        self.walkSymbols(b, tree.rootNode());
        if (self.symbol_hits.items.len == 0)
            self.setStatus("no symbols in {s}", .{b.displayName()});
    }

    fn walkSymbols(self: *Editor, b: *const Buffer, node: ts.Node) void {
        if (self.symbol_hits.items.len >= Popup.max_symbols) return;
        if (declCrumb(b, node)) |c| {
            const disp = std.fmt.allocPrint(self.alloc, "{s: <7}{s}", .{ c.kw, c.name }) catch return;
            self.symbol_hits.append(self.alloc, .{
                .row = @intCast(node.startPoint().row),
                .disp = disp,
            }) catch {
                self.alloc.free(disp);
                return;
            };
        }
        const n = node.namedChildCount();
        var i: u32 = 0;
        while (i < n) : (i += 1) self.walkSymbols(b, node.namedChild(i) orelse continue);
    }

    /// Open `path` and place the cursor on `line` (1-based), roughly centered.
    /// Returns false when the target could not actually be focused —
    /// openFile soft-fails (setStatus + plain return) on read errors, and
    /// moving the cursor in whatever buffer is current would silently jump
    /// the wrong file to the hit's line number.
    fn jumpTo(self: *Editor, path: []const u8, line: usize) bool {
        self.openFile(path) catch {
            self.setStatus("could not open {s}", .{path});
            return false;
        };
        if (self.buffers.items.len == 0) return false; // open failed softly
        const b = self.cur();
        if (!std.mem.eql(u8, b.file_name, path)) return false; // soft-fail kept old buffer
        b.row = @min(line -| 1, b.lines.items.len -| 1);
        b.col = b.firstNonWs(b.row);
        b.goal_col = b.col;
        b.clampCol(false);
        b.scroll = b.row -| (self.last_height / 2);
        return true;
    }

    /// vim quickfix analog over the last `Space f w` results, which outlive
    /// the picker (clearGrep only runs on a new grep or teardown).
    fn jumpQuickfix(self: *Editor, dir: i2) void {
        const n = self.grep_hits.items.len;
        if (n == 0) return self.setStatus("quickfix empty (Space f w to grep)", .{});
        if (self.qf_seen) {
            const i: isize = @intCast(self.qf_idx);
            self.qf_idx = @intCast(@mod(i + dir, @as(isize, @intCast(n))));
        } else self.qf_seen = true;
        if (self.qf_idx >= n) self.qf_idx = 0;
        const h = self.grep_hits.items[self.qf_idx];
        // Files can vanish or become unreadable between the grep and now:
        // never report success over a jump that didn't happen (and keep
        // qf_idx advanced so ]q can step past dead entries).
        if (!fileExists(h.path))
            return self.setStatus("quickfix {d}/{d}: {s} is gone", .{ self.qf_idx + 1, n, h.path });
        if (!self.jumpTo(h.path, h.line)) return; // jumpTo's error status stands
        self.setStatus("quickfix {d}/{d}: {s}:{d}", .{ self.qf_idx + 1, n, h.path, h.line });
    }

    fn popupTitle(self: *const Editor) []const u8 {
        return switch (self.popup.kind) {
            .buffers => " Buffers ",
            .themes => " Themes ",
            .files => " Find Files ",
            .keys => " Cheatsheet ",
            .grep => " Live Grep ",
            .recent => " Recent Files ",
            .lines => " Buffer Lines ",
            .symbols => " Document Symbols ",
            .qf => " Quickfix ",
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
            .recent => self.oldfiles.items.len,
            .lines => self.line_hits.items.len,
            .symbols => self.symbol_hits.items.len,
            .qf => self.grep_hits.items.len,
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
            .recent => self.oldfiles.items[i],
            .lines => self.line_hits.items[i].disp,
            .symbols => self.symbol_hits.items[i].disp,
            .qf => self.grep_hits.items[i].disp,
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
            self.clearLines(); // line-picker rows: thousands of heap strings
            self.clearSymbols();
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
                    .grep, .qf => {
                        const h = self.grep_hits.items[idx];
                        self.qf_idx = idx;
                        self.qf_seen = true;
                        // Same honesty as ]q: a vanished file must not
                        // fabricate an empty buffer named after it.
                        if (!fileExists(h.path)) {
                            self.setStatus("{s} is gone", .{h.path});
                        } else _ = self.jumpTo(h.path, h.line);
                    },
                    .recent => {
                        // openFile mutates oldfiles; work from a stable copy.
                        const path = self.alloc.dupe(u8, self.oldfiles.items[idx]) catch return;
                        defer self.alloc.free(path);
                        self.openFile(path) catch {
                            self.setStatus("could not open {s}", .{path});
                        };
                    },
                    .lines, .symbols => {
                        const target = if (kind == .lines)
                            self.line_hits.items[idx].row
                        else
                            self.symbol_hits.items[idx].row;
                        self.pushJump();
                        const b = self.cur();
                        b.row = @min(target, b.lines.items.len -| 1);
                        b.col = b.firstNonWs(b.row);
                        b.goal_col = b.col;
                        b.clampCol(false);
                        b.scroll = b.row -| (self.last_height / 2);
                    },
                    .keys => {},
                    .none => {},
                }
                // After the switch: the .lines arm reads line_hits above,
                // so the release must not happen inside closePopup.
                self.clearLines();
                self.clearSymbols();
            } else {
                self.closePopup();
                self.clearLines(); // zero-match Enter must release rows too
                self.clearSymbols();
            }
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
            .init => {
                // Files from argv opened before app.run may already have spawned zls.
                if (self.lsp != null and self.ticks == 0) self.armTick(ctx, poll_tick_ms);
                return ctx.requestFocus(self.widget());
            },
            .tick => {
                self.ticks -|= 1;
                if (self.yank_flash) |f| {
                    if (std.time.milliTimestamp() >= f.until_ms) {
                        self.yank_flash = null;
                        self.yank_flash_armed = false;
                        ctx.redraw = true;
                    }
                    // Not expired: no re-arm here — an early terminal tick
                    // spawning extras would multiply. A fresh yank resets
                    // yank_flash_armed, so its own keypress schedules the
                    // clear-tick for the new deadline.
                } else self.yank_flash_armed = false;
                if (self.term_view != .none) {
                    if (self.term) |*t| {
                        if (t.poll()) ctx.redraw = true;
                    }
                }
                if (self.lspTick()) ctx.redraw = true;
                // One chain, re-armed once per tick event (see `ticks`).
                if ((self.term_view != .none or self.lspAlive()) and self.ticks == 0)
                    self.armTick(ctx, poll_tick_ms);
                return;
            },
            .mouse => |m| {
                try self.handleMouse(ctx, m);
                // A tree double-click can open the first zig buffer and
                // spawn zls; without this the poll chain would only start
                // on the next keypress.
                if (self.lspAlive() and self.ticks == 0)
                    self.armTick(ctx, poll_tick_ms);
                return;
            },
            .key_press => |key| {
                self.status_len = 0;
                self.preview_len = 0;
                // Record live keys into the active macro register. The `q`
                // that stops recording is popped again in handleNormal.
                if (self.recording != null and self.replay_depth == 0)
                    try self.macros[self.recording.? - 'a'].append(self.alloc, key);
                if (self.replay_depth == 0) self.dotWatch(key);
                try self.dispatchKey(ctx, key);
                if (self.replay_depth == 0) self.dotSettle();
                if (self.yank_flash != null and !self.yank_flash_armed) {
                    self.yank_flash_armed = true;
                    self.armTick(ctx, @intCast(yank_flash_ms + 20));
                }
                if (self.lspAlive() and self.ticks == 0) self.armTick(ctx, poll_tick_ms);
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

    fn isPathChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or switch (c) {
            '_', '-', '.', '/', '~', '+', '@' => true,
            else => false,
        };
    }

    fn fileExists(path: []const u8) bool {
        const st = std.fs.cwd().statFile(path) catch return false;
        return st.kind == .file;
    }

    /// Apply operator `op` ('d'/'c'/'y') over a find-char motion. `f`/`t`
    /// are inclusive (through the target char); `F`/`T` are exclusive.
    fn opFindChar(self: *Editor, op: u8, kind: u8, cp: u21, count: u32) !void {
        const b = self.cur();
        const line = b.lineText(b.row);
        const tc = findCharTarget(line, b.col, kind, cp, count) orelse return;
        const lstart = b.lines.items[b.row].start;
        var s: usize = undefined;
        var e: usize = undefined;
        if (kind == 'f' or kind == 't') {
            s = lstart + b.col;
            const chl = std.unicode.utf8ByteSequenceLength(line[tc]) catch 1;
            e = lstart + tc + chl;
        } else {
            s = lstart + tc;
            e = lstart + b.col;
        }
        if (e <= s) return;
        try self.yankRange(s, e);
        if (op == 'y') {
            self.recordYankFlash(s, e);
            b.setCursorFromByte(s);
            return;
        }
        try b.replaceRange(s, e, "");
        b.setCursorFromByte(s);
        if (op == 'c') self.mode = .insert else b.clampCol(false);
    }

    fn findPending(kind: u8) Pending {
        return switch (kind) {
            'f' => .find_f,
            'F' => .find_F,
            't' => .find_t,
            else => .find_T,
        };
    }

    fn reverseFind(kind: u8) u8 {
        return switch (kind) {
            'f' => 'F',
            'F' => 'f',
            't' => 'T',
            else => 't',
        };
    }

    /// f/F/t/T motion: move to (or till) the nth occurrence of `cp` on the
    /// current line. `t`/`T` skip a zero-progress target so repeats advance.
    fn findChar(self: *Editor, kind: u8, cp: u21, count: u32) void {
        const b = self.cur();
        const line = b.lineText(b.row);
        if (findCharTarget(line, b.col, kind, cp, count)) |tc| {
            b.col = Buffer.snapToCp(line, tc);
            b.goal_col = @intCast(b.col);
        }
    }

    /// Search half of the f/F/t/T motion: returns the destination column in
    /// `line` relative to `col`, or null when there is no such occurrence.
    fn findCharTarget(line: []const u8, col: usize, kind: u8, cp: u21, count: u32) ?usize {
        if (line.len == 0) return null;
        var ebuf: [4]u8 = undefined;
        const elen = std.unicode.utf8Encode(cp, &ebuf) catch return null;
        const needle = ebuf[0..elen];
        const n: usize = if (count == 0) 1 else count;
        var left = n;
        var target: ?usize = null;
        switch (kind) {
            'f', 't' => {
                var i: usize = col + 1;
                while (i < line.len) : (i += 1) {
                    if (std.mem.startsWith(u8, line[i..], needle)) {
                        const cand = if (kind == 't') i - 1 else i;
                        if (cand <= col) continue; // `t` needs forward progress
                        left -= 1;
                        if (left == 0) {
                            target = cand;
                            break;
                        }
                    }
                }
            },
            'F', 'T' => {
                var i: usize = col;
                while (i > 0) {
                    i -= 1;
                    if (std.mem.startsWith(u8, line[i..], needle)) {
                        const cand = if (kind == 'T') i + 1 else i;
                        if (cand >= col) continue; // `T` needs backward progress
                        left -= 1;
                        if (left == 0) {
                            target = cand;
                            break;
                        }
                    }
                }
            },
            else => {},
        }
        return target;
    }

    /// `gf`: open the file path under the cursor. Tries the token as-is
    /// (cwd-relative or absolute), then relative to the current file's dir.
    fn gotoFile(self: *Editor) !void {
        const b = self.cur();
        const line = b.lineText(b.row);
        if (line.len == 0) return self.setStatus("no file name under cursor", .{});
        const col = @min(b.col, line.len - 1);
        if (!isPathChar(line[col])) return self.setStatus("no file name under cursor", .{});
        var s = col;
        while (s > 0 and isPathChar(line[s - 1])) s -= 1;
        var e = col + 1;
        while (e < line.len and isPathChar(line[e])) e += 1;
        // Trim leading '@' (Zig builtins like @import) and stray trailing dots.
        var tok = line[s..e];
        while (tok.len > 0 and tok[0] == '@') tok = tok[1..];
        while (tok.len > 0 and tok[tok.len - 1] == '.') tok = tok[0 .. tok.len - 1];
        if (tok.len == 0) return self.setStatus("no file name under cursor", .{});
        if (fileExists(tok)) {
            self.pushJump();
            return self.openFile(tok);
        }
        if (std.fs.path.dirname(b.file_name)) |dir| {
            const joined = try std.fs.path.join(self.alloc, &.{ dir, tok });
            defer self.alloc.free(joined);
            if (fileExists(joined)) {
                self.pushJump();
                return self.openFile(joined);
            }
        }
        self.setStatus("E447: can't find file \"{s}\"", .{tok});
    }

    /// Record the current position before a "big" jump (G/gg, n/N, marks,
    /// file switches). Truncates any forward (Ctrl-i) history, vim-style.
    fn pushJump(self: *Editor) void {
        if (self.buffers.items.len == 0) return;
        const b = self.cur();
        self.pushJumpAt(self.active, b.row, b.col);
    }

    /// pushJump for a position that is no longer the current one — an async LSP
    /// jump records where `gd` was pressed, several poll ticks earlier.
    fn pushJumpAt(self: *Editor, buf: usize, row: usize, col: usize) void {
        self.jumps.shrinkRetainingCapacity(self.jump_idx);
        if (self.jumps.items.len > 0) {
            const last = self.jumps.items[self.jumps.items.len - 1];
            if (last.buf == buf and last.row == row) {
                self.jump_idx = self.jumps.items.len;
                return;
            }
        }
        if (self.jumps.items.len >= 100) _ = self.jumps.orderedRemove(0);
        self.jumps.append(self.alloc, .{ .buf = buf, .row = row, .col = col }) catch {};
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
        const p = bracketMatchAt(text, pos) orelse
            return self.setStatus("no matching pair", .{});
        self.pushJump();
        b.setCursorFromByte(p);
    }

    /// Byte index of the bracket matching the one *at* `pos`, or null when
    /// `pos` is not on a bracket / the pair is unbalanced. Shared by `%` and
    /// the matchparen highlight in the draw pass.
    fn bracketMatchAt(text: []const u8, pos: usize) ?usize {
        if (pos >= text.len) return null;
        const pairs = "()[]{}";
        const c = text[pos];
        const idx = std.mem.indexOfScalar(u8, pairs, c) orelse return null;
        const fwd = idx % 2 == 0;
        const other = if (fwd) pairs[idx + 1] else pairs[idx - 1];
        var depth: u32 = 0;
        var p = pos;
        while (true) {
            if (text[p] == c) depth += 1 else if (text[p] == other) {
                depth -= 1;
                if (depth == 0) return p;
            }
            if (fwd) {
                p += 1;
                if (p >= text.len) return null;
            } else {
                if (p == 0) return null;
                p -= 1;
            }
        }
    }

    /// `gd`: zls first, buffer-local whole-word search when there is no server
    /// to ask. The LSP path returns immediately; `applyDefinition` finishes it.
    fn gotoDefinition(self: *Editor) void {
        if (self.buffers.items.len == 0) return;
        if (!self.lspDefRequest()) self.gotoDefLocal();
    }

    /// False when the request could not be sent at all (non-zig buffer, no /
    /// dead / not-yet-initialized server), which is the caller's cue to fall back.
    fn lspDefRequest(self: *Editor) bool {
        const b = self.cur();
        if (!b.isZig()) return false;
        const l = self.ensureLsp() orelse return false;
        if (!l.initialized or !b.lsp_opened) return false;
        const uri = self.bufUri(b) orelse return false;
        defer self.alloc.free(uri);
        l.definition(uri, b.row, b.col);
        self.lsp_req = .{ .buf = self.active, .row = b.row, .col = b.col };
        return true;
    }

    /// `gd` fallback: goto local definition, vim-flavored — jump to the first
    /// whole-word occurrence of the identifier under the cursor, loading
    /// the search register so n/N continue from there. Used directly when
    /// there is no LSP to ask, and by `applyDefinition` when zls answers null.
    fn gotoDefLocal(self: *Editor) void {
        if (self.buffers.items.len == 0) return;
        const b = self.cur();
        const text = b.buf.items;
        const line_start = b.lines.items[b.row].start;
        const line_end = line_start + b.lineLen(b.row);
        var pos = line_start + @min(b.col, b.lineLen(b.row));
        while (pos < line_end and Buffer.wordClass(text[pos]) != 1) pos += 1;
        if (pos >= line_end) return self.setStatus("no word under cursor", .{});
        const w = wordAt(text, pos).?; // pos is on a word char by the scan above
        const word = text[w.lo..w.hi];
        var i: usize = 0;
        const hit: ?usize = while (std.mem.indexOfPos(u8, text, i, word)) |p| {
            if (wordBounded(text, p, word.len)) break p;
            i = p + 1;
        } else null;
        const p = hit orelse return self.setStatus("gd: not found", .{});
        self.search.clearRetainingCapacity();
        self.search.appendSlice(self.alloc, word) catch return;
        self.search_hl = true;
        self.pushJump();
        b.setCursorFromByte(p);
        self.setStatus("gd: {s}", .{word});
    }

    const WordRange = struct { lo: usize, hi: usize };

    /// Byte range of the word containing `pos`, or null when `pos` is not
    /// on a word char.
    fn wordAt(text: []const u8, pos: usize) ?WordRange {
        if (pos >= text.len or Buffer.wordClass(text[pos]) != 1) return null;
        var lo = pos;
        while (lo > 0 and Buffer.wordClass(text[lo - 1]) == 1) lo -= 1;
        var hi = pos;
        while (hi < text.len and Buffer.wordClass(text[hi]) == 1) hi += 1;
        return .{ .lo = lo, .hi = hi };
    }

    /// vim-illuminate: byte range of the word under the cursor, or null
    /// when the cursor is not on a word char.
    fn wordUnderCursor(b: *const Buffer) ?WordRange {
        return wordAt(b.buf.items, b.lines.items[b.row].start + @min(b.col, b.lineLen(b.row)));
    }

    /// Next whole-word occurrence of `word` in the line `text` at or after
    /// line-relative offset `from`, skipping the occurrence the cursor is on
    /// (absolute offset `self_lo`). Rejected candidates (substrings, the
    /// cursor's own word) are skipped, not terminal.
    fn nextIllum(buf: []const u8, line_start: usize, text: []const u8, from: usize, word: []const u8, self_lo: usize) ?usize {
        var i = from;
        while (std.mem.indexOfPos(u8, text, i, word)) |p| {
            if (wordBounded(buf, line_start + p, word.len) and line_start + p != self_lo)
                return p;
            i = p + 1;
        }
        return null;
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
                'x', 'r', '~', 'J', 'p', 'o', 'O', 'i', 'a', 'A', 'I', 'd', 'g' => {},
                else => return,
            }
            self.dot_capturing = true;
            self.dot_rec.clearRetainingCapacity();
            self.dot_buf0 = self.active;
            self.dot_seq0 = self.cur().undo_seq;
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
        // Ctrl-chords with no pending prefix (e.g. Ctrl-s save mid-insert)
        // are side-effect commands, not part of the change — replaying them
        // via `.` would e.g. write the file as a surprise. Ctrl keys that a
        // pending handler consumes (r Ctrl-a, df<C-x>) ARE the change and
        // must stay in the record or the replay dangles mid-operator.
        // INVARIANT this rests on: every non-.none arm of handleNormal's
        // pending switch returns before the ctrl-mods block, so
        // "pending != .none" is exactly "a pending handler consumes this".
        // Insert-mode Ctrl-n/Ctrl-p ARE the change (the completion engine,
        // not a self-inserting key, produced the text), so they stay in the
        // record even though other ctrl chords are side-effect commands.
        const cmp_key = self.mode == .insert and
            (key.codepoint == 'n' or key.codepoint == 'p');
        if (key.mods.ctrl and self.pending == .none and !cmp_key) return;
        self.dot_rec.append(self.alloc, key) catch {};
    }

    /// Commit the in-progress dot capture once a change has completed.
    fn dotSettle(self: *Editor) void {
        if (!self.dot_capturing) return;
        if (self.mode != .normal or self.pending != .none) return;
        self.dot_capturing = false;
        // Commit only when the capture actually edited the buffer it
        // started in: an aborted operator (`d` then Esc/z/q) or a failed
        // edit would otherwise overwrite the register with a no-op,
        // losing the real last change.
        if (self.buffers.items.len == 0 or self.active != self.dot_buf0 or
            self.cur().undo_seq == self.dot_seq0) return;
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
                'c', 'C' => if (!key.mods.shift) {
                    ctx.quit = true;
                },
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
            '1'...'5' => {
                const idx: usize = @intCast(cp - '1');
                if (idx >= self.oldfiles.items.len) return;
                // openFile mutates oldfiles; work from a stable copy.
                const path = self.alloc.dupe(u8, self.oldfiles.items[idx]) catch return;
                defer self.alloc.free(path);
                self.openFile(path) catch return;
            },
            ':' => {
                self.mode = .command;
                self.cmd_is_search = false;
                self.status_len = 0;
                self.cmd.clearRetainingCapacity();
            },
            's' => self.restoreSession(),
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

    /// nvim-colorizer: a `#RGB`, `#RRGGBB`, or `#RRGGBBAA` literal in the text.
    const ColorSpan = struct { s: usize, e: usize, r: u8, g: u8, b: u8 };

    fn nib(ch: u8) u8 {
        return switch (ch) {
            '0'...'9' => ch - '0',
            'a'...'f' => ch - 'a' + 10,
            'A'...'F' => ch - 'A' + 10,
            else => 0,
        };
    }

    fn findColorSpan(text: []const u8, from: usize) ?ColorSpan {
        var idx = from;
        while (idx < text.len) {
            const h = std.mem.indexOfScalarPos(u8, text, idx, '#') orelse return null;
            var n: usize = 0;
            while (h + 1 + n < text.len and n < 9 and std.ascii.isHex(text[h + 1 + n])) n += 1;
            if (n == 3 or n == 6 or n == 8) {
                const d = text[h + 1 ..];
                var r: u8 = undefined;
                var g: u8 = undefined;
                var b: u8 = undefined;
                if (n == 3) {
                    r = nib(d[0]) * 17;
                    g = nib(d[1]) * 17;
                    b = nib(d[2]) * 17;
                } else {
                    r = nib(d[0]) * 16 + nib(d[1]);
                    g = nib(d[2]) * 16 + nib(d[3]);
                    b = nib(d[4]) * 16 + nib(d[5]);
                }
                return .{ .s = h, .e = h + 1 + n, .r = r, .g = g, .b = b };
            }
            idx = h + 1;
        }
        return null;
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

    fn diagAtCursor(self: *Editor) ?*const Lsp.Diag {
        if (self.buffers.items.len == 0) return null;
        const b = self.cur();
        for (b.diags.items) |*d| {
            if (d.line == b.row) return d;
        }
        return null;
    }

    /// ]d / [d over the sorted diagnostic list, wrapping like ]c.
    fn jumpDiag(self: *Editor, dir: i2) void {
        const b = self.cur();
        const ds = b.diags.items;
        if (ds.len == 0) return self.setStatus("no diagnostics", .{});
        var idx: usize = if (dir > 0) 0 else ds.len - 1; // wrap targets
        if (dir > 0) {
            for (ds, 0..) |d, i| {
                if (@as(usize, d.line) > b.row) {
                    idx = i;
                    break;
                }
            }
        } else {
            var i = ds.len;
            while (i > 0) : (i -= 1) {
                if (@as(usize, ds[i - 1].line) < b.row) {
                    idx = i - 1;
                    break;
                }
            }
        }
        self.pushJump();
        b.row = @min(@as(usize, ds[idx].line), b.lastRow()); // list may be stale
        b.col = @min(@as(usize, ds[idx].col), b.lineLen(b.row));
        b.clampCol(false);
        b.goal_col = b.col;
        // Cap: setStatus silently shows nothing when the format overflows 256 B.
        const msg = ds[idx].message;
        const cut = msg[0..Buffer.snapToCp(msg, @min(msg.len, 180))];
        self.setStatus("diag {d}/{d}: {s}", .{ idx + 1, ds.len, cut });
    }

    fn handleNormal(self: *Editor, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        const b = self.cur();
        // Any normal-mode key starts a fresh undo group, so a command's
        // edits (plus the insert session it may open) undo as one unit.
        b.undo_new_group = true;
        // Effective character: kitty reports 'g'+shift with shifted 'G',
        // legacy terminals report 'G' directly.
        const cp = key.shifted_codepoint orelse key.codepoint;

        switch (self.pending) {
            .none => {},
            .g => {
                self.pending = .none;
                // Dot-repeat: `gc…` is the only change here. gg/gv/gf/gd are
                // motions, and `gv` even leaves normal mode — that would keep
                // the capture alive into visual mode and let a later visual
                // edit commit e.g. `gvd` into the dot register. Abort now
                // (same reasoning as the mouse-click abort in handleMouse).
                if (cp != 'c') self.dot_capturing = false;
                if (cp == 'g') {
                    self.pushJump();
                    // `gg` = first line, `Ngg` = line N (like vim).
                    b.row = if (self.count > 0) @min(self.count - 1, b.lastRow()) else 0;
                    self.count = 0;
                    b.col = b.firstNonWs(b.row);
                    b.goal_col = @intCast(b.col);
                } else if (cp == 'v') {
                    self.reselectVisual();
                } else if (cp == 'f') {
                    self.gotoFile() catch {};
                } else if (cp == 'd') {
                    // No tick arming needed here: the .key_press tail
                    // re-arms after dispatchKey when lspAlive.
                    self.gotoDefinition();
                } else if (cp == 'c') {
                    self.pending = .g_comment;
                } else if (cp == 'r') {
                    self.lspReferences();
                }
                return ctx.consumeAndRedraw();
            },
            .g_comment => {
                self.pending = .none;
                switch (cp) {
                    // A count typed between `gc` and the motion (`gc2j`):
                    // keep accumulating instead of eating it as a bad motion.
                    '1'...'9' => {
                        self.count = @min(self.count * 10 + @as(u32, @intCast(cp - '0')), 99999);
                        self.pending = .g_comment;
                    },
                    '0' => if (self.count > 0) {
                        self.count = @min(self.count * 10, 99999);
                        self.pending = .g_comment;
                    } else {
                        // gc0: `0` as a motion — linewise op on the current
                        // line, like Comment.nvim.
                        b.toggleComment() catch {};
                    },
                    'c' => {
                        const n = self.takeCount();
                        if (n <= 1) {
                            b.toggleComment() catch {};
                        } else {
                            // toggleCommentRows keeps the byte column (screen
                            // position), unlike toggleComment which follows the
                            // shifted character — close enough to Comment.nvim.
                            const hi = @min(b.row + n - 1, b.lastRow());
                            b.toggleCommentRows(b.row, hi) catch {};
                        }
                    },
                    'j' => {
                        const n = self.takeCount();
                        self.commentRange(b.row, b.row + n);
                    },
                    'k' => {
                        const n = self.takeCount();
                        self.commentRange(b.row -| n, b.row);
                    },
                    'G' => {
                        const had = self.count > 0;
                        const n = self.takeCount();
                        const t = if (had) @min(n - 1, b.lastRow()) else b.lastRow();
                        self.commentRange(@min(b.row, t), @max(b.row, t));
                    },
                    // gcgg / gcNgg — count deliberately left intact.
                    'g' => self.pending = .g_comment_g,
                    'i' => self.pending = .g_comment_i, // gcip
                    else => self.count = 0,
                }
                return ctx.consumeAndRedraw();
            },
            .g_comment_g => {
                self.pending = .none;
                if (cp == 'g') {
                    const had = self.count > 0;
                    const n = self.takeCount();
                    const t = if (had) @min(n - 1, b.lastRow()) else 0;
                    self.commentRange(@min(b.row, t), @max(b.row, t));
                } else self.count = 0;
                return ctx.consumeAndRedraw();
            },
            .g_comment_i => {
                self.pending = .none;
                self.count = 0;
                if (cp == 'p') {
                    const r = paragraphRows(b);
                    self.commentRange(r[0], r[1]);
                }
                return ctx.consumeAndRedraw();
            },
            .z => {
                self.pending = .none;
                const h: usize = @max(1, self.last_height);
                switch (cp) {
                    'z' => b.scroll = b.row -| (h / 2),
                    't' => b.scroll = b.row,
                    'b' => b.scroll = b.row -| (h -| 1),
                    else => {},
                }
                return ctx.consumeAndRedraw();
            },
            .find_f, .find_t, .find_F, .find_T => {
                const kind: u8 = switch (self.pending) {
                    .find_f => 'f',
                    .find_t => 't',
                    .find_F => 'F',
                    else => 'T',
                };
                self.pending = .none;
                const op = self.find_op;
                self.find_op = 0;
                if (key.matches(vaxis.Key.escape, .{})) return ctx.consumeAndRedraw();
                self.last_find_kind = kind;
                self.last_find_cp = cp;
                if (op == 0) {
                    self.findChar(kind, cp, self.takeCount());
                } else try self.opFindChar(op, kind, cp, self.takeCount());
                return ctx.consumeAndRedraw();
            },
            .d => {
                self.pending = .none;
                const n = self.takeCount();
                switch (cp) {
                    'd' => for (0..n) |_| try b.deleteLine(),
                    'f', 'F', 't', 'T' => {
                        self.count = n; // restore count for the find stage
                        self.find_op = 'd';
                        self.pending = findPending(@intCast(cp));
                    },
                    's' => self.pending = .surround_del,
                    'i' => {
                        self.obj_op = 'd';
                        self.pending = .obj_i;
                    },
                    'a' => {
                        self.obj_op = 'd';
                        self.pending = .obj_a;
                    },
                    'w' => {
                        const s = b.cursorByte();
                        const e = nextWordByte(b, s);
                        if (e > s) {
                            try self.yankRange(s, e);
                            try b.replaceRange(s, e, "");
                            b.setCursorFromByte(s);
                        }
                    },
                    '$' => {
                        const s = b.cursorByte();
                        const e = b.lines.items[b.row].end;
                        if (e > s) {
                            try self.yankRange(s, e);
                            try b.replaceRange(s, e, "");
                            b.setCursorFromByte(s);
                            b.clampCol(false);
                        }
                    },
                    else => {},
                }
                return ctx.consumeAndRedraw();
            },
            .c_op => {
                self.pending = .none;
                switch (cp) {
                    'f', 'F', 't', 'T' => {
                        self.find_op = 'c';
                        self.pending = findPending(@intCast(cp));
                    },
                    's' => self.pending = .surround_old,
                    'i' => {
                        self.obj_op = 'c';
                        self.pending = .obj_i;
                    },
                    'a' => {
                        self.obj_op = 'c';
                        self.pending = .obj_a;
                    },
                    'c' => {
                        const line = b.lines.items[b.row];
                        try self.yankRange(line.start, line.end);
                        try b.replaceRange(line.start, line.end, "");
                        b.col = 0;
                        b.goal_col = 0;
                        self.mode = .insert;
                    },
                    'w', 'e' => {
                        const s = b.cursorByte();
                        const e = wordEndByte(b, s);
                        if (e > s) {
                            try self.yankRange(s, e);
                            try b.replaceRange(s, e, "");
                        }
                        b.setCursorFromByte(s);
                        self.mode = .insert;
                    },
                    '$' => {
                        const s = b.cursorByte();
                        const e = b.lines.items[b.row].end;
                        if (e > s) {
                            try self.yankRange(s, e);
                            try b.replaceRange(s, e, "");
                        }
                        b.setCursorFromByte(s);
                        self.mode = .insert;
                    },
                    else => {},
                }
                return ctx.consumeAndRedraw();
            },
            .indent_gt, .indent_lt, .indent_eq => {
                const p = self.pending;
                self.pending = .none;
                const match: u21 = switch (p) {
                    .indent_gt => '>',
                    .indent_lt => '<',
                    else => '=',
                };
                if (cp == match) {
                    const n = self.takeCount();
                    const hi = @min(b.row + n - 1, b.lines.items.len - 1);
                    if (p == .indent_eq)
                        try b.reindentRows(b.row, hi)
                    else
                        try b.indentRows(b.row, hi, p == .indent_lt);
                    b.col = b.firstNonWs(b.row);
                    b.goal_col = @intCast(b.col);
                }
                return ctx.consumeAndRedraw();
            },
            .y_op => {
                self.pending = .none;
                const n = self.takeCount();
                switch (cp) {
                    'f', 'F', 't', 'T' => {
                        self.count = n; // restore count for the find stage
                        self.find_op = 'y';
                        self.pending = findPending(@intCast(cp));
                    },
                    'y' => {
                        const lo = b.lines.items[b.row].start;
                        const last = @min(b.row + n - 1, b.lines.items.len - 1);
                        const hi = @min(b.lines.items[last].end + 1, b.buf.items.len);
                        try self.yankRange(lo, hi);
                        self.recordYankFlash(lo, hi);
                        self.reg_linewise = true;
                        if (self.reg.items.len == 0 or
                            self.reg.items[self.reg.items.len - 1] != '\n')
                            try self.reg.append(self.alloc, '\n');
                        self.setStatus("{d} line{s} yanked", .{ n, if (n == 1) "" else "s" });
                    },
                    'i' => {
                        self.obj_op = 'y';
                        self.pending = .obj_i;
                    },
                    'a' => {
                        self.obj_op = 'y';
                        self.pending = .obj_a;
                    },
                    'w' => {
                        const s = b.cursorByte();
                        const e = nextWordByte(b, s);
                        if (e > s) {
                            try self.yankRange(s, e);
                            self.recordYankFlash(s, e);
                        }
                    },
                    'e' => {
                        const s = b.cursorByte();
                        const e = wordEndByte(b, s);
                        if (e > s) {
                            try self.yankRange(s, e);
                            self.recordYankFlash(s, e);
                        }
                    },
                    '$' => {
                        const s = b.cursorByte();
                        const e = b.lines.items[b.row].end;
                        if (e > s) {
                            try self.yankRange(s, e);
                            self.recordYankFlash(s, e);
                        }
                    },
                    else => {},
                }
                return ctx.consumeAndRedraw();
            },
            .obj_i, .obj_a => {
                const around = self.pending == .obj_a;
                self.pending = .none;
                if (cp < 0x80) try self.doTextObject(@intCast(cp), around);
                return ctx.consumeAndRedraw();
            },
            .surround_old => {
                self.pending = .none;
                if (cp < 0x80) {
                    self.surround_from = @intCast(cp);
                    self.pending = .surround_new;
                }
                return ctx.consumeAndRedraw();
            },
            .surround_new => {
                self.pending = .none;
                if (cp < 0x80) try self.changeSurround(self.surround_from, @intCast(cp));
                return ctx.consumeAndRedraw();
            },
            .surround_del => {
                self.pending = .none;
                if (cp < 0x80) try self.changeSurround(@intCast(cp), 0);
                return ctx.consumeAndRedraw();
            },
            .surround_vis => {
                self.pending = .none;
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
                    'g' => self.pending = .leader_g,
                    'n' => self.numbers = !self.numbers,
                    'q' => self.openPopup(.qf),
                    'r' => self.pending = .leader_r,
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
                    'o' => self.openPopup(.recent),
                    's' => self.openPopup(.symbols),
                    'z' => self.openPopup(.lines),
                    else => {},
                }
                return ctx.consumeAndRedraw();
            },
            .leader_c => {
                self.pending = .none;
                switch (cp) {
                    'h' => self.openPopup(.keys),
                    'r' => {
                        const r = self.wordNearCursor() orelse {
                            self.setStatus("no word under cursor", .{});
                            return ctx.consumeAndRedraw();
                        };
                        self.mode = .command;
                        self.cmd_is_search = false;
                        self.cmd.clearRetainingCapacity();
                        // Prefill the old name (NvChad renamer style): it
                        // stays visible in the cmdline while editing, and
                        // plain Enter is caught by "rename: unchanged".
                        try self.cmd.appendSlice(self.alloc, "rename ");
                        try self.cmd.appendSlice(self.alloc, self.cur().buf.items[r[0]..r[1]]);
                    },
                    else => {},
                }
                return ctx.consumeAndRedraw();
            },
            .leader_r => {
                self.pending = .none;
                switch (cp) {
                    'n' => self.relnum = !self.relnum,
                    else => {},
                }
                return ctx.consumeAndRedraw();
            },
            .leader_g => {
                self.pending = .none;
                switch (cp) {
                    'b' => self.blameLine(),
                    'p' => self.previewHunk(),
                    'r' => self.resetHunk() catch {},
                    's' => self.stageHunk() catch {},
                    else => {},
                }
                return ctx.consumeAndRedraw();
            },
            .bracket_f => {
                self.pending = .none;
                switch (cp) {
                    'c' => self.jumpHunk(1),
                    'd' => self.jumpDiag(1),
                    'q' => self.jumpQuickfix(1),
                    else => {},
                }
                return ctx.consumeAndRedraw();
            },
            .bracket_b => {
                self.pending = .none;
                switch (cp) {
                    'c' => self.jumpHunk(-1),
                    'd' => self.jumpDiag(-1),
                    'q' => self.jumpQuickfix(-1),
                    else => {},
                }
                return ctx.consumeAndRedraw();
            },
        }

        if (key.mods.alt) return;
        const half: i64 = @max(1, self.last_height / 2);

        if (key.mods.ctrl) {
            switch (cp) {
                'c', 'C' => if (key.mods.shift)
                    try self.copyToClipboard(ctx)
                else {
                    ctx.quit = true;
                },
                'd' => b.moveVert(half, false),
                'u' => b.moveVert(-half, false),
                'e' => {
                    b.scroll = @min(b.scroll + 1, b.lastRow());
                    if (b.row < b.scroll) {
                        b.row = b.scroll;
                        b.clampCol(false);
                    }
                },
                'y' => {
                    b.scroll -|= 1;
                    const vh: usize = @max(1, self.last_height);
                    if (b.row >= b.scroll + vh) {
                        b.row = b.scroll + vh - 1;
                        b.clampCol(false);
                    }
                },
                'n' => self.toggleTree(),
                'o' => self.jumpBack(),
                'i' => self.jumpFwd(),
                'h' => if (self.tree_open) {
                    self.focus = .tree;
                },
                'r' => {
                    self.yank_flash = null; // same reason as the undo arm
                    const rn = self.takeCount();
                    for (0..rn) |_| {
                        if (!try b.redo()) {
                            self.setStatus("already at newest change", .{});
                            break;
                        }
                    }
                },
                's' => self.save(),
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
            'z' => self.pending = .z,
            'H' => {
                b.row = @min(b.scroll, b.lastRow());
                b.clampCol(false);
            },
            'M' => {
                b.row = @min(b.scroll + self.last_height / 2, b.lastRow());
                b.clampCol(false);
            },
            'L' => {
                b.row = @min(b.scroll + @max(@as(usize, self.last_height), 1) - 1, b.lastRow());
                b.clampCol(false);
            },
            'f' => self.pending = .find_f,
            'F' => self.pending = .find_F,
            't' => self.pending = .find_t,
            'T' => self.pending = .find_T,
            ';' => if (self.last_find_kind != 0)
                self.findChar(self.last_find_kind, self.last_find_cp, self.takeCount()),
            ',' => if (self.last_find_kind != 0)
                self.findChar(reverseFind(self.last_find_kind), self.last_find_cp, self.takeCount()),
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
            'K' => self.lspHover(),
            'd' => self.pending = .d,
            'c' => self.pending = .c_op,
            'y' => self.pending = .y_op,
            '>' => self.pending = .indent_gt,
            '<' => self.pending = .indent_lt,
            '=' => self.pending = .indent_eq,
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
            'u' => {
                // Undo/redo shift bytes without bumping undo_seq (in_undo
                // skips recordEdit), so the flash guard can't see it.
                self.yank_flash = null;
                for (0..n) |_| {
                    if (!try b.undo()) {
                        self.setStatus("already at oldest change", .{});
                        break;
                    }
                }
            },
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
                self.status_len = 0;
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
        // Vim's `'<` / `'>` marks: bounds of the selection just left.
        if (self.vis_row < b.row or (self.vis_row == b.row and self.vis_col <= b.col)) {
            b.mark_lt = .{ .row = self.vis_row, .col = self.vis_col };
            b.mark_gt = .{ .row = b.row, .col = b.col };
        } else {
            b.mark_lt = .{ .row = b.row, .col = b.col };
            b.mark_gt = .{ .row = self.vis_row, .col = self.vis_col };
        }
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
    // ---- surround (cs / ds / visual S) --------------------------------
    fn surroundPair(ch: u8) ?[2]u8 {
        return switch (ch) {
            '(', ')', 'b' => .{ '(', ')' },
            '[', ']' => .{ '[', ']' },
            '{', '}', 'B' => .{ '{', '}' },
            '<', '>' => .{ '<', '>' },
            '"' => .{ '"', '"' },
            '\'' => .{ '\'', '\'' },
            '`' => .{ '`', '`' },
            else => null,
        };
    }

    /// Byte offsets of the enclosing open/close delimiters, or null.
    /// Quotes pair up sequentially on the current line; brackets scan the
    /// whole buffer nesting-aware.
    fn findSurround(b: *Buffer, open: u8, close: u8) ?[2]usize {
        const text = b.buf.items;
        const cpos = b.cursorByte();
        if (open == close) {
            const line = b.lines.items[b.row];
            var fallback: ?[2]usize = null;
            var o: ?usize = null;
            var i = line.start;
            while (i < line.end) : (i += 1) {
                if (text[i] != open) continue;
                if (o) |op| {
                    if (cpos >= op and cpos <= i) return .{ op, i };
                    if (fallback == null and op > cpos) fallback = .{ op, i };
                    o = null;
                } else o = i;
            }
            return fallback;
        }
        // Bracket: walk back to the unmatched opener, then forward to its match.
        var o: ?usize = null;
        if (cpos < text.len and text[cpos] == open) {
            o = cpos;
        } else {
            var depth: usize = 0;
            var i = @min(cpos, text.len);
            while (i > 0) {
                i -= 1;
                if (text[i] == close) {
                    depth += 1;
                } else if (text[i] == open) {
                    if (depth == 0) {
                        o = i;
                        break;
                    }
                    depth -= 1;
                }
            }
        }
        const oo = o orelse return null;
        var depth: usize = 0;
        var j = oo + 1;
        while (j < text.len) : (j += 1) {
            if (text[j] == open) {
                depth += 1;
            } else if (text[j] == close) {
                if (depth == 0) return .{ oo, j };
                depth -= 1;
            }
        }
        return null;
    }

    // ---- text objects (ciw / di( / ca" ...) ---------------------------
    /// End (exclusive) of the word-class run at `s`; whitespace runs span
    /// spaces/tabs only, never the newline.
    fn wordEndByte(b: *Buffer, s: usize) usize {
        const text = b.buf.items;
        if (s >= text.len) return s;
        const cls = Buffer.wordClass(text[s]);
        var e = s;
        if (cls == 0) {
            while (e < text.len and (text[e] == ' ' or text[e] == '\t')) e += 1;
        } else {
            while (e < text.len and Buffer.wordClass(text[e]) == cls) e += 1;
        }
        return @max(e, s + 1);
    }

    /// Start of the next word on the current line (vim `dw` target).
    fn nextWordByte(b: *Buffer, s: usize) usize {
        const text = b.buf.items;
        const line_end = b.lines.items[b.row].end;
        var i = s;
        if (i < line_end) {
            const cls = Buffer.wordClass(text[i]);
            if (cls != 0) while (i < line_end and Buffer.wordClass(text[i]) == cls) {
                i += 1;
            };
            while (i < line_end and (text[i] == ' ' or text[i] == '\t')) i += 1;
        }
        return i;
    }

    /// Byte range [start, end) of a text object, or null.
    fn objectRange(b: *Buffer, kind: u8, around: bool) ?[2]usize {
        const text = b.buf.items;
        if (kind == 'w') {
            const cpos = b.cursorByte();
            if (cpos >= text.len or text[cpos] == '\n') return null;
            const cls = Buffer.wordClass(text[cpos]);
            var s = cpos;
            var e = cpos;
            if (cls == 0) {
                while (s > 0 and (text[s - 1] == ' ' or text[s - 1] == '\t')) s -= 1;
                while (e < text.len and (text[e] == ' ' or text[e] == '\t')) e += 1;
                return .{ s, e };
            }
            while (s > 0 and Buffer.wordClass(text[s - 1]) == cls) s -= 1;
            while (e < text.len and Buffer.wordClass(text[e]) == cls) e += 1;
            if (around) {
                const e0 = e;
                while (e < text.len and (text[e] == ' ' or text[e] == '\t')) e += 1;
                if (e == e0) // no trailing ws: take leading instead
                    while (s > 0 and (text[s - 1] == ' ' or text[s - 1] == '\t')) {
                        s -= 1;
                    };
            }
            return .{ s, e };
        }
        const pair = surroundPair(kind) orelse return null;
        const pos = findSurround(b, pair[0], pair[1]) orelse return null;
        return if (around)
            .{ pos[0], pos[1] + 1 }
        else
            .{ pos[0] + 1, pos[1] };
    }

    /// Arm the on-yank flash over [lo,hi). Invalidated by any edit: the
    /// recorded undo_seq must still match at draw time.
    fn recordYankFlash(self: *Editor, lo: usize, hi: usize) void {
        if (hi <= lo or self.buffers.items.len == 0) return;
        self.yank_flash = .{
            .buf = self.active,
            .seq = self.cur().undo_seq,
            .lo = lo,
            .hi = hi,
            .until_ms = std.time.milliTimestamp() + yank_flash_ms,
        };
        // Force the current keypress to schedule a clear-tick for THIS
        // deadline, even if one was pending for an earlier yank.
        self.yank_flash_armed = false;
    }

    /// Charwise copy into the unnamed register.
    fn yankRange(self: *Editor, s: usize, e: usize) !void {
        const b = self.cur();
        self.reg.clearRetainingCapacity();
        try self.reg.appendSlice(self.alloc, b.buf.items[s..e]);
        self.reg_linewise = false;
    }

    fn doTextObject(self: *Editor, kind: u8, around: bool) !void {
        const b = self.cur();
        const r = objectRange(b, kind, around) orelse
            return self.setStatus("no object: {c}", .{kind});
        try self.yankRange(r[0], r[1]);
        if (self.obj_op == 'y') {
            self.recordYankFlash(r[0], r[1]);
            b.setCursorFromByte(r[0]);
            b.clampCol(false);
            return;
        }
        try b.replaceRange(r[0], r[1], "");
        b.setCursorFromByte(r[0]);
        if (self.obj_op == 'c') self.mode = .insert else b.clampCol(false);
    }

    /// `to == 0` deletes the surrounding pair (ds); otherwise replaces it (cs).
    fn changeSurround(self: *Editor, from: u8, to: u8) !void {
        const b = self.cur();
        const old = surroundPair(from) orelse return self.setStatus("unknown pair: {c}", .{from});
        const pos = findSurround(b, old[0], old[1]) orelse
            return self.setStatus("no surrounding {c}", .{old[0]});
        if (to == 0) {
            try b.replaceRange(pos[1], pos[1] + 1, "");
            try b.replaceRange(pos[0], pos[0] + 1, "");
        } else {
            const new = surroundPair(to) orelse return self.setStatus("unknown pair: {c}", .{to});
            try b.replaceRange(pos[1], pos[1] + 1, &.{new[1]});
            try b.replaceRange(pos[0], pos[0] + 1, &.{new[0]});
        }
        b.setCursorFromByte(pos[0]);
    }

    /// Ctrl-Shift-C: copy to the system clipboard via OSC 52 — the visual
    /// selection when one is active, otherwise the yank register. Terminals
    /// that forward the chord used to hit the Ctrl-C quit arm instead.
    fn copyToClipboard(self: *Editor, ctx: *vxfw.EventContext) !void {
        const text = if (self.selRange()) |r|
            self.cur().buf.items[r[0]..r[1]]
        else
            self.reg.items;
        if (text.len == 0) return self.setStatus("nothing to copy (yank or select first)", .{});
        try ctx.addCmd(.{ .copy_to_clipboard = text });
        self.setStatus("copied {d} bytes to system clipboard", .{text.len});
    }

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

    /// Toggle comments over rows [lo,hi] (clamped) and park the cursor on
    /// the first non-blank column of the first row — Comment.nvim's
    /// behaviour for `gc` + motion.
    fn commentRange(self: *Editor, lo: usize, hi: usize) void {
        const b = self.cur();
        const l = @min(lo, b.lastRow());
        const h = @min(@max(hi, l), b.lastRow());
        b.toggleCommentRows(l, h) catch {};
        b.row = l;
        b.col = b.firstNonWs(l);
        b.goal_col = b.col;
    }

    /// Blank-line-delimited block containing the cursor row (vim `ip`,
    /// linewise). On a blank row this is the run of blank rows instead —
    /// toggleCommentRows then no-ops, which is the right nothing.
    fn paragraphRows(b: *Buffer) [2]usize {
        const want = b.rowBlank(b.row);
        var lo = b.row;
        while (lo > 0 and b.rowBlank(lo - 1) == want) lo -= 1;
        var hi = b.row;
        const last = b.lastRow();
        while (hi < last and b.rowBlank(hi + 1) == want) hi += 1;
        return .{ lo, hi };
    }

    /// Toggle comments over the selected rows, then leave visual mode with the
    /// cursor on the first row (shared by visual `Space /` and `gc`).
    fn commentSelection(self: *Editor) void {
        const b = self.cur();
        const lo = @min(self.vis_row, b.row);
        const hi = @max(@min(self.vis_row, b.lines.items.len - 1), b.row);
        b.toggleCommentRows(lo, hi) catch {};
        self.exitVisual();
        b.row = @min(lo, b.lines.items.len - 1);
        b.col = b.firstNonWs(b.row);
        b.goal_col = b.col;
    }

    fn handleVisual(self: *Editor, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        const b = self.cur();
        b.undo_new_group = true;
        const cp = key.shifted_codepoint orelse key.codepoint;
        const half: i64 = @max(1, self.last_height / 2);

        if (self.pending == .surround_vis) {
            self.pending = .none;
            if (cp < 0x80) if (surroundPair(@intCast(cp))) |p| {
                if (self.selRange()) |r| {
                    try b.replaceRange(r[1], r[1], &.{p[1]});
                    try b.replaceRange(r[0], r[0], &.{p[0]});
                    self.exitVisual();
                    b.setCursorFromByte(r[0]);
                }
            };
            return ctx.consumeAndRedraw();
        }

        switch (self.pending) {
            .find_f, .find_t, .find_F, .find_T => {
                const kind: u8 = switch (self.pending) {
                    .find_f => 'f',
                    .find_t => 't',
                    .find_F => 'F',
                    else => 'T',
                };
                self.pending = .none;
                if (cp != vaxis.Key.escape) {
                    self.last_find_kind = kind;
                    self.last_find_cp = cp;
                    self.findChar(kind, cp, self.takeCount());
                }
                return ctx.consumeAndRedraw();
            },
            else => {},
        }

        if (self.pending == .leader) {
            self.pending = .none;
            if (cp == '/') {
                self.commentSelection();
            }
            return ctx.consumeAndRedraw();
        }

        if (self.pending == .g) {
            self.pending = .none;
            if (cp == 'g') {
                b.row = 0;
                b.col = 0;
                b.goal_col = 0;
            } else if (cp == 'c') {
                self.commentSelection();
            }
            return ctx.consumeAndRedraw();
        }

        // Count prefix for visual operators (e.g. `3>`).
        if (!key.mods.ctrl and cp >= '0' and cp <= '9' and (cp != '0' or self.count > 0)) {
            self.count = @min(self.count * 10 + @as(u32, @intCast(cp - '0')), 99999);
            return ctx.consumeAndRedraw();
        }

        if (key.mods.ctrl) {
            switch (cp) {
                'c', 'C' => if (key.mods.shift)
                    try self.copyToClipboard(ctx)
                else {
                    ctx.quit = true;
                },
                'd' => b.moveVert(half, false),
                'u' => b.moveVert(-half, false),
                'e' => {
                    b.scroll = @min(b.scroll + 1, b.lastRow());
                    if (b.row < b.scroll) {
                        b.row = b.scroll;
                        b.clampCol(false);
                    }
                },
                'y' => {
                    b.scroll -|= 1;
                    const vh: usize = @max(1, self.last_height);
                    if (b.row >= b.scroll + vh) {
                        b.row = b.scroll + vh - 1;
                        b.clampCol(false);
                    }
                },
                else => return,
            }
            return ctx.consumeAndRedraw();
        }

        switch (cp) {
            vaxis.Key.escape => self.exitVisual(),
            ' ' => self.pending = .leader,
            ':' => {
                // `:` from visual mode — command line prefilled with the range.
                self.exitVisual();
                self.mode = .command;
                self.cmd_is_search = false;
                self.status_len = 0;
                self.cmd.clearRetainingCapacity();
                try self.cmd.appendSlice(self.alloc, "'<,'>");
            },
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
            'S' => self.pending = .surround_vis,
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
            '<', '>', '=' => {
                const lo = @min(self.vis_row, b.row);
                const hi = @max(@min(self.vis_row, b.lines.items.len - 1), b.row);
                if (cp == '=') {
                    self.count = 0;
                    b.reindentRows(lo, hi) catch {};
                } else {
                    var steps = self.takeCount();
                    while (steps > 0) : (steps -= 1)
                        b.indentRows(lo, hi, cp == '<') catch {};
                }
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
                    self.recordYankFlash(r[0], r[1]);
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
            'f' => self.pending = .find_f,
            'F' => self.pending = .find_F,
            't' => self.pending = .find_t,
            'T' => self.pending = .find_T,
            ';' => if (self.last_find_kind != 0)
                self.findChar(self.last_find_kind, self.last_find_cp, self.takeCount()),
            ',' => if (self.last_find_kind != 0)
                self.findChar(reverseFind(self.last_find_kind), self.last_find_cp, self.takeCount()),
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
            'g' => self.pending = .g,
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
        // NvChad <C-s>: write the buffer without leaving insert mode.
        if (key.mods.ctrl and key.codepoint == 's') { self.save(); return ctx.consumeAndRedraw(); }
        if (self.cmp.active) {
            if (try self.cmpKey(ctx, key)) return;
        } else if (key.matches('n', .{ .ctrl = true }) or key.matches('p', .{ .ctrl = true })) {
            try self.cmpOpen(key.codepoint == 'p');
            return ctx.consumeAndRedraw();
        }
        switch (key.codepoint) {
            vaxis.Key.escape => {
                self.cmpClose();
                self.mode = .normal;
                if (b.col > 0) b.col = Buffer.snapToCp(b.lineText(b.row), b.col - 1);
                b.clampCol(false);
                b.goal_col = b.col;
            },
            vaxis.Key.enter => try b.insertText("\n"),
            vaxis.Key.backspace => try backspacePair(b),
            vaxis.Key.tab => try b.insertText("    "),
            else => {
                if (key.mods.ctrl or key.mods.alt) return;
                const text = key.text orelse return;
                if (text.len == 1 and try autoPair(b, text[0])) {
                    ctx.consumeAndRedraw();
                    return;
                }
                try b.insertText(text);
            },
        }
        ctx.consumeAndRedraw();
    }

    /// nvim-autopairs behavior for a single typed byte. Returns true when the
    /// key was fully handled (pair inserted or closer skipped).
    fn autoPair(b: *Buffer, ch: u8) !bool {
        const pos = b.lines.items[b.row].start + @min(b.col, b.lineLen(b.row));
        const text = b.buf.items;
        const at: u8 = if (pos < text.len) text[pos] else '\n';
        switch (ch) {
            '(', '[', '{' => {
                const close: u8 = switch (ch) {
                    '(' => ')',
                    '[' => ']',
                    else => '}',
                };
                try b.insertText(&.{ ch, close });
                b.col -= 1;
                b.goal_col = b.col;
                return true;
            },
            ')', ']', '}' => {
                if (at != ch) return false;
                b.col += 1;
                b.goal_col = b.col;
                return true;
            },
            '"', '\'', '`' => {
                if (at == ch) {
                    b.col += 1;
                    b.goal_col = b.col;
                    return true;
                }
                // No `'` pairing right after a word char (it's, lifetimes).
                if (ch == '\'' and pos > 0 and Buffer.wordClass(text[pos - 1]) == 1)
                    return false;
                try b.insertText(&.{ ch, ch });
                b.col -= 1;
                b.goal_col = b.col;
                return true;
            },
            else => return false,
        }
    }

    /// Backspace between the two halves of an empty pair removes both.
    fn backspacePair(b: *Buffer) !void {
        const pos = b.lines.items[b.row].start + @min(b.col, b.lineLen(b.row));
        const text = b.buf.items;
        var kill_mate = false;
        if (pos > 0 and pos < text.len) {
            const mate: u8 = switch (text[pos - 1]) {
                '(' => ')',
                '[' => ']',
                '{' => '}',
                '"', '\'', '`' => text[pos - 1],
                else => 0,
            };
            kill_mate = mate != 0 and text[pos] == mate;
        }
        // Opener first: deleting the closer while the cursor sits at line end
        // would let the EOL clamp drag the cursor before backspace runs.
        try b.backspace();
        if (kill_mate) {
            // deleteCharAtCursor applies the normal-mode EOL clamp; restore
            // the insert-mode column so later typing stays put.
            const keep = b.col;
            try b.deleteCharAtCursor();
            b.col = @min(keep, b.lineLen(b.row));
            b.goal_col = b.col;
        }
    }

    // ---- completion -------------------------------------------------------

    fn cmpClose(self: *Editor) void {
        for (self.cmp.items.items) |it| self.alloc.free(it);
        self.cmp.items.clearRetainingCapacity();
        self.cmp.prefix.clearRetainingCapacity();
        self.cmp.active = false;
        self.cmp.sel = 0;
        self.cmp.len = 0;
    }

    /// Harvest distinct word runs (wordClass == 1, len >= 2) from every open
    /// buffer that start with `prefix`, appending them to cmp.items.
    fn cmpCollect(self: *Editor, prefix: []const u8) !void {
        var seen = std.StringHashMap(void).init(self.alloc);
        defer seen.deinit();
        for (self.buffers.items) |*ob| {
            const text = ob.buf.items;
            var i: usize = 0;
            while (i < text.len) {
                if (Buffer.wordClass(text[i]) != 1) {
                    i += 1;
                    continue;
                }
                var j = i;
                while (j < text.len and Buffer.wordClass(text[j]) == 1) j += 1;
                const w = text[i..j];
                i = j;
                if (w.len < 2 or w.len <= prefix.len) continue; // no-op candidates
                if (!std.mem.startsWith(u8, w, prefix)) continue;
                if (seen.contains(w)) continue;
                const owned = try self.alloc.dupe(u8, w);
                try self.cmp.items.append(self.alloc, owned);
                try seen.put(owned, {}); // key is owned by items
                if (self.cmp.items.items.len >= Cmp.max_items) break;
            }
            if (self.cmp.items.items.len >= Cmp.max_items) break;
        }
        std.mem.sort([]u8, self.cmp.items.items, {}, struct {
            fn less(_: void, a: []u8, b: []u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
    }

    /// Replace the completion region with `text`, cursor just after it.
    fn cmpApply(self: *Editor, text: []const u8) !void {
        const b = self.cur();
        const ls = b.lines.items[b.row].start; // edit never spans rows
        try b.replaceRange(self.cmp.start, self.cmp.start + self.cmp.len, text);
        self.cmp.len = text.len;
        b.col = self.cmp.start - ls + text.len;
        b.goal_col = b.col;
    }

    fn cmpCycle(self: *Editor, delta: isize) !void {
        const n = self.cmp.items.items.len;
        if (n == 0) return;
        const next = @mod(@as(isize, @intCast(self.cmp.sel)) + delta, @as(isize, @intCast(n)));
        self.cmp.sel = @intCast(next);
        try self.cmpApply(self.cmp.items.items[@intCast(next)]);
    }

    /// Ctrl-n / Ctrl-p in insert mode: open the menu on the word before the
    /// cursor (vim semantics — the first press already inserts a match).
    fn cmpOpen(self: *Editor, back: bool) !void {
        self.cmpClose();
        const b = self.cur();
        const text = b.buf.items;
        const pos = b.lines.items[b.row].start + @min(b.col, b.lineLen(b.row));
        var s = pos;
        while (s > 0 and Buffer.wordClass(text[s - 1]) == 1) s -= 1;
        try self.cmp.prefix.appendSlice(self.alloc, text[s..pos]);
        try self.cmpCollect(self.cmp.prefix.items);
        // No match: leave the typed text alone, like vim's
        // "Pattern not found" — never substitute an unrelated word.
        if (self.cmp.items.items.len == 0) {
            self.cmpClose();
            return self.setStatus("no completions for prefix", .{});
        }
        self.cmp.active = true;
        self.cmp.start = s;
        self.cmp.len = pos - s;
        self.cmp.sel = if (back) self.cmp.items.items.len - 1 else 0;
        try self.cmpApply(self.cmp.items.items[self.cmp.sel]);
    }

    /// Keys while the menu is up. Returns true when the key was consumed;
    /// false means "menu closed, handle the key normally".
    fn cmpKey(self: *Editor, ctx: *vxfw.EventContext, key: vaxis.Key) !bool {
        if (key.matches('n', .{ .ctrl = true }) or key.matches(vaxis.Key.down, .{})) {
            try self.cmpCycle(1);
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches('p', .{ .ctrl = true }) or key.matches(vaxis.Key.up, .{})) {
            try self.cmpCycle(-1);
            ctx.consumeAndRedraw();
            return true;
        }
        // The completed text is already in the buffer, so Enter/Tab just
        // dismiss the menu.
        if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.tab, .{})) {
            self.cmpClose();
            ctx.consumeAndRedraw();
            return true;
        }
        // Any other key — including Esc, which must also leave insert mode
        // like vim's single-Esc-through-the-pum — closes the menu and is
        // then handled normally (typing accepts the completed text).
        self.cmpClose();
        return false;
    }

    fn handleCommand(self: *Editor, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        switch (key.codepoint) {
            vaxis.Key.escape => self.mode = .normal,
            vaxis.Key.enter => if (self.cmd_is_search) {
                self.mode = .normal;
                self.search.clearRetainingCapacity();
                try self.search.appendSlice(self.alloc, self.cmd.items);
                self.search_hl = true;
                self.findNext(1);
            } else try self.execCommand(ctx),
            vaxis.Key.tab => if (!self.cmd_is_search) try self.completeCmdline(),
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

    // ---- cmdline tab completion -------------------------------------------

    /// Tab in `:` mode — completes command names, `:theme` names, and file
    /// paths for `:e` / `:w` (nvim-cmp cmdline flavor, TUI-sized).
    fn completeCmdline(self: *Editor) !void {
        const s = self.cmd.items;
        if (std.mem.indexOfScalar(u8, s, ' ')) |sp| {
            const head = s[0..sp];
            const arg = s[sp + 1 ..];
            if (std.mem.eql(u8, head, "theme")) {
                var buf: [themes.list.len][]const u8 = undefined;
                for (&themes.list, 0..) |*t, i| buf[i] = t.name;
                return self.completeFrom(&buf, arg, sp + 1);
            }
            if (std.mem.eql(u8, head, "e") or std.mem.eql(u8, head, "w"))
                return self.completePath(arg, sp + 1);
            return;
        }
        const cmds = [_][]const u8{ "q", "q!", "qa", "qa!", "w", "wq", "x", "e", "bn", "bp", "bd", "bd!", "ls", "theme", "themes", "noh", "rename", "LspRestart" };
        return self.completeFrom(&cmds, s, 0);
    }

    /// Complete `cmd[start..]` against `options`: extend to the longest common
    /// prefix of all matches; list candidates in the status line when ambiguous.
    fn completeFrom(self: *Editor, options: []const []const u8, prefix: []const u8, start: usize) !void {
        var lcp: ?[]const u8 = null;
        var count: usize = 0;
        var listing: [96]u8 = undefined;
        var listing_len: usize = 0;
        for (options) |opt| {
            if (!std.mem.startsWith(u8, opt, prefix)) continue;
            count += 1;
            lcp = if (lcp) |p| p[0..std.mem.indexOfDiff(u8, p, opt) orelse p.len] else opt;
            if (listing_len + opt.len + 1 <= listing.len) {
                if (listing_len > 0) {
                    listing[listing_len] = ' ';
                    listing_len += 1;
                }
                @memcpy(listing[listing_len..][0..opt.len], opt);
                listing_len += opt.len;
            }
        }
        const p = lcp orelse return self.setStatus("no match: {s}", .{prefix});
        self.cmd.items.len = start;
        try self.cmd.appendSlice(self.alloc, p);
        if (count > 1) self.setStatus("{s}", .{listing[0..listing_len]});
    }

    /// File-path completion for `:e ` / `:w ` — scans the arg's directory.
    fn completePath(self: *Editor, arg: []const u8, start: usize) !void {
        const slash = std.mem.lastIndexOfScalar(u8, arg, '/');
        const dir_part = if (slash) |i| arg[0 .. i + 1] else "";
        const base = if (slash) |i| arg[i + 1 ..] else arg;

        var names: std.ArrayListUnmanaged([]u8) = .{};
        defer {
            for (names.items) |n| self.alloc.free(n);
            names.deinit(self.alloc);
        }
        var dir = std.fs.cwd().openDir(if (dir_part.len == 0) "." else dir_part, .{ .iterate = true }) catch
            return self.setStatus("no such dir: {s}", .{dir_part});
        defer dir.close();
        var iter = dir.iterate();
        while (iter.next() catch null) |ent| {
            if (!std.mem.startsWith(u8, ent.name, base)) continue;
            if (base.len == 0 and ent.name[0] == '.') continue; // hide dotfiles unless asked
            const suffix: []const u8 = if (ent.kind == .directory) "/" else "";
            const full = try std.fmt.allocPrint(self.alloc, "{s}{s}{s}", .{ dir_part, ent.name, suffix });
            try names.append(self.alloc, full);
        }
        if (names.items.len == 0) return self.setStatus("no match: {s}", .{arg});
        var buf: [self.status_buf.len]u8 = undefined;
        var lcp: []const u8 = names.items[0];
        var listing_len: usize = 0;
        for (names.items) |n| {
            lcp = lcp[0..std.mem.indexOfDiff(u8, lcp, n) orelse lcp.len];
            const short = n[dir_part.len..];
            if (listing_len + short.len + 1 <= buf.len) {
                if (listing_len > 0) {
                    buf[listing_len] = ' ';
                    listing_len += 1;
                }
                @memcpy(buf[listing_len..][0..short.len], short);
                listing_len += short.len;
            }
        }
        self.cmd.items.len = start;
        try self.cmd.appendSlice(self.alloc, lcp);
        if (names.items.len > 1) self.setStatus("{s}", .{buf[0..listing_len]});
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
            noh,
            rename,
            LspRestart,
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
                if (it.next()) |path| try self.cur().setPath(path);
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
            .noh => self.search_hl = false,
            .rename => try self.renameWord(it.next() orelse return self.setStatus("usage: :rename <new-name>", .{})),
            .LspRestart => self.lspRestart(),
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
        } else if (std.mem.startsWith(u8, s, "'<,'>")) {
            // Range from the last visual selection.
            const lt = b.mark_lt orelse return false;
            const gt = b.mark_gt orelse return false;
            lo = @min(lt.row, b.lines.items.len - 1);
            hi = @min(gt.row, b.lines.items.len - 1);
            if (lo > hi) std.mem.swap(usize, &lo, &hi);
            i += 5;
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
        var pat_raw = parts.next() orelse return false;
        if (pat_raw.len == 0) {
            // `:s//rep/` — reuse the last search pattern, like vim.
            if (self.search.items.len == 0) {
                self.setStatus("empty substitute pattern", .{});
                return true;
            }
            pat_raw = self.search.items;
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
            // The substitute pattern becomes the search pattern (vim behavior),
            // unless we already borrowed it from the search register.
            if (pat.ptr != self.search.items.ptr) {
                self.search.clearRetainingCapacity();
                self.search.appendSlice(self.alloc, pat) catch {};
            }
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

    /// Byte range [lo, hi) of the identifier under (or to the right of) the
    /// cursor on the current line, or null when the line has none.
    fn wordNearCursor(self: *Editor) ?[2]usize {
        const b = self.cur();
        const text = b.buf.items;
        const line_start = b.lines.items[b.row].start;
        const line_end = line_start + b.lineLen(b.row);
        var pos = line_start + @min(b.col, b.lineLen(b.row));
        while (pos < line_end and Buffer.wordClass(text[pos]) != 1) pos += 1;
        if (pos >= line_end) return null;
        const w = wordAt(text, pos).?; // pos is on a word char by the scan above
        return .{ w.lo, w.hi };
    }

    /// `:rename <new>` — replace every whole-word occurrence of the identifier
    /// under the cursor. Rewrites the buffer in one pass and applies it as a
    /// single replaceRange: one tree-sitter reparse and one undo entry, and
    /// the cursor follows the renamed occurrence it started on.
    fn renameWord(self: *Editor, new: []const u8) !void {
        if (self.buffers.items.len == 0) return self.setStatus("no open buffer", .{});
        const b = self.cur();
        const r = self.wordNearCursor() orelse return self.setStatus("no word under cursor", .{});
        const old = try self.alloc.dupe(u8, b.buf.items[r[0]..r[1]]);
        defer self.alloc.free(old);
        if (std.mem.eql(u8, old, new)) return self.setStatus("rename: unchanged", .{});
        var out: std.ArrayListUnmanaged(u8) = .{};
        defer out.deinit(self.alloc);
        try out.ensureTotalCapacity(self.alloc, b.buf.items.len);
        const text = b.buf.items;
        var hits: usize = 0;
        var cursor_byte: usize = r[0];
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, text, i, old)) |p| {
            if (!wordBounded(text, p, old.len)) {
                try out.appendSlice(self.alloc, text[i .. p + 1]);
                i = p + 1;
                continue;
            }
            try out.appendSlice(self.alloc, text[i..p]);
            if (p == r[0]) cursor_byte = out.items.len;
            try out.appendSlice(self.alloc, new);
            hits += 1;
            i = p + old.len;
        }
        try out.appendSlice(self.alloc, text[i..]);
        try b.replaceRange(0, text.len, out.items);
        b.setCursorFromByte(cursor_byte);
        b.goal_col = b.col;
        self.setStatus("renamed {d} occurrence{s} of {s}", .{ hits, if (hits == 1) "" else "s", old });
    }

    /// `*` / `#`: whole-word search for the identifier under (or right of)
    /// the cursor. Loads the search register so n/N continue the hunt.
    fn searchWord(self: *Editor, dir: i2) void {
        if (self.buffers.items.len == 0) return;
        const b = self.cur();
        const text = b.buf.items;
        const r = self.wordNearCursor() orelse return self.setStatus("no word under cursor", .{});
        const word = text[r[0]..r[1]];
        self.search.clearRetainingCapacity();
        self.search.appendSlice(self.alloc, word) catch return;
        self.search_hl = true;
        const hit = findWordHit(text, self.search.items, r[0], dir) orelse
            return self.setStatus("pattern not found: {s}", .{self.search.items});
        self.pushJump();
        b.setCursorFromByte(hit);
        const st = searchStats(text, self.search.items, hit);
        self.setStatus("/{s} [{d}/{d}]", .{ self.search.items, st.idx, st.total });
    }

    /// Match count for the status line: total plain occurrences of `pat` and
    /// the 1-based index of the one at `pos`. Steps by 1 (overlapping) so the
    /// count matches exactly the set of positions n/N walks.
    fn searchStats(text: []const u8, pat: []const u8, pos: usize) struct { idx: usize, total: usize } {
        if (pat.len == 0) return .{ .idx = 0, .total = 0 };
        var total: usize = 0;
        var idx: usize = 0;
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, text, i, pat)) |p| {
            total += 1;
            if (p == pos) idx = total;
            i = p + 1;
        }
        return .{ .idx = idx, .total = total };
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
            const st = searchStats(text, pat, pos);
            if (wrapped)
                self.setStatus("search hit {s}, continuing at {s} [{d}/{d}]", .{
                    if (dir > 0) "BOTTOM" else "TOP",
                    if (dir > 0) "TOP" else "BOTTOM",
                    st.idx,
                    st.total,
                })
            else
                self.setStatus("/{s} [{d}/{d}]", .{ pat, st.idx, st.total });
        } else {
            self.setStatus("pattern not found: {s}", .{pat});
        }
    }

    // ---- integrated terminal (NvTerm-style) -------------------------------

    const poll_tick_ms: u32 = 80;

    /// Arm one tick and account for it. Every ctx.tick call in the editor goes
    /// through here.
    fn armTick(self: *Editor, ctx: *vxfw.EventContext, ms: u32) void {
        ctx.tick(ms, self.widget()) catch return;
        self.ticks +|= 1;
    }

    fn lspAlive(self: *Editor) bool {
        return if (self.lsp) |*l| l.alive else false;
    }

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
        if (self.ticks == 0) self.armTick(ctx, poll_tick_ms);
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
        // Any click or wheel dismisses the hunk preview — the buffer may
        // scroll or change underneath it (keys clear it in the event loop,
        // but mouse events branch off before that reset).
        const had_preview = m.type == .press and self.preview_len != 0;
        if (m.type == .press) self.preview_len = 0;
        // Presses, drags and wheel events move the cursor or switch buffers,
        // which would leave the completion menu's byte region stale (next
        // Ctrl-n applying at a wrong offset or in a different buffer). Bare
        // pointer motion moves nothing — vxfw reports it (DECSET 1003), and
        // closing on it would break cycling whenever the mouse twitches.
        if (self.cmp.active and
            (m.type == .press or m.type == .drag or
                m.button == .wheel_up or m.button == .wheel_down))
        {
            self.cmpClose();
        }
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

        // Any left press cancels a half-typed prefix and its count: a later
        // keystroke must not resume an operator at the click destination, and
        // the which-key panel must not outlive the click. Covers every press
        // path below (tabline, tree, text area, dead space).
        const had_pending = self.pending != .none;
        self.pending = .none;
        self.count = 0;
        // Also abort any in-flight dot capture: with the prefix gone,
        // dotSettle would otherwise commit the orphaned keys plus whatever
        // is typed next (e.g. `r` click `j` -> dot register "rj").
        self.dot_capturing = false;

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
            // Miss (right of the last tab): still repaint a stale which-key
            // panel away, since the prefix was cleared above.
            if (had_pending or had_preview) ctx.consumeAndRedraw();
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

        // Press on dead space (status row, splits): nothing to do, but a
        // cleared prefix or hunk preview means a visible panel must be
        // redrawn away.
        if (had_pending or had_preview) ctx.consumeAndRedraw();
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
                'c', 'C' => if (!key.mods.shift) {
                    ctx.quit = true;
                },
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
        const gutter: u16 = if (self.numbers or self.relnum)
            @intCast(std.fmt.count("{d}", .{b.lines.items.len}) + 3) // sign col + digits + pad
        else
            2; // sign col + pad
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

        // matchparen: when the cursor rests on a bracket, passively
        // highlight it and its partner (NvChad-style).
        var mp_a: usize = std.math.maxInt(usize);
        var mp_b: usize = std.math.maxInt(usize);
        if (self.focus == .editor) {
            const cur_abs = b.lines.items[b.row].start + @min(b.col, b.lineLen(b.row));
            if (bracketMatchAt(b.buf.items, cur_abs)) |m| {
                mp_a = cur_abs;
                mp_b = m;
            }
        }

        // vim-illuminate: passively underline other occurrences of the word
        // under the cursor (normal mode, editor focus only).
        const illum: ?struct { word: []const u8, self_lo: usize } =
            if (self.focus == .editor and self.mode == .normal)
                if (wordUnderCursor(b)) |w|
                    .{ .word = b.buf.items[w.lo..w.hi], .self_lo = w.lo }
                else
                    null
            else
                null;

        // highlight.on_yank: only paint while the buffer is untouched since
        // the yank — any edit shifts the recorded byte range.
        const flash: ?[2]usize = if (self.yank_flash) |f|
            (if (f.buf == self.active and f.seq == b.undo_seq) [2]usize{ f.lo, f.hi } else null)
        else
            null;

        var row: u16 = 0;
        while (row < text_rows) : (row += 1) {
            const li = b.scroll + row;
            if (li >= b.lines.items.len) break;
            const line = b.lines.items[li];
            const draw_row = text_top + row;

            if (self.numbers or self.relnum) {
                // relnum alone = vim's pure relativenumber (cursor row shows
                // 0); with numbers on, the cursor row keeps its absolute
                // number (hybrid, like NvChad).
                const num_val = if (self.relnum and li != b.row)
                    (if (li > b.row) li - b.row else b.row - li)
                else if (self.numbers)
                    (li + 1)
                else
                    0;
                const num = try std.fmt.allocPrint(ctx.arena, "{d}", .{num_val});
                _ = writeText(surface, ctx, @intCast(x0 + gutter - 1 - num.len), draw_row, num, if (li == b.row) cursor_ln_style else gutter_style);
            }

            // Diagnostics own the sign cell when present; the git sign shows through
            // only on lines zls has nothing to say about.
            if (b.diagFor(li)) |sev| {
                const dc = switch (sev) {
                    1 => th.red,
                    2 => th.orange,
                    3 => th.blue,
                    else => th.gray,
                };
                _ = writeText(surface, ctx, x0, draw_row, "●", .{ .fg = dc, .bg = th.bg });
            } else switch (b.signFor(li)) {
                .none => {},
                .add => _ = writeText(surface, ctx, x0, draw_row, "▎", .{ .fg = th.green, .bg = th.bg }),
                .change => _ = writeText(surface, ctx, x0, draw_row, "▎", .{ .fg = th.orange, .bg = th.bg }),
                .delete => _ = writeText(surface, ctx, x0, draw_row, "▁", .{ .fg = th.red, .bg = th.bg }),
            }

            const text = b.buf.items[line.start..line.end];
            const pat = self.search.items;
            const search_style: vaxis.Style = .{ .fg = th.bg, .bg = th.yellow };
            const sel = self.selRange();
            var match: ?usize = if (self.search_hl and pat.len > 0) std.mem.indexOf(u8, text, pat) else null;
            var ill_at: ?usize = if (illum) |il|
                nextIllum(b.buf.items, line.start, text, 0, il.word, il.self_lo)
            else
                null;
            var cspan: ?ColorSpan = findColorSpan(text, 0);
            var col: u16 = x0 + gutter;
            var i: usize = 0;
            while (i < text.len and col < text_right) {
                const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
                const end = @min(i + cp_len, text.len);
                const slice = text[i..end];
                var style = b.hl.styleAt(line.start + i);
                if (cspan) |c| {
                    if (i >= c.e) cspan = findColorSpan(text, i);
                }
                if (cspan) |c| {
                    if (i >= c.s and i < c.e) {
                        // Paint the literal in its own color, contrast-picked fg.
                        const lum: u32 = 299 * @as(u32, c.r) + 587 * @as(u32, c.g) + 114 * @as(u32, c.b);
                        style.bg = .{ .rgb = .{ c.r, c.g, c.b } };
                        style.fg = if (lum > 140_000) .{ .rgb = .{ 0, 0, 0 } } else .{ .rgb = .{ 255, 255, 255 } };
                    }
                }
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
                if (flash) |fr| {
                    const abs = line.start + i;
                    if (abs >= fr[0] and abs < fr[1]) {
                        style.bg = th.orange;
                        style.fg = th.bg;
                    }
                }
                {
                    const abs = line.start + i;
                    if (abs == mp_a or abs == mp_b) {
                        style.fg = th.cyan;
                        style.bg = th.bar_bg;
                        style.bold = true;
                    }
                }
                // Illuminate last: it only adds an underline, so it coexists
                // with (rather than being wiped by) the whole-struct search
                // style and the bg-based selection/matchparen styles.
                if (illum) |il| {
                    if (ill_at) |ia| {
                        if (i >= ia + il.word.len)
                            ill_at = nextIllum(b.buf.items, line.start, text, i, il.word, il.self_lo);
                    }
                    if (ill_at) |ia| {
                        if (i >= ia and i < ia + il.word.len) style.ul_style = .single;
                    }
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
        if (self.focus == .editor and self.popup.kind == .none and (self.mode == .normal or self.mode == .visual or self.mode == .visual_line) and self.pending != .none) {
            self.drawWhichKey(surface, ctx, max);
        }
        if (self.preview_len > 0 and self.popup.kind == .none) self.drawPreview(surface, ctx, max);
        if (self.term_view == .float) self.drawTermFloat(surface, ctx, max.width, max.height - 1);
        if (self.cmp.active) self.drawCmp(surface, ctx, x0, gutter, text_top, text_rows, text_right);
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
            .{ .icon = "\u{f1da}", .label = "Restore Session", .key = "s" },
            .{ .icon = "\u{f011}", .label = "Quit", .key = "q" },
        };
        const btn_w: u16 = 26;
        const n_recent: u16 = @intCast(@min(self.oldfiles.items.len, 5));
        const recent_h: u16 = if (n_recent > 0) n_recent + 1 else 0;
        const total_h: u16 = @as(u16, logo.len) + 1 + (@as(u16, btns.len) * 2 - 1) + 2 + recent_h;
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
        // Recent files (NvDash-style), opened with 1-5.
        if (n_recent > 0) {
            var ri: u16 = 0;
            while (ri < n_recent and y < max.height -| 1) : (ri += 1) {
                const full = self.oldfiles.items[ri];
                // Show a path tail that fits the button column width.
                var tail = full;
                const fit: usize = btn_w - 6;
                if (tail.len > fit) {
                    tail = tail[tail.len - fit ..];
                    if (std.mem.indexOfScalar(u8, tail, '/')) |sl| tail = tail[sl + 1 ..];
                }
                const bx: u16 = x_off + (area_w -| btn_w) / 2;
                const digit = std.fmt.allocPrint(ctx.arena, "{d}", .{ri + 1}) catch "?";
                var col = writeText(surface, ctx, bx, y, digit, .{ .fg = th.yellow, .bold = true });
                col = writeText(surface, ctx, col, y, "  ", .{});
                _ = writeText(surface, ctx, col, y, tail, .{ .fg = th.fg });
                y += 1;
            }
            y += 1;
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
            const end = writeText(surface, ctx, 0, status_row, cmdline, bar_style);
            // Completion candidates (set by completeCmdline), right-aligned.
            if (self.status_len > 0) {
                const msg = self.status_buf[0..self.status_len];
                const w: u16 = @min(@as(u16, @intCast(ctx.stringWidth(msg))), width -| (end + 2));
                if (w > 0) {
                    const x: u16 = width - w;
                    const dim_style: vaxis.Style = .{ .fg = th.gutter, .bg = th.bar_bg };
                    _ = writeText(surface, ctx, x, status_row, msg, dim_style);
                }
            }
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

        if (self.lspAlive()) {
            const lsp_style: vaxis.Style = .{ .fg = th.gutter_active, .bg = th.bar_bg };
            end = writeText(surface, ctx, end, status_row, " zls ", lsp_style);
        }

        if (b) |buf| {
            var errs: usize = 0;
            var warns: usize = 0;
            for (buf.diags.items) |d| {
                if (d.severity == 1) errs += 1 else if (d.severity == 2) warns += 1;
            }
            if (errs + warns > 0) {
                const seg = std.fmt.allocPrint(ctx.arena, " E:{d} W:{d} ", .{ errs, warns }) catch return;
                const dstyle: vaxis.Style = .{
                    .fg = if (errs > 0) th.red else th.orange,
                    .bg = th.bar_bg,
                    .bold = true,
                };
                end = writeText(surface, ctx, end, status_row, seg, dstyle);
            }
        }

        const diag_at_cursor = if (self.status_len == 0) self.diagAtCursor() else null;
        const left = if (self.status_len > 0)
            std.fmt.allocPrint(ctx.arena, " {s}", .{self.status_buf[0..self.status_len]}) catch return
        else if (diag_at_cursor) |d|
            std.fmt.allocPrint(ctx.arena, " ● {s}", .{d.message}) catch return
        else if (b) |buf|
            std.fmt.allocPrint(ctx.arena, " {s}{s}", .{
                buf.file_name,
                if (buf.dirty) " [+]" else "",
            }) catch return
        else
            " dashboard";
        const left_style: vaxis.Style = if (diag_at_cursor != null) .{ .fg = th.gutter, .bg = th.bar_bg } else bar_style;
        end = writeText(surface, ctx, end, status_row, left, left_style);

        if (b) |buf| {
            var crumbs: [4]Crumb = undefined;
            const nc = self.breadcrumbs(&crumbs);
            if (nc > 0) {
                const seg = if (nc >= 2)
                    std.fmt.allocPrint(ctx.arena, " {s} > {s} {s} ", .{
                        crumbs[1].name, crumbs[0].kw, crumbs[0].name,
                    }) catch return
                else
                    std.fmt.allocPrint(ctx.arena, " {s} {s} ", .{ crumbs[0].kw, crumbs[0].name }) catch return;
                const w: u16 = @intCast(@min(ctx.stringWidth(seg), width));
                const right = std.fmt.allocPrint(ctx.arena, " {d}/{d}  {d}:{d} ", .{
                    self.active + 1, self.buffers.items.len, buf.row + 1, buf.col + 1,
                }) catch return;
                const rx: u16 = if (right.len < width) width - @as(u16, @intCast(right.len)) else 0;
                if (w > 0 and rx -| w > end) {
                    const crumb_style: vaxis.Style = .{ .fg = th.gutter_active, .bg = th.bar_bg };
                    _ = writeText(surface, ctx, rx - w, status_row, seg, crumb_style);
                }
                if (right.len < width) {
                    _ = writeText(surface, ctx, rx, status_row, right, mode_style);
                }
            } else {
                const right = std.fmt.allocPrint(ctx.arena, " {d}/{d}  {d}:{d} ", .{
                    self.active + 1, self.buffers.items.len, buf.row + 1, buf.col + 1,
                }) catch return;
                if (right.len < width) {
                    _ = writeText(surface, ctx, @intCast(width - right.len), status_row, right, mode_style);
                }
            }
        }
    }

    fn drawWhichKey(self: *Editor, surface: vxfw.Surface, ctx: vxfw.DrawContext, max: vxfw.Size) void {
        const visual = self.mode == .visual or self.mode == .visual_line;
        const rows = whichKeyRows(self.pending, visual) orelse return;
        const th = self.theme.p;

        // Panel width: longest row + 2 (left-pad 1 col + right margin 1).
        var max_width: u16 = 0;
        for (rows) |row| {
            const w: u16 = @intCast(@min(ctx.stringWidth(row), max.width));
            if (w > max_width) max_width = w;
        }
        const panel_w = max_width + 2;
        if (max.width < panel_w) return;

        const panel_h: u16 = @intCast(rows.len);
        const status_row = max.height -| 1;
        // + 1: keep the panel below the tabline (row 0).
        if (status_row < panel_h + 1) return;

        const x0 = max.width -| panel_w; // right-aligned
        const y0 = status_row -| panel_h;

        const bg_style: vaxis.Style = .{ .bg = th.bar_bg };
        const text_style: vaxis.Style = .{ .fg = th.fg, .bg = th.bar_bg };
        const key_style: vaxis.Style = .{ .fg = th.blue, .bg = th.bar_bg, .bold = true };

        // Fill background.
        var r: u16 = 0;
        while (r < panel_h) : (r += 1) {
            var c: u16 = 0;
            while (c < panel_w) : (c += 1) {
                surface.writeCell(x0 + c, y0 + r, .{ .style = bg_style });
            }
        }

        // Draw each row: the key part ends at the first double space
        // ("K  desc", "f F t T  desc"); rows without one draw as plain text.
        r = 0;
        while (r < rows.len) : (r += 1) {
            const row = rows[r];
            var col = x0 + 1; // left-pad 1 col
            const sep = std.mem.indexOf(u8, row, "  ") orelse 0;
            col = writeText(surface, ctx, col, y0 + r, row[0..sep], key_style);
            _ = writeText(surface, ctx, col, y0 + r, row[sep..], text_style);
        }
    }

    /// nvim-cmp-lite popup: candidate rows near the cursor, selected row
    /// highlighted, below the cursor when it fits and above otherwise.
    fn drawCmp(self: *Editor, surface: vxfw.Surface, ctx: vxfw.DrawContext, x0: u16, gutter: u16, text_top: u16, text_rows: u16, text_right: u16) void {
        const b = self.cur();
        const items = self.cmp.items.items;
        if (items.len == 0) return;
        if (b.row < b.scroll or b.row >= b.scroll + text_rows) return;
        const th = self.theme.p;
        const visible: u16 = @intCast(@min(items.len, Cmp.rows));
        var w: u16 = 0;
        for (items) |it| {
            const iw: u16 = @intCast(@min(it.len + 2, 30));
            if (iw > w) w = iw;
        }
        if (w + 2 > text_right) return;
        const cur_row: u16 = text_top + @as(u16, @intCast(b.row - b.scroll));
        const anchor: u16 = x0 + gutter + self.displayCol(ctx);
        const col0: u16 = if (anchor + w <= text_right) anchor else text_right - w;
        const below = cur_row + 1 + visible <= text_top + text_rows;
        if (!below and cur_row < text_top + visible) return;
        const row0: u16 = if (below) cur_row + 1 else cur_row - visible;
        const sel = self.cmp.sel;
        const start = if (sel >= visible) sel - visible + 1 else 0;
        const body: vaxis.Style = .{ .fg = th.fg, .bg = th.bar_bg };
        const sel_style: vaxis.Style = .{ .fg = th.bg, .bg = th.blue, .bold = true };
        var vi: u16 = 0;
        while (vi < visible) : (vi += 1) {
            const idx = start + vi;
            if (idx >= items.len) break;
            const st = if (idx == sel) sel_style else body;
            var c: u16 = 0;
            while (c < w) : (c += 1) surface.writeCell(col0 + c, row0 + vi, .{ .style = st });
            // Clip to the box (codepoint-safe): long candidates must not
            // spill over the buffer text to the right.
            var cap: usize = @min(items[idx].len, @as(usize, w) -| 2);
            while (cap > 0 and cap < items[idx].len and (items[idx][cap] & 0xC0) == 0x80) cap -= 1;
            _ = writeText(surface, ctx, col0 + 1, row0 + vi, items[idx][0..cap], st);
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
            // Clip to the inner width (codepoint-safe): grep/quickfix rows
            // can be far wider than the frame and were eating the border.
            const inner: usize = w -| 3; // left pad 2 + right border 1
            var cap = @min(name.len, inner);
            while (cap > 0 and cap < name.len and (name[cap] & 0xC0) == 0x80) cap -= 1;
            _ = writeText(surface.*, ctx, x0 + 2, item_row, name[0..cap], if (is_sel) sel_style else body);
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
