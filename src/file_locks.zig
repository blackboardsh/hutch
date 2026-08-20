const std = @import("std");
const builtin = @import("builtin");

const retry_delay = std.Io.Duration.fromMilliseconds(10);

/// Opens `path` without following its final symlink and waits for the requested
/// advisory lock. Zig 0.16's Windows blocking lock path does not handle
/// `STATUS_PENDING`, so Windows always uses an immediate native probe plus a
/// bounded-delay poll instead of asking `openFile` to block inside NtLockFile.
pub fn openBlocking(
    io: std.Io,
    directory: std.Io.Dir,
    path: []const u8,
    mode: std.Io.Dir.OpenFileOptions.Mode,
    lock: std.Io.File.Lock,
) std.Io.File.OpenError!std.Io.File {
    if (builtin.os.tag != .windows) {
        return directory.openFile(io, path, .{
            .mode = mode,
            .lock = lock,
            .follow_symlinks = false,
        });
    }

    const file = try openSynchronousNoFollowWindows(directory, path, mode);
    errdefer file.close(io);
    try lockBlocking(io, file, lock);
    return file;
}

/// Opens `path` without following its final symlink and either returns with the
/// requested advisory lock or reports `error.WouldBlock` immediately.
pub fn openNonblocking(
    io: std.Io,
    directory: std.Io.Dir,
    path: []const u8,
    mode: std.Io.Dir.OpenFileOptions.Mode,
    lock: std.Io.File.Lock,
) std.Io.File.OpenError!std.Io.File {
    if (builtin.os.tag != .windows) {
        return directory.openFile(io, path, .{
            .mode = mode,
            .lock = lock,
            .lock_nonblocking = true,
            .follow_symlinks = false,
        });
    }

    const file = try openSynchronousNoFollowWindows(directory, path, mode);
    errdefer file.close(io);
    if (!try tryLock(io, file, lock)) return error.WouldBlock;
    return file;
}

pub const ContendedFile = struct {
    file: std.Io.File,
    contended: bool,
};

/// Attempts the lock once before waiting so callers can retain their existing
/// contention diagnostics without duplicating platform-specific lock code.
pub fn openBlockingWithContention(
    io: std.Io,
    directory: std.Io.Dir,
    path: []const u8,
    mode: std.Io.Dir.OpenFileOptions.Mode,
    lock: std.Io.File.Lock,
) std.Io.File.OpenError!ContendedFile {
    const file = openNonblocking(io, directory, path, mode, lock) catch |err| switch (err) {
        error.WouldBlock => return .{
            .file = try openBlocking(io, directory, path, mode, lock),
            .contended = true,
        },
        else => return err,
    };
    return .{ .file = file, .contended = false };
}

/// Waits for a lock on an already-open file. On Windows this deliberately uses
/// only immediate NtLockFile probes, which is also safe for asynchronous
/// no-follow handles used by readers elsewhere in Hutch.
pub fn lockBlocking(
    io: std.Io,
    file: std.Io.File,
    lock: std.Io.File.Lock,
) std.Io.File.LockError!void {
    while (!try tryLock(io, file, lock)) {
        try std.Io.sleep(io, retry_delay, .awake);
    }
}

pub fn tryLock(
    io: std.Io,
    file: std.Io.File,
    lock: std.Io.File.Lock,
) std.Io.File.LockError!bool {
    if (builtin.os.tag != .windows) return file.tryLock(io, lock);
    return tryLockWindows(file, lock);
}

