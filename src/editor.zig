const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const ts = @import("tree-sitter");
const syntax = @import("syntax.zig");

fn rgb(r: u8, g: u8, b: u8) vaxis.Color {
    return .{ .rgb = .{ r, g, b } };
}

/// Modal (vim-style) editing widget. The cursor column is a byte offset into
/// the current line, kept on a UTF-8 codepoint boundary. The last line of the
/// lines table is always present, possibly empty (so a trailing newline shows
/// as an empty final line and edit logic needs no end-of-buffer special cases).
pub const Editor = struct {
    alloc: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8) = .{},
    lines: std.ArrayListUnmanaged(Line) = .{},
    hl: *syntax.Highlighter,
    file_name: []const u8,

    mode: Mode = .normal,
    pending: Pending = .none,
    row: usize = 0,
    col: usize = 0,
    goal_col: usize = 0,
    scroll: usize = 0,
    last_height: u16 = 24,
    dirty: bool = false,
    cmd: std.ArrayListUnmanaged(u8) = .{},
    status_buf: [256]u8 = undefined,
    status_len: usize = 0,

    pub const Mode = enum { normal, insert, command };
    const Pending = enum { none, g, d };
    pub const Line = struct { start: u32, end: u32 };

    pub fn init(
        alloc: std.mem.Allocator,
        hl: *syntax.Highlighter,
        file_name: []const u8,
        contents: []const u8,
    ) !Editor {
        var self = Editor{ .alloc = alloc, .hl = hl, .file_name = file_name };
        try self.buf.appendSlice(alloc, contents);
        try self.rebuildLines();
        try hl.update(self.buf.items, null);
        return self;
    }

    pub fn deinit(self: *Editor) void {
        self.buf.deinit(self.alloc);
        self.lines.deinit(self.alloc);
        self.cmd.deinit(self.alloc);
    }

    pub fn widget(self: *Editor) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    // ---- text model -------------------------------------------------------

    fn rebuildLines(self: *Editor) !void {
        self.lines.clearRetainingCapacity();
        var start: u32 = 0;
        for (self.buf.items, 0..) |byte, i| {
            if (byte == '\n') {
                try self.lines.append(self.alloc, .{ .start = start, .end = @intCast(i) });
                start = @intCast(i + 1);
            }
        }
        try self.lines.append(self.alloc, .{ .start = start, .end = @intCast(self.buf.items.len) });
    }

    fn lineText(self: *const Editor, row: usize) []const u8 {
        const line = self.lines.items[row];
        return self.buf.items[line.start..line.end];
    }

    fn lineLen(self: *const Editor, row: usize) usize {
        const line = self.lines.items[row];
        return line.end - line.start;
    }

    fn cursorByte(self: *const Editor) usize {
        return self.lines.items[self.row].start + self.col;
    }

    fn lineOfByte(self: *const Editor, byte: usize) usize {
        const items = self.lines.items;
        var lo: usize = 0;
        var hi: usize = items.len - 1;
        while (lo < hi) {
            const mid = (lo + hi + 1) / 2;
            if (items[mid].start <= byte) lo = mid else hi = mid - 1;
        }
        return lo;
    }

    fn pointAt(self: *const Editor, byte: usize) ts.Point {
        const li = self.lineOfByte(byte);
        return .{ .row = @intCast(li), .column = @intCast(byte - self.lines.items[li].start) };
    }

    /// Apply one edit to the buffer, then reparse incrementally.
    fn replaceRange(self: *Editor, start: usize, end: usize, text: []const u8) !void {
        var newlines: u32 = 0;
        var after_last_nl: usize = 0;
        for (text, 0..) |b, i| {
            if (b == '\n') {
                newlines += 1;
                after_last_nl = i + 1;
            }
        }
        const start_point = self.pointAt(start);
        const edit = ts.InputEdit{
            .start_byte = @intCast(start),
            .old_end_byte = @intCast(end),
            .new_end_byte = @intCast(start + text.len),
            .start_point = start_point,
            .old_end_point = self.pointAt(end),
            .new_end_point = if (newlines == 0)
                .{ .row = start_point.row, .column = start_point.column + @as(u32, @intCast(text.len)) }
            else
                .{ .row = start_point.row + newlines, .column = @intCast(text.len - after_last_nl) },
        };
        try self.buf.replaceRange(self.alloc, start, end - start, text);
        try self.rebuildLines();
        try self.hl.update(self.buf.items, edit);
        self.dirty = true;
    }

    // ---- cursor helpers ---------------------------------------------------

    fn snapToCp(text: []const u8, col_in: usize) usize {
        var col = @min(col_in, text.len);
        while (col > 0 and col < text.len and (text[col] & 0xC0) == 0x80) col -= 1;
        return col;
    }

    fn cpLenAt(self: *const Editor, row: usize, col: usize) usize {
        const text = self.lineText(row);
        if (col >= text.len) return 1;
        return std.unicode.utf8ByteSequenceLength(text[col]) catch 1;
    }

    fn clampCol(self: *Editor) void {
        const len = self.lineLen(self.row);
        const max_col = if (self.mode == .insert) len else if (len == 0) 0 else len - 1;
        self.col = snapToCp(self.lineText(self.row), @min(self.col, max_col));
    }

    fn setCursorFromByte(self: *Editor, byte: usize) void {
        const li = self.lineOfByte(@min(byte, self.buf.items.len));
        self.row = li;
        self.col = @min(byte, self.buf.items.len) - self.lines.items[li].start;
        self.clampCol();
        self.goal_col = self.col;
    }

    fn firstNonWs(self: *const Editor, row: usize) usize {
        const text = self.lineText(row);
        for (text, 0..) |b, i| {
            if (b != ' ' and b != '\t') return i;
        }
        return 0;
    }

    // ---- motions ----------------------------------------------------------

    fn moveLeft(self: *Editor) void {
        if (self.col == 0) return;
        self.col = snapToCp(self.lineText(self.row), self.col - 1);
        self.goal_col = self.col;
    }

    fn moveRight(self: *Editor) void {
        const len = self.lineLen(self.row);
        const next = self.col + self.cpLenAt(self.row, self.col);
        const limit = if (self.mode == .insert) len else if (len == 0) 0 else len - 1;
        if (next <= limit) self.col = next;
        self.goal_col = self.col;
    }

    fn moveVert(self: *Editor, delta: i64) void {
        const last: i64 = @intCast(self.lines.items.len - 1);
        const target = std.math.clamp(@as(i64, @intCast(self.row)) + delta, 0, last);
        self.row = @intCast(target);
        self.col = self.goal_col;
        self.clampCol();
    }

    fn wordClass(b: u8) u8 {
        if (b == ' ' or b == '\t' or b == '\n' or b == '\r') return 0;
        if (std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80) return 1;
        return 2;
    }

    fn wordForward(self: *Editor) void {
        const items = self.buf.items;
        var i = self.cursorByte();
        if (i < items.len) {
            const c = wordClass(items[i]);
            if (c != 0) {
                while (i < items.len and wordClass(items[i]) == c) i += 1;
            }
            while (i < items.len and wordClass(items[i]) == 0) i += 1;
        }
        self.setCursorFromByte(i);
    }

    fn wordBackward(self: *Editor) void {
        const items = self.buf.items;
        var i = self.cursorByte();
        while (i > 0 and wordClass(items[i - 1]) == 0) i -= 1;
        if (i > 0) {
            const c = wordClass(items[i - 1]);
            while (i > 0 and wordClass(items[i - 1]) == c) i -= 1;
        }
        self.setCursorFromByte(i);
    }

    fn wordEnd(self: *Editor) void {
        const items = self.buf.items;
        var i = self.cursorByte();
        if (i < items.len) i += 1;
        while (i < items.len and wordClass(items[i]) == 0) i += 1;
        if (i < items.len) {
            const c = wordClass(items[i]);
            while (i + 1 < items.len and wordClass(items[i + 1]) == c) i += 1;
        }
        self.setCursorFromByte(@min(i, items.len -| 1));
    }

    // ---- edits ------------------------------------------------------------

    fn deleteCharAtCursor(self: *Editor) !void {
        if (self.lineLen(self.row) == 0) return;
        const pos = self.cursorByte();
        try self.replaceRange(pos, pos + self.cpLenAt(self.row, self.col), "");
        self.clampCol();
    }

    fn deleteLine(self: *Editor) !void {
        const line = self.lines.items[self.row];
        var start: usize = line.start;
        var end: usize = line.end;
        if (end < self.buf.items.len) {
            end += 1; // take the trailing newline
        } else if (start > 0) {
            start -= 1; // last line: take the preceding newline instead
        }
        try self.replaceRange(start, end, "");
        self.row = @min(self.row, self.lines.items.len - 1);
        self.clampCol();
    }

    fn insertText(self: *Editor, text: []const u8) !void {
        const pos = self.cursorByte();
        try self.replaceRange(pos, pos, text);
        self.setCursorFromByte(pos + text.len);
    }

    fn backspace(self: *Editor) !void {
        if (self.col > 0) {
            const text = self.lineText(self.row);
            const prev = snapToCp(text, self.col - 1);
            const pos = self.lines.items[self.row].start;
            try self.replaceRange(pos + prev, pos + self.col, "");
            self.col = prev;
            self.goal_col = prev;
        } else if (self.row > 0) {
            const prev_len = self.lineLen(self.row - 1);
            const nl = self.lines.items[self.row - 1].end;
            try self.replaceRange(nl, nl + 1, "");
            self.row -= 1;
            self.col = prev_len;
            self.goal_col = prev_len;
        }
    }

    // ---- status line ------------------------------------------------------

    fn setStatus(self: *Editor, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.bufPrint(&self.status_buf, fmt, args) catch return;
        self.status_len = msg.len;
    }

    fn save(self: *Editor) void {
        std.fs.cwd().writeFile(.{ .sub_path = self.file_name, .data = self.buf.items }) catch |err| {
            self.setStatus("write failed: {s}", .{@errorName(err)});
            return;
        };
        self.dirty = false;
        self.setStatus("\"{s}\" {d}L, {d}B written", .{ self.file_name, self.lines.items.len, self.buf.items.len });
    }

    // ---- events -----------------------------------------------------------

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => return ctx.requestFocus(self.widget()),
            .key_press => |key| {
                self.status_len = 0;
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
        // Effective character: kitty reports 'g'+shift with shifted 'G',
        // legacy terminals report 'G' directly.
        const cp = key.shifted_codepoint orelse key.codepoint;

        switch (self.pending) {
            .none => {},
            .g => {
                self.pending = .none;
                if (cp == 'g') {
                    self.row = 0;
                    self.col = 0;
                    self.goal_col = 0;
                }
                return ctx.consumeAndRedraw();
            },
            .d => {
                self.pending = .none;
                if (cp == 'd') try self.deleteLine();
                return ctx.consumeAndRedraw();
            },
        }

        if (key.mods.alt) return;
        const half: i64 = @max(1, self.last_height / 2);

        if (key.mods.ctrl) {
            switch (cp) {
                'c' => ctx.quit = true,
                'd' => self.moveVert(half),
                'u' => self.moveVert(-half),
                else => return,
            }
            return ctx.consumeAndRedraw();
        }

        switch (cp) {
            'h', vaxis.Key.left => self.moveLeft(),
            'l', vaxis.Key.right => self.moveRight(),
            'j', vaxis.Key.down => self.moveVert(1),
            'k', vaxis.Key.up => self.moveVert(-1),
            vaxis.Key.page_down => self.moveVert(half),
            vaxis.Key.page_up => self.moveVert(-half),
            'w' => self.wordForward(),
            'b' => self.wordBackward(),
            'e' => self.wordEnd(),
            '0', vaxis.Key.home => {
                self.col = 0;
                self.goal_col = 0;
            },
            '^' => {
                self.col = self.firstNonWs(self.row);
                self.goal_col = self.col;
            },
            '$', vaxis.Key.end => {
                const len = self.lineLen(self.row);
                self.col = if (len == 0) 0 else snapToCp(self.lineText(self.row), len - 1);
                self.goal_col = std.math.maxInt(u32);
            },
            'g' => self.pending = .g,
            'G' => {
                self.row = self.lines.items.len - 1;
                self.clampCol();
            },
            'd' => self.pending = .d,
            'x' => try self.deleteCharAtCursor(),
            'i' => self.mode = .insert,
            'a' => {
                self.mode = .insert;
                const len = self.lineLen(self.row);
                if (len > 0) self.col = @min(self.col + self.cpLenAt(self.row, self.col), len);
            },
            'A' => {
                self.mode = .insert;
                self.col = self.lineLen(self.row);
            },
            'I' => {
                self.mode = .insert;
                self.col = self.firstNonWs(self.row);
            },
            'o' => {
                const pos = self.lines.items[self.row].end;
                try self.replaceRange(pos, pos, "\n");
                self.row += 1;
                self.col = 0;
                self.goal_col = 0;
                self.mode = .insert;
            },
            'O' => {
                const pos = self.lines.items[self.row].start;
                try self.replaceRange(pos, pos, "\n");
                self.col = 0;
                self.goal_col = 0;
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
        switch (key.codepoint) {
            vaxis.Key.escape => {
                self.mode = .normal;
                if (self.col > 0) self.col = snapToCp(self.lineText(self.row), self.col - 1);
                self.clampCol();
                self.goal_col = self.col;
            },
            vaxis.Key.enter => try self.insertText("\n"),
            vaxis.Key.backspace => try self.backspace(),
            vaxis.Key.tab => try self.insertText("    "),
            else => {
                if (key.mods.ctrl or key.mods.alt) return;
                const text = key.text orelse return;
                try self.insertText(text);
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

        const Cmd = enum { q, @"q!", w, wq, x };
        if (std.meta.stringToEnum(Cmd, s)) |cmd| switch (cmd) {
            .q => {
                if (self.dirty) self.setStatus("unsaved changes (:q! to discard, :wq to save)", .{}) else ctx.quit = true;
            },
            .@"q!" => ctx.quit = true,
            .w => self.save(),
            .wq, .x => {
                self.save();
                if (!self.dirty) ctx.quit = true;
            },
        } else if (std.fmt.parseInt(usize, s, 10) catch null) |n| {
            self.row = std.math.clamp(n -| 1, 0, self.lines.items.len - 1);
            self.clampCol();
        } else {
            self.setStatus("not an editor command: {s}", .{s});
        }
    }

    // ---- drawing ----------------------------------------------------------

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), max);
        if (max.width == 0 or max.height < 2) return surface;

        const text_rows: u16 = max.height - 1;
        self.last_height = text_rows;

        // Keep the cursor visible.
        if (self.row < self.scroll) self.scroll = self.row;
        if (self.row >= self.scroll + text_rows) self.scroll = self.row - text_rows + 1;

        const gutter: u16 = @intCast(std.fmt.count("{d}", .{self.lines.items.len}) + 2);
        const gutter_style: vaxis.Style = .{ .fg = rgb(0x4b, 0x52, 0x63) };
        const cursor_ln_style: vaxis.Style = .{ .fg = rgb(0x9d, 0xa5, 0xb4) };

        var row: u16 = 0;
        while (row < text_rows) : (row += 1) {
            const li = self.scroll + row;
            if (li >= self.lines.items.len) break;
            const line = self.lines.items[li];

            const num = try std.fmt.allocPrint(ctx.arena, "{d}", .{li + 1});
            _ = writeText(surface, ctx, @intCast(gutter - 1 - num.len), row, num, if (li == self.row) cursor_ln_style else gutter_style);

            const text = self.buf.items[line.start..line.end];
            var col: u16 = gutter;
            var i: usize = 0;
            while (i < text.len and col < max.width) {
                const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
                const end = @min(i + cp_len, text.len);
                const slice = text[i..end];
                const style = self.hl.styleAt(line.start + i);
                if (slice[0] == '\t') {
                    const stop = gutter + (((col - gutter) / 4) + 1) * 4;
                    while (col < stop and col < max.width) : (col += 1) {
                        surface.writeCell(col, row, .{ .style = style });
                    }
                } else {
                    const w: u16 = @intCast(@min(ctx.stringWidth(slice), 4));
                    if (w > 0) {
                        if (col + w > max.width) break;
                        surface.writeCell(col, row, .{
                            .char = .{ .grapheme = slice, .width = @intCast(w) },
                            .style = style,
                        });
                        col += w;
                    }
                }
                i = end;
            }
        }

        self.drawStatus(surface, ctx, text_rows, max.width);

        // Terminal cursor placement.
        if (self.mode == .command) {
            surface.cursor = .{
                .row = text_rows,
                .col = @intCast(@min(1 + self.cmd.items.len, max.width - 1)),
                .shape = .beam,
            };
        } else if (self.row >= self.scroll and self.row < self.scroll + text_rows) {
            surface.cursor = .{
                .row = @intCast(self.row - self.scroll),
                .col = @intCast(@min(gutter + self.displayCol(ctx), max.width - 1)),
                .shape = if (self.mode == .insert) .beam else .block,
            };
        }
        return surface;
    }

    /// Display column of the cursor within its line (tabs expand to 4-stops).
    fn displayCol(self: *const Editor, ctx: vxfw.DrawContext) u16 {
        const text = self.lineText(self.row);
        var disp: u16 = 0;
        var i: usize = 0;
        while (i < text.len and i < self.col) {
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
        const bar_style: vaxis.Style = .{ .fg = rgb(0xab, 0xb2, 0xbf), .bg = rgb(0x3e, 0x44, 0x52) };
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
            .normal => .{ .fg = rgb(0x28, 0x2c, 0x34), .bg = rgb(0x98, 0xc3, 0x79), .bold = true },
            .insert => .{ .fg = rgb(0x28, 0x2c, 0x34), .bg = rgb(0x61, 0xaf, 0xef), .bold = true },
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
                self.file_name,
                if (self.dirty) " [+]" else "",
            }) catch return;
        end = writeText(surface, ctx, end, status_row, left, bar_style);

        const right = std.fmt.allocPrint(ctx.arena, " {d}:{d} ", .{ self.row + 1, self.col + 1 }) catch return;
        if (right.len < width) {
            _ = writeText(surface, ctx, @intCast(width - right.len), status_row, right, mode_style);
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
