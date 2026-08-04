const std = @import("std");
const ts = @import("tree-sitter");
const syntax = @import("syntax.zig");
const themes = @import("theme.zig");

/// One open file: text storage, line table, cursor/scroll state and its own
/// syntax highlighter (tree-sitter trees are per-buffer). The last line of
/// the lines table is always present, possibly empty, so a trailing newline
/// shows as an empty final line and edit logic needs no special cases.
pub const Buffer = struct {
    alloc: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8) = .{},
    lines: std.ArrayListUnmanaged(Line) = .{},
    hl: syntax.Highlighter,
    /// Owned copy of the path this buffer reads from / writes to.
    file_name: []u8,

    row: usize = 0,
    col: usize = 0,
    goal_col: usize = 0,
    scroll: usize = 0,
    dirty: bool = false,

    /// Per-line git status vs HEAD (gitsigns-style gutter markers).
    /// Refreshed on open/save; may be shorter than `lines` after edits.
    git_signs: std.ArrayListUnmanaged(Sign) = .{},

    /// a-z vim marks (`m{a-z}`); positions are clamped when jumped to, so
    /// stale marks after edits degrade gracefully instead of invalidating.
    marks: [26]?Mark = [_]?Mark{null} ** 26,

    pub const Mark = struct { row: usize, col: usize };
    pub const Sign = enum(u8) { none, add, change, delete };

    pub const Line = struct { start: u32, end: u32 };

    pub fn init(
        alloc: std.mem.Allocator,
        file_name: []const u8,
        contents: []const u8,
        theme: *const themes.Theme,
    ) !Buffer {
        var hl = try syntax.Highlighter.init(alloc);
        errdefer hl.deinit();
        hl.theme = theme;
        hl.styles.items[0] = hl.baseStyle(); // style id 0 must match the theme

        var self = Buffer{
            .alloc = alloc,
            .hl = hl,
            .file_name = try alloc.dupe(u8, file_name),
        };
        errdefer alloc.free(self.file_name);
        try self.buf.appendSlice(alloc, contents);
        try self.rebuildLines();
        try self.hl.update(self.buf.items, null);
        return self;
    }

    pub fn deinit(self: *Buffer) void {
        self.buf.deinit(self.alloc);
        self.lines.deinit(self.alloc);
        self.git_signs.deinit(self.alloc);
        self.hl.deinit();
        self.alloc.free(self.file_name);
    }

    pub fn signFor(self: *const Buffer, row_idx: usize) Sign {
        if (row_idx < self.git_signs.items.len) return self.git_signs.items[row_idx];
        return .none;
    }

    /// Short name shown in the tabline.
    pub fn displayName(self: *const Buffer) []const u8 {
        return std.fs.path.basename(self.file_name);
    }

    // ---- text model -------------------------------------------------------

    fn rebuildLines(self: *Buffer) !void {
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

    pub fn lineText(self: *const Buffer, row: usize) []const u8 {
        const line = self.lines.items[row];
        return self.buf.items[line.start..line.end];
    }

    pub fn lineLen(self: *const Buffer, row: usize) usize {
        const line = self.lines.items[row];
        return line.end - line.start;
    }

    /// Last "real" row: skips the phantom empty line that follows a
    /// trailing newline (vim semantics for `G`).
    pub fn lastRow(self: *const Buffer) usize {
        const n = self.lines.items.len;
        if (n > 1 and self.lineLen(n - 1) == 0) return n - 2;
        return n -| 1;
    }

    pub fn cursorByte(self: *const Buffer) usize {
        return self.lines.items[self.row].start + self.col;
    }

    fn lineOfByte(self: *const Buffer, byte: usize) usize {
        const items = self.lines.items;
        var lo: usize = 0;
        var hi: usize = items.len - 1;
        while (lo < hi) {
            const mid = (lo + hi + 1) / 2;
            if (items[mid].start <= byte) lo = mid else hi = mid - 1;
        }
        return lo;
    }

    fn pointAt(self: *const Buffer, byte: usize) ts.Point {
        const li = self.lineOfByte(byte);
        return .{ .row = @intCast(li), .column = @intCast(byte - self.lines.items[li].start) };
    }

    /// Apply one edit to the buffer, then reparse incrementally.
    pub fn replaceRange(self: *Buffer, start: usize, end: usize, text: []const u8) !void {
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

    pub fn snapToCp(text: []const u8, col_in: usize) usize {
        var col = @min(col_in, text.len);
        while (col > 0 and col < text.len and (text[col] & 0xC0) == 0x80) col -= 1;
        return col;
    }

    pub fn cpLenAt(self: *const Buffer, row: usize, col: usize) usize {
        const text = self.lineText(row);
        if (col >= text.len) return 1;
        return std.unicode.utf8ByteSequenceLength(text[col]) catch 1;
    }

    pub fn clampCol(self: *Buffer, insert: bool) void {
        const len = self.lineLen(self.row);
        const max_col = if (insert) len else if (len == 0) 0 else len - 1;
        self.col = snapToCp(self.lineText(self.row), @min(self.col, max_col));
    }

    pub fn setCursorFromByte(self: *Buffer, byte: usize) void {
        const li = self.lineOfByte(@min(byte, self.buf.items.len));
        self.row = li;
        self.col = @min(byte, self.buf.items.len) - self.lines.items[li].start;
        self.clampCol(false);
        self.goal_col = self.col;
    }

    pub fn firstNonWs(self: *const Buffer, row: usize) usize {
        const text = self.lineText(row);
        for (text, 0..) |b, i| {
            if (b != ' ' and b != '\t') return i;
        }
        return 0;
    }

    /// Line-comment token for this buffer's language (NvChad `Space /`).
    pub fn commentPrefix(self: *const Buffer) []const u8 {
        const ext = std.fs.path.extension(self.file_name);
        const map = .{
            .{ ".py", "#" },   .{ ".sh", "#" },   .{ ".rb", "#" },
            .{ ".toml", "#" }, .{ ".yaml", "#" }, .{ ".yml", "#" },
            .{ ".lua", "--" }, .{ ".sql", "--" }, .{ ".hs", "--" },
            .{ ".vim", "\"" }, .{ ".ml", "(*" },
        };
        inline for (map) |e| {
            if (std.mem.eql(u8, ext, e[0])) return e[1];
        }
        return "//"; // zig, c, cpp, js, ts, rs, go, java, zon, ...
    }

    /// Toggle the line comment on the current line, preserving indentation.
    pub fn toggleComment(self: *Buffer) !void {
        const prefix = self.commentPrefix();
        const line = self.lines.items[self.row];
        const fnw = self.firstNonWs(self.row);
        const text = self.lineText(self.row);
        const rest = text[fnw..];
        if (std.mem.startsWith(u8, rest, prefix)) {
            var rm = prefix.len;
            if (rest.len > rm and rest[rm] == ' ') rm += 1;
            try self.replaceRange(line.start + fnw, line.start + fnw + rm, "");
            self.col -|= @min(self.col, rm);
        } else {
            if (rest.len == 0) return; // skip blank lines
            var buf: [8]u8 = undefined;
            const ins = std.fmt.bufPrint(&buf, "{s} ", .{prefix}) catch return;
            try self.replaceRange(line.start + fnw, line.start + fnw, ins);
            self.col += ins.len;
        }
        self.clampCol(false);
        self.goal_col = self.col;
    }

    fn rowBlank(self: *const Buffer, row: usize) bool {
        for (self.lineText(row)) |c| {
            if (c != ' ' and c != '\t') return false;
        }
        return true;
    }

    fn rowCommented(self: *const Buffer, row: usize) bool {
        const text = self.lineText(row);
        const fnw = self.firstNonWs(row);
        return std.mem.startsWith(u8, text[fnw..], self.commentPrefix());
    }

    /// Comment/uncomment rows [lo, hi] as a group (comment.nvim style):
    /// uncomment only when every non-blank row is already commented,
    /// otherwise comment every non-blank, not-yet-commented row.
    pub fn toggleCommentRows(self: *Buffer, lo: usize, hi: usize) !void {
        const prefix = self.commentPrefix();
        var all_commented = true;
        var any = false;
        var i = lo;
        while (i <= hi) : (i += 1) {
            if (self.rowBlank(i)) continue;
            any = true;
            if (!self.rowCommented(i)) all_commented = false;
        }
        if (!any) return;
        i = lo;
        while (i <= hi) : (i += 1) {
            if (self.rowBlank(i)) continue;
            const line = self.lines.items[i];
            const fnw = self.firstNonWs(i);
            const rest = self.lineText(i)[fnw..];
            if (all_commented) {
                var rm = prefix.len;
                if (rest.len > rm and rest[rm] == ' ') rm += 1;
                try self.replaceRange(line.start + fnw, line.start + fnw + rm, "");
            } else if (!std.mem.startsWith(u8, rest, prefix)) {
                var buf: [8]u8 = undefined;
                const ins = std.fmt.bufPrint(&buf, "{s} ", .{prefix}) catch return;
                try self.replaceRange(line.start + fnw, line.start + fnw, ins);
            }
        }
        self.clampCol(false);
        self.goal_col = self.col;
    }

    /// Indent (`>`) or dedent (`<`) rows [lo, hi] by one 4-space step.
    pub fn indentRows(self: *Buffer, lo: usize, hi: usize, dedent: bool) !void {
        var i = lo;
        while (i <= hi) : (i += 1) {
            const line = self.lines.items[i];
            if (dedent) {
                const text = self.lineText(i);
                var rm: usize = 0;
                while (rm < 4 and rm < text.len and text[rm] == ' ') rm += 1;
                if (rm == 0 and text.len > 0 and text[0] == '\t') rm = 1;
                if (rm > 0) try self.replaceRange(line.start, line.start + rm, "");
            } else {
                if (self.rowBlank(i)) continue; // never indent blank lines
                try self.replaceRange(line.start, line.start, "    ");
            }
        }
        self.clampCol(false);
        self.goal_col = self.col;
    }

    /// Vim `J`: join `row` with the following line — the newline and the next
    /// line's leading whitespace collapse into a single space (no space when
    /// the next line is empty or the current line ends the joined pair with
    /// whitespace). Returns the byte column of the join point.
    pub fn joinLines(self: *Buffer, row: usize) !?usize {
        if (row + 1 >= self.lines.items.len) return null;
        const line = self.lines.items[row];
        const next = self.lines.items[row + 1];
        const ntext = self.buf.items[next.start..next.end];
        var nfw: usize = 0;
        while (nfw < ntext.len and (ntext[nfw] == ' ' or ntext[nfw] == '\t')) nfw += 1;
        const join_col = line.end - line.start;
        const next_empty = nfw == ntext.len;
        const sep: []const u8 = if (next_empty or join_col == 0) "" else " ";
        try self.replaceRange(line.end, next.start + nfw, sep);
        return join_col;
    }

    // ---- motions ----------------------------------------------------------

    pub fn moveLeft(self: *Buffer) void {
        if (self.col == 0) return;
        self.col = snapToCp(self.lineText(self.row), self.col - 1);
        self.goal_col = self.col;
    }

    pub fn moveRight(self: *Buffer, insert: bool) void {
        const len = self.lineLen(self.row);
        const next = self.col + self.cpLenAt(self.row, self.col);
        const limit = if (insert) len else if (len == 0) 0 else len - 1;
        if (next <= limit) self.col = next;
        self.goal_col = self.col;
    }

    pub fn moveVert(self: *Buffer, delta: i64, insert: bool) void {
        const last: i64 = @intCast(self.lines.items.len - 1);
        const target = std.math.clamp(@as(i64, @intCast(self.row)) + delta, 0, last);
        self.row = @intCast(target);
        self.col = self.goal_col;
        self.clampCol(insert);
    }

    pub fn wordClass(b: u8) u8 {
        if (b == ' ' or b == '\t' or b == '\n' or b == '\r') return 0;
        if (std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80) return 1;
        return 2;
    }

    pub fn wordForward(self: *Buffer) void {
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

    pub fn wordBackward(self: *Buffer) void {
        const items = self.buf.items;
        var i = self.cursorByte();
        while (i > 0 and wordClass(items[i - 1]) == 0) i -= 1;
        if (i > 0) {
            const c = wordClass(items[i - 1]);
            while (i > 0 and wordClass(items[i - 1]) == c) i -= 1;
        }
        self.setCursorFromByte(i);
    }

    pub fn wordEnd(self: *Buffer) void {
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

    pub fn deleteCharAtCursor(self: *Buffer) !void {
        if (self.lineLen(self.row) == 0) return;
        const pos = self.cursorByte();
        try self.replaceRange(pos, pos + self.cpLenAt(self.row, self.col), "");
        self.clampCol(false);
    }

    /// Replace the codepoint under the cursor with `text` (vim `r`).
    pub fn replaceCharAtCursor(self: *Buffer, text: []const u8) !void {
        if (self.lineLen(self.row) == 0) return;
        const pos = self.cursorByte();
        try self.replaceRange(pos, pos + self.cpLenAt(self.row, self.col), text);
    }

    /// Toggle ASCII case under the cursor, then advance (vim `~`).
    pub fn toggleCaseAtCursor(self: *Buffer) !void {
        if (self.lineLen(self.row) == 0) return;
        const pos = self.cursorByte();
        const c = self.buf.items[pos];
        if (std.ascii.isAlphabetic(c)) {
            const flipped = [1]u8{if (std.ascii.isLower(c))
                std.ascii.toUpper(c)
            else
                std.ascii.toLower(c)};
            try self.replaceRange(pos, pos + 1, &flipped);
        }
        self.moveRight(false);
    }

    pub fn deleteLine(self: *Buffer) !void {
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
        self.clampCol(false);
    }

    pub fn insertText(self: *Buffer, text: []const u8) !void {
        const pos = self.cursorByte();
        try self.replaceRange(pos, pos, text);
        self.setCursorFromByte(pos + text.len);
    }

    pub fn backspace(self: *Buffer) !void {
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

    pub fn save(self: *Buffer) !void {
        try std.fs.cwd().writeFile(.{ .sub_path = self.file_name, .data = self.buf.items });
        self.dirty = false;
    }
};
