const std = @import("std");
const builtin = @import("builtin");

const test_invocation = [_][]const u8{
    "test",
    "tests/pass fixture.test.ts",
    "tests/second.test.ts",
    "--test-name-pattern",
    "exact value",
    "--bail=3",
};

const local_exec_arguments = [_][]const u8{
    "two words",
    "$literal",
    "%PATH%",
    "!HUTCH_BATCH_DELAYED!",
    "quote\"value",
    "amp&value",
    "pipe|value",
    "caret^value",
    "",
    "--flag=value",
    "工作-🚀",
};

fn run(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    launcher: []const u8,
    engine: []const u8,
    runtime: []const u8,
    mode: []const u8,
    invocation: []const []const u8,
    expected_entrypoint: ?[]const u8,
) !std.process.Child.Term {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, launcher);
    try argv.appendSlice(allocator, invocation);

    var environment = try init.environ_map.clone(allocator);
    defer environment.deinit();
    try environment.put("HUTCH_ENGINE_BINARY", engine);
    try environment.put("DASH_COTTONTAIL", runtime);
    try environment.put("HUTCH_TEST_FIXTURE_MODE", mode);
    if (expected_entrypoint) |entrypoint| {
        try environment.put("HUTCH_TEST_EXPECTED_ENTRYPOINT", entrypoint);
    }
    try environment.put("HUTCH_NO_UPDATE_CHECK", "1");
    try environment.put("CI", "1");

    const temp_dir = environment.get("TMPDIR") orelse
        environment.get("TEMP") orelse
        environment.get("TMP") orelse
        if (builtin.os.tag == .windows) "." else "/tmp";
    var child = try std.process.spawn(init.io, .{
        .argv = argv.items,
        .environ_map = &environment,
        .cwd = .{ .path = temp_dir },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(init.io);
    return try child.wait(init.io);
}

const CapturedRun = struct {
    term: std.process.Child.Term,
    stdout: []const u8,
    stderr: []const u8,
};

const EnvironmentOverride = struct {
    key: []const u8,
    value: []const u8,
};

fn runConfigCommandWithOverrides(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    launcher: []const u8,
    engine: []const u8,
    runtime: []const u8,
    project_dir: []const u8,
    fake_bin_dir: []const u8,
    mode: []const u8,
    config_json: []const u8,
    invocation: []const []const u8,
    overrides: []const EnvironmentOverride,
) !CapturedRun {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, launcher);
    try argv.appendSlice(allocator, invocation);

    var environment = try init.environ_map.clone(allocator);
    defer environment.deinit();
    try environment.put("HUTCH_ENGINE_BINARY", engine);
    try environment.put("DASH_COTTONTAIL", runtime);
    try environment.put("HUTCH_TEST_FIXTURE_MODE", mode);
    try environment.put("HUTCH_TEST_CONFIG_JSON", config_json);
    try environment.put("HUTCH_TEST_EXPECTED_CWD", project_dir);
    try environment.put("HUTCH_NO_UPDATE_CHECK", "1");
    try environment.put("HUTCH_BATCH_SENTINEL", "expanded-percent-value");
    try environment.put("HUTCH_BATCH_DELAYED", "expanded-delayed-value");
    try environment.put("CI", "1");
    for (overrides) |override| {
        try environment.put(override.key, override.value);
    }

    const path_key = if (builtin.os.tag == .windows) "Path" else "PATH";
    // Deliberately exclude the installed Hutch path. Recursive `hutch` argv
    // must resolve to the sibling launcher selected by the current engine.
    try environment.put(path_key, fake_bin_dir);

    const result = try std.process.run(allocator, init.io, .{
        .argv = argv.items,
        .cwd = .{ .path = project_dir },
        .environ_map = &environment,
        .stderr_limit = .limited(1024 * 1024),
        .stdout_limit = .limited(1024 * 1024),
    });
    return .{
        .term = result.term,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn runConfigCommand(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    launcher: []const u8,
    engine: []const u8,
    runtime: []const u8,
    project_dir: []const u8,
    fake_bin_dir: []const u8,
    mode: []const u8,
    config_json: []const u8,
    invocation: []const []const u8,
) !CapturedRun {
    return runConfigCommandWithOverrides(
        init,
        allocator,
        launcher,
        engine,
        runtime,
        project_dir,
        fake_bin_dir,
        mode,
        config_json,
        invocation,
        &.{},
    );
}

fn runBuiltinCommand(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    launcher: []const u8,
    engine: []const u8,
    project_dir: []const u8,
    fake_bin_dir: []const u8,
    mode: []const u8,
    invocation: []const []const u8,
) !CapturedRun {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, launcher);
    try argv.appendSlice(allocator, invocation);

    var environment = try init.environ_map.clone(allocator);
    defer environment.deinit();
    try environment.put("HUTCH_ENGINE_BINARY", engine);
    try environment.put("HUTCH_TEST_FIXTURE_MODE", mode);
    try environment.put("HUTCH_TEST_EXPECTED_CWD", project_dir);
    try environment.put("HUTCH_NO_UPDATE_CHECK", "1");
    try environment.put("CI", "1");

    const path_key = if (builtin.os.tag == .windows) "Path" else "PATH";
    try environment.put(path_key, fake_bin_dir);

    const result = try std.process.run(allocator, init.io, .{
        .argv = argv.items,
        .cwd = .{ .path = project_dir },
        .environ_map = &environment,
        .stderr_limit = .limited(1024 * 1024),
        .stdout_limit = .limited(1024 * 1024),
    });
    return .{
        .term = result.term,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn expectExit(term: std.process.Child.Term, expected: u8) !void {
    switch (term) {
        .exited => |actual| if (actual != expected) return error.UnexpectedExitCode,
        else => return error.UnexpectedTermination,
    }
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) return error.ExpectedTextMissing;
}

fn expectMissing(init: std.process.Init, path: []const u8) !void {
    std.Io.Dir.cwd().access(init.io, path, .{}) catch return;
    return error.UnexpectedInjectionMarker;
}

fn expectNoPrivateTempArtifacts(init: std.process.Init, directory: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(init.io, directory, .{ .iterate = true });
    defer dir.close(init.io);
    var iterator = dir.iterate();
    while (try iterator.next(init.io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, "hutch-config-loader-") or
            std.mem.startsWith(u8, entry.name, "hutch-shell-launcher-"))
        {
            return error.PrivateTempArtifactEscapedIntoProject;
        }
    }
}

fn writeLocalDependencyProject(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    root: []const u8,
    name: []const u8,
) !void {
    const dep_dir = try std.fs.path.join(allocator, &.{ root, "local-dep" });
    try std.Io.Dir.cwd().createDirPath(init.io, dep_dir);
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ dep_dir, "package.json" }),
        .data = "{\"name\":\"local-dep\",\"version\":\"1.0.0\"}\n",
    });
    const manifest = try std.fmt.allocPrint(
        allocator,
        "{{\"name\":\"{s}\",\"version\":\"1.0.0\",\"dependencies\":{{\"local-dep\":\"file:./local-dep\"}}}}\n",
        .{name},
    );
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ root, "package.json" }),
        .data = manifest,
    });
}

