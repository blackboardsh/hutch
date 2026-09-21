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
    // `hutch status` reads the whole store layout, so it is rooted as its own
    // test binary: tests in a file that is only imported by the engine root
    // are not part of the engine test artifact.
    const status_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/status_cli.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    status_tests.root_module.link_libc = true;
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

    const cache_tests = b.addTest(.{
        .name = "hutch-package-cache-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/package_manager_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &.{"locked cache"},
    });
    cache_tests.root_module.link_libc = true;
    const run_cache_tests = b.addRunArtifact(cache_tests);
    const cache_test_step = b.step("test:package-cache", "Test locked package-cache replacement");
    cache_test_step.dependOn(&run_cache_tests.step);

    // Root patch application tests directly so file creation and mode changes
    // also run in the Windows release test job.
    const patch_tests = b.addTest(.{
        .name = "hutch-package-patch-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/package_manager/package_manager_patch.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_patch_tests = b.addRunArtifact(patch_tests);

    const routing_tests = b.addTest(.{
        .name = "hutch-command-path-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .filters = &.{"command path probes"},
    });
    const local_runtime_tests = b.addTest(.{
        .name = "hutch-local-runtime-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/electrobun.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .filters = &.{"bundled Cottontail"},
    });
    const dev_runtime_test_step = b.step("test:dev-runtime", "Test development runtime overrides and command path routing");
    dev_runtime_test_step.dependOn(&b.addRunArtifact(routing_tests).step);
    dev_runtime_test_step.dependOn(&b.addRunArtifact(local_runtime_tests).step);

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
    const run_status_tests = b.addRunArtifact(status_tests);
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
    const runtime_command_test_step = b.step("test:commands", "Test real launcher and engine command routing");
    runtime_command_test_step.dependOn(&run_runtime_command_regression.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_engine_tests.step);
    test_step.dependOn(&run_cache_tests.step);
    test_step.dependOn(&run_patch_tests.step);
    test_step.dependOn(&run_launcher_tests.step);
    test_step.dependOn(&run_windows_icon_tests.step);
    test_step.dependOn(&run_status_tests.step);
    test_step.dependOn(&run_electrobun_tests.step);
    test_step.dependOn(&run_electrobun_template_tests.step);
    test_step.dependOn(&run_hostname_connect_regression_tests.step);
    test_step.dependOn(&run_runtime_command_regression.step);
}
