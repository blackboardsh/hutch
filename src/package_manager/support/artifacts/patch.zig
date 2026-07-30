const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;
const whitespace = " \t\n\r";

pub const PatchFilePart = union(enum) {
    file_patch: *FilePatch,
    file_deletion: *FileDeletion,
    file_creation: *FileCreation,
    file_rename: *FileRename,
    file_mode_change: *FileModeChange,

    fn deinit(self: *PatchFilePart, allocator: Allocator) void {
        switch (self.*) {
            .file_patch => |value| {
                value.deinit(allocator);
                allocator.destroy(value);
            },
            .file_deletion => |value| {
                value.deinit(allocator);
                allocator.destroy(value);
            },
            .file_creation => |value| {
                value.deinit(allocator);
                allocator.destroy(value);
            },
            .file_rename => |value| allocator.destroy(value),
            .file_mode_change => |value| allocator.destroy(value),
        }
    }
};

pub const PatchFile = struct {
    parts: List(PatchFilePart) = .empty,

    pub fn deinit(self: *PatchFile, allocator: Allocator) void {
        for (self.parts.items) |*part| part.deinit(allocator);
        self.parts.deinit(allocator);
        self.* = .{};
    }
};

pub const PatchMutationPart = struct {
    type: PartType,
    lines: List([]const u8) = .empty,
    no_newline_at_end_of_file: bool = false,

    pub const PartType = enum(u2) {
        context = 0,
        insertion,
        deletion,
    };

    fn deinit(self: *PatchMutationPart, allocator: Allocator) void {
        self.lines.deinit(allocator);
    }
};

pub const Hunk = struct {
    header: Header,
    parts: List(PatchMutationPart) = .empty,

    pub const Header = struct {
        original: Range,
        patched: Range,

        pub const empty: Header = .{
            .original = .{ .start = 1, .len = 0 },
            .patched = .{ .start = 1, .len = 0 },
        };
    };

    pub const Range = struct {
        start: u32 = 1,
        len: u32,
    };

    fn deinit(self: *Hunk, allocator: Allocator) void {
        for (self.parts.items) |*part| part.deinit(allocator);
        self.parts.deinit(allocator);
        self.* = .{ .header = Header.empty };
    }

    fn verifyIntegrity(self: *const Hunk) bool {
        var original_length: usize = 0;
        var patched_length: usize = 0;
        for (self.parts.items) |part| switch (part.type) {
            .context => {
                original_length += part.lines.items.len;
                patched_length += part.lines.items.len;
            },
            .insertion => patched_length += part.lines.items.len,
            .deletion => original_length += part.lines.items.len,
        };
        return original_length == self.header.original.len and
            patched_length == self.header.patched.len;
    }
};

pub const FileMode = enum(u32) {
    non_executable = 0o644,
    executable = 0o755,

    fn fromU32(mode: u32) ?FileMode {
        return switch (mode) {
            0o644 => .non_executable,
            0o755 => .executable,
            else => null,
        };
    }
};

pub const FileRename = struct {
    from_path: []const u8,
    to_path: []const u8,
};

pub const FileModeChange = struct {
    path: []const u8,
    old_mode: FileMode,
    new_mode: FileMode,
};

pub const FilePatch = struct {
    path: []const u8,
    hunks: List(Hunk),
    before_hash: ?[]const u8,
    after_hash: ?[]const u8,

    fn deinit(self: *FilePatch, allocator: Allocator) void {
        for (self.hunks.items) |*hunk| hunk.deinit(allocator);
        self.hunks.deinit(allocator);
    }
};

pub const FileDeletion = struct {
    path: []const u8,
    mode: FileMode,
    hunk: ?*Hunk,
    hash: ?[]const u8,

    fn deinit(self: *FileDeletion, allocator: Allocator) void {
        if (self.hunk) |hunk| {
            hunk.deinit(allocator);
            allocator.destroy(hunk);
        }
    }
};

pub const FileCreation = struct {
    path: []const u8,
    mode: FileMode,
    hunk: ?*Hunk,
    hash: ?[]const u8,

    fn deinit(self: *FileCreation, allocator: Allocator) void {
        if (self.hunk) |hunk| {
            hunk.deinit(allocator);
            allocator.destroy(hunk);
        }
    }
};

pub const ParseError = error{
    OutOfMemory,
    unrecognized_pragma,
    no_newline_at_eof_pragma_encountered_without_context,
    hunk_lines_encountered_before_hunk_header,
    hunk_header_integrity_check_failed,
    bad_diff_line,
    bad_header_line,
    rename_from_and_to_not_give,
    no_path_given_for_file_deletion,
    no_path_given_for_file_creation,
    bad_file_mode,
};

