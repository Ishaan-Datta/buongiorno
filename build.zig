const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "buongiorno",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();

    const clap = b.dependency("clap", .{});
    const spoon = b.dependency("spoon", .{});

    exe.root_module.addImport("clap", clap.module("clap"));
    exe.root_module.addImport("spoon", spoon.module("spoon"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run buongiorno");
    run_step.dependOn(&run_cmd.step);
}
