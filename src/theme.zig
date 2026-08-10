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
    /// Visual-selection backing. Dark themes reuse bar_bg; a light theme
    /// needs its own slot: every syntax hue is darker than the ground, so a
    /// gray step dark enough to see washes the text out — a hue tint stays
    /// unmistakable while keeping the luminance (and the text's contrast) up.
    sel_bg: vaxis.Color,
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
        .sel_bg = c(0x3e4452),
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
        .sel_bg = c(0x3c3836),
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
        .sel_bg = c(0x292e42),
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
        .sel_bg = c(0x313244),
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
        .sel_bg = c(0x3b4252),
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
    // Light theme (Atom One Light). Every slot is picked against its real
    // consumers: accents stay dark enough that `bg`-colored text (search,
    // completion selection, yank flash, mode badge) is legible on them,
    // and gray must stay visibly dim on white (comments, inlay hints,
    // which-key descriptions).
    .{
        .name = "white",
        .p = .{
            .bg = c(0xfafafa),
            .fg = c(0x383a42),
            .gutter = c(0xc2c2c3),
            .gutter_active = c(0x696c77),
            .bar_bg = c(0xdfdfe0),
            .bar_fg = c(0x424243),
            // Blue tint, not a gray step: on a light ground a gray dark
            // enough to see as a selection washes out the (darker-than-
            // ground) syntax hues; a tint reads by hue instead, so it can
            // stay light enough that selected text keeps its contrast.
            // Red still sits at ~2.8 on it -- accepted: red must stay light
            // enough to keep its identity on the near-white ground and as
            // the diagnostic dot, and no selection tone does better.
            .sel_bg = c(0xd2e3fa),
            .badge_fg = c(0xfafafa),
            .red = c(0xe45649),
            .orange = c(0x986801),
            // yellow/green run darker than stock One Light: yellow is also the
            // search-highlight backing for near-white text, and both are the
            // hues a light ground washes out first (measured 3.06/3.07 at the
            // stock values).
            .yellow = c(0xa66f00),
            .green = c(0x398a38),
            .cyan = c(0x0184bc),
            .blue = c(0x4078f2),
            .purple = c(0xa626a4),
            .gray = c(0xa0a1a7),
        },
    },
    // The remaining light themes follow the same rules as "white": accents
    // dark enough for bg-colored text on them (search/badge/flash), a hue-
    // tinted sel_bg (cool tint on the warm grounds so it reads by hue), and
    // any stock hue measured near/below 3.0 on its ground runs darker here.
    // Known cost of the cool tint (same family as white's red-in-selection
    // note): blue/cyan foregrounds sit closest to it in hue and lose the
    // most contrast on it -- solarized-light blue ~2.8 and latte cyan ~2.7
    // inside a selection. Accepted: washed-out, not invisible, and darkening
    // those hues would cost their identity on the ground.
    .{
        .name = "gruvbox-light",
        .p = .{
            .bg = c(0xfbf1c7),
            .fg = c(0x3c3836),
            .gutter = c(0xd5c4a1),
            .gutter_active = c(0x665c54),
            .bar_bg = c(0xebdbb2),
            .bar_fg = c(0x504945),
            .sel_bg = c(0xd1dce5),
            .badge_fg = c(0xfbf1c7),
            .red = c(0x9d0006),
            .orange = c(0xaf3a03),
            // Faded yellow 0xb57614 measures ~3.3 as the search backing on
            // the cream ground; run darker.
            .yellow = c(0xa06a0e),
            .green = c(0x79740e),
            .cyan = c(0x427b58),
            .blue = c(0x076678),
            .purple = c(0x8f3f71),
            .gray = c(0x928374),
        },
    },
    // Solarized is deliberately soft: fg is base01 (the "emphasized" tone,
    // ~4.9 on the paper ground) — the strongest tone the scheme intends for
    // body text.
    .{
        .name = "solarized-light",
        .p = .{
            .bg = c(0xfdf6e3),
            .fg = c(0x586e75),
            .gutter = c(0xc9c2ad),
            .gutter_active = c(0x657b83),
            .bar_bg = c(0xeee8d5),
            .bar_fg = c(0x586e75),
            .sel_bg = c(0xd3e3e8),
            .badge_fg = c(0xfdf6e3),
            .red = c(0xdc322f),
            .orange = c(0xcb4b16),
            // Stock yellow 0xb58900 / green 0x859900 / cyan 0x2aa198 all sit
            // at ~2.9 on the paper ground; run darker.
            .yellow = c(0x9a7500),
            .green = c(0x6e7f00),
            .cyan = c(0x1f8a82),
            .blue = c(0x268bd2),
            .purple = c(0x6c71c4),
            .gray = c(0x93a1a1),
        },
    },
    // Catppuccin Latte.
    .{
        .name = "latte",
        .p = .{
            .bg = c(0xeff1f5),
            .fg = c(0x4c4f69),
            .gutter = c(0xbcc0cc),
            .gutter_active = c(0x6c6f85),
            .bar_bg = c(0xdce0e8),
            .bar_fg = c(0x5c5f77),
            .sel_bg = c(0xd0dcf5),
            .badge_fg = c(0xeff1f5),
            .red = c(0xd20f39),
            // Stock peach 0xfe640b is too light to back bg-colored text
            // (yank flash ~2.7); stock yellow 0xdf8e1d / green 0x40a02b
            // measure ~2.3/3.0 on the ground; all run darker.
            .orange = c(0xd0570a),
            .yellow = c(0x9c6e0a),
            .green = c(0x358a24),
            .cyan = c(0x179299),
            .blue = c(0x1e66f5),
            .purple = c(0x8839ef),
            .gray = c(0x8c8fa1),
        },
    },
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