pub fn parsePatchFile(allocator: Allocator, file: []const u8) ParseError!PatchFile {
    var parser = Parser.init(allocator);
    defer parser.deinit();

    parser.parse(file, false) catch |err| {
        if (err != error.hunk_header_integrity_check_failed) return err;
        parser.reset();
        try parser.parse(file, true);
    };
    return secondPass(allocator, parser.result.items);
}

pub fn gitDiffPreprocessPaths(
    allocator: Allocator,
    old_folder: []const u8,
    new_folder: []const u8,
) Allocator.Error![2][]const u8 {
    if (builtin.os.tag != .windows) return .{ old_folder, new_folder };
    return .{
        try normalizedWindowsPath(allocator, old_folder),
        try normalizedWindowsPath(allocator, new_folder),
    };
}

fn normalizedWindowsPath(allocator: Allocator, input: []const u8) Allocator.Error![]const u8 {
    const result = try allocator.dupe(u8, input);
    std.mem.replaceScalar(u8, result, '\\', '/');
    return result;
}

const FileDetails = struct {
    diff_line_from_path: ?[]const u8 = null,
    diff_line_to_path: ?[]const u8 = null,
    old_mode: ?[]const u8 = null,
    new_mode: ?[]const u8 = null,
    deleted_file_mode: ?[]const u8 = null,
    new_file_mode: ?[]const u8 = null,
    rename_from: ?[]const u8 = null,
    rename_to: ?[]const u8 = null,
    before_hash: ?[]const u8 = null,
    after_hash: ?[]const u8 = null,
    from_path: ?[]const u8 = null,
    to_path: ?[]const u8 = null,
    hunks: List(Hunk) = .empty,

    fn takeHunks(self: *FileDetails) List(Hunk) {
        const result = self.hunks;
        self.hunks = .empty;
        return result;
    }

    fn deinit(self: *FileDetails, allocator: Allocator) void {
        for (self.hunks.items) |*hunk| hunk.deinit(allocator);
        self.hunks.deinit(allocator);
        self.* = .{};
    }

    fn nullifyEmptyStrings(self: *FileDetails) void {
        inline for (std.meta.fields(FileDetails)) |field| {
            if (field.type == ?[]const u8) {
                const value = @field(self, field.name);
                if (value != null and value.?.len == 0) @field(self, field.name) = null;
            }
        }
    }
};

