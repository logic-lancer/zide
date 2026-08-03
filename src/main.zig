const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const syntax = @import("syntax.zig");
const Editor = @import("editor.zig").Editor;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    const path = if (args.len > 1) args[1] else "src/main.zig";

    const contents = std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => try alloc.dupe(u8, ""),
        else => {
            std.debug.print("could not read '{s}': {s}\n", .{ path, @errorName(err) });
            return err;
        },
    };
    defer alloc.free(contents);

    var hl = try syntax.Highlighter.init(alloc);
    defer hl.deinit();

    var editor = try Editor.init(alloc, &hl, path, contents);
    defer editor.deinit();

    var app = try vxfw.App.init(alloc);
    defer app.deinit();
    try app.run(editor.widget(), .{});
}
