const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const ts_dep = b.dependency("tree_sitter", .{
        .target = target,
        .optimize = optimize,
    });
    // Grammar packages ship no build.zig; we compile parser.c ourselves.
    const grammar_dep = b.dependency("tree_sitter_zig", .{});
  
    const exe = b.addExecutable(.{
        .name = "zide",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addImport("vaxis", vaxis_dep.module("vaxis"));
    exe.root_module.addImport("tree-sitter", ts_dep.module("tree_sitter"));
    exe.root_module.addCSourceFile(.{
        .file = grammar_dep.path("src/parser.c"),
        .flags = &.{"-std=c11"},
    });
    exe.root_module.addIncludePath(grammar_dep.path("src"));

    // Size discipline (nullclaw-style): strip symbols outside Debug and let
    // the linker drop unreferenced sections.
    if (optimize != .debug) exe.root_module.strip = true;
    exe.link_function_sections = true;
    exe.link_data_sections = true;
    exe.link_gc_sections = true;

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the editor");
    run_step.dependOn(&run_cmd.step);
}
