const std = @import("std");
const vaxis = @import("vaxis");
const ts = @import("tree-sitter");

extern fn tree_sitter_zig() *ts.Language;

const highlights_scm = @embedFile("queries/zig/highlights.scm");

fn rgb(r: u8, g: u8, b: u8) vaxis.Color {
    return .{ .rgb = .{ r, g, b } };
}

const theme = struct {
    const red = rgb(0xe0, 0x6c, 0x75);
    const orange = rgb(0xd1, 0x9a, 0x66);
    const yellow = rgb(0xe5, 0xc0, 0x7b);
    const green = rgb(0x98, 0xc3, 0x79);
    const cyan = rgb(0x56, 0xb6, 0xc2);
    const blue = rgb(0x61, 0xaf, 0xef);
    const purple = rgb(0xc6, 0x78, 0xdd);
    const gray = rgb(0x5c, 0x63, 0x70);
};

/// One Dark-ish theme. Exact capture names win over the base segment
/// (`@keyword.repeat` -> "keyword"). Null means "leave unstyled".
fn styleForCapture(name: []const u8) ?vaxis.Style {
    const Full = enum { @"variable.member", @"variable.builtin" };
    if (std.meta.stringToEnum(Full, name)) |full| return switch (full) {
        .@"variable.member" => .{ .fg = theme.red },
        .@"variable.builtin" => .{ .fg = theme.orange },
    };

    const Base = enum {
        keyword, string, character, comment, function, @"type",
        number, boolean, constant, operator, label, attribute, module, import,
    };
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse name.len;
    const base = std.meta.stringToEnum(Base, name[0..dot]) orelse return null;
    return switch (base) {
        .keyword => .{ .fg = theme.purple },
        .string, .character => .{ .fg = theme.green },
        .comment => .{ .fg = theme.gray, .italic = true },
        .function => .{ .fg = theme.blue },
        .@"type", .module, .import => .{ .fg = theme.yellow },
        .number, .boolean, .constant => .{ .fg = theme.orange },
        .operator => .{ .fg = theme.cyan },
        .label, .attribute => .{ .fg = theme.red },
    };
}

/// Owns the tree-sitter state for one buffer and maintains a per-byte style
/// table. `update` reparses incrementally when given the edit that was just
/// applied to the source.
pub const Highlighter = struct {
    alloc: std.mem.Allocator,
    parser: *ts.Parser,
    query: *ts.Query,
    tree: ?*ts.Tree = null,
    /// Per-byte index into `styles`; 0 = default style.
    style_ids: []u8 = &.{},
    styles: std.ArrayListUnmanaged(vaxis.Style) = .{},
    name_ids: std.StringHashMapUnmanaged(u8) = .{},

    pub fn init(alloc: std.mem.Allocator) !Highlighter {
        const language = tree_sitter_zig();
        const parser = ts.Parser.create();
        errdefer parser.destroy();
        try parser.setLanguage(language);
        var err_offset: u32 = 0;
        const query = ts.Query.create(language, highlights_scm, &err_offset) catch |err| {
            std.debug.print("highlights.scm error at byte {d}: {s}\n", .{ err_offset, @errorName(err) });
            return err;
        };
        var self = Highlighter{ .alloc = alloc, .parser = parser, .query = query };
        try self.styles.append(alloc, .{});
        return self;
    }

    pub fn deinit(self: *Highlighter) void {
        if (self.tree) |t| t.destroy();
        self.query.destroy();
        self.parser.destroy();
        self.alloc.free(self.style_ids);
        self.styles.deinit(self.alloc);
        self.name_ids.deinit(self.alloc);
    }

    /// Reparse `source` and rebuild the style table. Pass the edit that
    /// produced this source (null on first parse / full reload).
    pub fn update(self: *Highlighter, source: []const u8, edit: ?ts.InputEdit) !void {
        if (self.tree) |old| {
            if (edit) |e| old.edit(e);
            const new_tree = self.parser.parseString(source, old) orelse return error.ParseFailed;
            old.destroy();
            self.tree = new_tree;
        } else {
            self.tree = self.parser.parseString(source, null) orelse return error.ParseFailed;
        }

        if (self.style_ids.len != source.len) {
            self.alloc.free(self.style_ids);
            self.style_ids = try self.alloc.alloc(u8, source.len);
        }
        @memset(self.style_ids, 0);

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();
        cursor.exec(self.query, self.tree.?.rootNode());

        // NOTE: query predicates (#eq?/#match?) are not evaluated yet; the two
        // predicate-bearing patterns in the zig query may over-highlight slightly.
        while (cursor.nextCapture()) |item| {
            const capture = item[1].captures[item[0]];
            const name = self.query.captureNameForId(capture.index) orelse continue;
            const gop = try self.name_ids.getOrPut(self.alloc, name);
            if (!gop.found_existing) {
                if (styleForCapture(name)) |style| {
                    gop.value_ptr.* = @intCast(self.styles.items.len);
                    try self.styles.append(self.alloc, style);
                } else {
                    gop.value_ptr.* = 0;
                }
            }
            const sid = gop.value_ptr.*;
            if (sid == 0) continue;
            const start = capture.node.startByte();
            const end = @min(capture.node.endByte(), source.len);
            if (start < end) @memset(self.style_ids[start..end], sid);
        }
    }

    pub fn styleAt(self: *const Highlighter, byte: usize) vaxis.Style {
        if (byte >= self.style_ids.len) return .{};
        return self.styles.items[self.style_ids[byte]];
    }
};
