const std = @import("std");
const builtin = @import("builtin");

const expected_test_args = [_][]const u8{
    "test",
    "tests/pass fixture.test.ts",
    "tests/second.test.ts",
    "--test-name-pattern",
    "exact value",
    "--bail=3",
};

const expected_shell_args = [_][]const u8{
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
};

const expected_package_manager_adversarial_args = [_][]const u8{
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
};

fn expectArgs(actual: []const [:0]const u8, expected: []const []const u8) !void {
    if (actual.len != expected.len) return error.UnexpectedArgumentCount;
    for (expected, actual) |expected_arg, actual_arg| {
        if (!std.mem.eql(u8, expected_arg, actual_arg)) return error.UnexpectedArgument;
    }
}

fn runRecursiveHutchVersion(init: std.process.Init) !void {
    var child = try std.process.spawn(init.io, .{
        .argv = &.{ "hutch", "--version" },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    defer child.kill(init.io);
    switch (try child.wait(init.io)) {
        .exited => |exit_code| if (exit_code != 0) return error.RecursiveHutchFailed,
        else => return error.RecursiveHutchTerminated,
    }
}

fn expectConfiguredCwd(init: std.process.Init) !void {
    const expected_path = init.environ_map.get("HUTCH_TEST_EXPECTED_CWD") orelse
        return error.MissingExpectedCwd;
    const allocator = init.arena.allocator();
    const expected = try std.Io.Dir.cwd().realPathFileAlloc(init.io, expected_path, allocator);
    const actual = try std.Io.Dir.cwd().realPathFileAlloc(init.io, ".", allocator);
    if (!std.mem.eql(u8, expected, actual)) return error.UnexpectedConfiguredCwd;
}

fn expectPrivateTempDirectory(
    init: std.process.Init,
    path: []const u8,
    prefix: []const u8,
) !void {
    if (!std.mem.startsWith(u8, std.fs.path.basename(path), prefix)) {
        return error.UnexpectedPrivateTempDirectoryName;
    }
    const stat = try std.Io.Dir.cwd().statFile(init.io, path, .{
        .follow_symlinks = false,
    });
    if (stat.kind != .directory) return error.PrivateTempDirectoryWasReplaced;
    if (comptime builtin.os.tag != .windows) {
        if (stat.permissions.toMode() & 0o077 != 0) {
            return error.PrivateTempDirectoryPermissionsTooBroad;
        }
    }
}

fn expectPrivateFileInRoot(
    init: std.process.Init,
    private_root: []const u8,
    path: []const u8,
    expected_name: []const u8,
) !void {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPrivateFilePath;
    if (!std.mem.eql(u8, parent, private_root)) return error.PrivateFileOutsideRoot;
    if (!std.mem.eql(u8, std.fs.path.basename(path), expected_name)) {
        return error.UnexpectedPrivateFileName;
    }
    const stat = try std.Io.Dir.cwd().statFile(init.io, path, .{
        .follow_symlinks = false,
    });
    if (stat.kind != .file) return error.PrivateFileMissing;
    if (comptime builtin.os.tag != .windows) {
        if (stat.permissions.toMode() & 0o777 != 0o600) {
            return error.PrivateFilePermissionsTooBroad;
        }
    }
}

fn expectPrivateEmptyBunfig(init: std.process.Init, private_root: []const u8) !void {
    const path = try std.fs.path.join(init.arena.allocator(), &.{ private_root, "bunfig.toml" });
    try expectPrivateFileInRoot(init, private_root, path, "bunfig.toml");
    const contents = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        path,
        init.arena.allocator(),
        .limited(1),
    );
    if (contents.len != 0) return error.PrivateBunfigWasNotEmpty;
}

fn expectPrivateShellTask(
    init: std.process.Init,
    wrapper_path: []const u8,
    private_root: []const u8,
) !void {
    try expectPrivateTempDirectory(init, private_root, "hutch-shell-launcher-");
    try expectPrivateFileInRoot(init, private_root, wrapper_path, "hutch-shell-wrapper.mjs");
    try expectPrivateEmptyBunfig(init, private_root);
    const wrapper_source = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        wrapper_path,
        init.arena.allocator(),
        .limited(16 * 1024),
    );
    for ([_][]const u8{
        "__cottontailLoadDotenv",
        "__cottontailLoadStandaloneBunfig",
        "process.argv.slice(2)",
        "Bun.argv",
        "cottontail.argv.splice(1)",
        "cottontail.args.splice(0)",
        "process.execArgv.splice(0)",
        "cottontail.execArgv.splice(0)",
        "cottontail.internal.hutchShellTask",
        "Bun.stdin.stream()",
    }) |marker| {
        if (std.mem.indexOf(u8, wrapper_source, marker) == null) {
            return error.PrivateShellWrapperContractMissing;
        }
    }
    const argv_snapshot = std.mem.indexOf(u8, wrapper_source, "process.argv.slice(2)") orelse
        return error.PrivateShellWrapperContractMissing;
    const dotenv_load = std.mem.indexOf(u8, wrapper_source, "__cottontailLoadDotenv") orelse
        return error.PrivateShellWrapperContractMissing;
    if (argv_snapshot > dotenv_load) return error.PrivateShellWrapperExposedProtocolArgv;
    const bunfig_load = std.mem.indexOf(u8, wrapper_source, "__cottontailLoadStandaloneBunfig") orelse
        return error.PrivateShellWrapperContractMissing;
    const first_argv_scrub = std.mem.indexOf(u8, wrapper_source, "clearPrivateArgv();") orelse
        return error.PrivateShellWrapperContractMissing;
    if (first_argv_scrub >= dotenv_load) return error.PrivateShellWrapperExposedProtocolArgv;
    const final_argv_scrub = std.mem.lastIndexOf(u8, wrapper_source, "clearPrivateArgv();") orelse
        return error.PrivateShellWrapperContractMissing;
    if (final_argv_scrub <= bunfig_load or final_argv_scrub == first_argv_scrub) {
        return error.PrivateShellWrapperRetainedMutatedArgv;
    }

    const path_key = if (builtin.os.tag == .windows) "Path" else "PATH";
    const path = init.environ_map.get(path_key) orelse
        init.environ_map.get("PATH") orelse return error.MissingPath;
    var entries = std.mem.splitScalar(u8, path, std.fs.path.delimiter);
    const shim_dir = entries.first();
    if (!std.mem.eql(u8, shim_dir, private_root)) {
        return error.PrivateShellLauncherPathMismatch;
    }
    const launcher = try std.fs.path.join(init.arena.allocator(), &.{
        shim_dir,
        if (builtin.os.tag == .windows) "hutch.exe" else "hutch",
    });
    const stat = try std.Io.Dir.cwd().statFile(init.io, launcher, .{
        .follow_symlinks = false,
    });
    if (stat.kind != .file) return error.PrivateShellLauncherMissing;

    if (init.environ_map.get("HUTCH_TEST_EXPECTED_TASK_TMPDIR")) |expected| {
        const actual = init.environ_map.get("TMPDIR") orelse return error.MissingExpectedTaskTmpdir;
        if (!std.mem.eql(u8, actual, expected)) return error.TaskTmpdirWasChanged;
    }
    if (init.environ_map.get("HUTCH_TEST_EXPECTED_TASK_TEMP")) |expected| {
        const actual = init.environ_map.get("TEMP") orelse return error.MissingExpectedTaskTemp;
        if (!std.mem.eql(u8, actual, expected)) return error.TaskTempWasChanged;
    }
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    // Older engines may probe imports before starting the runtime. Keep the
    // fixture neutral so this forwarding test can straddle that removal.
    if (args.len > 1 and std.mem.eql(u8, args[1], "--cottontail-scan-package-imports")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "[]\n");
        return;
    }
    const mode = init.environ_map.get("HUTCH_TEST_FIXTURE_MODE") orelse
        return error.MissingFixtureMode;

    if (std.mem.startsWith(u8, mode, "config-")) {
        if (args.len == 5 and
            std.mem.eql(u8, args[1], "--hutch-config-file") and
            std.mem.eql(u8, args[3], "--hutch-private-root"))
        {
            const loader_dir = args[4];
            try expectPrivateTempDirectory(init, loader_dir, "hutch-config-loader-");
            try expectPrivateFileInRoot(init, loader_dir, args[2], "load.mjs");
            try expectPrivateEmptyBunfig(init, loader_dir);
            const config_json = init.environ_map.get("HUTCH_TEST_CONFIG_JSON") orelse
                return error.MissingConfigJson;
            if (std.mem.eql(u8, mode, "config-console-log")) {
                try std.Io.File.stdout().writeStreamingAll(init.io, "config console output\n");
            }

            const loader_source = try std.Io.Dir.cwd().readFileAlloc(
                init.io,
                args[2],
                init.arena.allocator(),
                .limited(1024 * 1024),
            );
            const result_marker = "config.json";
            if (std.mem.indexOf(u8, loader_source, result_marker) == null) {
                return error.ConfigResultSideChannelMissing;
            }
            if (std.mem.indexOf(u8, loader_source, "__hutchChmodConfig") == null or
                std.mem.indexOf(u8, loader_source, "0o600") == null)
            {
                return error.ConfigResultPermissionsMissing;
            }
            const argv_scrub = std.mem.indexOf(u8, loader_source, "process.argv.splice(1)") orelse
                return error.ConfigArgvScrubMissing;
            const cottontail_argv_scrub = std.mem.indexOf(u8, loader_source, "cottontail.argv.splice(1)") orelse
                return error.ConfigArgvScrubMissing;
            for ([_][]const u8{
                "Bun.argv",
                "cottontail.args.splice(0)",
                "process.execArgv.splice(0)",
                "cottontail.execArgv.splice(0)",
            }) |marker| {
                if (std.mem.indexOf(u8, loader_source, marker) == null) {
                    return error.ConfigArgvScrubMissing;
                }
            }
            const config_import = std.mem.indexOf(u8, loader_source, "await import(") orelse
                return error.ConfigDynamicImportMissing;
            if (argv_scrub > config_import) return error.ConfigImportExposedPrivateArgv;
            if (cottontail_argv_scrub > config_import) return error.ConfigImportExposedPrivateArgv;
            const clear_call = std.mem.indexOf(u8, loader_source, "__hutchClearPrivateArgv();") orelse
                return error.ConfigArgvScrubMissing;
            if (clear_call > config_import) return error.ConfigImportExposedPrivateArgv;
            const result_path = try std.fs.path.join(init.arena.allocator(), &.{ loader_dir, result_marker });
            try std.Io.Dir.cwd().writeFile(init.io, .{
                .sub_path = result_path,
                .data = config_json,
            });
            return;
        }

        if (args.len >= 6 and
            std.mem.eql(u8, args[1], "--hutch-shell-file") and
            std.mem.eql(u8, args[3], "--hutch-private-root"))
        {
            try expectConfiguredCwd(init);
            try expectPrivateShellTask(init, args[2], args[4]);
            const command = args[5];
            const appended = args[6..];
            if (std.mem.eql(u8, mode, "config-hutch-shell")) {
                if (!std.mem.eql(u8, command, "hutch --version")) return error.UnexpectedShellCommand;
                try expectArgs(appended, &.{});
                return runRecursiveHutchVersion(init);
            }
            if (std.mem.eql(u8, mode, "config-shell-args")) {
                if (!std.mem.eql(u8, command, "shell-probe")) return error.UnexpectedShellCommand;
                return expectArgs(appended, &expected_shell_args);
            }
            if (std.mem.eql(u8, mode, "config-ts-command")) {
                if (!std.mem.eql(u8, command, "entry.ts")) return error.UnexpectedShellCommand;
                return expectArgs(appended, &.{"two words"});
            }
            if (std.mem.eql(u8, mode, "config-bun-shell")) {
                if (!std.mem.eql(u8, command, "HUTCH_VALUE=alpha; echo \"$HUTCH_VALUE\" | tr a-z A-Z")) {
                    return error.UnexpectedShellCommand;
                }
                return expectArgs(appended, &.{});
            }
            if (std.mem.eql(u8, mode, "config-shell-fail")) {
                if (!std.mem.eql(u8, command, "exit 37")) return error.UnexpectedShellCommand;
                try expectArgs(appended, &.{});
                std.process.exit(37);
            }
            return error.UnknownShellTaskMode;
        }

        const executable = std.fs.path.basename(args[0]);
        const adversarial_mode_prefix = "config-pm-adversarial-";
        if (std.mem.startsWith(u8, mode, adversarial_mode_prefix)) {
            const expected_manager = mode[adversarial_mode_prefix.len..];
            if (!std.mem.startsWith(u8, executable, expected_manager)) {
                return error.UnexpectedConfigCommand;
            }
            return expectArgs(args[1..], &expected_package_manager_adversarial_args);
        }
        if (std.mem.eql(u8, mode, "config-npm")) {
            if (!std.mem.startsWith(u8, executable, "npm")) return error.UnexpectedConfigCommand;
            return expectArgs(args[1..], &.{ "install", "--offline", "two words", "$literal" });
        }
        if (std.mem.eql(u8, mode, "config-pnpm")) {
            if (!std.mem.startsWith(u8, executable, "pnpm")) return error.UnexpectedConfigCommand;
            return expectArgs(args[1..], &.{ "run", "dev", "--filter", "app one" });
        }
        if (std.mem.eql(u8, mode, "config-pm-default-install")) {
            if (!std.mem.startsWith(u8, executable, "npm")) return error.UnexpectedConfigCommand;
            return expectArgs(args[1..], &.{ "install", "two words", "$literal" });
        }
        if (std.mem.eql(u8, mode, "config-pm-bun-raw")) {
            if (!std.mem.startsWith(u8, executable, "bun")) return error.UnexpectedConfigCommand;
            return expectArgs(args[1..], &.{ "add", "left-pad", "--exact" });
        }
        if (std.mem.eql(u8, mode, "config-pm-custom-install")) {
            if (!std.mem.startsWith(u8, executable, "custom-pm")) return error.UnexpectedConfigCommand;
            return expectArgs(args[1..], &.{ "install", "--frozen" });
        }
        if (std.mem.eql(u8, mode, "config-hutch") or
            std.mem.eql(u8, mode, "config-hutch-shell"))
        {
            try expectArgs(args[1..], &.{"--version"});
            try std.Io.File.stdout().writeStreamingAll(init.io, "0.0.0-test\n");
            return;
        }
        if (std.mem.eql(u8, mode, "config-list")) return error.UnexpectedConfigCommand;
        return error.UnknownFixtureMode;
    }

    if (std.mem.eql(u8, mode, "pm-no-config-npm")) {
        const executable = std.fs.path.basename(args[0]);
        if (!std.mem.startsWith(u8, executable, "npm")) return error.UnexpectedConfigCommand;
        return expectArgs(args[1..], &.{ "install", "--ignore-scripts" });
    }

    if (std.mem.eql(u8, mode, "runtime-options")) {
        const entrypoint = init.environ_map.get("HUTCH_TEST_EXPECTED_ENTRYPOINT") orelse
            return error.MissingExpectedEntrypoint;
        const expected = [_][]const u8{
            "--ignore-dce-annotations",
            "run",
            entrypoint,
        };
        return expectArgs(args[1..], &expected);
    }
    if (std.mem.eql(u8, mode, "hutch-options")) {
        const entrypoint = init.environ_map.get("HUTCH_TEST_EXPECTED_ENTRYPOINT") orelse
            return error.MissingExpectedEntrypoint;
        const expected = [_][]const u8{ "run", "--silent", entrypoint };
        return expectArgs(args[1..], &expected);
    }

    try expectArgs(args[1..], &expected_test_args);
    if (std.mem.eql(u8, mode, "pass")) return;
    if (std.mem.eql(u8, mode, "fail")) std.process.exit(37);
    if (std.mem.eql(u8, mode, "signal")) {
        if (comptime builtin.os.tag == .windows) {
            std.process.exit(143);
        } else {
            try std.posix.raise(std.posix.SIG.TERM);
            return error.SignalDidNotTerminateProcess;
        }
    }
    return error.UnknownFixtureMode;
}
