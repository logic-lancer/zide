const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Editor = @import("editor.zig").Editor;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var editor = Editor.init(alloc);
    defer editor.deinit();

    if (args.len > 1) {
        for (args[1..]) |path| try editor.openFile(path);
        editor.active = 0;
    } else {
        try editor.openFile("src/main.zig");
    }
    if (editor.buffers.items.len == 0) {
        std.debug.print("no files could be opened\n", .{});
        return error.NoBuffers;
    }

    var app = try vxfw.App.init(alloc);
    defer app.deinit();
    try app.run(editor.widget(), .{});
}
