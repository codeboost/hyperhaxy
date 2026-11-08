const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const haxy = b.dependency("haxy", .{}).module("haxy");

    // main
    {
        const exe = b.addExecutable(.{
            .name = "hyperhaxy",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("haxy", haxy);
        b.installArtifact(exe);
    }

    // try
    {
        const exe = b.addExecutable(.{
            .name = "try",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main_demo.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("haxy", haxy);
        const try_install = b.addInstallArtifact(exe, .{});

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(&try_install.step);
        run_cmd.addPassthruArgs();

        const run_step = b.step("try", "Try the app");
        run_step.dependOn(&run_cmd.step);
    }
}