const Parser = struct {
    allocator: Allocator,
    result: List(FileDetails) = .empty,
    current_file: FileDetails = .{},
    state: State = .header,
    current_hunk: ?Hunk = null,
    current_part: ?PatchMutationPart = null,

    const State = enum { header, hunks };
    const LineType = enum(u3) {
        context = 0,
        insertion,
        deletion,
        header,
        pragma,
    };

    fn init(allocator: Allocator) Parser {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Parser) void {
        self.current_file.deinit(self.allocator);
        if (self.current_hunk) |*hunk| hunk.deinit(self.allocator);
        if (self.current_part) |*part| part.deinit(self.allocator);
        for (self.result.items) |*file| file.deinit(self.allocator);
        self.result.deinit(self.allocator);
        self.* = .{ .allocator = self.allocator };
    }

    fn reset(self: *Parser) void {
        const allocator = self.allocator;
        self.deinit();
        self.* = init(allocator);
    }

    fn parse(self: *Parser, input: []const u8, support_legacy_diffs: bool) ParseError!void {
        if (input.len == 0) return;
        var end = input.len;
        if (input[end - 1] == '\n') end -= 1;
        if (end == 0) return;

        var lines = LookbackIterator.init(std.mem.splitScalar(u8, input[0..end], '\n'));
        while (lines.next()) |line| {
            switch (self.state) {
                .header => try self.parseHeaderLine(line, &lines),
                .hunks => try self.parseHunkLine(line, &lines, support_legacy_diffs),
            }
        }

        try self.commitFile();
        for (self.result.items) |file| {
            for (file.hunks.items) |hunk| {
                if (!hunk.verifyIntegrity()) return error.hunk_header_integrity_check_failed;
            }
        }
    }

    fn parseHeaderLine(
        self: *Parser,
        line: []const u8,
        lines: *LookbackIterator,
    ) ParseError!void {
        if (std.mem.startsWith(u8, line, "@@")) {
            self.state = .hunks;
            self.current_file.hunks = .empty;
            lines.back();
        } else if (std.mem.startsWith(u8, line, "diff --git ")) {
            if (self.current_file.diff_line_from_path != null) try self.commitFile();
            const paths = parseDiffLinePaths(line) orelse return error.bad_diff_line;
            self.current_file.diff_line_from_path = paths[0];
            self.current_file.diff_line_to_path = paths[1];
        } else if (std.mem.startsWith(u8, line, "old mode ")) {
            self.current_file.old_mode = std.mem.trim(u8, line["old mode ".len..], whitespace);
        } else if (std.mem.startsWith(u8, line, "new mode ")) {
            self.current_file.new_mode = std.mem.trim(u8, line["new mode ".len..], whitespace);
        } else if (std.mem.startsWith(u8, line, "deleted file mode ")) {
            self.current_file.deleted_file_mode = std.mem.trim(u8, line["deleted file mode ".len..], whitespace);
        } else if (std.mem.startsWith(u8, line, "new file mode ")) {
            self.current_file.new_file_mode = std.mem.trim(u8, line["new file mode ".len..], whitespace);
        } else if (std.mem.startsWith(u8, line, "rename from ")) {
            self.current_file.rename_from = std.mem.trim(u8, line["rename from ".len..], whitespace);
        } else if (std.mem.startsWith(u8, line, "rename to ")) {
            self.current_file.rename_to = std.mem.trim(u8, line["rename to ".len..], whitespace);
        } else if (std.mem.startsWith(u8, line, "index ")) {
            const hashes = parseDiffHashes(line["index ".len..]) orelse return;
            self.current_file.before_hash = hashes[0];
            self.current_file.after_hash = hashes[1];
        } else if (std.mem.startsWith(u8, line, "--- ")) {
            const prefix_len = @min(line.len, "--- a/".len);
            self.current_file.from_path = std.mem.trim(u8, line[prefix_len..], whitespace);
        } else if (std.mem.startsWith(u8, line, "+++ ")) {
            const prefix_len = @min(line.len, "+++ b/".len);
            self.current_file.to_path = std.mem.trim(u8, line[prefix_len..], whitespace);
        }
    }

    fn parseHunkLine(
        self: *Parser,
        line: []const u8,
        lines: *LookbackIterator,
        support_legacy_diffs: bool,
    ) ParseError!void {
        if (support_legacy_diffs and std.mem.startsWith(u8, line, "--- a/")) {
            self.state = .header;
            try self.commitFile();
            lines.back();
            return;
        }

        const line_type: LineType = if (line.len == 0)
            .context
        else switch (line[0]) {
            '@' => .header,
            '-' => .deletion,
            '+' => .insertion,
            ' ', '\r' => .context,
            '\\' => .pragma,
            else => {
                self.state = .header;
                try self.commitFile();
                lines.back();
                return;
            },
        };

        switch (line_type) {
            .header => {
                try self.commitHunk();
                self.current_hunk = try parseHunkHeader(line);
            },
            .pragma => {
                if (!std.mem.startsWith(u8, line, "\\ No newline at end of file"))
                    return error.unrecognized_pragma;
                if (self.current_part == null)
                    return error.no_newline_at_eof_pragma_encountered_without_context;
                self.current_part.?.no_newline_at_end_of_file = true;
            },
            .insertion, .deletion, .context => {
                if (self.current_hunk == null)
                    return error.hunk_lines_encountered_before_hunk_header;
                const part_type: PatchMutationPart.PartType = @enumFromInt(@intFromEnum(line_type));
                if (self.current_part != null and self.current_part.?.type != part_type) {
                    try self.current_hunk.?.parts.append(self.allocator, self.current_part.?);
                    self.current_part = null;
                }
                if (self.current_part == null) self.current_part = .{ .type = part_type };
                try self.current_part.?.lines.append(self.allocator, line[@min(1, line.len)..]);
            },
        }
    }

    fn commitHunk(self: *Parser) ParseError!void {
        if (self.current_hunk) |*hunk| {
            if (self.current_part) |part| {
                try hunk.parts.append(self.allocator, part);
                self.current_part = null;
            }
            try self.current_file.hunks.append(self.allocator, hunk.*);
            self.current_hunk = null;
        }
    }

    fn commitFile(self: *Parser) ParseError!void {
        try self.commitHunk();
        self.current_file.nullifyEmptyStrings();
        try self.result.append(self.allocator, self.current_file);
        self.current_file = .{};
        self.state = .header;
    }
};

const LookbackIterator = struct {
    inner: std.mem.SplitIterator(u8, .scalar),
    previous_index: usize = 0,

    fn init(inner: std.mem.SplitIterator(u8, .scalar)) LookbackIterator {
        return .{ .inner = inner };
    }

    fn next(self: *LookbackIterator) ?[]const u8 {
        self.previous_index = self.inner.index orelse self.previous_index;
        return self.inner.next();
    }

    fn back(self: *LookbackIterator) void {
        self.inner.index = self.previous_index;
    }
};

