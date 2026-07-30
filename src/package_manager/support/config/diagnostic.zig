const std = @import("std");

pub const Severity = enum {
    @"error",
    note,
};

pub fn print(
    writer: *std.Io.Writer,
    path: []const u8,
    source: []const u8,
    offset: usize,
    severity: Severity,
    comptime format: []const u8,
    args: anytype,
) !void {
    const location = locate(source, offset);
    const line_number_width = decimalWidth(location.line);

    try writer.print("{d} | {s}\n", .{ location.line, location.text });
    try writer.splatByteAll(' ', line_number_width + 3);
    try writeCaretPadding(writer, location.text[0..location.byte_column]);
    try writer.writeAll("^\n");
    try writer.print("{s}: ", .{@tagName(severity)});
    try writer.print(format, args);
    try writer.writeByte('\n');
    try writer.print(
        "{s}at {s}:{d}:{d}\n",
        .{
            if (severity == .note) "   " else "    ",
            path,
            location.line,
            location.byte_column + 1,
        },
    );
}

const SourceLocation = struct {
    line: usize,
    byte_column: usize,
    text: []const u8,
};

fn locate(source: []const u8, requested_offset: usize) SourceLocation {
    const offset = @min(requested_offset, source.len);
    var line: usize = 1;
    var line_start: usize = 0;
    var index: usize = 0;

    while (index < offset) : (index += 1) {
        if (source[index] == '\n') {
            line += 1;
            line_start = index + 1;
        }
    }

    var line_end = line_start;
    while (line_end < source.len and source[line_end] != '\n' and source[line_end] != '\r') {
        line_end += 1;
    }

    return .{
        .line = line,
        .byte_column = offset - line_start,
        .text = source[line_start..line_end],
    };
}

fn writeCaretPadding(writer: *std.Io.Writer, prefix: []const u8) !void {
    for (prefix) |byte| {
        try writer.writeByte(if (byte == '\t') '\t' else ' ');
    }
}

fn decimalWidth(value: usize) usize {
    var remaining = value;
    var width: usize = 1;
    while (remaining >= 10) {
        remaining /= 10;
        width += 1;
    }
    return width;
}

test "diagnostic preserves Bun's one-line source layout" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try print(
        &output.writer,
        "/tmp/package.json",
        "{\"dependencies\":[]}",
        16,
        .@"error",
        "dependencies expects an object",
        .{},
    );
    try std.testing.expectEqualStrings(
        \\1 | {"dependencies":[]}
        \\                    ^
        \\error: dependencies expects an object
        \\    at /tmp/package.json:1:17
        \\
    , output.written());
}
