const std = @import("std");

const max_config_bytes = 16 * 1024 * 1024;

pub const Rewrite = struct {
    content: []const u8,
    previous: []const u8,
};

const TokenKind = enum { identifier, string, punctuation, template };

const Token = struct {
    kind: TokenKind,
    start: usize,
    end: usize,
};

const ScanError = error{
    UnterminatedComment,
    UnterminatedString,
    UnterminatedTemplate,
};

pub fn rewriteSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    version: []const u8,
) !Rewrite {
    _ = std.SemanticVersion.parse(version) catch return error.InvalidElectrobunVersion;

    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(allocator);
    var cursor: usize = 0;
    while (try nextToken(source, &cursor)) |token| try tokens.append(allocator, token);

    var match: ?Token = null;
    var index: usize = 0;
    while (index + 2 < tokens.items.len) : (index += 1) {
        if (!tokenIsKey(source, tokens.items[index], "electrobun") or
            !tokenIsPunctuation(source, tokens.items[index + 1], ':') or
            !tokenIsPunctuation(source, tokens.items[index + 2], '{')) continue;

        var depth: usize = 1;
        var field = index + 3;
        while (field < tokens.items.len and depth > 0) : (field += 1) {
            const token = tokens.items[field];
            if (tokenIsPunctuation(source, token, '{')) {
                depth += 1;
                continue;
            }
            if (tokenIsPunctuation(source, token, '}')) {
                depth -= 1;
                continue;
            }
            if (depth != 1 or field + 2 >= tokens.items.len or
                !tokenIsKey(source, token, "version") or
                !tokenIsPunctuation(source, tokens.items[field + 1], ':')) continue;

            const value = tokens.items[field + 2];
            if (value.kind != .string) return error.ElectrobunVersionMustBeStringLiteral;
            if (stringHasEscape(source, value)) return error.ElectrobunVersionMustBePlainLiteral;
            if (match != null) return error.AmbiguousElectrobunVersion;
            match = value;
        }
    }

    const value = match orelse return error.ElectrobunVersionNotFound;
    const previous = source[value.start + 1 .. value.end - 1];
    _ = std.SemanticVersion.parse(previous) catch return error.InvalidExistingElectrobunVersion;
    const quote = source[value.start];

    var content: std.ArrayList(u8) = .empty;
    try content.appendSlice(allocator, source[0..value.start]);
    try content.append(allocator, quote);
    try content.appendSlice(allocator, version);
    try content.append(allocator, quote);
    try content.appendSlice(allocator, source[value.end..]);
    return .{
        .content = content.items,
        .previous = previous,
    };
}

pub fn pinConfigFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    expected_previous: []const u8,
    version: []const u8,
) !Rewrite {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_config_bytes));
    const rewrite = try rewriteSource(allocator, source, version);
    if (!std.mem.eql(u8, rewrite.previous, expected_previous)) {
        return error.ElectrobunVersionSourceMismatch;
    }
    if (std.mem.eql(u8, source, rewrite.content)) return rewrite;

    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer atomic_file.deinit(io);
    var write_buffer: [4096]u8 = undefined;
    var writer = atomic_file.file.writer(io, &write_buffer);
    try writer.interface.writeAll(rewrite.content);
    try writer.interface.flush();
    try atomic_file.file.sync(io);
    try atomic_file.replace(io);
    return rewrite;
}

fn nextToken(source: []const u8, cursor: *usize) ScanError!?Token {
    while (cursor.* < source.len) {
        const byte = source[cursor.*];
        if (std.ascii.isWhitespace(byte)) {
            cursor.* += 1;
            continue;
        }
        if (byte == '/' and cursor.* + 1 < source.len and source[cursor.* + 1] == '/') {
            cursor.* += 2;
            while (cursor.* < source.len and source[cursor.*] != '\n' and source[cursor.*] != '\r') cursor.* += 1;
            continue;
        }
        if (byte == '/' and cursor.* + 1 < source.len and source[cursor.* + 1] == '*') {
            cursor.* += 2;
            while (cursor.* + 1 < source.len and
                !(source[cursor.*] == '*' and source[cursor.* + 1] == '/')) cursor.* += 1;
            if (cursor.* + 1 >= source.len) return error.UnterminatedComment;
            cursor.* += 2;
            continue;
        }
        break;
    }
    if (cursor.* >= source.len) return null;

    const start = cursor.*;
    const byte = source[start];
    if (byte == '\'' or byte == '"') {
        cursor.* += 1;
        while (cursor.* < source.len) {
            if (source[cursor.*] == '\\') {
                cursor.* += 1;
                if (cursor.* >= source.len) return error.UnterminatedString;
                cursor.* += 1;
                continue;
            }
            if (source[cursor.*] == byte) {
                cursor.* += 1;
                return .{ .kind = .string, .start = start, .end = cursor.* };
            }
            cursor.* += 1;
        }
        return error.UnterminatedString;
    }
    if (byte == '`') {
        cursor.* = try skipTemplate(source, start);
        return .{ .kind = .template, .start = start, .end = cursor.* };
    }
    if (isIdentifierStart(byte)) {
        cursor.* += 1;
        while (cursor.* < source.len and isIdentifierContinue(source[cursor.*])) cursor.* += 1;
        return .{ .kind = .identifier, .start = start, .end = cursor.* };
    }

    cursor.* += 1;
    return .{ .kind = .punctuation, .start = start, .end = cursor.* };
}

