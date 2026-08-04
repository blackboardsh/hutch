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
        const marker = try std.fmt.allocPrint(allocator, "{s}.scan", .{entrypoint});
        try environment.put("HUTCH_TEST_SCAN_MARKER", marker);
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
    const scan_marker = try std.fmt.allocPrint(allocator, "{s}.scan", .{entrypoint});
    std.Io.Dir.cwd().deleteFile(init.io, scan_marker) catch {};
    defer std.Io.Dir.cwd().deleteFile(init.io, scan_marker) catch {};
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
}
