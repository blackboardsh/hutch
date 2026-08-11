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
    if (args.len > 1 and std.mem.eql(u8, args[1], "--cottontail-scan-package-imports")) {
        if (init.environ_map.get("HUTCH_TEST_SCAN_MARKER")) |marker| {
            try std.Io.Dir.cwd().writeFile(init.io, .{
                .sub_path = marker,
                .data = "scanned\n",
            });
        }
        try std.Io.File.stdout().writeStreamingAll(init.io, "[]\n");
        return;
    }
    const mode = init.environ_map.get("HUTCH_TEST_FIXTURE_MODE") orelse
        return error.MissingFixtureMode;

    if (std.mem.startsWith(u8, mode, "config-")) {
        if (args.len == 2 and
            std.mem.indexOf(u8, std.fs.path.basename(args[1]), "hutch-config-loader-") != null)
        {
            const config_json = init.environ_map.get("HUTCH_TEST_CONFIG_JSON") orelse
                return error.MissingConfigJson;
            try std.Io.File.stdout().writeStreamingAll(init.io, config_json);
            try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
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
        if (std.mem.eql(u8, mode, "config-list")) return error.UnexpectedConfigCommand;
        return error.UnknownFixtureMode;
    }

    if (std.mem.eql(u8, mode, "runtime-options")) {
        const entrypoint = init.environ_map.get("HUTCH_TEST_EXPECTED_ENTRYPOINT") orelse
            return error.MissingExpectedEntrypoint;
        const marker = init.environ_map.get("HUTCH_TEST_SCAN_MARKER") orelse
            return error.MissingScanMarker;
        std.Io.Dir.cwd().access(init.io, marker, .{}) catch return error.AutoInstallWasNotPrepared;
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
        const expected = [_][]const u8{entrypoint};
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
