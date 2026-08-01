const std = @import("std");
const builtin = @import("builtin");

const expected_args = [_][]const u8{
    "test",
    "tests/pass fixture.test.ts",
    "tests/second.test.ts",
    "--test-name-pattern",
    "exact value",
    "--bail=3",
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != expected_args.len + 1) return error.UnexpectedArgumentCount;
    for (expected_args, args[1..]) |expected, actual| {
        if (!std.mem.eql(u8, expected, actual)) return error.UnexpectedArgument;
    }

    const mode = init.environ_map.get("HUTCH_TEST_FIXTURE_MODE") orelse
        return error.MissingFixtureMode;
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
