const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const themes = @import("theme.zig");
const Buffer = @import("buffer.zig").Buffer;

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
    status_buf: [256]u8 = undefined,
    status_len: usize = 0,
    popup: Popup = .{},

    pub const Mode = enum { normal, insert, command };
    const Pending = enum { none, g, d, leader };

    /// Floating picker overlay (buffers / themes), telescope-flavored:
    /// typing filters, arrows or C-j/C-k move, Enter picks, Esc closes.
    const Popup = struct {
        kind: Kind = .none,
        filter: std.ArrayListUnmanaged(u8) = .{},
        selected: usize = 0,

        const Kind = enum { none, buffers, themes };
        const max_items = 64;
    };

    pub fn init(alloc: std.mem.Allocator) Editor {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Editor) void {
        for (self.buffers.items) |*b| b.deinit();
        self.buffers.deinit(self.alloc);
        self.cmd.deinit(self.alloc);
        self.popup.filter.deinit(self.alloc);
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
                self.active = i;
                return;
            }
        }
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
    }

    fn cycleBuffer(self: *Editor, delta: isize) void {
        const n = self.buffers.items.len;
        if (n < 2) return;
        const i: isize = @intCast(self.active);
        self.active = @intCast(@mod(i + delta, @as(isize, @intCast(n))));
    }

    /// Close the active buffer; quits when it was the last one.
    fn closeBuffer(self: *Editor, ctx: *vxfw.EventContext, force: bool) void {
        const b = self.cur();
        if (b.dirty and !force) {
            self.setStatus("unsaved changes in {s} (add ! to discard)", .{b.displayName()});
            return;
        }
        var removed = self.buffers.orderedRemove(self.active);
        removed.deinit();
        if (self.buffers.items.len == 0) {
            ctx.quit = true;
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
    }

    // ---- popup ------------------------------------------------------------

    fn openPopup(self: *Editor, kind: Popup.Kind) void {
        self.popup.kind = kind;
        self.popup.selected = 0;
        self.popup.filter.clearRetainingCapacity();
    }

    fn closePopup(self: *Editor) void {
        self.popup.kind = .none;
    }

    fn popupTitle(self: *const Editor) []const u8 {
        return switch (self.popup.kind) {
            .buffers => " Buffers ",
            .themes => " Themes ",
            .none => "",
        };
    }

    fn popupItemCount(self: *const Editor) usize {
        return switch (self.popup.kind) {
            .buffers => self.buffers.items.len,
            .themes => themes.list.len,
            .none => 0,
        };
    }

    fn popupItemName(self: *const Editor, i: usize) []const u8 {
        return switch (self.popup.kind) {
            .buffers => self.buffers.items[i].displayName(),
            .themes => themes.list[i].name,
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
        } else if (!key.mods.ctrl and !key.mods.alt) {
            const text = key.text orelse return;
            try self.popup.filter.appendSlice(self.alloc, text);
            self.popup.selected = 0;
        }
        ctx.consumeAndRedraw();
    }

    // ---- events -----------------------------------------------------------

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => return ctx.requestFocus(self.widget()),
            .key_press => |key| {
                self.status_len = 0;
                if (self.popup.kind != .none) return self.handlePopup(ctx, key);
                switch (self.mode) {
                    .normal => try self.handleNormal(ctx, key),
                    .insert => try self.handleInsert(ctx, key),
                    .command => try self.handleCommand(ctx, key),
                }
            },
            else => {},
        }
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
                    b.row = 0;
                    b.col = 0;
                    b.goal_col = 0;
                }
                return ctx.consumeAndRedraw();
            },
            .d => {
                self.pending = .none;
                if (cp == 'd') try b.deleteLine();
                return ctx.consumeAndRedraw();
            },
            .leader => {
                self.pending = .none;
                switch (cp) {
                    'b' => self.openPopup(.buffers),
                    't' => self.openPopup(.themes),
                    'x' => self.closeBuffer(ctx, false),
                    else => {},
                }
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
                else => return,
            }
            return ctx.consumeAndRedraw();
        }

        switch (cp) {
            vaxis.Key.tab => if (key.mods.shift) self.cycleBuffer(-1) else self.cycleBuffer(1),
            ' ' => self.pending = .leader,
            'h', vaxis.Key.left => b.moveLeft(),
            'l', vaxis.Key.right => b.moveRight(false),
            'j', vaxis.Key.down => b.moveVert(1, false),
            'k', vaxis.Key.up => b.moveVert(-1, false),
            vaxis.Key.page_down => b.moveVert(half, false),
            vaxis.Key.page_up => b.moveVert(-half, false),
            'w' => b.wordForward(),
            'b' => b.wordBackward(),
            'e' => b.wordEnd(),
            '0', vaxis.Key.home => {
                b.col = 0;
                b.goal_col = 0;
            },
            '^' => {
                b.col = b.firstNonWs(b.row);
                b.goal_col = b.col;
            },
            '$', vaxis.Key.end => {
                const len = b.lineLen(b.row);
                b.col = if (len == 0) 0 else Buffer.snapToCp(b.lineText(b.row), len - 1);
                b.goal_col = std.math.maxInt(u32);
            },
            'g' => self.pending = .g,
            'G' => {
                b.row = b.lines.items.len - 1;
                b.clampCol(false);
            },
            'd' => self.pending = .d,
            'x' => try b.deleteCharAtCursor(),
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
                self.cmd.clearRetainingCapacity();
            },
            vaxis.Key.escape => self.pending = .none,
            else => return,
        }
        ctx.consumeAndRedraw();
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
            vaxis.Key.enter => try self.execCommand(ctx),
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
            .w => self.save(),
            .wq, .x => {
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
            const b = self.cur();
            b.row = std.math.clamp(n -| 1, 0, b.lines.items.len - 1);
            b.clampCol(false);
        } else {
            self.setStatus("not an editor command: {s}", .{s});
        }
    }

    // ---- drawing ----------------------------------------------------------

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), max);
        if (max.width == 0 or max.height < 3) return surface;

        const b = self.cur();
        const th = self.theme.p;
        const text_top: u16 = 1; // row 0 is the tabline
        const text_rows: u16 = max.height - 2;
        self.last_height = text_rows;

        // Keep the cursor visible.
        if (b.row < b.scroll) b.scroll = b.row;
        if (b.row >= b.scroll + text_rows) b.scroll = b.row - text_rows + 1;

        const gutter: u16 = @intCast(std.fmt.count("{d}", .{b.lines.items.len}) + 2);
        const gutter_style: vaxis.Style = .{ .fg = th.gutter, .bg = th.bg };
        const cursor_ln_style: vaxis.Style = .{ .fg = th.gutter_active, .bg = th.bg };

        self.drawTabline(surface, ctx, max.width);

        // Paint the theme background over the whole text area first.
        const base = b.hl.baseStyle();
        var fill_row: u16 = text_top;
        while (fill_row < text_top + text_rows) : (fill_row += 1) {
            var fill_col: u16 = 0;
            while (fill_col < max.width) : (fill_col += 1) {
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
            _ = writeText(surface, ctx, @intCast(gutter - 1 - num.len), draw_row, num, if (li == b.row) cursor_ln_style else gutter_style);

            const text = b.buf.items[line.start..line.end];
            var col: u16 = gutter;
            var i: usize = 0;
            while (i < text.len and col < max.width) {
                const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
                const end = @min(i + cp_len, text.len);
                const slice = text[i..end];
                const style = b.hl.styleAt(line.start + i);
                if (slice[0] == '\t') {
                    const stop = gutter + (((col - gutter) / 4) + 1) * 4;
                    while (col < stop and col < max.width) : (col += 1) {
                        surface.writeCell(col, draw_row, .{ .style = style });
                    }
                } else {
                    const w: u16 = @intCast(@min(ctx.stringWidth(slice), 4));
                    if (w > 0) {
                        if (col + w > max.width) break;
                        surface.writeCell(col, draw_row, .{
                            .char = .{ .grapheme = slice, .width = @intCast(w) },
                            .style = style,
                        });
                        col += w;
                    }
                }
                i = end;
            }
        }

        self.drawStatus(surface, ctx, max.height - 1, max.width);
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
        } else if (b.row >= b.scroll and b.row < b.scroll + text_rows) {
            surface.cursor = .{
                .row = @intCast(text_top + b.row - b.scroll),
                .col = @intCast(@min(gutter + self.displayCol(ctx), max.width - 1)),
                .shape = if (self.mode == .insert) .beam else .block,
            };
        }
        return surface;
    }

    fn drawTabline(self: *Editor, surface: vxfw.Surface, ctx: vxfw.DrawContext, width: u16) void {
        const th = self.theme.p;
        const line_style: vaxis.Style = .{ .fg = th.bar_fg, .bg = th.bar_bg };
        var col: u16 = 0;
        while (col < width) : (col += 1) {
            surface.writeCell(col, 0, .{ .style = line_style });
        }

        const active_style: vaxis.Style = .{ .fg = th.fg, .bg = th.bg, .bold = true };
        const inactive_style: vaxis.Style = .{ .fg = th.gutter_active, .bg = th.bar_bg };
        col = 0;
        for (self.buffers.items, 0..) |*b, i| {
            if (col >= width) break;
            const label = std.fmt.allocPrint(ctx.arena, " {s}{s} ", .{
                b.displayName(),
                if (b.dirty) " [+]" else "",
            }) catch return;
            col = writeText(surface, ctx, col, 0, label, if (i == self.active) active_style else inactive_style);
        }
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
        const b = self.cur();
        const th = self.theme.p;
        const bar_style: vaxis.Style = .{ .fg = th.bar_fg, .bg = th.bar_bg };
        var col: u16 = 0;
        while (col < width) : (col += 1) {
            surface.writeCell(col, status_row, .{ .style = bar_style });
        }

        if (self.mode == .command) {
            const cmdline = std.fmt.allocPrint(ctx.arena, ":{s}", .{self.cmd.items}) catch return;
            _ = writeText(surface, ctx, 0, status_row, cmdline, bar_style);
            return;
        }

        const mode_style: vaxis.Style = switch (self.mode) {
            .normal => .{ .fg = th.badge_fg, .bg = th.green, .bold = true },
            .insert => .{ .fg = th.badge_fg, .bg = th.blue, .bold = true },
            .command => unreachable,
        };
        const mode_txt = switch (self.mode) {
            .normal => " NORMAL ",
            .insert => " INSERT ",
            .command => unreachable,
        };
        var end = writeText(surface, ctx, 0, status_row, mode_txt, mode_style);

        const left = if (self.status_len > 0)
            std.fmt.allocPrint(ctx.arena, " {s}", .{self.status_buf[0..self.status_len]}) catch return
        else
            std.fmt.allocPrint(ctx.arena, " {s}{s}", .{
                b.file_name,
                if (b.dirty) " [+]" else "",
            }) catch return;
        end = writeText(surface, ctx, end, status_row, left, bar_style);

        const right = std.fmt.allocPrint(ctx.arena, " {d}/{d}  {d}:{d} ", .{
            self.active + 1, self.buffers.items.len, b.row + 1, b.col + 1,
        }) catch return;
        if (right.len < width) {
            _ = writeText(surface, ctx, @intCast(width - right.len), status_row, right, mode_style);
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