fn secondPass(allocator: Allocator, files: []FileDetails) ParseError!PatchFile {
    var result: PatchFile = .{};
    errdefer result.deinit(allocator);

    for (files) |*file| {
        const kind: enum { patch, deletion, creation, rename, mode } =
            if (file.rename_from != null)
                .rename
            else if (file.deleted_file_mode != null)
                .deletion
            else if (file.new_file_mode != null)
                .creation
            else if (file.hunks.items.len > 0)
                .patch
            else
                .mode;

        var destination: ?[]const u8 = null;
        switch (kind) {
            .rename => {
                const from = file.rename_from orelse return error.rename_from_and_to_not_give;
                const to = file.rename_to orelse return error.rename_from_and_to_not_give;
                const rename = try allocator.create(FileRename);
                rename.* = .{ .from_path = from, .to_path = to };
                errdefer allocator.destroy(rename);
                try result.parts.append(allocator, .{ .file_rename = rename });
                destination = to;
            },
            .deletion => {
                const path = file.diff_line_from_path orelse file.from_path orelse
                    return error.no_path_given_for_file_deletion;
                const mode = parseFileMode(file.deleted_file_mode.?) orelse return error.bad_file_mode;
                const deletion = try allocator.create(FileDeletion);
                deletion.* = .{
                    .path = path,
                    .mode = mode,
                    .hunk = null,
                    .hash = file.before_hash,
                };
                errdefer {
                    deletion.deinit(allocator);
                    allocator.destroy(deletion);
                }
                deletion.hunk = try takeFirstHunk(allocator, file);
                try result.parts.append(allocator, .{ .file_deletion = deletion });
            },
            .creation => {
                const path = file.diff_line_to_path orelse file.to_path orelse
                    return error.no_path_given_for_file_creation;
                const mode = parseFileMode(file.new_file_mode.?) orelse return error.bad_file_mode;
                const creation = try allocator.create(FileCreation);
                creation.* = .{
                    .path = path,
                    .mode = mode,
                    .hunk = null,
                    .hash = file.after_hash,
                };
                errdefer {
                    creation.deinit(allocator);
                    allocator.destroy(creation);
                }
                creation.hunk = try takeFirstHunk(allocator, file);
                try result.parts.append(allocator, .{ .file_creation = creation });
            },
            .patch, .mode => destination = file.to_path orelse file.diff_line_to_path,
        }

        if (destination != null and file.old_mode != null and file.new_mode != null and
            !std.mem.eql(u8, file.old_mode.?, file.new_mode.?))
        {
            const old_mode = parseFileMode(file.old_mode.?) orelse return error.bad_file_mode;
            const new_mode = parseFileMode(file.new_mode.?) orelse return error.bad_file_mode;
            const change = try allocator.create(FileModeChange);
            change.* = .{
                .path = destination.?,
                .old_mode = old_mode,
                .new_mode = new_mode,
            };
            errdefer allocator.destroy(change);
            try result.parts.append(allocator, .{ .file_mode_change = change });
        }

        if (destination != null and file.hunks.items.len > 0) {
            const patch = try allocator.create(FilePatch);
            patch.* = .{
                .path = destination.?,
                .hunks = file.takeHunks(),
                .before_hash = file.before_hash,
                .after_hash = file.after_hash,
            };
            errdefer {
                patch.deinit(allocator);
                allocator.destroy(patch);
            }
            try result.parts.append(allocator, .{ .file_patch = patch });
        }
    }
    return result;
}

fn takeFirstHunk(allocator: Allocator, file: *FileDetails) ParseError!?*Hunk {
    if (file.hunks.items.len == 0) return null;
    const hunk = try allocator.create(Hunk);
    hunk.* = file.hunks.items[0];
    file.hunks.items[0] = .{ .header = Hunk.Header.empty };
    return hunk;
}

fn parseFileMode(value: []const u8) ?FileMode {
    const parsed = (std.fmt.parseInt(u32, value, 8) catch return null) & 0o777;
    return FileMode.fromU32(parsed);
}

fn parseHunkHeader(line_input: []const u8) ParseError!Hunk {
    var line = std.mem.trim(u8, line_input, whitespace);
    if (!std.mem.startsWith(u8, line, "@@ -")) return error.bad_header_line;
    line = line["@@ -".len..];
    const original = try parseRange(line);
    line = original.rest;
    if (!std.mem.startsWith(u8, line, " +")) return error.bad_header_line;
    line = line[2..];
    const patched = try parseRange(line);
    if (!std.mem.startsWith(u8, patched.rest, " @@")) return error.bad_header_line;
    return .{
        .header = .{
            .original = original.range,
            .patched = patched.range,
        },
    };
}

