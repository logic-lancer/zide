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

    // With no args zide starts on the dashboard (NvDash-style).
    if (args.len > 1) {
        for (args[1..]) |path| try editor.openFile(path);
        if (editor.buffers.items.len > 0) editor.active = 0;
    }

    var app = try vxfw.App.init(alloc);
    defer app.deinit();
    try app.run(editor.widget(), .{});
}
