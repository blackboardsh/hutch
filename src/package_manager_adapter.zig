const std = @import("std");

pub const Name = enum {
    npm,
    bun,
    pnpm,
    yarn,

    pub fn command(self: Name) []const u8 {
        return @tagName(self);
    }
};

pub const Selection = struct {
    name: Name,
    executable: []const u8,
};

pub fn defaultSelection() Selection {
    return .{ .name = .npm, .executable = "npm" };
}

fn parseName(value: std.json.Value) !Name {
    if (value != .string) return error.InvalidPackageManagerConfig;
    return std.meta.stringToEnum(Name, value.string) orelse
        error.UnsupportedPackageManager;
}

pub fn fromConfig(root: std.json.Value) !Selection {
    const value = switch (root) {
        .object => |object| object.get("packageManager") orelse return defaultSelection(),
        else => return defaultSelection(),
    };

    return switch (value) {
        .string => .{
            .name = try parseName(value),
            .executable = value.string,
        },
        .object => |object| objectSelection: {
            const name = try parseName(object.get("name") orelse
                return error.InvalidPackageManagerConfig);
            const executable = if (object.get("executable")) |configured| executable: {
                if (configured != .string or
                    std.mem.trim(u8, configured.string, " \r\n\t").len == 0)
                {
                    return error.InvalidPackageManagerConfig;
                }
                break :executable configured.string;
            } else name.command();
            break :objectSelection .{
                .name = name,
                .executable = executable,
            };
        },
        else => error.InvalidPackageManagerConfig,
    };
}

pub fn run(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    selection: Selection,
    subcommand: ?[]const u8,
    forwarded_args: []const [:0]const u8,
) !std.process.Child.Term {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, selection.executable);
    if (subcommand) |command| try argv.append(allocator, command);
    for (forwarded_args) |arg| try argv.append(allocator, arg);

    // Keep package managers on the native argv path. On Windows, Zig's
    // process implementation resolves .cmd/.bat through PATHEXT and routes
    // them through its hardened batch serializer. That path disables delayed
    // expansion, protects cmd.exe metacharacters, and rejects NUL/CR/LF rather
    // than silently changing argv. Pre-wrapping this in cmd.exe or a shell
    // would bypass those guarantees.
    var child = try std.process.spawn(init.io, .{
        .argv = argv.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    defer child.kill(init.io);
    return try child.wait(init.io);
}

fn expectSelectionForTest(
    source: []const u8,
    expected_name: Name,
    expected_executable: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), source, .{});
    const selection = try fromConfig(parsed);
    try std.testing.expectEqual(expected_name, selection.name);
    try std.testing.expectEqualStrings(expected_executable, selection.executable);
}

fn expectConfigErrorForTest(expected: anyerror, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), source, .{});
    try std.testing.expectError(expected, fromConfig(parsed));
}

test "package manager defaults to external npm" {
    try expectSelectionForTest("{}", .npm, "npm");
    try expectSelectionForTest("null", .npm, "npm");
}

test "package manager accepts the supported external managers" {
    inline for (.{ Name.npm, Name.bun, Name.pnpm, Name.yarn }) |expected| {
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"packageManager\":\"{s}\"}}",
            .{@tagName(expected)},
        );
        defer std.testing.allocator.free(source);
        try expectSelectionForTest(source, expected, @tagName(expected));
    }
}

test "package manager object supports an explicit executable" {
    try expectSelectionForTest(
        "{\"packageManager\":{\"name\":\"pnpm\",\"executable\":\"/opt/tools/pnpm-project\"}}",
        .pnpm,
        "/opt/tools/pnpm-project",
    );
    try expectSelectionForTest(
        "{\"packageManager\":{\"name\":\"bun\"}}",
        .bun,
        "bun",
    );
}

test "package manager rejects unsupported or malformed selections" {
    try expectConfigErrorForTest(
        error.UnsupportedPackageManager,
        "{\"packageManager\":\"deno\"}",
    );
    try expectConfigErrorForTest(
        error.InvalidPackageManagerConfig,
        "{\"packageManager\":42}",
    );
    try expectConfigErrorForTest(
        error.InvalidPackageManagerConfig,
        "{\"packageManager\":{\"executable\":\"npm\"}}",
    );
    try expectConfigErrorForTest(
        error.InvalidPackageManagerConfig,
        "{\"packageManager\":{\"name\":\"npm\",\"executable\":\"  \"}}",
    );
}
