const std = @import("std");
const builtin = @import("builtin");

pub const state_relative_root = "state/cache-v2";

pub const GraphLock = struct {
    file: std.Io.File,

    pub fn close(self: GraphLock, io: std.Io) void {
        self.file.close(io);
    }
};

pub const ObjectLease = struct {
    file: std.Io.File,

    pub fn close(self: ObjectLease, io: std.Io) void {
        self.file.close(io);
    }
};

pub fn acquireGraph(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    mode: std.Io.File.Lock,
) !GraphLock {
    const state_parent = try std.fs.path.join(allocator, &.{ home, "state" });
    try ensureDirectoryWithin(io, allocator, home, state_parent, error.InvalidCacheStatePath);
    const state_root = try std.fs.path.join(allocator, &.{ home, state_relative_root });
    try ensureDirectoryWithin(io, allocator, home, state_root, error.InvalidCacheStatePath);
    const lock_path = try std.fs.path.join(allocator, &.{ state_root, "graph.lock" });
    try initializePersistentFile(io, lock_path);
    if (!try pathResolvesWithin(io, allocator, home, lock_path)) return error.InvalidCacheStatePath;
    return .{ .file = try std.Io.Dir.cwd().openFile(io, lock_path, .{
        .mode = .read_write,
        .lock = mode,
        .follow_symlinks = false,
    }) };
}

/// The caller must hold the shared graph lock and must have already validated
/// `root` as an immutable Hutch-managed object inside `home`.
pub fn acquireObjectLease(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    root: []const u8,
) !ObjectLease {
    if (!try pathResolvesWithin(io, allocator, home, root)) return error.InvalidManagedObjectPath;
    const lock_path = try std.mem.concat(allocator, u8, &.{ root, ".lock" });
    try initializePersistentFile(io, lock_path);
    if (!try pathResolvesWithin(io, allocator, home, lock_path)) return error.InvalidManagedObjectPath;
    return .{ .file = try std.Io.Dir.cwd().openFile(io, lock_path, .{
        .mode = .read_write,
        .lock = .shared,
        .follow_symlinks = false,
    }) };
}

pub fn tryAcquireObjectExclusive(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
) !?std.Io.File {
    const lock_path = try std.mem.concat(allocator, u8, &.{ root, ".lock" });
    return std.Io.Dir.cwd().openFile(io, lock_path, .{
        .mode = .read_write,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound, error.WouldBlock, error.AccessDenied, error.PermissionDenied => null,
        else => return err,
    };
}

pub fn initializePersistentFile(io: std.Io, path: []const u8) !void {
    const initializer: ?std.Io.File = std.Io.Dir.cwd().createFile(io, path, .{
        .read = true,
        .truncate = false,
        .exclusive = true,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => null,
        else => return err,
    };
    if (initializer) |file| file.close(io);
}

fn pathResolvesWithin(
    io: std.Io,
    allocator: std.mem.Allocator,
    parent: []const u8,
    child: []const u8,
) !bool {
    const canonical_parent = try std.Io.Dir.cwd().realPathFileAlloc(io, parent, allocator);
    const canonical_child = try std.Io.Dir.cwd().realPathFileAlloc(io, child, allocator);
    const canonical_cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    const lexical_parent = try std.fs.path.resolve(allocator, &.{ canonical_cwd, parent });
    const lexical_child = try std.fs.path.resolve(allocator, &.{ canonical_cwd, child });
    const relative = try std.fs.path.relative(allocator, canonical_cwd, null, lexical_parent, lexical_child);
    if (relative.len == 0 or std.fs.path.isAbsolute(relative)) return false;
    const expected_child = try std.fs.path.resolve(allocator, &.{ canonical_parent, relative });
    if (!pathHasParent(expected_child, canonical_parent)) return false;
    return pathEqual(expected_child, canonical_child);
}

fn pathHasParent(child: []const u8, parent: []const u8) bool {
    if (child.len <= parent.len or !pathEqual(child[0..parent.len], parent)) return false;
    return std.fs.path.isSep(child[parent.len]);
}

fn pathEqual(lhs: []const u8, rhs: []const u8) bool {
    return if (builtin.os.tag == .windows)
        std.ascii.eqlIgnoreCase(lhs, rhs)
    else
        std.mem.eql(u8, lhs, rhs);
}

fn ensureDirectoryWithin(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    path: []const u8,
    comptime invalid_path_error: anyerror,
) !void {
    const existing: ?std.Io.File.Stat = std.Io.Dir.cwd().statFile(io, path, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |stat| {
        if (stat.kind != .directory) return invalid_path_error;
    }
    try std.Io.Dir.cwd().createDirPath(io, path);
    if (!try pathResolvesWithin(io, allocator, home, path)) return invalid_path_error;
}

test "a shared object lease excludes cache detachment until process release" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const relative = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const fixture = try std.Io.Dir.cwd().realPathFileAlloc(io, relative, allocator);
    const home = try std.fs.path.join(allocator, &.{ fixture, "dash-home" });
    const root = try std.fs.path.join(allocator, &.{
        home,
        "products",
        "hutch",
        "1.0.0",
        "0123456789abcdef0123456789abcdef01234567",
        "macos-arm64",
    });
    try std.Io.Dir.cwd().createDirPath(io, root);

    const graph = try acquireGraph(io, allocator, home, .shared);
    const lease = try acquireObjectLease(io, allocator, home, root);
    graph.close(io);
    try std.testing.expect((try tryAcquireObjectExclusive(io, allocator, root)) == null);

    lease.close(io);
    const exclusive = (try tryAcquireObjectExclusive(io, allocator, root)).?;
    exclusive.close(io);
}