fn expectPathExists(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().access(io, path, .{}) catch return error.ExpectedPathMissing;
}

fn toolchainPlatformKey() []const u8 {
    return switch (builtin.os.tag) {
        .macos => if (builtin.cpu.arch == .aarch64) "macos-arm64" else "macos-x64",
        .linux => if (builtin.cpu.arch == .aarch64) "linux-arm64" else "linux-x64",
        else => "windows-x64",
    };
}

fn writeFakePackageManager(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    fake_bin: []const u8,
    runtime: []const u8,
    name: []const u8,
    windows_extension: []const u8,
) !void {
    const fake_command = try std.fmt.allocPrint(
        allocator,
        "{s}{c}{s}{s}",
        .{
            fake_bin,
            std.fs.path.sep,
            name,
            if (builtin.os.tag == .windows) windows_extension else "",
        },
    );
    if (builtin.os.tag == .windows) {
        const wrapper = try std.fmt.allocPrint(
            allocator,
            "@\"{s}\" \"--hutch-test-package-manager={s}\" %*\r\n",
            .{ runtime, name },
        );
        try std.Io.Dir.cwd().writeFile(init.io, .{
            .sub_path = fake_command,
            .data = wrapper,
        });
    } else {
        try std.Io.Dir.copyFile(
            std.Io.Dir.cwd(),
            runtime,
            std.Io.Dir.cwd(),
            fake_command,
            init.io,
            .{ .permissions = .executable_file, .make_path = true },
        );
    }
}

fn writeLocalBin(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    bin_directory: []const u8,
    runtime: []const u8,
    name: []const u8,
    windows_extension: []const u8,
) !void {
    try std.Io.Dir.cwd().createDirPath(init.io, bin_directory);
    const executable = try std.fmt.allocPrint(
        allocator,
        "{s}{c}{s}{s}",
        .{
            bin_directory,
            std.fs.path.sep,
            name,
            if (builtin.os.tag == .windows) windows_extension else "",
        },
    );
    if (builtin.os.tag == .windows) {
        const wrapper = try std.fmt.allocPrint(
            allocator,
            "@\"{s}\" \"--hutch-test-local-bin={s}\" %*\r\n",
            .{ runtime, name },
        );
        try std.Io.Dir.cwd().writeFile(init.io, .{
            .sub_path = executable,
            .data = wrapper,
        });
    } else {
        try std.Io.Dir.copyFile(
            std.Io.Dir.cwd(),
            runtime,
            std.Io.Dir.cwd(),
            executable,
            init.io,
            .{ .permissions = .executable_file, .make_path = true },
        );
    }
}