fn tryLockWindows(
    file: std.Io.File,
    lock: std.Io.File.Lock,
) std.Io.File.LockError!bool {
    const windows = std.os.windows;
    const exclusive = switch (lock) {
        .none => return true,
        .shared => false,
        .exclusive => true,
    };
    var io_status_block: windows.IO_STATUS_BLOCK = undefined;
    const byte_offset: windows.LARGE_INTEGER = 0;
    const byte_length: windows.LARGE_INTEGER = 1;
    while (true) switch (windows.ntdll.NtLockFile(
        file.handle,
        null,
        null,
        null,
        &io_status_block,
        &byte_offset,
        &byte_length,
        null,
        .TRUE,
        .fromBool(exclusive),
    )) {
        .SUCCESS => return true,
        // NTFS normally reports LOCK_NOT_GRANTED. Other Windows file-system
        // drivers may report FILE_LOCK_CONFLICT for the same live contention.
        .LOCK_NOT_GRANTED, .FILE_LOCK_CONFLICT => return false,
        .CANCELLED => continue,
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        else => |status| return windows.unexpectedStatus(status),
    };
}

/// `std.Io.Dir.openFile(..., .{ .follow_symlinks = false })` intentionally
/// creates an asynchronous Windows handle. A contended NtLockFile on that
/// handle returns `STATUS_PENDING`, which Zig 0.16's File lock implementation
/// does not complete. Lock files need no asynchronous I/O, so open the same
/// reparse-point-safe handle synchronously before attempting a byte-range lock.
fn openSynchronousNoFollowWindows(
    directory: std.Io.Dir,
    path: []const u8,
    mode: std.Io.Dir.OpenFileOptions.Mode,
) std.Io.File.OpenError!std.Io.File {
    const windows = std.os.windows;
    const path_w_buffer = try std.Io.Threaded.sliceToPrefixedFileW(
        directory.handle,
        path,
        .{},
    );
    const path_w = path_w_buffer.span();
    const attributes: windows.OBJECT.ATTRIBUTES = .{
        .RootDirectory = if (std.fs.path.isAbsoluteWindowsWtf16(path_w))
            null
        else
            directory.handle,
        .ObjectName = @constCast(&path_w_buffer.string()),
    };
    const access_mask: windows.ACCESS_MASK = .{
        .STANDARD = .{ .SYNCHRONIZE = true },
        .GENERIC = .{
            .READ = mode != .write_only,
            .WRITE = mode != .read_only,
        },
    };
    var io_status_block: windows.IO_STATUS_BLOCK = undefined;
    var handle: windows.HANDLE = undefined;
    while (true) switch (windows.ntdll.NtCreateFile(
        &handle,
        access_mask,
        &attributes,
        &io_status_block,
        null,
        .{ .NORMAL = true },
        .VALID_FLAGS,
        .OPEN,
        .{
            .IO = .SYNCHRONOUS_NONALERT,
            .NON_DIRECTORY_FILE = true,
            .OPEN_REPARSE_POINT = true,
        },
        null,
        0,
    )) {
        .SUCCESS => return .{
            .handle = handle,
            .flags = .{ .nonblocking = false },
        },
        .CANCELLED => continue,
        .OBJECT_NAME_INVALID, .OBJECT_PATH_SYNTAX_BAD => return error.BadPathName,
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
        .BAD_NETWORK_PATH, .BAD_NETWORK_NAME => return error.NetworkNotFound,
        .NO_MEDIA_IN_DEVICE, .PIPE_NOT_AVAILABLE => return error.NoDevice,
        .ACCESS_DENIED, .USER_MAPPED_FILE => return error.AccessDenied,
        .PIPE_BUSY => return error.PipeBusy,
        .OBJECT_NAME_COLLISION => return error.PathAlreadyExists,
        .FILE_IS_A_DIRECTORY => return error.IsDir,
        .NOT_A_DIRECTORY => return error.NotDir,
        .SHARING_VIOLATION, .DELETE_PENDING => return error.FileBusy,
        .VIRUS_INFECTED, .VIRUS_DELETED => return error.AntivirusInterference,
        else => |status| return windows.unexpectedStatus(status),
    };
}

