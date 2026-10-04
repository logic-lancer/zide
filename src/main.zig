const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Editor = @import("editor.zig").Editor;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer _ = safe.deinit();

    const alloc = safe.allocator();

    const args = try init.minimal.args.toSlice(alloc);
    defer alloc.free(args);
    var editor = Editor.init(io, alloc, init.environ_map);
    defer editor.deinit();

    // With no args zide starts on the dashboard (NvDash-style).
    if (args.len > 1) {
        for (args[1..]) |path| try editor.openFile(path);
        if (editor.buffers.items.len > 0) editor.active = 0;
    }

    var buffer: [1024]u8 = undefined;
    var app = try vxfw.App.init(io, alloc, init.environ_map, &buffer);
    defer app.deinit();
    try app.run(editor.widget(), .{});
}
