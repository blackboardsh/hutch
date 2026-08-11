const std = @import("std");

pub const TarGzipOptions = struct {
    strip_components: u32,
};

pub fn extractTarGzip(
    io: std.Io,
    allocator: std.mem.Allocator,
    destination: std.Io.Dir,
    bytes: []const u8,
    options: TarGzipOptions,
) !void {
    var compressed_reader: std.Io.Reader = .fixed(bytes);
    var decompression_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor: std.compress.flate.Decompress = .init(
        &compressed_reader,
        .gzip,
        &decompression_buffer,
    );
    var file_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var file_buffer: [16 * 1024]u8 = undefined;
    var diagnostics: std.tar.Diagnostics = .{ .allocator = allocator };
    defer diagnostics.deinit();

    var iterator: std.tar.Iterator = .init(&decompressor.reader, .{
        .file_name_buffer = &file_name_buffer,
        .link_name_buffer = &link_name_buffer,
        .diagnostics = &diagnostics,
    });
    while (try iterator.next()) |entry| {
        const path_len = sanitizeTarPath(
            &path_buffer,
            entry.name,
            options.strip_components,
        ) catch return error.UnsafeArchivePath;
        if (path_len == 0) continue;
        const path = path_buffer[0..path_len];

        switch (entry.kind) {
            .directory => try destination.createDirPath(io, path),
            .file => {
                if (std.fs.path.dirname(path)) |parent| {
                    try destination.createDirPath(io, parent);
                }
                const permissions: std.Io.File.Permissions = if (std.Io.File.Permissions.has_executable_bit and
                    (entry.mode & 0o100) != 0) .executable_file else .default_file;
                var file = try destination.createFile(io, path, .{
                    .truncate = true,
                    .permissions = permissions,
                });
                defer file.close(io);
                var writer = file.writer(io, &file_buffer);
                try iterator.streamRemaining(entry, &writer.interface);
                try writer.interface.flush();
            },
            .sym_link => return error.ArchiveLinksNotAllowed,
        }
    }

    if (diagnostics.errors.items.len > 0) return error.InvalidArchive;
}

pub fn sanitizeTarPath(
    buffer: []u8,
    path: []const u8,
    strip_components: u32,
) error{Invalid}!usize {
    if (path.len == 0 or path[0] == '/' or path[0] == '\\') return error.Invalid;
    if (std.mem.indexOfAny(u8, path, "\\:") != null) return error.Invalid;

    var output_len: usize = 0;
    var to_strip = strip_components;
    var components = std.mem.tokenizeScalar(u8, path, '/');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) return error.Invalid;
        if (to_strip > 0) {
            to_strip -= 1;
            continue;
        }
        const separator_len: usize = if (output_len == 0) 0 else 1;
        if (output_len + separator_len + component.len > buffer.len) {
            return error.Invalid;
        }
        if (separator_len == 1) {
            buffer[output_len] = '/';
            output_len += 1;
        }
        @memcpy(buffer[output_len..][0..component.len], component);
        output_len += component.len;
    }
    if (to_strip > 0) return error.Invalid;
    return output_len;
}

test "tar paths cannot escape the extraction root" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "bin/cottontail",
        buffer[0..try sanitizeTarPath(&buffer, "root/bin/cottontail", 1)],
    );
    try std.testing.expectError(
        error.Invalid,
        sanitizeTarPath(&buffer, "root/../escape", 1),
    );
    try std.testing.expectError(
        error.Invalid,
        sanitizeTarPath(&buffer, "/absolute", 1),
    );
    try std.testing.expectError(
        error.Invalid,
        sanitizeTarPath(&buffer, "C:/absolute", 0),
    );
}
