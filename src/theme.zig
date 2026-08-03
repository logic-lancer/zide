const std = @import("std");
const vaxis = @import("vaxis");

/// 0xRRGGBB -> vaxis truecolor.
fn c(x: u24) vaxis.Color {
    return .{ .rgb = .{
        @intCast(x >> 16),
        @intCast((x >> 8) & 0xff),
        @intCast(x & 0xff),
    } };
}

/// Everything a theme needs: 8 accent colors for syntax plus UI slots
/// (base46-style, à la NvChad).
pub const Palette = struct {
    bg: vaxis.Color,
    fg: vaxis.Color,
    gutter: vaxis.Color,
    gutter_active: vaxis.Color,
    bar_bg: vaxis.Color,
    bar_fg: vaxis.Color,
    /// Dark text drawn on top of the colored mode badge.
    badge_fg: vaxis.Color,

    red: vaxis.Color,
    orange: vaxis.Color,
    yellow: vaxis.Color,
    green: vaxis.Color,
    cyan: vaxis.Color,
    blue: vaxis.Color,
    purple: vaxis.Color,
    gray: vaxis.Color,
};

pub const Theme = struct {
    name: []const u8,
    p: Palette,

    /// Map a tree-sitter capture name to a style. Exact names win over the
    /// base segment (`@keyword.repeat` -> "keyword"). Null = leave unstyled.
    pub fn styleForCapture(self: *const Theme, name: []const u8) ?vaxis.Style {
        const p = self.p;

        const Full = enum { @"variable.member", @"variable.builtin" };
        if (std.meta.stringToEnum(Full, name)) |full| return switch (full) {
            .@"variable.member" => .{ .fg = p.red },
            .@"variable.builtin" => .{ .fg = p.orange },
        };

        const Base = enum {
            keyword,
            string,
            character,
            comment,
            function,
            type,
            number,
            boolean,
            constant,
            operator,
            label,
            attribute,
            module,
            import,
        };
        const dot = std.mem.indexOfScalar(u8, name, '.') orelse name.len;
        const base = std.meta.stringToEnum(Base, name[0..dot]) orelse return null;
        return switch (base) {
            .keyword => .{ .fg = p.purple },
            .string, .character => .{ .fg = p.green },
            .comment => .{ .fg = p.gray, .italic = true },
            .function => .{ .fg = p.blue },
            .type, .module, .import => .{ .fg = p.yellow },
            .number, .boolean, .constant => .{ .fg = p.orange },
            .operator => .{ .fg = p.cyan },
            .label, .attribute => .{ .fg = p.red },
        };
    }
};

pub const list = [_]Theme{
    .{ .name = "onedark", .p = .{
        .bg = c(0x282c34),
        .fg = c(0xabb2bf),
        .gutter = c(0x4b5263),
        .gutter_active = c(0x9da5b4),
        .bar_bg = c(0x3e4452),
        .bar_fg = c(0xabb2bf),
        .badge_fg = c(0x282c34),
        .red = c(0xe06c75),
        .orange = c(0xd19a66),
        .yellow = c(0xe5c07b),
        .green = c(0x98c379),
        .cyan = c(0x56b6c2),
        .blue = c(0x61afef),
        .purple = c(0xc678dd),
        .gray = c(0x5c6370),
    } },
    .{ .name = "gruvbox", .p = .{
        .bg = c(0x282828),
        .fg = c(0xebdbb2),
        .gutter = c(0x665c54),
        .gutter_active = c(0xbdae93),
        .bar_bg = c(0x3c3836),
        .bar_fg = c(0xa89984),
        .badge_fg = c(0x282828),
        .red = c(0xfb4934),
        .orange = c(0xfe8019),
        .yellow = c(0xfabd2f),
        .green = c(0xb8bb26),
        .cyan = c(0x8ec07c),
        .blue = c(0x83a598),
        .purple = c(0xd3869b),
        .gray = c(0x928374),
    } },
    .{ .name = "tokyonight", .p = .{
        .bg = c(0x1a1b26),
        .fg = c(0xc0caf5),
        .gutter = c(0x3b4261),
        .gutter_active = c(0x737aa2),
        .bar_bg = c(0x292e42),
        .bar_fg = c(0xa9b1d6),
        .badge_fg = c(0x1a1b26),
        .red = c(0xf7768e),
        .orange = c(0xff9e64),
        .yellow = c(0xe0af68),
        .green = c(0x9ece6a),
        .cyan = c(0x7dcfff),
        .blue = c(0x7aa2f7),
        .purple = c(0xbb9af7),
        .gray = c(0x565f89),
    } },
    .{ .name = "catppuccin", .p = .{
        .bg = c(0x1e1e2e),
        .fg = c(0xcdd6f4),
        .gutter = c(0x45475a),
        .gutter_active = c(0xb4befe),
        .bar_bg = c(0x313244),
        .bar_fg = c(0xbac2de),
        .badge_fg = c(0x1e1e2e),
        .red = c(0xf38ba8),
        .orange = c(0xfab387),
        .yellow = c(0xf9e2af),
        .green = c(0xa6e3a1),
        .cyan = c(0x89dceb),
        .blue = c(0x89b4fa),
        .purple = c(0xcba6f7),
        .gray = c(0x6c7086),
    } },
    .{ .name = "nord", .p = .{
        .bg = c(0x2e3440),
        .fg = c(0xd8dee9),
        .gutter = c(0x4c566a),
        .gutter_active = c(0xd8dee9),
        .bar_bg = c(0x3b4252),
        .bar_fg = c(0xd8dee9),
        .badge_fg = c(0x2e3440),
        .red = c(0xbf616a),
        .orange = c(0xd08770),
        .yellow = c(0xebcb8b),
        .green = c(0xa3be8c),
        .cyan = c(0x88c0d0),
        .blue = c(0x81a1c1),
        .purple = c(0xb48ead),
        .gray = c(0x616e88),
    } },
};

/// Space-separated theme names, built at comptime (for :themes / errors).
pub const names = blk: {
    var s: []const u8 = "";
    for (list, 0..) |t, i| s = s ++ (if (i == 0) "" else " ") ++ t.name;
    break :blk s;
};

pub fn find(name: []const u8) ?*const Theme {
    for (&list) |*t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

/// The theme after `t`, wrapping — powers bare `:theme` cycling.
pub fn next(t: *const Theme) *const Theme {
    for (&list, 0..) |*ti, i| {
        if (ti == t) return &list[(i + 1) % list.len];
    }
    return &list[0];
}
