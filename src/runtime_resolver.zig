const std = @import("std");
const builtin = @import("builtin");
const bootstrap_pragma = @import("bootstrap_pragma.zig");
const release_store = @import("release_store.zig");
const version_selector = @import("version_selector.zig");

pub const Resolution = struct {
    root: []const u8,
    executable: []const u8,
    version: ?[]const u8 = null,
    revision: ?[]const u8 = null,
    local: bool,
};

pub fn resolveCottontail(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    command_args: []const [:0]const u8,
) !Resolution {
    if (init.environ_map.get("DASH_COTTONTAIL") orelse
        init.environ_map.get("COTTONTAIL_BINARY")) |configured|
    {
        return localResolution(init.io, allocator, configured);
    }

    if (environmentFlagEnabled(init.environ_map, "DASH_USE_LOCAL_COTTONTAIL")) {
        return resolveLocalCheckout(init, allocator);
    }

    const selector = if (init.environ_map.get("DASH_COTTONTAIL_SELECTOR")) |configured|
        try version_selector.parse(configured)
    else blk: {
        const pragma = try bootstrap_pragma.discover(init, allocator, command_args);
        if (pragma.cottontail) |selected| break :blk selected;
        const channel = init.environ_map.get("HUTCH_ACTIVE_CHANNEL") orelse "production";
        break :blk try version_selector.parse(channel);
    };

    const release = try release_store.resolve(
        init,
        allocator,
        .cottontail,
        selector,
        .{
            .refresh = environmentFlagEnabled(init.environ_map, "DASH_RELEASE_REFRESH"),
            .offline = environmentFlagEnabled(init.environ_map, "DASH_RELEASE_OFFLINE"),
        },
    );
    return .{
        .root = release.root,
        .executable = release.executable,
        .version = release.version,
        .revision = release.revision,
        .local = false,
    };
}

fn resolveLocalCheckout(
    init: std.process.Init,
    allocator: std.mem.Allocator,
) !Resolution {
    if (init.environ_map.get("DASH_LOCAL_COTTONTAIL_ROOT") orelse
        init.environ_map.get("COTTONTAIL_ROOT")) |root|
    {
        const executable = try std.fs.path.join(allocator, &.{
            root,
            "zig-out",
            "bin",
            cottontailBinaryName(),
        });
        if (!pathExists(init.io, executable)) return error.LocalCottontailNotFound;
        return .{
            .root = try allocator.dupe(u8, root),
            .executable = executable,
            .local = true,
        };
    }

    const executable_dir = try std.process.executableDirPathAlloc(init.io, allocator);
    const root = try std.fs.path.join(allocator, &.{
        executable_dir,
        "..",
        "..",
        "..",
        "..",
        "cottontail",
    });
    const executable = try std.fs.path.join(allocator, &.{
        root,
        "zig-out",
        "bin",
        cottontailBinaryName(),
    });
    if (!pathExists(init.io, executable)) return error.LocalCottontailNotFound;
    return .{
        .root = root,
        .executable = executable,
        .local = true,
    };
}

fn localResolution(
    io: std.Io,
    allocator: std.mem.Allocator,
    configured: []const u8,
) !Resolution {
    const executable = if (std.fs.path.isAbsolute(configured))
        try allocator.dupe(u8, configured)
    else
        try std.Io.Dir.cwd().realPathFileAlloc(io, configured, allocator);
    if (!pathExists(io, executable)) return error.ConfiguredCottontailNotFound;

    const bin_dir = std.fs.path.dirname(executable) orelse return error.InvalidCottontailPath;
    const root = std.fs.path.dirname(bin_dir) orelse bin_dir;
    return .{
        .root = try allocator.dupe(u8, root),
        .executable = executable,
        .local = true,
    };
}

fn cottontailBinaryName() []const u8 {
    return if (builtin.os.tag == .windows) "cottontail.exe" else "cottontail";
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

test "runtime resolver binary names match the host" {
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("cottontail.exe", cottontailBinaryName());
    } else {
        try std.testing.expectEqualStrings("cottontail", cottontailBinaryName());
    }
}
