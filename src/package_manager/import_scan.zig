const std = @import("std");
const runtime_entrypoint = @import("../runtime_entrypoint.zig");

// Lexical package-import scanner for standalone Cottontail scripts. It
// extracts import/export-from/require specifiers without a module resolver,
// following relative imports transitively so multi-file scripts work. It is
// deliberately not a resolver: dev/build tooling stays in Hutch, and shipped
// application runtimes carry none of it.

const max_source_bytes = 16 * 1024 * 1024;
const max_scanned_files = 512;

pub fn scan(
    io: std.Io,
    allocator: std.mem.Allocator,
    entry_points: []const []const u8,
    working_dir: []const u8,
) ![]const []const u8 {
    var visited: std.StringArrayHashMapUnmanaged(void) = .empty;
    var specifiers: std.StringArrayHashMapUnmanaged(void) = .empty;
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(allocator);

    for (entry_points) |entry| {
        const absolute = if (std.fs.path.isAbsolute(entry))
            try allocator.dupe(u8, entry)
        else
            try std.fs.path.resolve(allocator, &.{ working_dir, entry });
        try queue.append(allocator, absolute);
    }

    while (queue.pop()) |path| {
        if (visited.count() >= max_scanned_files) break;
        const entry = try visited.getOrPut(allocator, path);
        if (entry.found_existing) continue;

        const source = std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            allocator,
            .limited(max_source_bytes),
        ) catch continue;

        var iterator = SpecifierIterator{ .source = source };
        while (iterator.next()) |specifier| {
            if (specifier.len == 0) continue;
            if (std.mem.startsWith(u8, specifier, "./") or
                std.mem.startsWith(u8, specifier, "../") or
                std.fs.path.isAbsolute(specifier))
            {
                const directory = std.fs.path.dirname(path) orelse continue;
                const joined = try std.fs.path.resolve(allocator, &.{ directory, specifier });
                const resolved = (runtime_entrypoint.resolve(io, allocator, joined) catch null) orelse continue;
                try queue.append(allocator, resolved);
                continue;
            }
            _ = try specifiers.getOrPut(allocator, specifier);
        }
    }

    return specifiers.keys();
}

const SpecifierIterator = struct {
    source: []const u8,
    index: usize = 0,
    // The two most recent significant tokens, newest first. Identifier tokens
    // keep their text; punctuation keeps a one-byte slice.
    last: [2][]const u8 = .{ "", "" },

    fn push(self: *SpecifierIterator, token: []const u8) void {
        self.last[1] = self.last[0];
        self.last[0] = token;
    }

    fn stringIsSpecifier(self: *const SpecifierIterator) bool {
        if (std.mem.eql(u8, self.last[0], "from")) return true;
        if (std.mem.eql(u8, self.last[0], "import")) return true;
        if (std.mem.eql(u8, self.last[0], "(") and
            (std.mem.eql(u8, self.last[1], "import") or std.mem.eql(u8, self.last[1], "require")))
        {
            return true;
        }
        return false;
    }

    fn next(self: *SpecifierIterator) ?[]const u8 {
        const source = self.source;
        while (self.index < source.len) {
            const byte = source[self.index];
            if (byte == '/' and self.index + 1 < source.len) {
                if (source[self.index + 1] == '/') {
                    self.index = std.mem.indexOfScalarPos(u8, source, self.index, '\n') orelse source.len;
                    continue;
                }
                if (source[self.index + 1] == '*') {
                    self.index = if (std.mem.indexOfPos(u8, source, self.index + 2, "*/")) |end|
                        end + 2
                    else
                        source.len;
                    continue;
                }
            }
            if (byte == '\'' or byte == '"') {
                const start = self.index + 1;
                var end = start;
                while (end < source.len and source[end] != byte) {
                    if (source[end] == '\\') end += 1;
                    end += 1;
                }
                const literal = source[start..@min(end, source.len)];
                const is_specifier = self.stringIsSpecifier();
                self.push("\"");
                self.index = @min(end + 1, source.len);
                if (is_specifier) return literal;
                continue;
            }
            if (byte == '`') {
                // Template literals are never import specifiers; skip them,
                // honoring escapes. Interpolated expressions are rare enough
                // in scripts that skipping their contents is acceptable.
                var end = self.index + 1;
                while (end < source.len and source[end] != '`') {
                    if (source[end] == '\\') end += 1;
                    end += 1;
                }
                self.push("`");
                self.index = @min(end + 1, source.len);
                continue;
            }
            if (std.ascii.isAlphabetic(byte) or byte == '_' or byte == '$') {
                var end = self.index + 1;
                while (end < source.len and
                    (std.ascii.isAlphanumeric(source[end]) or source[end] == '_' or source[end] == '$'))
                {
                    end += 1;
                }
                self.push(source[self.index..end]);
                self.index = end;
                continue;
            }
            if (!std.ascii.isWhitespace(byte)) {
                self.push(source[self.index .. self.index + 1]);
            }
            self.index += 1;
        }
        return null;
    }
};

test "scanner extracts static, re-export, dynamic, and require specifiers" {
    var iterator = SpecifierIterator{ .source =
    \\import isOdd from "is-odd"; // import "commented-out"
    \\import "side-effect";
    \\import { x } from '@scope/pkg/sub';
    \\export { y } from "re-exported";
    \\const dynamic = await import("dynamic-pkg");
    \\const legacy = require('legacy-pkg');
    \\/* import "block-commented" */
    \\const template = `import "templated"`;
    \\const unrelated = "not-a-specifier";
    };
    var found: std.ArrayList([]const u8) = .empty;
    defer found.deinit(std.testing.allocator);
    while (iterator.next()) |specifier| {
        try found.append(std.testing.allocator, specifier);
    }
    const expected = [_][]const u8{
        "is-odd",
        "side-effect",
        "@scope/pkg/sub",
        "re-exported",
        "dynamic-pkg",
        "legacy-pkg",
    };
    try std.testing.expectEqual(expected.len, found.items.len);
    for (expected, found.items) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

test "scan follows relative imports and dedupes package specifiers" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try tmp.dir.writeFile(io, .{
        .sub_path = "entry.ts",
        .data = "import \"pkg-a\";\nimport \"./nested/local\";\n",
    });
    try tmp.dir.createDirPath(io, "nested");
    try tmp.dir.writeFile(io, .{
        .sub_path = "nested/local.ts",
        .data = "import \"pkg-a\";\nimport \"pkg-b\";\nimport \"../entry\";\n",
    });
    const relative = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, relative, allocator);

    const found = try scan(io, allocator, &.{"entry.ts"}, root);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("pkg-a", found[0]);
    try std.testing.expectEqualStrings("pkg-b", found[1]);
}