fn writeSuccessfulPathCommand(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    directory: []const u8,
    name: []const u8,
) !void {
    const path = try std.fmt.allocPrint(
        allocator,
        "{s}{c}{s}{s}",
        .{
            directory,
            std.fs.path.sep,
            name,
            if (builtin.os.tag == .windows) ".cmd" else "",
        },
    );
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = path,
        .data = if (builtin.os.tag == .windows) "@exit /b 0\r\n" else "#!/bin/sh\nexit 0\n",
        .flags = .{ .permissions = .executable_file },
    });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 4) return error.InvalidArguments;

    const launcher = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[1], allocator);
    const engine = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[2], allocator);
    const runtime = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[3], allocator);

    try expectExit(try run(init, allocator, launcher, engine, runtime, "pass", &test_invocation, null), 0);
    try expectExit(try run(init, allocator, launcher, engine, runtime, "fail", &test_invocation, null), 37);

    const signal_term = try run(init, allocator, launcher, engine, runtime, "signal", &test_invocation, null);
    if (comptime builtin.os.tag == .windows) {
        try expectExit(signal_term, 143);
    } else switch (signal_term) {
        .signal => |signal| if (signal != std.posix.SIG.TERM) return error.UnexpectedSignal,
        else => return error.SignalWasNotPropagated,
    }

    const temp_dir = init.environ_map.get("TMPDIR") orelse
        init.environ_map.get("TEMP") orelse
        init.environ_map.get("TMP") orelse
        if (builtin.os.tag == .windows) "." else "/tmp";
    const entrypoint = try std.fs.path.join(allocator, &.{ temp_dir, "hutch-runtime-options-entry.ts" });
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = entrypoint,
        .data = "console.log('runtime option fixture');\n",
    });
    defer std.Io.Dir.cwd().deleteFile(init.io, entrypoint) catch {};

    const runtime_options = [_][]const u8{
        "--ignore-dce-annotations",
        "run",
        entrypoint,
    };
    try expectExit(try run(
        init,
        allocator,
        launcher,
        engine,
        runtime,
        "runtime-options",
        &runtime_options,
        entrypoint,
    ), 0);

    const hutch_options = [_][]const u8{
        "run",
        "--silent",
        entrypoint,
    };
    try expectExit(try run(
        init,
        allocator,
        launcher,
        engine,
        runtime,
        "hutch-options",
        &hutch_options,
        entrypoint,
    ), 0);

    const fixture_root = try std.fmt.allocPrint(
        allocator,
        "{s}{c}hutch-config-runner-{d}",
        .{ temp_dir, std.fs.path.sep, std.Thread.getCurrentId() },
    );
    std.Io.Dir.cwd().deleteTree(init.io, fixture_root) catch {};
    defer std.Io.Dir.cwd().deleteTree(init.io, fixture_root) catch {};
    const fake_bin = try std.fs.path.join(allocator, &.{ fixture_root, "fake-bin" });
    try std.Io.Dir.cwd().createDirPath(init.io, fake_bin);
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ fixture_root, "hutch.config.ts" }),
        .data = "export default {};\n",
    });
    // Any attempt by Hutch to parse package.json makes these invocations fail.
    // External package managers still receive the project directory normally.
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ fixture_root, "package.json" }),
        .data = "{ this is intentionally invalid package json\n",
    });

    for ([_][]const u8{ "npm", "bun", "pnpm", "custom-pm" }) |name| {
        try writeFakePackageManager(init, allocator, fake_bin, runtime, name, ".cmd");
    }

    const no_config_root = try std.fmt.allocPrint(
        allocator,
        "{s}{c}hutch-package-manager-no-config-{d}",
        .{ temp_dir, std.fs.path.sep, std.Thread.getCurrentId() },
    );
    std.Io.Dir.cwd().deleteTree(init.io, no_config_root) catch {};
    defer std.Io.Dir.cwd().deleteTree(init.io, no_config_root) catch {};
    try std.Io.Dir.cwd().createDirPath(init.io, no_config_root);
    // Without configuration or lockfiles the built-in resolver installs; a
    // file: dependency completes offline and writes hutch.lock.
    try writeLocalDependencyProject(init, allocator, no_config_root, "no-config-fixture");
    const default_without_config = try runConfigCommand(
        init,
        allocator,
        launcher,
        engine,
        runtime,
        no_config_root,
        fake_bin,
        "pm-no-config-builtin",
        "{}",
        &.{ "install", "--ignore-scripts" },
    );
    try expectExit(default_without_config.term, 0);
    try expectPathExists(init.io, try std.fs.path.join(allocator, &.{ no_config_root, "hutch.lock" }));

    const config_json =
        \\{"scripts":{"install":["npm","install","--offline"],"npm-install":["npm","install","--offline"],"pnpm-dev":["pnpm","run","dev"],"hutch-version":["hutch","--version"],"hutch-version-shell":"hutch --version","shell-args":"shell-probe","ts-command":"entry.ts","bun-shell":"HUTCH_VALUE=alpha; echo \"$HUTCH_VALUE\" | tr a-z A-Z","shell-fail":"exit 37"}}
    ;
    // A bare non-path name is a configured task even when Cottontail could
    // resolve a same-stem source file. Direct runtime entrypoints stay
    // explicit (`hutch npm-install.ts` or `hutch ./npm-install`).
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ fixture_root, "npm-install.ts" }),
        .data = "throw new Error('configured task must win');\n",
    });
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ fixture_root, "install.ts" }),
        .data = "throw new Error('install is reserved for the external package manager');\n",
    });
    const listed = try runConfigCommand(
        init,
        allocator,
        launcher,
        engine,
        runtime,
        fixture_root,
        fake_bin,
        "config-list",
        config_json,
        &.{"run"},
    );
    try expectExit(listed.term, 0);
    try expectContains(listed.stdout, "npm-install\n");
    try expectContains(listed.stdout, "install\n");
    try expectContains(listed.stdout, "pnpm-dev\n");
    try expectContains(listed.stdout, "hutch-version\n");

    const npm_run = try runConfigCommand(
        init,
        allocator,
        launcher,
        engine,
        runtime,
        fixture_root,
        fake_bin,
        "config-npm",
        config_json,
        &.{ "npm-install", "two words", "$literal" },
    );
    try expectExit(npm_run.term, 0);

    const builtin_root = try std.fs.path.join(allocator, &.{ fixture_root, "builtin-default" });
    try std.Io.Dir.cwd().createDirPath(init.io, builtin_root);
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ builtin_root, "hutch.config.ts" }),
        .data = "export default {};\n",
    });
    try writeLocalDependencyProject(init, allocator, builtin_root, "builtin-default-fixture");
    const install_bare = try runConfigCommand(
        init,
        allocator,
        launcher,
        engine,
        runtime,
        builtin_root,
        fake_bin,
        "config-pm-default-builtin",
        "{\"scripts\":{}}",
        &.{"install"},
    );
    try expectExit(install_bare.term, 0);
    try expectPathExists(init.io, try std.fs.path.join(allocator, &.{ builtin_root, "hutch.lock" }));

    // The default package-manager selection has its own small CLI. Its
    // version is Hutch's version (not Bun's), and both explicit and bare help
    // stay local without resolving a runtime or an external manager.
    const hutch_version = try runBuiltinCommand(
        init,
        allocator,
        launcher,
        engine,
        no_config_root,
        fake_bin,
        "pm-builtin-metadata",
        &.{"--version"},
    );
    try expectExit(hutch_version.term, 0);
    const pm_version = try runBuiltinCommand(
        init,
        allocator,
        launcher,
        engine,
        no_config_root,
        fake_bin,
        "pm-builtin-metadata",
        &.{ "pm", "--version" },
    );
    try expectExit(pm_version.term, 0);
    try std.testing.expectEqualStrings(hutch_version.stdout, pm_version.stdout);

    const pm_help = try runBuiltinCommand(
        init,
        allocator,
        launcher,
        engine,
        no_config_root,
        fake_bin,
        "pm-builtin-metadata",
        &.{ "pm", "--help" },
    );
    try expectExit(pm_help.term, 0);
    try expectContains(pm_help.stdout, "hutch pm exec [--] <command> [args...]");
    const pm_bare = try runBuiltinCommand(
        init,
        allocator,
        launcher,
        engine,
        no_config_root,
        fake_bin,
        "pm-builtin-metadata",
        &.{"pm"},
    );
    try expectExit(pm_bare.term, 0);
    try expectContains(pm_bare.stdout, "hutch pm exec [--] <command> [args...]");

    const upgrade_help = try runBuiltinCommand(
        init,
        allocator,
        launcher,
        engine,
        no_config_root,
        fake_bin,
        "upgrade-help",
        &.{ "upgrade", "--help" },
    );
    const self_update_help = try runBuiltinCommand(
        init,
        allocator,
        launcher,
        engine,
        no_config_root,
        fake_bin,
        "upgrade-help",
        &.{ "self", "update", "--help" },
    );
    try expectExit(upgrade_help.term, 0);
    try expectExit(self_update_help.term, 0);
    try expectContains(upgrade_help.stdout, "hutch upgrade [production|stable|canary|latest|<semver>|build:<revision>]");
    try std.testing.expectEqualStrings(self_update_help.stdout, upgrade_help.stdout);
    try std.testing.expectEqualStrings("", upgrade_help.stderr);
    try std.testing.expectEqualStrings("", self_update_help.stderr);

    // A deliberately invalid selector is rejected before release resolution,
    // proving the top-level alias maps the selector exactly like `self update`
    // without making this hermetic suite contact a release service.
    const upgrade_selector = try runBuiltinCommand(
        init,
        allocator,
        launcher,
        engine,
        no_config_root,
        fake_bin,
        "upgrade-selector",
        &.{ "upgrade", "not-a-selector" },
    );
    const self_update_selector = try runBuiltinCommand(
        init,
        allocator,
        launcher,
        engine,
        no_config_root,
        fake_bin,
        "upgrade-selector",
        &.{ "self", "update", "not-a-selector" },
    );
    try expectExit(upgrade_selector.term, 1);
    try expectExit(self_update_selector.term, 1);
    try expectContains(upgrade_selector.stderr, "invalid release selector");
    try std.testing.expectEqualStrings(self_update_selector.stderr, upgrade_selector.stderr);

    const builtin_exec_root = try std.fs.path.join(allocator, &.{ no_config_root, "builtin-exec" });
    const builtin_exec_cwd = try std.fs.path.join(allocator, &.{ builtin_exec_root, "nested", "cwd" });
    const builtin_exec_bin = try std.fs.path.join(
        allocator,
        &.{ builtin_exec_root, "node_modules", ".bin" },
    );
    try std.Io.Dir.cwd().createDirPath(init.io, builtin_exec_cwd);
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ builtin_exec_root, "package.json" }),
        .data = "{\"name\":\"builtin-exec-fixture\",\"version\":\"1.0.0\"}\n",
    });
    try writeLocalBin(init, allocator, builtin_exec_bin, runtime, "local-probe", ".cmd");
    try writeLocalBin(init, allocator, builtin_exec_bin, runtime, "local-fail", ".cmd");

    const local_exec_invocation = [_][]const u8{
        "pm",
        "exec",
        "--",
        "local-probe",
    } ++ local_exec_arguments;
    const local_exec = try runBuiltinCommand(
        init,
        allocator,
        launcher,
        engine,
        builtin_exec_cwd,
        fake_bin,
        "pm-exec-success",
        &local_exec_invocation,
    );
    try expectExit(local_exec.term, 0);

    const local_fail = try runBuiltinCommand(
        init,
        allocator,
        launcher,
        engine,
        builtin_exec_cwd,
        fake_bin,
        "pm-exec-exit",
        &.{ "pm", "exec", "local-fail", "exit" },
    );
    try expectExit(local_fail.term, 37);

    // A same-named executable on PATH is deliberately runnable, but built-in
    // exec must still fail when the project-local bin entry is absent.
    try writeSuccessfulPathCommand(init, allocator, fake_bin, "path-only-probe");
    const no_path_fallback = try runBuiltinCommand(
        init,
        allocator,
        launcher,
        engine,
        builtin_exec_cwd,
        fake_bin,
        "pm-exec-path-fallback",
        &.{ "pm", "exec", "path-only-probe" },
    );
    try expectExit(no_path_fallback.term, 1);
    try expectContains(no_path_fallback.stderr, "was not found in");
    try expectContains(no_path_fallback.stderr, "node_modules");

    if (comptime builtin.os.tag == .windows) {
        try writeLocalBin(init, allocator, builtin_exec_bin, runtime, "local-bat-probe", ".bat");
        const local_bat_invocation = [_][]const u8{
            "pm",
            "exec",
            "local-bat-probe",
        } ++ local_exec_arguments;
        const local_bat = try runBuiltinCommand(
            init,
            allocator,
            launcher,
            engine,
            builtin_exec_cwd,
            fake_bin,
            "pm-exec-bat",
            &local_bat_invocation,
        );
        try expectExit(local_bat.term, 0);

        for ([_][]const u8{ "line\nfeed", "carriage\rreturn" }) |invalid_arg| {
            const invalid_local_batch_arg = try runBuiltinCommand(
                init,
                allocator,
                launcher,
                engine,
                builtin_exec_cwd,
                fake_bin,
                "pm-exec-batch-invalid",
                &.{ "pm", "exec", "local-probe", invalid_arg },
            );
            try expectExit(invalid_local_batch_arg.term, 1);
            try expectContains(
                invalid_local_batch_arg.stderr,
                "Windows .cmd/.bat shims reject arguments containing NUL, CR, or LF",
            );
        }
    }

    // Foreign lockfiles are ignored entirely: the built-in resolver runs,
    // creates hutch.lock, and leaves the foreign file untouched.
    const ignored_lock_root = try std.fs.path.join(allocator, &.{ fixture_root, "ignored-bun-lock" });
    try std.Io.Dir.cwd().createDirPath(init.io, ignored_lock_root);
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ ignored_lock_root, "hutch.config.ts" }),
        .data = "export default {};\n",
    });
    try writeLocalDependencyProject(init, allocator, ignored_lock_root, "ignored-bun-lock-fixture");
    const stale_bun_lock = try std.fs.path.join(allocator, &.{ ignored_lock_root, "bun.lock" });
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = stale_bun_lock,
        .data = "{ stale bun lockfile that hutch must never read }\n",
    });
    const ignored_lock = try runConfigCommand(
        init,
        allocator,
        launcher,
        engine,
        runtime,
        ignored_lock_root,
        fake_bin,
        "config-pm-ignored-lock",
        "{\"scripts\":{}}",
        &.{"install"},
    );
    try expectExit(ignored_lock.term, 0);
    try expectPathExists(init.io, try std.fs.path.join(allocator, &.{ ignored_lock_root, "hutch.lock" }));
    const stale_contents = try std.Io.Dir.cwd().readFileAlloc(init.io, stale_bun_lock, allocator, .limited(4096));
    if (!std.mem.eql(u8, stale_contents, "{ stale bun lockfile that hutch must never read }\n")) {
        return error.ForeignLockfileWasModified;
    }

    const bun_raw = try runConfigCommand(
        init,
        allocator,
        launcher,
        engine,
        runtime,
        fixture_root,
        fake_bin,
        "config-pm-bun-raw",
        "{\"packageManager\":\"bun\",\"scripts\":{}}",
        &.{ "pm", "add", "left-pad", "--exact" },
    );
    try expectExit(bun_raw.term, 0);

    // Explicit managers own the entire pm argv, including words understood
    // by Hutch's built-in CLI and the optional `--` separator.
    const external_exec = try runConfigCommand(
        init,
        allocator,
        launcher,
        engine,
        runtime,
        fixture_root,
        fake_bin,
        "config-pm-external-exec",
        "{\"packageManager\":\"npm\",\"scripts\":{}}",
        &.{ "pm", "exec", "--", "local-probe", "two words" },
    );
    try expectExit(external_exec.term, 0);

    const custom_install = try runConfigCommand(
        init,
        allocator,
        launcher,
        engine,
        runtime,
        fixture_root,
        fake_bin,
        "config-pm-custom-install",
        "{\"packageManager\":{\"name\":\"pnpm\",\"executable\":\"custom-pm\"}}",
        &.{ "install", "--frozen" },
    );
    try expectExit(custom_install.term, 0);

    // The default bun is vendored as a toolchain. With the PATH bun reporting
    // a version Hutch's default cannot accept, resolution must fall through to
    // the pre-installed managed toolchain and run that binary by exact path.
    const vendored_home = try std.fs.path.join(allocator, &.{ fixture_root, "hutch-home" });
    const vendored_root = try std.fs.path.join(allocator, &.{
        vendored_home,
        "toolchains",
        "bun",
        "1.3.13",
        toolchainPlatformKey(),
    });
    const vendored_bun = try std.fs.path.join(allocator, &.{
        vendored_root,
        if (builtin.os.tag == .windows) "bun.exe" else "bun",
    });
    try std.Io.Dir.copyFile(
        std.Io.Dir.cwd(),
        runtime,
        std.Io.Dir.cwd(),
        vendored_bun,
        init.io,
        .{ .permissions = .executable_file, .make_path = true },
    );
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ vendored_root, ".hutch-toolchain" }),
        .data = "1.3.13",
    });
    const vendored_install = try runConfigCommandWithOverrides(
        init,
        allocator,
        launcher,
        engine,
        runtime,
        fixture_root,
        fake_bin,
        "config-pm-vendored-bun",
        "{\"packageManager\":\"bun\",\"scripts\":{}}",
        &.{ "install", "--linker=isolated" },
        &.{
            .{ .key = "HUTCH_HOME", .value = vendored_home },
            .{ .key = "HUTCH_TEST_VENDORED_BUN_PATH", .value = vendored_bun },
            .{ .key = "HUTCH_TEST_VENDORED_BUN_VERSION", .value = "1.3.13" },
            .{ .key = "HUTCH_TEST_PATH_BUN_VERSION", .value = "0.0.1" },
        },
    );
    try expectExit(vendored_install.term, 0);

    const missing_manager = try runConfigCommand(
        init,
        allocator,
        launcher,
        engine,
        runtime,
        fixture_root,
        fake_bin,
        "config-pm-missing",
        "{\"packageManager\":\"yarn\"}",
        &.{"install"},
    );
    try expectExit(missing_manager.term, 1);
    try expectContains(missing_manager.stderr, "could not run package manager yarn (yarn)");

    // npm/pnpm normally expose .cmd shims and Yarn commonly exposes either a
    // .cmd or .bat shim on Windows. Exercise both extensions through Hutch's
    // native argv adapter with values that would become cmd.exe grammar if
    // batch serialization regressed.
    try writeFakePackageManager(init, allocator, fake_bin, runtime, "yarn", ".bat");
    const injection_marker = try std.fs.path.join(
        allocator,
        &.{ fixture_root, "hutch-batch-argument-injected.txt" },
    );
    const adversarial_invocation = [_][]const u8{
        "install",
        "%HUTCH_BATCH_SENTINEL%",
        "!HUTCH_BATCH_DELAYED!",
        "caret^value",
        "quote\"value",
        "amp&value",
        "pipe|value",
        "input<value",
        "output>value",
        "(parentheses)",
        "",
        "trailing\\",
        "two words",
        "tab\tvalue",
        "工作-🚀",
        "safe & echo injected>hutch-batch-argument-injected.txt & rem",
        "--hutch-test-package-manager=forwarded",
    };
    const manager_cases = [_]struct {
        mode: []const u8,
        config: []const u8,
    }{
        .{ .mode = "config-pm-adversarial-npm", .config = "{\"packageManager\":\"npm\"}" },
        .{ .mode = "config-pm-adversarial-pnpm", .config = "{\"packageManager\":\"pnpm\"}" },
        .{ .mode = "config-pm-adversarial-yarn", .config = "{\"packageManager\":\"yarn\"}" },
    };
    for (manager_cases) |case| {
        std.Io.Dir.cwd().deleteFile(init.io, injection_marker) catch {};
        const adversarial = try runConfigCommand(
            init,
            allocator,
            launcher,
            engine,
            runtime,
            fixture_root,
            fake_bin,
            case.mode,
            case.config,
            &adversarial_invocation,
        );
        try expectExit(adversarial.term, 0);
        try expectMissing(init, injection_marker);
    }

    if (comptime builtin.os.tag == .windows) {
        for ([_][]const u8{ "line\nfeed", "carriage\rreturn" }) |invalid_arg| {
            const invalid_batch_arg = try runConfigCommand(
                init,
                allocator,
                launcher,
                engine,
                runtime,
                fixture_root,
                fake_bin,
                "config-pm-adversarial-npm",
                "{\"packageManager\":\"npm\"}",
                &.{ "install", invalid_arg },
            );
            try expectExit(invalid_batch_arg.term, 1);
            try expectContains(
                invalid_batch_arg.stderr,
                "Windows .cmd/.bat package-manager shims reject arguments containing NUL, CR, or LF",
            );
            try expectMissing(init, injection_marker);
        }
    }

    const install_run = try runConfigCommand(
        init,
        allocator,
        launcher,
        engine,
        runtime,
        fixture_root,
        fake_bin,
        "config-npm",
        config_json,
        &.{ "run", "install", "two words", "$literal" },
    );
    try expectExit(install_run.term, 0);

    const optional_install_run = try runConfigCommand(
        init,
        allocator,
        launcher,
        engine,
        runtime,
        fixture_root,
        fake_bin,
        "config-npm",
        config_json,
        &.{ "run", "--if-configured", "install", "two words", "$literal" },
    );
    try expectExit(optional_install_run.term, 0);

    const shell_args_run = try runConfigCommand(
        init,
        allocator,
        launcher,
        engine,
        runtime,
        fixture_root,
        fake_bin,
        "config-shell-args",
        config_json,
        &.{
            "shell-args",
            "two words",
            "$literal",
            "%PATH%",
            "quote\"inside",
            "amp&ersand",
            "pipe|value",
            "paren(value)",
            "caret^value",
            "bang!value",
            "trail\\",
            "",
            "--config",
            "../../must-stay-an-argument",
            "--conditions=hutch-shell-sentinel",
            "--feature",
            "hutch-shell-sentinel",
        },
    );
    try expectExit(shell_args_run.term, 0);

    // A filename-looking string is still Bun.$ command text. Only an argv
    // array requests exact process execution.
    const ts_command_run = try runConfigCommand(
        init,
        allocator,
        launcher,
        engine,
        runtime,
        fixture_root,
        fake_bin,
        "config-ts-command",
        config_json,
        &.{ "ts-command", "two words" },
    );
    try expectExit(ts_command_run.term, 0);

    const bun_shell_run = try runConfigCommand(
        init,
        allocator,
        launcher,
        engine,
        runtime,
        fixture_root,
        fake_bin,
        "config-bun-shell",
        config_json,
        &.{"bun-shell"},
    );
    try expectExit(bun_shell_run.term, 0);

    const shell_fail_run = try runConfigCommand(
        init,
        allocator,
        launcher,
        engine,
        runtime,
        fixture_root,
        fake_bin,
        "config-shell-fail",
        config_json,
        &.{"shell-fail"},
    );
    try expectExit(shell_fail_run.term, 37);

    // Hutch-owned private files must stop Cottontail's ordinary nearest-bunfig
    // walk inside their 0700 leaf. If either loader fell through to this
    // attacker-controlled temp ancestor, its deliberately missing preload
    // would abort before hutch.config.ts or the shell wrapper could run.
    const hostile_temp_root = try std.fmt.allocPrint(
        allocator,
        "{s}{c}hutch-hostile-bunfig-{d}",
        .{ temp_dir, std.fs.path.sep, std.Thread.getCurrentId() },
    );
    std.Io.Dir.cwd().deleteTree(init.io, hostile_temp_root) catch {};
    defer std.Io.Dir.cwd().deleteTree(init.io, hostile_temp_root) catch {};
    try std.Io.Dir.cwd().createDir(init.io, hostile_temp_root, if (builtin.os.tag == .windows)
        .default_dir
    else
        @enumFromInt(0o700));
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ hostile_temp_root, "bunfig.toml" }),
        .data = "preload = [\"./must-not-run.mjs\"]\n",
    });
    const hostile_temp_overrides = [_]EnvironmentOverride{
        .{ .key = "TMPDIR", .value = hostile_temp_root },
        .{ .key = "TEMP", .value = hostile_temp_root },
        .{ .key = "HUTCH_TEST_EXPECTED_TASK_TMPDIR", .value = hostile_temp_root },
        .{ .key = "HUTCH_TEST_EXPECTED_TASK_TEMP", .value = hostile_temp_root },
    };
    const hostile_config_run = try runConfigCommandWithOverrides(
        init,
        allocator,
        launcher,
        engine,
        runtime,
        fixture_root,
        fake_bin,
        "config-list",
        config_json,
        &.{"run"},
        &hostile_temp_overrides,
    );
    try expectExit(hostile_config_run.term, 0);
    const hostile_shell_run = try runConfigCommandWithOverrides(
        init,
        allocator,
        launcher,
        engine,
        runtime,
        fixture_root,
        fake_bin,
        "config-bun-shell",
        config_json,
        &.{"bun-shell"},
        &hostile_temp_overrides,
    );
    try expectExit(hostile_shell_run.term, 0);

    const pnpm_run = try runConfigCommand(
        init,
        allocator,
        launcher,
        engine,
        runtime,
        fixture_root,
        fake_bin,
        "config-pnpm",
        config_json,
        &.{ "run", "pnpm-dev", "--filter", "app one" },
    );
    try expectExit(pnpm_run.term, 0);

    const split_launcher_dir = try std.fs.path.join(allocator, &.{ fixture_root, "launcher-only" });
    const split_engine_dir = try std.fs.path.join(allocator, &.{ fixture_root, "engine-only" });
    try std.Io.Dir.cwd().createDirPath(init.io, split_launcher_dir);
    try std.Io.Dir.cwd().createDirPath(init.io, split_engine_dir);
    const split_launcher = try std.fs.path.join(
        allocator,
        &.{ split_launcher_dir, std.fs.path.basename(launcher) },
    );
    const split_engine = try std.fs.path.join(
        allocator,
        &.{ split_engine_dir, std.fs.path.basename(engine) },
    );
    try std.Io.Dir.copyFile(
        std.Io.Dir.cwd(),
        launcher,
        std.Io.Dir.cwd(),
        split_launcher,
        init.io,
        .{ .permissions = .executable_file, .make_path = true },
    );
    try std.Io.Dir.copyFile(
        std.Io.Dir.cwd(),
        engine,
        std.Io.Dir.cwd(),
        split_engine,
        init.io,
        .{ .permissions = .executable_file, .make_path = true },
    );

    const hutch_run = try runConfigCommand(
        init,
        allocator,
        split_launcher,
        split_engine,
        runtime,
        fixture_root,
        fake_bin,
        "config-hutch",
        config_json,
        &.{"hutch-version"},
    );
    try expectExit(hutch_run.term, 0);
    try expectContains(hutch_run.stdout, "0.0.0-test\n");

    const hutch_shell_run = try runConfigCommand(
        init,
        allocator,
        split_launcher,
        split_engine,
        runtime,
        fixture_root,
        fake_bin,
        "config-hutch-shell",
        config_json,
        &.{"hutch-version-shell"},
    );
    try expectExit(hutch_shell_run.term, 0);
    try expectContains(hutch_shell_run.stdout, "0.0.0-test\n");

    // Canary installs name the authoritative launcher `hutch-canary`, while
    // configured shell tasks conventionally invoke `hutch`. A same-directory
    // production launcher must not capture that recursive command.
    const canary_launcher_dir = try std.fs.path.join(allocator, &.{ fixture_root, "canary-launcher-only" });
    try std.Io.Dir.cwd().createDirPath(init.io, canary_launcher_dir);
    const canary_launcher = try std.fs.path.join(
        allocator,
        &.{ canary_launcher_dir, if (builtin.os.tag == .windows) "hutch-canary.exe" else "hutch-canary" },
    );
    try std.Io.Dir.copyFile(
        std.Io.Dir.cwd(),
        launcher,
        std.Io.Dir.cwd(),
        canary_launcher,
        init.io,
        .{ .permissions = .executable_file },
    );
    const wrong_production_launcher = try std.fs.path.join(
        allocator,
        &.{ canary_launcher_dir, if (builtin.os.tag == .windows) "hutch.cmd" else "hutch" },
    );
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = wrong_production_launcher,
        .data = if (builtin.os.tag == .windows) "@exit /b 91\r\n" else "#!/bin/sh\nexit 91\n",
        .flags = .{ .permissions = .executable_file },
    });
    const canary_hutch_shell_run = try runConfigCommand(
        init,
        allocator,
        canary_launcher,
        split_engine,
        runtime,
        fixture_root,
        fake_bin,
        "config-hutch-shell",
        config_json,
        &.{"hutch-version-shell"},
    );
    try expectExit(canary_hutch_shell_run.term, 0);
    try expectContains(canary_hutch_shell_run.stdout, "0.0.0-test\n");

    // A project must never become Hutch's scratch directory merely because it
    // poisoned TMPDIR/TEMP. Exercise both the config side channel and the
    // copied canary launcher while the project itself is read-only. On POSIX,
    // make the first candidate a symlink preclaim as well; the retained
    // no-follow parent must reject it and fall back to a trusted system root.
    const hardened_project = try std.fs.path.join(
        allocator,
        &.{ fixture_root, "temp-hardening-project" },
    );
    try std.Io.Dir.cwd().createDirPath(init.io, hardened_project);
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ hardened_project, "hutch.config.ts" }),
        .data = "export default {};\n",
    });
    const poison_candidate = try std.fs.path.join(
        allocator,
        &.{ hardened_project, "poisoned-temp" },
    );
    if (comptime builtin.os.tag != .windows) {
        try std.Io.Dir.cwd().symLink(
            init.io,
            hardened_project,
            poison_candidate,
            .{ .is_directory = true },
        );
    } else {
        try std.Io.Dir.cwd().createDir(init.io, poison_candidate, .default_dir);
    }

    const project_stat = try std.Io.Dir.cwd().statFile(init.io, hardened_project, .{});
    if (comptime builtin.os.tag != .windows) {
        try std.Io.Dir.cwd().setFilePermissions(
            init.io,
            hardened_project,
            @enumFromInt(0o555),
            .{ .follow_symlinks = false },
        );
    }
    defer if (builtin.os.tag != .windows) {
        std.Io.Dir.cwd().setFilePermissions(
            init.io,
            hardened_project,
            project_stat.permissions,
            .{ .follow_symlinks = false },
        ) catch {};
    };

    const poisoned_temp_overrides = [_]EnvironmentOverride{
        .{ .key = "TMPDIR", .value = poison_candidate },
        .{ .key = "TEMP", .value = hardened_project },
        .{ .key = "HUTCH_TEST_EXPECTED_TASK_TMPDIR", .value = poison_candidate },
        .{ .key = "HUTCH_TEST_EXPECTED_TASK_TEMP", .value = hardened_project },
    };
    const hardened_config = try runConfigCommandWithOverrides(
        init,
        allocator,
        launcher,
        engine,
        runtime,
        hardened_project,
        fake_bin,
        "config-list",
        "{\"scripts\":{}}",
        &.{"run"},
        &poisoned_temp_overrides,
    );
    try expectExit(hardened_config.term, 0);

    const hardened_shell = try runConfigCommandWithOverrides(
        init,
        allocator,
        canary_launcher,
        split_engine,
        runtime,
        hardened_project,
        fake_bin,
        "config-hutch-shell",
        "{\"scripts\":{\"hutch-version-shell\":\"hutch --version\"}}",
        &.{"hutch-version-shell"},
        &poisoned_temp_overrides,
    );
    try expectExit(hardened_shell.term, 0);
    try expectContains(hardened_shell.stdout, "0.0.0-test\n");
    try expectNoPrivateTempArtifacts(init, hardened_project);

    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ fixture_root, "package.json" }),
        .data = "{\"scripts\":{\"package-only\":\"exit 0\"}}\n",
    });
    const package_only_list = try runConfigCommand(
        init,
        allocator,
        launcher,
        engine,
        runtime,
        fixture_root,
        fake_bin,
        "config-list",
        "{\"scripts\":{}}",
        &.{"run"},
    );
    try expectExit(package_only_list.term, 0);
    if (package_only_list.stdout.len != 0) return error.PackageScriptsWereListed;

    const package_only_run = try runConfigCommand(
        init,
        allocator,
        launcher,
        engine,
        runtime,
        fixture_root,
        fake_bin,
        "config-list",
        config_json,
        &.{"package-only"},
    );
    try expectExit(package_only_run.term, 1);
    try expectContains(package_only_run.stderr, "Script not found");

    const absent_install = try runConfigCommand(
        init,
        allocator,
        launcher,
        engine,
        runtime,
        fixture_root,
        fake_bin,
        "config-pm-explicit-npm-install",
        "{\"packageManager\":\"npm\",\"scripts\":{}}",
        &.{ "install", "two words", "$literal" },
    );
    try expectExit(absent_install.term, 0);

    const absent_optional_install = try runConfigCommand(
        init,
        allocator,
        launcher,
        engine,
        runtime,
        fixture_root,
        fake_bin,
        "config-list",
        "{\"scripts\":{}}",
        &.{ "run", "--if-configured", "install" },
    );
    try expectExit(absent_optional_install.term, 0);
    if (absent_optional_install.stdout.len != 0 or absent_optional_install.stderr.len != 0) {
        return error.OptionalScriptWasNotSilent;
    }

    const logged_config = try runConfigCommand(
        init,
        allocator,
        launcher,
        engine,
        runtime,
        fixture_root,
        fake_bin,
        "config-console-log",
        "{\"scripts\":{}}",
        &.{ "run", "--if-configured", "install" },
    );
    try expectExit(logged_config.term, 0);
    try expectContains(logged_config.stdout, "config console output\n");

    const non_object_config = try runConfigCommand(
        init,
        allocator,
        launcher,
        engine,
        runtime,
        fixture_root,
        fake_bin,
        "config-list",
        "[]",
        &.{ "run", "--if-configured", "install" },
    );
    try expectExit(non_object_config.term, 1);
    try expectContains(non_object_config.stderr, "InvalidHutchConfig");
}
