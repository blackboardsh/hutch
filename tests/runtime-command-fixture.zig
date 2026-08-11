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

fn expectPrivateShellLauncher(init: std.process.Init) !void {
    const path_key = if (builtin.os.tag == .windows) "Path" else "PATH";
    const path = init.environ_map.get(path_key) orelse
        init.environ_map.get("PATH") orelse return error.MissingPath;
    var entries = std.mem.splitScalar(u8, path, std.fs.path.delimiter);
    const shim_dir = entries.first();
    try expectPrivateTempDirectory(init, shim_dir, "hutch-shell-launcher-");
    const launcher = try std.fs.path.join(init.arena.allocator(), &.{
        shim_dir,
        if (builtin.os.tag == .windows) "hutch.exe" else "hutch",
    });
    const stat = try std.Io.Dir.cwd().statFile(init.io, launcher, .{
        .follow_symlinks = false,
    });
    if (stat.kind != .file) return error.PrivateShellLauncherMissing;
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
        if (args.len == 2 and std.mem.eql(u8, std.fs.path.basename(args[1]), "load.mjs")) {
            const loader_dir = std.fs.path.dirname(args[1]) orelse return error.InvalidConfigLoaderPath;
            try expectPrivateTempDirectory(init, loader_dir, "hutch-config-loader-");
            const config_json = init.environ_map.get("HUTCH_TEST_CONFIG_JSON") orelse
                return error.MissingConfigJson;
            if (std.mem.eql(u8, mode, "config-console-log")) {
                try std.Io.File.stdout().writeStreamingAll(init.io, "config console output\n");
            }

            const loader_source = try std.Io.Dir.cwd().readFileAlloc(
                init.io,
                args[1],
                init.arena.allocator(),
                .limited(1024 * 1024),
            );
            const result_marker = "config.json";
            if (std.mem.indexOf(u8, loader_source, result_marker) == null) {
                return error.ConfigResultSideChannelMissing;
            }
            const result_path = try std.fs.path.join(init.arena.allocator(), &.{ loader_dir, result_marker });
            try std.Io.Dir.cwd().writeFile(init.io, .{
                .sub_path = result_path,
                .data = config_json,
            });
            return;
        }

        if (args.len >= 3 and std.mem.eql(u8, args[1], "--hutch-shell")) {
            try expectConfiguredCwd(init);
            try expectPrivateShellLauncher(init);
            const command = args[2];
            const appended = args[3..];
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