fn parseRange(input: []const u8) ParseError!struct { range: Hunk.Range, rest: []const u8 } {
    var end: usize = 0;
    while (end < input.len and std.ascii.isDigit(input[end])) end += 1;
    if (end == 0 or end >= input.len) return error.bad_header_line;
    const start = std.fmt.parseInt(u32, input[0..end], 10) catch return error.bad_header_line;
    var len: u32 = 1;
    if (input[end] == ',') {
        const len_start = end + 1;
        end = len_start;
        while (end < input.len and std.ascii.isDigit(input[end])) end += 1;
        if (end == len_start) return error.bad_header_line;
        len = std.fmt.parseInt(u32, input[len_start..end], 10) catch return error.bad_header_line;
    }
    if (end >= input.len or input[end] != ' ') return error.bad_header_line;
    return .{
        .range = .{ .start = @max(1, start), .len = len },
        .rest = input[end..],
    };
}

fn parseDiffHashes(line: []const u8) ?[2][]const u8 {
    const delimiter = std.mem.indexOf(u8, line, "..") orelse return null;
    const before = line[0..delimiter];
    if (!isWord(before)) return null;
    const after_start = delimiter + 2;
    if (after_start >= line.len) return null;
    const after_end = std.mem.indexOfAny(u8, line[after_start..], " \n\r\t") orelse
        line[after_start..].len;
    const after = line[after_start .. after_start + after_end];
    if (!isWord(after)) return null;
    return .{ before, after };
}

fn isWord(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    }
    return true;
}

fn parseDiffLinePaths(line: []const u8) ?[2][]const u8 {
    const prefix = "diff --git a/";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const rest = line[prefix.len..];
    if (rest.len == 0) return null;

    var search_index: usize = 0;
    while (std.mem.indexOfScalarPos(u8, rest, search_index, 'b')) |index| {
        if (index > 0 and rest[index - 1] == ' ' and index + 1 < rest.len and rest[index + 1] == '/') {
            return .{
                rest[0 .. index - 1],
                std.mem.trimEnd(u8, rest[index + 2 ..], " \n\r\t"),
            };
        }
        search_index = index + 1;
    }
    return null;
}

test "parse patch, creation, deletion, rename, and mode changes" {
    const source =
        \\diff --git a/lib/a.txt b/lib/a.txt
        \\index 1111111..2222222 100644
        \\--- a/lib/a.txt
        \\+++ b/lib/a.txt
        \\@@ -1,2 +1,2 @@
        \\ one
        \\-two
        \\+three
        \\diff --git a/new.txt b/new.txt
        \\new file mode 100644
        \\index 0000000..3333333
        \\--- /dev/null
        \\+++ b/new.txt
        \\@@ -0,0 +1 @@
        \\+new
        \\diff --git a/old.txt b/old.txt
        \\deleted file mode 100644
        \\index 4444444..0000000
        \\--- a/old.txt
        \\+++ /dev/null
        \\@@ -1 +0,0 @@
        \\-old
        \\diff --git a/from.txt b/to.txt
        \\similarity index 100%
        \\rename from from.txt
        \\rename to to.txt
        \\old mode 100644
        \\new mode 100755
    ;

    var patch = try parsePatchFile(std.testing.allocator, source);
    defer patch.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 5), patch.parts.items.len);

    try std.testing.expectEqualStrings("lib/a.txt", patch.parts.items[0].file_patch.path);
    try std.testing.expectEqualStrings("new.txt", patch.parts.items[1].file_creation.path);
    try std.testing.expectEqualStrings("old.txt", patch.parts.items[2].file_deletion.path);
    try std.testing.expectEqualStrings("from.txt", patch.parts.items[3].file_rename.from_path);
    try std.testing.expectEqualStrings("to.txt", patch.parts.items[4].file_mode_change.path);
    try std.testing.expectEqual(FileMode.executable, patch.parts.items[4].file_mode_change.new_mode);
}

test "reject malformed hunk lengths" {
    const malformed =
        \\diff --git a/a b/a
        \\--- a/a
        \\+++ b/a
        \\@@ -1,2 +1,2 @@
        \\ one
    ;
    try std.testing.expectError(
        error.hunk_header_integrity_check_failed,
        parsePatchFile(std.testing.allocator, malformed),
    );
}
