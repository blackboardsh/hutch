const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const launcher = b.addExecutable(.{
        .name = "hutch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/launcher.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const engine = b.addExecutable(.{
        .name = "hutch-engine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    engine.root_module.link_libc = true;
    b.installArtifact(launcher);
    b.installArtifact(engine);

    const run_cmd = b.addRunArtifact(launcher);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Build and run Hutch");
    run_step.dependOn(&run_cmd.step);

    const engine_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const launcher_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/launcher.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    engine_tests.root_module.link_libc = true;

    const package_manager_support_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/package_manager/support/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    package_manager_support_tests.root_module.link_libc = true;

    const run_engine_tests = b.addRunArtifact(engine_tests);
    const run_launcher_tests = b.addRunArtifact(launcher_tests);
    const run_package_manager_support_tests = b.addRunArtifact(package_manager_support_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_engine_tests.step);
    test_step.dependOn(&run_launcher_tests.step);
    test_step.dependOn(&run_package_manager_support_tests.step);
}
