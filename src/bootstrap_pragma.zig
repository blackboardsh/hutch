const std = @import("std");
const version_selector = @import("version_selector.zig");

const prefix = "// @dash";
const max_first_line_bytes = 4096;

pub const Pragma = struct {
    cli: ?version_selector.Selector = null,
    cottontail: ?version_selector.Selector = null,

    fn overlay(self: *Pragma, other: Pragma) void {
        if (other.cli != null) self.cli = other.cli;
        if (other.cottontail != null) self.cottontail = other.cottontail;
    }
};

pub fn parseFirstLine(line_with_ending: []const u8) !?Pragma {
    const newline = std.mem.indexOfAny(u8, line_with_ending, "\r\n") orelse line_with_ending.len;
    const line = line_with_ending[0..newline];
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    if (line.len > prefix.len and line[prefix.len] != ' ' and line[prefix.len] != '\t') {
        return null;
    }

    var pragma: Pragma = .{};
    var fields = std.mem.tokenizeAny(u8, line[prefix.len..], " \t");
    var found = false;
    while (fields.next()) |field| {
        found = true;
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse return error.InvalidDashPragmaField;
        if (equals == 0 or equals + 1 == field.len) return error.InvalidDashPragmaField;
        if (std.mem.indexOfScalarPos(u8, field, equals + 1, '=') != null) {
            return error.InvalidDashPragmaField;
        }
        const key = field[0..equals];
        const value = field[equals + 1 ..];
        const selector = try version_selector.parse(value);

        if (std.mem.eql(u8, key, "cli")) {
            if (pragma.cli != null) return error.DuplicateDashPragmaField;
            pragma.cli = selector;
        } else if (std.mem.eql(u8, key, "cottontail")) {
            if (pragma.cottontail != null) return error.DuplicateDashPragmaField;
            pragma.cottontail = selector;
        } else {
            return error.UnknownDashPragmaField;
        }
    }
    if (!found) return error.EmptyDashPragma;
    return pragma;
}

pub fn parseFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !?Pragma {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var reader_buffer: [max_first_line_bytes]u8 = undefined;
    var source_buffer: [max_first_line_bytes]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    const count = try reader.interface.readSliceShort(&source_buffer);
    const source = source_buffer[0..count];
    if (source.len == max_first_line_bytes and std.mem.indexOfAny(u8, source, "\r\n") == null) {
        return error.DashPragmaLineTooLong;
    }
    const owned = try allocator.dupe(u8, source);
    return parseFirstLine(owned);
}

pub fn findNearestConfig(
    io: std.Io,
    allocator: std.mem.Allocator,
) !?[]const u8 {
    var current: []const u8 = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    while (true) {
        // hutch.config.* is the canonical name; dash.config.* remains
        // supported as the legacy name.
        for ([_][]const u8{
            "hutch.config.ts",
            "hutch.config.js",
            "hutch.config.mjs",
            "dash.config.ts",
            "dash.config.js",
            "dash.config.mjs",
        }) |name| {
            const candidate = try std.fs.path.join(allocator, &.{ current, name });
            if (absolutePathExists(io, candidate)) return candidate;
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        current = parent;
    }
    return null;
}

pub fn discover(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    command_args: []const [:0]const u8,
) !Pragma {
    var result: Pragma = .{};
    if (try findNearestConfig(init.io, allocator)) |config_path| {
        if (try parseFile(init.io, allocator, config_path)) |config_pragma| {
            result.overlay(config_pragma);
        }
    }

    if (entrypointArgument(init.io, command_args)) |entrypoint| {
        if (try parseFile(init.io, allocator, entrypoint)) |entrypoint_pragma| {
            result.overlay(entrypoint_pragma);
        }
    }
    return result;
}

fn entrypointArgument(io: std.Io, args: []const [:0]const u8) ?[]const u8 {
    if (args.len == 0) return null;
    const candidate = args[0];
    if (candidate.len == 0 or candidate[0] == '-') return null;
    if (!hasScriptExtension(candidate)) return null;
    std.Io.Dir.cwd().access(io, candidate, .{}) catch return null;
    return candidate;
}

fn hasScriptExtension(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".js") or
        std.mem.endsWith(u8, path, ".mjs") or
        std.mem.endsWith(u8, path, ".cjs") or
        std.mem.endsWith(u8, path, ".ts") or
        std.mem.endsWith(u8, path, ".mts") or
        std.mem.endsWith(u8, path, ".cts");
}

fn absolutePathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

test "strict dash pragma parses independent CLI and runtime selectors" {
    const pragma = (try parseFirstLine(
        "// @dash cli=1.4.0 cottontail=build:0123456789abcdef0123456789abcdef01234567\r\n",
    )).?;
    try std.testing.expectEqual(version_selector.Kind.version, pragma.cli.?.kind);
    try std.testing.expectEqual(version_selector.Kind.build, pragma.cottontail.?.kind);

    const stable = (try parseFirstLine(
        "// @dash cli=stable cottontail=stable\n",
    )).?;
    try std.testing.expectEqual(version_selector.Kind.production, stable.cli.?.kind);
    try std.testing.expectEqualStrings("production", stable.cli.?.value);
    try std.testing.expectEqual(version_selector.Kind.production, stable.cottontail.?.kind);
}

test "ordinary comments are not dash pragmas" {
    try std.testing.expect((try parseFirstLine("// @dashboard is unrelated\n")) == null);
    try std.testing.expect((try parseFirstLine("// source file\n")) == null);
}

test "dash pragma rejects unknown, duplicate, and malformed fields" {
    try std.testing.expectError(
        error.UnknownDashPragmaField,
        parseFirstLine("// @dash runtime=production\n"),
    );
    try std.testing.expectError(
        error.DuplicateDashPragmaField,
        parseFirstLine("// @dash cli=production cli=canary\n"),
    );
    try std.testing.expectError(
        error.InvalidDashPragmaField,
        parseFirstLine("// @dash cli\n"),
    );
    try std.testing.expectError(error.EmptyDashPragma, parseFirstLine("// @dash\n"));
}