fn windowsHandleIsSynchronous(file: std.Io.File) !bool {
    const windows = std.os.windows;
    var io_status_block: windows.IO_STATUS_BLOCK = undefined;
    var information: windows.FILE.MODE.INFORMATION = undefined;
    switch (windows.ntdll.NtQueryInformationFile(
        file.handle,
        &io_status_block,
        &information,
        @sizeOf(windows.FILE.MODE.INFORMATION),
        .Mode,
    )) {
        .SUCCESS => return information.Mode.IO != .ASYNCHRONOUS,
        else => |status| return windows.unexpectedStatus(status),
    }
}

test "Windows no-follow lock handles are synchronous and report live contention" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try tmp.dir.realPathFileAlloc(io, ".", arena.allocator());
    const path = try std.fs.path.join(arena.allocator(), &.{ root, "contention.lock" });
    const initializer = try std.Io.Dir.cwd().createFile(io, path, .{
        .read = true,
        .truncate = false,
        .exclusive = true,
    });
    initializer.close(io);

    const owner = try openBlocking(
        io,
        std.Io.Dir.cwd(),
        path,
        .read_write,
        .exclusive,
    );
    var owner_open = true;
    defer if (owner_open) owner.close(io);
    try std.testing.expect(try windowsHandleIsSynchronous(owner));

    const waiter = try openSynchronousNoFollowWindows(
        std.Io.Dir.cwd(),
        path,
        .read_write,
    );
    defer waiter.close(io);
    try std.testing.expect(try windowsHandleIsSynchronous(waiter));
    try std.testing.expect(!try tryLock(io, waiter, .shared));
    try std.testing.expect(!try tryLock(io, waiter, .exclusive));

    owner.close(io);
    owner_open = false;
    try std.testing.expect(try tryLock(io, waiter, .shared));
}

const WindowsBlockingHandoffContext = struct {
    path: []const u8,
    contended: std.Io.Event = .unset,
    failure: ?anyerror = null,
    acquired: bool = false,

    fn run(context: *@This()) void {
        const probe = openNonblocking(
            std.testing.io,
            std.Io.Dir.cwd(),
            context.path,
            .read_write,
            .shared,
        ) catch |err| switch (err) {
            error.WouldBlock => {
                context.contended.set(std.testing.io);
                return context.waitForSharedLock();
            },
            else => {
                context.failure = err;
                context.contended.set(std.testing.io);
                return;
            },
        };
        probe.close(std.testing.io);
        context.failure = error.ExpectedExclusiveLockContention;
        context.contended.set(std.testing.io);
    }

    fn waitForSharedLock(context: *@This()) void {
        const lease = openBlocking(
            std.testing.io,
            std.Io.Dir.cwd(),
            context.path,
            .read_write,
            .shared,
        ) catch |err| {
            context.failure = err;
            return;
        };
        defer lease.close(std.testing.io);
        context.acquired = true;
    }
};

test "Windows blocking shared lock completes after exclusive owner release" {
    if (builtin.os.tag != .windows or builtin.single_threaded) return error.SkipZigTest;

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try tmp.dir.realPathFileAlloc(io, ".", arena.allocator());
    const path = try std.fs.path.join(arena.allocator(), &.{ root, "blocking-handoff.lock" });
    const initializer = try std.Io.Dir.cwd().createFile(io, path, .{
        .read = true,
        .truncate = false,
        .exclusive = true,
    });
    initializer.close(io);

    const owner = try openBlocking(
        io,
        std.Io.Dir.cwd(),
        path,
        .read_write,
        .exclusive,
    );
    var owner_open = true;
    var waiter: ?std.Thread = null;
    defer {
        if (owner_open) owner.close(io);
        if (waiter) |thread| thread.join();
    }

    var context: WindowsBlockingHandoffContext = .{ .path = path };
    waiter = try std.Thread.spawn(.{}, WindowsBlockingHandoffContext.run, .{&context});

    try context.contended.wait(io);
    owner.close(io);
    owner_open = false;
    waiter.?.join();
    waiter = null;

    if (context.failure) |err| return err;
    try std.testing.expect(context.acquired);
}
