const std = @import("std");
const package_manager = @import("package_manager/root.zig");

const extensions = [_][]const u8{
    ".tsx", ".jsx", ".mts", ".ts", ".cts", ".js", ".mjs", ".cjs", ".json",
};

fn pathIsFile(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

pub fn pathIsDirectory(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .directory;
}

fn fallbackExtensions(path: []const u8) []const []const u8 {
    const extension = std.fs.path.extension(path);
    if (std.mem.eql(u8, extension, ".mjs")) return &.{".mts"};
    if (std.mem.eql(u8, extension, ".js") or std.mem.eql(u8, extension, ".jsx")) {
        return &.{ ".ts", ".tsx", ".mts" };
    }
    return &.{};
}

pub fn resolve(
    io: std.Io,
    allocator: std.mem.Allocator,
    requested: []const u8,
) !?[:0]const u8 {
    return resolveDepth(io, allocator, requested, 0);
}

fn resolveDepth(
    io: std.Io,
    allocator: std.mem.Allocator,
    requested: []const u8,
    depth: usize,
) !?[:0]const u8 {
    if (requested.len == 0 or depth > 8) return null;
    const trailing_separator = requested[requested.len - 1] == '/' or
        requested[requested.len - 1] == '\\';

    if (!trailing_separator) {
        if (pathIsFile(io, requested)) return try allocator.dupeZ(u8, requested);

        const extension = std.fs.path.extension(requested);
        if (extension.len > 0) {
            const stem = requested[0 .. requested.len - extension.len];
            for (fallbackExtensions(requested)) |replacement| {
                const candidate = try std.mem.concat(allocator, u8, &.{ stem, replacement });
                if (pathIsFile(io, candidate)) return try allocator.dupeZ(u8, candidate);
            }
        } else {
            for (extensions) |candidate_extension| {
                const candidate = try std.mem.concat(allocator, u8, &.{ requested, candidate_extension });
                if (pathIsFile(io, candidate)) return try allocator.dupeZ(u8, candidate);
            }
        }
    }

    if (!pathIsDirectory(io, requested)) return null;
    const package_json = try std.fs.path.join(allocator, &.{ requested, "package.json" });
    if (std.Io.Dir.cwd().readFileAlloc(
        io,
        package_json,
        allocator,
        .limited(16 * 1024 * 1024),
    ) catch null) |source| {
        if (package_manager.lockfile.normalizeJsonc(allocator, source) catch null) |normalized| {
            if (std.json.parseFromSliceLeaky(std.json.Value, allocator, normalized, .{
                .duplicate_field_behavior = .use_last,
            }) catch null) |manifest| {
                if (manifest == .object) {
                    if (manifest.object.get("main")) |main_value| {
                        if (main_value == .string and main_value.string.len > 0) {
                            const main_path = if (std.fs.path.isAbsolute(main_value.string))
                                main_value.string
                            else
                                try std.fs.path.join(allocator, &.{ requested, main_value.string });
                            if (try resolveDepth(io, allocator, main_path, depth + 1)) |resolved| {
                                return resolved;
                            }
                        }
                    }
                }
            }
        }
    }

    for (extensions) |candidate_extension| {
        const basename = try std.mem.concat(allocator, u8, &.{ "index", candidate_extension });
        const candidate = try std.fs.path.join(allocator, &.{ requested, basename });
        if (pathIsFile(io, candidate)) return try allocator.dupeZ(u8, candidate);
    }
    return null;
}

test "entrypoint resolution matches Bun file and directory priority" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    try tmp.dir.createDirPath(io, "folderandfile");
    try tmp.dir.writeFile(io, .{ .sub_path = "folderandfile.js", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "folderandfile/index.js", .data = "" });
    try tmp.dir.createDirPath(io, "package-main");
    try tmp.dir.writeFile(io, .{
        .sub_path = "package-main/package.json",
        .data = "{ // comment\n \"main\": \"entry.ts\", }\n",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "package-main/entry.ts", .data = "" });

    const ambiguous = try std.fs.path.join(allocator, &.{ root, "folderandfile" });
    defer allocator.free(ambiguous);
    const ambiguous_resolved = (try resolve(io, allocator, ambiguous)).?;
    defer allocator.free(ambiguous_resolved);
    try std.testing.expect(std.mem.endsWith(u8, ambiguous_resolved, "folderandfile.js"));

    const directory = try std.fmt.allocPrint(allocator, "{s}{c}", .{ ambiguous, std.fs.path.sep });
    defer allocator.free(directory);
    const directory_resolved = (try resolve(io, allocator, directory)).?;
    defer allocator.free(directory_resolved);
    try std.testing.expect(std.mem.endsWith(u8, directory_resolved, "folderandfile/index.js"));

    const package_main = try std.fs.path.join(allocator, &.{ root, "package-main" });
    defer allocator.free(package_main);
    const package_resolved = (try resolve(io, allocator, package_main)).?;
    defer allocator.free(package_resolved);
    try std.testing.expect(std.mem.endsWith(u8, package_resolved, "package-main/entry.ts"));
}
