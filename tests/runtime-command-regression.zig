const std = @import("std");
const builtin = @import("builtin");

const invocation = [_][]const u8{
    "test",
    "tests/pass fixture.test.ts",
    "tests/second.test.ts",
    "--test-name-pattern",
    "exact value",
    "--bail=3",
};

fn run(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    launcher: []const u8,
    engine: []const u8,
    runtime: []const u8,
    mode: []const u8,
) !std.process.Child.Term {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, launcher);
    try argv.appendSlice(allocator, &invocation);

    var environment = try init.environ_map.clone(allocator);
    defer environment.deinit();
    try environment.put("HUTCH_ENGINE_BINARY", engine);
    try environment.put("DASH_COTTONTAIL", runtime);
    try environment.put("HUTCH_TEST_FIXTURE_MODE", mode);
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

fn expectExit(term: std.process.Child.Term, expected: u8) !void {
    switch (term) {
        .exited => |actual| if (actual != expected) return error.UnexpectedExitCode,
        else => return error.UnexpectedTermination,
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 4) return error.InvalidArguments;

    const launcher = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[1], allocator);
    const engine = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[2], allocator);
    const runtime = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[3], allocator);

    try expectExit(try run(init, allocator, launcher, engine, runtime, "pass"), 0);
    try expectExit(try run(init, allocator, launcher, engine, runtime, "fail"), 37);

    const signal_term = try run(init, allocator, launcher, engine, runtime, "signal");
    if (comptime builtin.os.tag == .windows) {
        try expectExit(signal_term, 143);
    } else switch (signal_term) {
        .signal => |signal| if (signal != std.posix.SIG.TERM) return error.UnexpectedSignal,
        else => return error.SignalWasNotPropagated,
    }
}
