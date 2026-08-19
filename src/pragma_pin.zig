const std = @import("std");
const bootstrap_pragma = @import("bootstrap_pragma.zig");
const version_selector = @import("version_selector.zig");

pub const config_file_names = [_][]const u8{
    "hutch.config.ts",
    "hutch.config.js",
    "hutch.config.mjs",
};

pub const Rewrite = struct {
    content: []const u8,
    /// The field's previous selector text, or null when the field was unset.
    previous: ?[]const u8,
};

/// Rewrites the `// @hutch` first-line pragma so `key` selects `value`,
/// leaving every other byte of the source untouched. A source without a
/// pragma gains one as a new first line. A malformed pragma is an error:
/// it must be fixed by hand, not rewritten around.
pub fn rewriteSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    key: []const u8,
    value: []const u8,
) !Rewrite {
    _ = try version_selector.parse(value);

    const line_end = std.mem.indexOfAny(u8, source, "\r\n") orelse source.len;
    const first_line = source[0..line_end];
    const rest = source[line_end..];

    const is_pragma = std.mem.startsWith(u8, first_line, bootstrap_pragma.prefix) and
        (first_line.len == bootstrap_pragma.prefix.len or
            first_line[bootstrap_pragma.prefix.len] == ' ' or
            first_line[bootstrap_pragma.prefix.len] == '\t');

    var line: std.ArrayList(u8) = .empty;
    try line.appendSlice(allocator, bootstrap_pragma.prefix);
    var previous: ?[]const u8 = null;

    if (is_pragma) {
        _ = try bootstrap_pragma.parseFirstLine(first_line);
        var replaced = false;
        var fields = std.mem.tokenizeAny(u8, first_line[bootstrap_pragma.prefix.len..], " \t");
        while (fields.next()) |field| {
            const equals = std.mem.indexOfScalar(u8, field, '=').?;
            try line.append(allocator, ' ');
            if (std.mem.eql(u8, field[0..equals], key)) {
                previous = field[equals + 1 ..];
                replaced = true;
                try line.appendSlice(allocator, key);
                try line.append(allocator, '=');
                try line.appendSlice(allocator, value);
            } else {
                try line.appendSlice(allocator, field);
            }
        }
        if (!replaced) {
            try line.append(allocator, ' ');
            try line.appendSlice(allocator, key);
            try line.append(allocator, '=');
            try line.appendSlice(allocator, value);
        }
    } else {
        try line.append(allocator, ' ');
        try line.appendSlice(allocator, key);
        try line.append(allocator, '=');
        try line.appendSlice(allocator, value);
    }

    var content: std.ArrayList(u8) = .empty;
    try content.appendSlice(allocator, line.items);
    if (is_pragma) {
        try content.appendSlice(allocator, rest);
    } else {
        const ending: []const u8 = if (std.mem.startsWith(u8, rest, "\r")) "\r\n" else "\n";
        try content.appendSlice(allocator, ending);
        try content.appendSlice(allocator, source);
    }

    _ = (try bootstrap_pragma.parseFirstLine(content.items)) orelse
        return error.InvalidHutchPragmaField;
    return .{ .content = content.items, .previous = previous };
}

pub fn pinConfigFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    key: []const u8,
    value: []const u8,
) !Rewrite {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
    const rewrite = try rewriteSource(allocator, source, key, value);
    if (!std.mem.eql(u8, source, rewrite.content)) {
        var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
        defer atomic_file.deinit(io);
        var write_buffer: [4096]u8 = undefined;
        var writer = atomic_file.file.writer(io, &write_buffer);
        try writer.interface.writeAll(rewrite.content);
        try writer.interface.flush();
        try atomic_file.file.sync(io);
        try atomic_file.replace(io);
    }
    return rewrite;
}

const skipped_directories = [_][]const u8{
    ".git",
    ".hutch",
    "node_modules",
    "zig-out",
    ".zig-cache",
};

/// Collects every hutch.config.* under `root`, depth-first, skipping
/// dependency and build-output directories. Paths are relative to `root`.
pub fn findConfigsRecursive(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
) ![]const []const u8 {
    var found: std.ArrayList([]const u8) = .empty;
    var pending: std.ArrayList([]const u8) = .empty;
    try pending.append(allocator, try allocator.dupe(u8, root));

    while (pending.pop()) |directory| {
        var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            const child = try std.fs.path.join(allocator, &.{ directory, entry.name });
            switch (entry.kind) {
                .directory => {
                    for (skipped_directories) |skipped| {
                        if (std.mem.eql(u8, entry.name, skipped)) break;
                    } else try pending.append(allocator, child);
                },
                .file => {
                    for (config_file_names) |name| {
                        if (std.mem.eql(u8, entry.name, name)) {
                            try found.append(allocator, child);
                            break;
                        }
                    }
                },
                else => {},
            }
        }
    }

    std.mem.sort([]const u8, found.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return found.items;
}

test "rewriting replaces one field and preserves the others verbatim" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rewrite = try rewriteSource(
        arena.allocator(),
        "// @hutch cli=0.19.0 cottontail=0.5.0\nexport default {};\n",
        "cli",
        "0.20.0",
    );
    try std.testing.expectEqualStrings(
        "// @hutch cli=0.20.0 cottontail=0.5.0\nexport default {};\n",
        rewrite.content,
    );
    try std.testing.expectEqualStrings("0.19.0", rewrite.previous.?);
}

test "rewriting adds a missing field to an existing pragma" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rewrite = try rewriteSource(
        arena.allocator(),
        "// @hutch cottontail=0.5.0\r\nexport default {};\r\n",
        "cli",
        "latest",
    );
    try std.testing.expectEqualStrings(
        "// @hutch cottontail=0.5.0 cli=latest\r\nexport default {};\r\n",
        rewrite.content,
    );
    try std.testing.expect(rewrite.previous == null);
}

test "rewriting inserts a pragma line above a source without one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rewrite = try rewriteSource(
        arena.allocator(),
        "export default { packageManager: \"bun\" };\n",
        "cli",
        "0.21.0",
    );
    try std.testing.expectEqualStrings(
        "// @hutch cli=0.21.0\nexport default { packageManager: \"bun\" };\n",
        rewrite.content,
    );
    try std.testing.expect(rewrite.previous == null);
}

test "rewriting refuses invalid selectors and malformed pragmas" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.InvalidSemanticVersion,
        rewriteSource(arena.allocator(), "export default {};\n", "cli", "newest"),
    );
    try std.testing.expectError(
        error.InvalidHutchPragmaField,
        rewriteSource(arena.allocator(), "// @hutch cli\n", "cli", "0.20.0"),
    );
}
