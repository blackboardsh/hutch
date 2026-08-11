const std = @import("std");

pub fn build(b: *std.Build) void {
    // Release artifacts must run on baseline hardware. Keep the default
    // conservative as a second line of defense behind the release command's
    // explicit -Dcpu=baseline argument.
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_model = .baseline },
    });
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
    const windows_icon_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/windows_icon.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const electrobun_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/electrobun.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    electrobun_tests.root_module.link_libc = true;
    const electrobun_template_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/electrobun_templates.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    engine_tests.root_module.link_libc = true;

    const hostname_connect_regression_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/hostname-connect-regression.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    hostname_connect_regression_tests.root_module.link_libc = true;

    const run_engine_tests = b.addRunArtifact(engine_tests);
    const run_launcher_tests = b.addRunArtifact(launcher_tests);
    const run_windows_icon_tests = b.addRunArtifact(windows_icon_tests);
    const run_electrobun_tests = b.addRunArtifact(electrobun_tests);
    const run_electrobun_template_tests = b.addRunArtifact(electrobun_template_tests);
    const run_hostname_connect_regression_tests = b.addRunArtifact(hostname_connect_regression_tests);

    const runtime_command_fixture = b.addExecutable(.{
        .name = "hutch-runtime-command-fixture",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/runtime-command-fixture.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const runtime_command_regression = b.addExecutable(.{
        .name = "hutch-runtime-command-regression",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/runtime-command-regression.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_runtime_command_regression = b.addRunArtifact(runtime_command_regression);
    run_runtime_command_regression.addArtifactArg(launcher);
    run_runtime_command_regression.addArtifactArg(engine);
    run_runtime_command_regression.addArtifactArg(runtime_command_fixture);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_engine_tests.step);
    test_step.dependOn(&run_launcher_tests.step);
    test_step.dependOn(&run_windows_icon_tests.step);
    test_step.dependOn(&run_electrobun_tests.step);
    test_step.dependOn(&run_electrobun_template_tests.step);
    test_step.dependOn(&run_hostname_connect_regression_tests.step);
    test_step.dependOn(&run_runtime_command_regression.step);
}