fn skipTemplate(source: []const u8, start: usize) ScanError!usize {
    var cursor = start + 1;
    while (cursor < source.len) {
        if (source[cursor] == '\\') {
            cursor += 1;
            if (cursor >= source.len) return error.UnterminatedTemplate;
            cursor += 1;
            continue;
        }
        if (source[cursor] == '`') return cursor + 1;
        if (source[cursor] == '$' and cursor + 1 < source.len and source[cursor + 1] == '{') {
            cursor = try skipTemplateExpression(source, cursor + 2);
            continue;
        }
        cursor += 1;
    }
    return error.UnterminatedTemplate;
}

fn skipTemplateExpression(source: []const u8, start: usize) ScanError!usize {
    var cursor = start;
    var depth: usize = 1;
    while (cursor < source.len) {
        const byte = source[cursor];
        if (byte == '\'' or byte == '"') {
            cursor = try skipQuoted(source, cursor, byte);
            continue;
        }
        if (byte == '`') {
            cursor = try skipTemplate(source, cursor);
            continue;
        }
        if (byte == '/' and cursor + 1 < source.len and source[cursor + 1] == '/') {
            cursor += 2;
            while (cursor < source.len and source[cursor] != '\n' and source[cursor] != '\r') cursor += 1;
            continue;
        }
        if (byte == '/' and cursor + 1 < source.len and source[cursor + 1] == '*') {
            cursor += 2;
            while (cursor + 1 < source.len and
                !(source[cursor] == '*' and source[cursor + 1] == '/')) cursor += 1;
            if (cursor + 1 >= source.len) return error.UnterminatedComment;
            cursor += 2;
            continue;
        }
        if (byte == '{') depth += 1;
        if (byte == '}') {
            depth -= 1;
            if (depth == 0) return cursor + 1;
        }
        cursor += 1;
    }
    return error.UnterminatedTemplate;
}

fn skipQuoted(source: []const u8, start: usize, quote: u8) ScanError!usize {
    var cursor = start + 1;
    while (cursor < source.len) {
        if (source[cursor] == '\\') {
            cursor += 1;
            if (cursor >= source.len) return error.UnterminatedString;
            cursor += 1;
            continue;
        }
        if (source[cursor] == quote) return cursor + 1;
        cursor += 1;
    }
    return error.UnterminatedString;
}

fn isIdentifierStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == '$';
}

fn isIdentifierContinue(byte: u8) bool {
    return isIdentifierStart(byte) or std.ascii.isDigit(byte);
}

fn tokenIsKey(source: []const u8, token: Token, expected: []const u8) bool {
    return switch (token.kind) {
        .identifier => std.mem.eql(u8, source[token.start..token.end], expected),
        .string => !stringHasEscape(source, token) and
            std.mem.eql(u8, source[token.start + 1 .. token.end - 1], expected),
        else => false,
    };
}

fn tokenIsPunctuation(source: []const u8, token: Token, expected: u8) bool {
    return token.kind == .punctuation and token.end == token.start + 1 and source[token.start] == expected;
}

fn stringHasEscape(source: []const u8, token: Token) bool {
    return std.mem.indexOfScalar(u8, source[token.start + 1 .. token.end - 1], '\\') != null;
}

test "rewrites only the direct electrobun version literal" {
    const source =
        \\// @hutch cli=0.24.3
        \\const decoy = `electrobun: { version: "9.9.9" }`;
        \\export default {
        \\  scripts: { version: "leave-me" },
        \\  electrobun: {
        \\    channel: { version: "also-leave-me" },
        \\    version: "2.0.1-beta.29",
        \\  },
        \\};
        \\
    ;
    const rewrite = try rewriteSource(std.testing.allocator, source, "2.0.1");
    defer std.testing.allocator.free(rewrite.content);
    try std.testing.expectEqualStrings("2.0.1-beta.29", rewrite.previous);
    try std.testing.expect(std.mem.indexOf(u8, rewrite.content, "version: \"2.0.1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewrite.content, "version: \"leave-me\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewrite.content, "version: \"also-leave-me\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewrite.content, "version: \"9.9.9\"") != null);
}

test "ignores electrobun-shaped text in nested template expressions" {
    const source =
        \\const decoy = `${`electrobun: { version: "2.0.0" }`} ${JSON.stringify({ electrobun: { version: "2.0.0" } })}`;
        \\export default { electrobun: { version: "2.0.0" } };
        \\
    ;
    const rewrite = try rewriteSource(std.testing.allocator, source, "2.0.1");
    defer std.testing.allocator.free(rewrite.content);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, rewrite.content, "version: \"2.0.0\""));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rewrite.content, "version: \"2.0.1\""));
}

test "supports quoted keys and single-quoted versions" {
    const source = "export default { 'electrobun': { 'version': '2.0.0' } };\n";
    const rewrite = try rewriteSource(std.testing.allocator, source, "2.0.1");
    defer std.testing.allocator.free(rewrite.content);
    try std.testing.expectEqualStrings(
        "export default { 'electrobun': { 'version': '2.0.1' } };\n",
        rewrite.content,
    );
}

test "fails closed for missing ambiguous or computed pins" {
    try std.testing.expectError(
        error.ElectrobunVersionNotFound,
        rewriteSource(std.testing.allocator, "export default {};\n", "2.0.1"),
    );
    try std.testing.expectError(
        error.AmbiguousElectrobunVersion,
        rewriteSource(
            std.testing.allocator,
            "export default { electrobun: { version: '2.0.0', version: '2.0.0' } };\n",
            "2.0.1",
        ),
    );
    try std.testing.expectError(
        error.ElectrobunVersionMustBeStringLiteral,
        rewriteSource(
            std.testing.allocator,
            "export default { electrobun: { version: CURRENT } };\n",
            "2.0.1",
        ),
    );
}
