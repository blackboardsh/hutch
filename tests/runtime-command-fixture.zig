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

fn expectArgs(actual: []const [:0]const u8, expected: []const []const u8) !void {
    if (actual.len != expected.len) return error.UnexpectedArgumentCount;
    for (expected, actual) |expected_arg, actual_arg| {
        if (!std.mem.eql(u8, expected_arg, actual_arg)) return error.UnexpectedArgument;
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
        if (args.len == 2 and std.mem.eql(u8, std.fs.path.basename(args[1]), "load.mjs")) {
            const loader_dir = std.fs.path.dirname(args[1]) orelse return error.InvalidConfigLoaderPath;
            if (!std.mem.startsWith(u8, std.fs.path.basename(loader_dir), "hutch-config-loader-")) {
                return error.ConfigLoaderDirectoryWasNotPrivate;
            }
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

        const executable = std.fs.path.basename(args[0]);
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
