//! Keep private configuration loaders ahead of ambient runtime preloads.
const std = @import("std");

pub fn environment(allocator: std.mem.Allocator, original: *const std.process.Environ.Map) !std.process.Environ.Map {
    var result = try original.clone(allocator);
    _ = result.swapRemove("BUN_OPTIONS");
    _ = result.swapRemove("NODE_OPTIONS");
    return result;
}

/// Restore the calling environment only after the loader has hidden its
/// private argv, and before importing any project-controlled configuration.
pub fn restorationSource(allocator: std.mem.Allocator, original: *const std.process.Environ.Map) ![]u8 {
    const values = try std.json.Stringify.valueAlloc(allocator, .{
        .BUN_OPTIONS = original.get("BUN_OPTIONS"),
        .NODE_OPTIONS = original.get("NODE_OPTIONS"),
    }, .{});
    defer allocator.free(values);
    return std.fmt.allocPrint(
        allocator,
        "for (const [name, value] of Object.entries({s})) {{\n" ++
            "  if (value === null) delete process.env[name]; else process.env[name] = value;\n" ++
            "}}\n",
        .{values},
    );
}

pub fn bunArguments(allocator: std.mem.Allocator, binary: []const u8, loader: []const u8, bunfig: []const u8) ![]const []const u8 {
    // Bun's optional --config value must remain in the same argv element.
    const config_arg = try std.fmt.allocPrint(allocator, "--config={s}", .{bunfig});
    const argv = try allocator.alloc([]const u8, 4);
    argv[0..4].* = .{ binary, "--no-env-file", config_arg, loader };
    return argv;
}
