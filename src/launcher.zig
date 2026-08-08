const std = @import("std");
const builtin = @import("builtin");
const bootstrap_pragma = @import("bootstrap_pragma.zig");
const process_replace = @import("process_replace.zig");
const release_store = @import("release_store.zig");
const version_selector = @import("version_selector.zig");

const version = @import("version.zig").version;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const command_args = if (args.len > 1) args[1..] else args[0..0];
    const channel = activeChannel(init, allocator) catch |err| {
        return exitWithError(init.io, "invalid active release channel", err);
    };
    const pragma = bootstrap_pragma.discover(init, allocator, command_args) catch |err| {
        return exitWithError(init.io, "invalid // @hutch pragma", err);
    };
    const selector = pragma.cli orelse version_selector.parse(channel) catch unreachable;

    const engine = resolveEngine(init, allocator, selector, channel) catch |err| {
        return exitWithError(init.io, "could not resolve Hutch", err);
    };
    const exit_code = try runEngine(init, allocator, engine, channel, args);
    if (exit_code != 0) std.process.exit(exit_code);
}

fn resolveEngine(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    selector: version_selector.Selector,
    active_channel: []const u8,
) ![]const u8 {
    if (init.environ_map.get("HUTCH_ENGINE_BINARY")) |configured| {
        if (!pathExists(init.io, configured)) return error.ConfiguredHutchEngineNotFound;
        return allocator.dupe(u8, configured);
    }

    const adjacent = try adjacentEnginePath(init, allocator);
    const uses_current_release = switch (selector.kind) {
        .production, .canary => std.mem.eql(u8, selector.channel().?, active_channel),
        .version => std.mem.eql(u8, selector.value, version),
        .build => false,
    };
    if (uses_current_release and pathExists(init.io, adjacent)) return adjacent;

    const refresh = environmentFlagEnabled(init.environ_map, "DASH_RELEASE_REFRESH");
    const offline = environmentFlagEnabled(init.environ_map, "DASH_RELEASE_OFFLINE");
    const resolved = try release_store.resolve(
        init,
        allocator,
        .hutch,
        selector,
        .{ .refresh = refresh, .offline = offline },
    );
    return resolved.executable;
}

fn adjacentEnginePath(init: std.process.Init, allocator: std.mem.Allocator) ![]const u8 {
    const executable_dir = try std.process.executableDirPathAlloc(init.io, allocator);
    return std.fs.path.join(allocator, &.{
        executable_dir,
        if (builtin.os.tag == .windows) "hutch-engine.exe" else "hutch-engine",
    });
}

fn runEngine(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    engine: []const u8,
    channel: []const u8,
    original_args: []const [:0]const u8,
) !u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try appendEngineArguments(allocator, &argv, engine, original_args);

    var environment = try init.environ_map.clone(allocator);
    defer environment.deinit();
    const launcher_path = try std.process.executablePathAlloc(init.io, allocator);
    try environment.put("HUTCH_ACTIVE_CHANNEL", channel);
    try environment.put("HUTCH_LAUNCHER_PATH", launcher_path);
    try environment.put("HUTCH_LAUNCHER_VERSION", version);

    if (comptime builtin.os.tag != .windows) {
        try process_replace.replace(allocator, engine, argv.items, &environment);
        unreachable;
    }

    var child = try std.process.spawn(init.io, .{
        .argv = argv.items,
        .environ_map = &environment,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    defer child.kill(init.io);
    return termExitCode(try child.wait(init.io));
}

fn appendEngineArguments(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    engine: []const u8,
    original_args: []const [:0]const u8,
) !void {
    try argv.append(allocator, engine);
    if (original_args.len <= 1) return;
    for (original_args[1..]) |argument| try argv.append(allocator, argument);
}

fn activeChannel(init: std.process.Init, allocator: std.mem.Allocator) ![]const u8 {
    if (init.environ_map.get("HUTCH_ACTIVE_CHANNEL")) |channel| {
        return version_selector.normalizeChannel(channel);
    }

    const executable = try std.process.executablePathAlloc(init.io, allocator);
    return channelForExecutableName(std.fs.path.basename(executable));
}

fn channelForExecutableName(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "hutch-canary") or
        std.mem.eql(u8, name, "hutch-canary.exe"))
    {
        return "canary";
    }
    return "production";
}

fn environmentFlagEnabled(environment: *const std.process.Environ.Map, name: []const u8) bool {
    const value = environment.get(name) orelse return false;
    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes");
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn termExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| @intCast(@min(code, 255)),
        .signal => |signal| signal: {
            if (builtin.os.tag != .windows) std.posix.raise(signal) catch {};
            break :signal @intCast(@min(128 + @intFromEnum(signal), 255));
        },
        .stopped => 1,
        .unknown => 1,
    };
}

fn exitWithError(io: std.Io, context: []const u8, err: anyerror) void {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    writer.interface.print(
        "hutch: {s}: {s}\n",
        .{ context, @errorName(err) },
    ) catch {};
    writer.interface.flush() catch {};
    std.process.exit(1);
}

test "launcher only reuses an adjacent release for matching selectors" {
    const production = try version_selector.parse("production");
    const exact = try version_selector.parse(version);
    const other = try version_selector.parse("999.0.0");
    try std.testing.expect(production.channel() != null);
    try std.testing.expectEqualStrings(version, exact.value);
    try std.testing.expect(!std.mem.eql(u8, other.value, version));
}

test "global launcher aliases select independent channels" {
    try std.testing.expectEqualStrings("production", channelForExecutableName("hutch"));
    try std.testing.expectEqualStrings("production", channelForExecutableName("hutch.exe"));
    try std.testing.expectEqualStrings("canary", channelForExecutableName("hutch-canary"));
    try std.testing.expectEqualStrings("canary", channelForExecutableName("hutch-canary.exe"));
}

test "stable active channel uses the production release" {
    try std.testing.expectEqualStrings(
        "production",
        try version_selector.normalizeChannel("stable"),
    );
}

test "launcher preserves the complete test invocation for the engine" {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);

    const original_args = [_][:0]const u8{
        "hutch",
        "test",
        "tests/one.test.ts",
        "tests/two test.ts",
        "--test-name-pattern",
        "exact value",
        "--bail=3",
    };
    try appendEngineArguments(
        std.testing.allocator,
        &argv,
        "/tmp/hutch-engine",
        &original_args,
    );

    try std.testing.expectEqual(@as(usize, original_args.len), argv.items.len);
    try std.testing.expectEqualStrings("/tmp/hutch-engine", argv.items[0]);
    for (original_args[1..], argv.items[1..]) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
}
