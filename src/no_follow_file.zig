const std = @import("std");
const builtin = @import("builtin");

/// Opens a file without following its final path component. Preserve the I/O
/// backend's flags: Zig 0.17 opens Windows no-follow handles synchronously, so
/// the former 0.16 nonblocking override would wait for nonexistent async I/O.
pub fn openForRead(
    directory: std.Io.Dir,
    io: std.Io,
    path: []const u8,
    options: std.Io.Dir.OpenFileOptions,
) std.Io.File.OpenError!std.Io.File {
    var no_follow_options = options;
    no_follow_options.follow_symlinks = false;
    return directory.openFile(io, path, no_follow_options);
}

test "no-follow file handles can be read positionally" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "fixture.txt",
        .data = "hutch",
    });

    var file = try openForRead(tmp.dir, std.testing.io, "fixture.txt", .{
        .allow_directory = false,
    });
    defer file.close(std.testing.io);
    if (comptime builtin.os.tag == .windows) {
        const windows = std.os.windows;
        var io_status_block: windows.IO_STATUS_BLOCK = undefined;
        var information: windows.FILE.MODE.INFORMATION = undefined;
        try std.testing.expectEqual(windows.NTSTATUS.SUCCESS, windows.ntdll.NtQueryInformationFile(
            file.handle,
            &io_status_block,
            &information,
            @sizeOf(windows.FILE.MODE.INFORMATION),
            .Mode,
        ));
        const asynchronous = information.Mode.IO == .ASYNCHRONOUS;
        try std.testing.expectEqual(asynchronous, file.flags.nonblocking);
    }

    var buffer: [16]u8 = undefined;
    var reader = file.reader(std.testing.io, &buffer);
    const bytes = try reader.interface.allocRemaining(std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("hutch", bytes);
}
