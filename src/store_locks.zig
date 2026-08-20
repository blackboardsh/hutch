const std = @import("std");
const builtin = @import("builtin");
const file_locks = @import("file_locks.zig");

pub const state_relative_root = "state";

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

    /// Keeps the lease alive across the POSIX exec paths used for Cottontail
    /// and runtime handoff. Windows retains the lease in the spawning parent.
    pub fn makeInheritable(self: ObjectLease, io: std.Io) !void {
        _ = io;
        if (builtin.os.tag == .windows) return;
        const flags = while (true) {
            const rc = std.posix.system.fcntl(self.file.handle, std.posix.F.GETFD, @as(usize, 0));
            switch (std.posix.errno(rc)) {
                .SUCCESS => break @as(usize, @intCast(rc)),
                .INTR => continue,
                else => |err| return std.posix.unexpectedErrno(err),
            }
        };
        while (true) {
            const rc = std.posix.system.fcntl(
                self.file.handle,
                std.posix.F.SETFD,
                flags & ~@as(usize, std.posix.FD_CLOEXEC),
            );
            switch (std.posix.errno(rc)) {
                .SUCCESS => return,
                .INTR => continue,
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }
    }
};

pub fn acquireGraph(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    mode: std.Io.File.Lock,
) !GraphLock {
    const state_root = try std.fs.path.join(allocator, &.{ home, state_relative_root });
    try ensureDirectoryWithin(io, allocator, home, state_root, error.InvalidStoreStatePath);
    const locks_root = try std.fs.path.join(allocator, &.{ state_root, "locks" });
    try ensureDirectoryWithin(io, allocator, home, locks_root, error.InvalidStoreStatePath);
    const lock_path = try std.fs.path.join(allocator, &.{ locks_root, "graph.lock" });
    try initializePersistentFile(io, lock_path);
    if (!try pathResolvesWithin(io, allocator, home, lock_path)) return error.InvalidStoreStatePath;
    return .{ .file = try file_locks.openBlocking(
        io,
        std.Io.Dir.cwd(),
        lock_path,
        .read_write,
        mode,
    ) };
}

/// Acquires the store graph exclusively without waiting. Automatic
/// maintenance uses this so an ordinary Hutch invocation never stalls behind
/// an active resolver, build, or another maintenance command.
pub fn tryAcquireGraphExclusive(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
) !?GraphLock {
    const state_root = try std.fs.path.join(allocator, &.{ home, state_relative_root });
    try ensureDirectoryWithin(io, allocator, home, state_root, error.InvalidStoreStatePath);
    const locks_root = try std.fs.path.join(allocator, &.{ state_root, "locks" });
    try ensureDirectoryWithin(io, allocator, home, locks_root, error.InvalidStoreStatePath);
    const lock_path = try std.fs.path.join(allocator, &.{ locks_root, "graph.lock" });
    try initializePersistentFile(io, lock_path);
    if (!try pathResolvesWithin(io, allocator, home, lock_path)) return error.InvalidStoreStatePath;
    const file = file_locks.openNonblocking(
        io,
        std.Io.Dir.cwd(),
        lock_path,
        .read_write,
        .exclusive,
    ) catch |err| switch (err) {
        error.WouldBlock, error.AccessDenied, error.PermissionDenied => return null,
        else => return err,
    };
    return .{ .file = file };
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
    return .{ .file = try file_locks.openBlocking(
        io,
        std.Io.Dir.cwd(),
        lock_path,
        .read_write,
        .shared,
    ) };
}

pub fn tryAcquireObjectExclusive(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
) !?std.Io.File {
    const lock_path = try std.mem.concat(allocator, u8, &.{ root, ".lock" });
    return file_locks.openNonblocking(
        io,
        std.Io.Dir.cwd(),
        lock_path,
        .read_write,
        .exclusive,
    ) catch |err| switch (err) {
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

test "a shared object lease excludes store detachment until process release" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const relative = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const fixture = try std.Io.Dir.cwd().realPathFileAlloc(io, relative, allocator);
    const home = try std.fs.path.join(allocator, &.{ fixture, "hutch-home" });
    const root = try std.fs.path.join(allocator, &.{
        home,
        "releases",
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

test "automatic graph acquisition never waits on a live user" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const relative = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const fixture = try std.Io.Dir.cwd().realPathFileAlloc(io, relative, allocator);
    const home = try std.fs.path.join(allocator, &.{ fixture, "hutch-home" });

    const shared = try acquireGraph(io, allocator, home, .shared);
    try std.testing.expect((try tryAcquireGraphExclusive(io, allocator, home)) == null);
    shared.close(io);

    const exclusive = (try tryAcquireGraphExclusive(io, allocator, home)).?;
    exclusive.close(io);
}
