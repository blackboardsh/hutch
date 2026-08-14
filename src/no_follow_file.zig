const std = @import("std");
const builtin = @import("builtin");

/// Opens a file without following its final path component and prepares the
/// returned handle for reading. Zig 0.16 opens Windows no-follow handles for
/// asynchronous I/O but does not reflect that in File.flags.
pub fn openForRead(
    directory: std.Io.Dir,
    io: std.Io,
    path: []const u8,
    options: std.Io.Dir.OpenFileOptions,
) std.Io.File.OpenError!std.Io.File {
    var no_follow_options = options;
    no_follow_options.follow_symlinks = false;
    var file = try directory.openFile(io, path, no_follow_options);
    if (comptime builtin.os.tag == .windows) file.flags.nonblocking = true;
    return file;
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
        try std.testing.expect(file.flags.nonblocking);
    }

    var buffer: [16]u8 = undefined;
    var reader = file.reader(std.testing.io, &buffer);
    const bytes = try reader.interface.allocRemaining(std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("hutch", bytes);
}
