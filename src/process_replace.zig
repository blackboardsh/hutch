const std = @import("std");
const builtin = @import("builtin");

pub fn replace(
    allocator: std.mem.Allocator,
    executable: []const u8,
    argv: []const []const u8,
    environment: *const std.process.Environ.Map,
) !void {
    if (comptime builtin.os.tag == .windows) {
        return error.ProcessReplacementUnsupported;
    }

    const executable_z = try allocator.dupeZ(u8, executable);
    const argv_z = try allocator.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |argument, index| {
        argv_z[index] = (try allocator.dupeZ(u8, argument)).ptr;
    }
    const environment_block = try environment.createPosixBlock(allocator, .{});

    _ = std.posix.system.execve(
        executable_z.ptr,
        argv_z.ptr,
        environment_block.slice.ptr,
    );
    return error.ProcessReplacementFailed;
}
