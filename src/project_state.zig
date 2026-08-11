const std = @import("std");

pub const OpenMode = enum {
    existing,
    create,
};

/// Open the project-owned `.hutch` directory without following the project
/// root or state directory through a symlink, junction, or other reparse
/// point. Callers should keep the returned handle open while accessing state.
pub fn open(
    io: std.Io,
    project_root: []const u8,
    mode: OpenMode,
    options: std.Io.Dir.OpenOptions,
) !std.Io.Dir {
    if (!std.fs.path.isAbsolute(project_root)) return error.ProjectRootNotAbsolute;

    var project = try openDirectoryNoFollow(std.Io.Dir.cwd(), io, project_root, .{});
    defer project.close(io);
    return openChild(io, project, ".hutch", mode, options);
}

/// Open one literal child directory without following it. The name is kept to
/// a single component so every project-state ancestor is checked separately.
pub fn openChild(
    io: std.Io,
    parent: std.Io.Dir,
    name: []const u8,
    mode: OpenMode,
    options: std.Io.Dir.OpenOptions,
) !std.Io.Dir {
    try validateName(name);
    if (mode == .create) {
        parent.createDir(io, name, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    return openDirectoryNoFollow(parent, io, name, options);
}

pub fn atomicWrite(
    io: std.Io,
    allocator: std.mem.Allocator,
    directory: std.Io.Dir,
    name: []const u8,
    bytes: []const u8,
) !void {
    try validateName(name);

    for (0..32) |_| {
        var random: [12]u8 = undefined;
        io.random(&random);
        const suffix = std.fmt.bytesToHex(random, .lower);
        const temporary = try std.fmt.allocPrint(allocator, ".{s}.tmp-{s}", .{ name, suffix });
        const file = directory.createFile(io, temporary, .{
            .read = true,
            .truncate = false,
            .exclusive = true,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        errdefer directory.deleteFile(io, temporary) catch {};
        {
            defer file.close(io);
            try file.writeStreamingAll(io, bytes);
        }
        try directory.rename(temporary, directory, name, io);
        return;
    }
    return error.ProjectStateTemporaryNameCollision;
}

pub fn readFileAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    directory: std.Io.Dir,
    name: []const u8,
    limit: std.Io.Limit,
) ![]u8 {
    try validateName(name);
    var file = try directory.openFile(io, name, .{
        .allow_directory = false,
        .follow_symlinks = false,
    });
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemainingAlignedSentinel(
        allocator,
        limit,
        .of(u8),
        null,
    ) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
}

fn openDirectoryNoFollow(
    parent: std.Io.Dir,
    io: std.Io,
    path: []const u8,
    options: std.Io.Dir.OpenOptions,
) !std.Io.Dir {
    var no_follow_options = options;
    no_follow_options.follow_symlinks = false;
    const directory = parent.openDir(io, path, no_follow_options) catch |err| switch (err) {
        error.NotDir, error.SymLinkLoop => return error.InvalidProjectStatePath,
        else => return err,
    };
    errdefer directory.close(io);
    const stat = try directory.stat(io);
    if (stat.kind != .directory) return error.InvalidProjectStatePath;
    return directory;
}

fn validateName(name: []const u8) !void {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
        return error.InvalidProjectStateName;
    }
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return error.InvalidProjectStateName;
}
