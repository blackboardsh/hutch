const std = @import("std");

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
    if (requested.len == 0) return null;
    const trailing_separator = requested[requested.len - 1] == '/' or
        requested[requested.len - 1] == '\\';

    if (!trailing_separator) {
        if (pathIsFile(io, requested)) return try allocator.dupeZ(u8, requested);

        const extension = std.fs.path.extension(requested);
        if (extension.len > 0) {
            const stem = requested[0 .. requested.len - extension.len];
            for (fallbackExtensions(requested)) |replacement| {
                const candidate = try std.mem.concat(allocator, u8, &.{ stem, replacement });
                defer allocator.free(candidate);
                if (pathIsFile(io, candidate)) return try allocator.dupeZ(u8, candidate);
            }
        } else {
            for (extensions) |candidate_extension| {
                const candidate = try std.mem.concat(allocator, u8, &.{ requested, candidate_extension });
                defer allocator.free(candidate);
                if (pathIsFile(io, candidate)) return try allocator.dupeZ(u8, candidate);
            }
        }
    }

    // Cottontail owns directory entrypoint semantics, including package.json
    // `main` and index-file resolution. Hutch only needs to identify that the
    // argument is an existing runtime path rather than a configured task name.
    if (pathIsDirectory(io, requested)) return try allocator.dupeZ(u8, requested);
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
        .data = "{ this manifest is intentionally invalid\n",
    });

    const ambiguous = try std.fs.path.join(allocator, &.{ root, "folderandfile" });
    defer allocator.free(ambiguous);
    const ambiguous_resolved = (try resolve(io, allocator, ambiguous)).?;
    defer allocator.free(ambiguous_resolved);
    try std.testing.expect(std.mem.endsWith(u8, ambiguous_resolved, "folderandfile.js"));

    const directory = try std.fmt.allocPrint(allocator, "{s}{c}", .{ ambiguous, std.fs.path.sep });
    defer allocator.free(directory);
    const directory_resolved = (try resolve(io, allocator, directory)).?;
    defer allocator.free(directory_resolved);
    try std.testing.expectEqualStrings(directory, directory_resolved);

    const package_main = try std.fs.path.join(allocator, &.{ root, "package-main" });
    defer allocator.free(package_main);
    const package_resolved = (try resolve(io, allocator, package_main)).?;
    defer allocator.free(package_resolved);
    try std.testing.expectEqualStrings(package_main, package_resolved);
}
