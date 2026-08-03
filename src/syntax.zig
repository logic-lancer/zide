const std = @import("std");
const vaxis = @import("vaxis");
const ts = @import("tree-sitter");
const themes = @import("theme.zig");

extern fn tree_sitter_zig() *ts.Language;

const highlights_scm = @embedFile("queries/zig/highlights.scm");

/// Owns the tree-sitter state for one buffer and maintains a per-byte style
/// table. `update` reparses incrementally when given the edit that was just
/// applied to the source.
pub const Highlighter = struct {
    alloc: std.mem.Allocator,
    parser: *ts.Parser,
    query: *ts.Query,
    tree: ?*ts.Tree = null,
    theme: *const themes.Theme = &themes.list[0],
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
        try self.styles.append(alloc, self.baseStyle());
        return self;
    }

    /// Default text style for the active theme (style id 0).
    pub fn baseStyle(self: *const Highlighter) vaxis.Style {
        return .{ .fg = self.theme.p.fg, .bg = self.theme.p.bg };
    }

    /// Switch theme and restyle the whole buffer. The name->style-id cache is
    /// theme-dependent, so it is rebuilt from scratch.
    pub fn setTheme(self: *Highlighter, t: *const themes.Theme, source: []const u8) !void {
        self.theme = t;
        self.name_ids.clearRetainingCapacity();
        self.styles.clearRetainingCapacity();
        try self.styles.append(self.alloc, self.baseStyle());
        try self.update(source, null);
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
                if (self.theme.styleForCapture(name)) |style| {
                    var themed = style;
                    themed.bg = self.theme.p.bg;
                    gop.value_ptr.* = @intCast(self.styles.items.len);
                    try self.styles.append(self.alloc, themed);
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
        if (byte >= self.style_ids.len) return self.baseStyle();
        return self.styles.items[self.style_ids[byte]];
    }
};
