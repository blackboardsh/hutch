const std = @import("std");

pub const Table = std.StringHashMap(Value);

pub const Value = union(enum) {
    string: []const u8,
    boolean: bool,
    integer: i64,
    float: f64,
    array: []const Value,
    table: *Table,
    /// Dates and other bare TOML values are retained so unrelated bunfig
    /// settings do not make install-option parsing fail.
    bare: []const u8,

    pub fn asString(value: Value) ?[]const u8 {
        return switch (value) {
            .string => |string| string,
            else => null,
        };
    }

    pub fn asBool(value: Value) ?bool {
        return switch (value) {
            .boolean => |boolean| boolean,
            else => null,
        };
    }

    pub fn asNumber(value: Value) ?f64 {
        return switch (value) {
            .integer => |integer| @floatFromInt(integer),
            .float => |float| float,
            else => null,
        };
    }

    pub fn asArray(value: Value) ?[]const Value {
        return switch (value) {
            .array => |array| array,
            else => null,
        };
    }

    pub fn asTable(value: Value) ?*Table {
        return switch (value) {
            .table => |table| table,
            else => null,
        };
    }
};

pub const Document = struct {
    backing_allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    root: *Table,

    pub fn deinit(document: *Document) void {
        document.arena.deinit();
        document.backing_allocator.destroy(document.arena);
        document.* = undefined;
    }

    pub fn get(document: *const Document, key: []const u8) ?Value {
        return document.root.get(key);
    }
};

pub fn parse(
    backing_allocator: std.mem.Allocator,
    source: []const u8,
) !Document {
    const arena = try backing_allocator.create(std.heap.ArenaAllocator);
    errdefer backing_allocator.destroy(arena);
    arena.* = .init(backing_allocator);
    errdefer arena.deinit();

    const allocator = arena.allocator();
    const root = try allocator.create(Table);
    root.* = Table.init(allocator);

    var parser: Parser = .{
        .allocator = allocator,
        .source = stripBom(source),
        .root = root,
    };
    try parser.parse();

    return .{
        .backing_allocator = backing_allocator,
        .arena = arena,
        .root = root,
    };
}

const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    root: *Table,
    index: usize = 0,
    current_table: []const []const u8 = &.{},

    fn parse(parser: *Parser) !void {
        while (true) {
            parser.skipDocumentWhitespace();
            if (parser.index >= parser.source.len) return;
            if (parser.source[parser.index] == '[') {
                if (parser.index + 1 < parser.source.len and
                    parser.source[parser.index + 1] == '[')
                {
                    return error.UnsupportedTomlArrayTable;
                }
                try parser.parseTableHeader();
            } else {
                try parser.parseAssignment();
            }
        }
    }

    fn parseTableHeader(parser: *Parser) !void {
        parser.index += 1;
        parser.skipHorizontalWhitespace();
        const path = try parser.parseKeyPath(']');
        parser.skipHorizontalWhitespace();
        try parser.expect(']');
        try parser.consumeLineEnd();
        _ = try ensureTable(parser.allocator, parser.root, path);
        parser.current_table = path;
    }

    fn parseAssignment(parser: *Parser) !void {
        const relative_path = try parser.parseKeyPath('=');
        parser.skipHorizontalWhitespace();
        try parser.expect('=');
        parser.skipHorizontalWhitespace();
        const value = try parser.parseValue();
        try parser.consumeLineEnd();

        const base = try ensureTable(
            parser.allocator,
            parser.root,
            parser.current_table,
        );
        if (relative_path.len == 0) return error.ExpectedTomlKey;
        const parent = try ensureTable(
            parser.allocator,
            base,
            relative_path[0 .. relative_path.len - 1],
        );
        const entry = try parent.getOrPut(relative_path[relative_path.len - 1]);
        if (entry.found_existing) return error.DuplicateTomlKey;
        entry.value_ptr.* = value;
    }

    fn parseKeyPath(parser: *Parser, terminator: u8) ![]const []const u8 {
        var parts = std.array_list.Managed([]const u8).init(parser.allocator);
        while (true) {
            parser.skipHorizontalWhitespace();
            if (parser.index >= parser.source.len) return error.UnexpectedEndOfToml;
            if (parser.source[parser.index] == terminator) break;
            try parts.append(try parser.parseKey());
            parser.skipHorizontalWhitespace();
            if (parser.index >= parser.source.len) return error.UnexpectedEndOfToml;
            if (parser.source[parser.index] == terminator) break;
            try parser.expect('.');
        }
        if (parts.items.len == 0) return error.ExpectedTomlKey;
        return parts.toOwnedSlice();
    }

    fn parseKey(parser: *Parser) ![]const u8 {
        if (parser.index >= parser.source.len) return error.UnexpectedEndOfToml;
        if (parser.source[parser.index] == '"' or parser.source[parser.index] == '\'') {
            return parser.parseString();
        }

        const start = parser.index;
        while (parser.index < parser.source.len) : (parser.index += 1) {
            const byte = parser.source[parser.index];
            if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') break;
        }
        if (parser.index == start) return error.ExpectedTomlKey;
        return parser.allocator.dupe(u8, parser.source[start..parser.index]);
    }

    fn parseValue(parser: *Parser) anyerror!Value {
        if (parser.index >= parser.source.len) return error.UnexpectedEndOfToml;
        return switch (parser.source[parser.index]) {
            '"', '\'' => .{ .string = try parser.parseString() },
            '[' => .{ .array = try parser.parseArray() },
            '{' => .{ .table = try parser.parseInlineTable() },
            else => try parser.parseBareValue(),
        };
    }

    fn parseString(parser: *Parser) ![]const u8 {
        const quote = parser.source[parser.index];
        const multiline = parser.index + 2 < parser.source.len and
            parser.source[parser.index + 1] == quote and
            parser.source[parser.index + 2] == quote;
        parser.index += if (multiline) 3 else 1;
        if (multiline and parser.index < parser.source.len and
            parser.source[parser.index] == '\n')
        {
            parser.index += 1;
        } else if (multiline and parser.index + 1 < parser.source.len and
            parser.source[parser.index] == '\r' and
            parser.source[parser.index + 1] == '\n')
        {
            parser.index += 2;
        }

        var output: std.Io.Writer.Allocating = .init(parser.allocator);
        while (parser.index < parser.source.len) {
            if (multiline) {
                if (parser.index + 2 < parser.source.len and
                    parser.source[parser.index] == quote and
                    parser.source[parser.index + 1] == quote and
                    parser.source[parser.index + 2] == quote)
                {
                    parser.index += 3;
                    return output.toOwnedSlice();
                }
            } else if (parser.source[parser.index] == quote) {
                parser.index += 1;
                return output.toOwnedSlice();
            }

            const byte = parser.source[parser.index];
            parser.index += 1;
            if (quote == '\'' or byte != '\\') {
                if (!multiline and (byte == '\n' or byte == '\r')) {
                    return error.UnterminatedTomlString;
                }
                try output.writer.writeByte(byte);
                continue;
            }
            if (parser.index >= parser.source.len) return error.UnterminatedTomlString;
            const escaped = parser.source[parser.index];
            parser.index += 1;
            switch (escaped) {
                'b' => try output.writer.writeByte(0x08),
                't' => try output.writer.writeByte('\t'),
                'n' => try output.writer.writeByte('\n'),
                'f' => try output.writer.writeByte(0x0c),
                'r' => try output.writer.writeByte('\r'),
                '"' => try output.writer.writeByte('"'),
                '\\' => try output.writer.writeByte('\\'),
                'u' => try parser.writeUnicodeEscape(&output.writer, 4),
                'U' => try parser.writeUnicodeEscape(&output.writer, 8),
                '\n' => if (multiline) parser.skipMultilineStringWhitespace() else return error.InvalidTomlEscape,
                '\r' => if (multiline and parser.index < parser.source.len and
                    parser.source[parser.index] == '\n')
                {
                    parser.index += 1;
                    parser.skipMultilineStringWhitespace();
                } else return error.InvalidTomlEscape,
                else => return error.InvalidTomlEscape,
            }
        }
        return error.UnterminatedTomlString;
    }

    fn writeUnicodeEscape(
        parser: *Parser,
        writer: *std.Io.Writer,
        digits: usize,
    ) !void {
        if (parser.index + digits > parser.source.len) return error.InvalidTomlEscape;
        const scalar = std.fmt.parseInt(
            u21,
            parser.source[parser.index .. parser.index + digits],
            16,
        ) catch return error.InvalidTomlEscape;
        parser.index += digits;
        var bytes: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(scalar, &bytes) catch
            return error.InvalidTomlEscape;
        try writer.writeAll(bytes[0..length]);
    }

    fn skipMultilineStringWhitespace(parser: *Parser) void {
        while (parser.index < parser.source.len and
            std.ascii.isWhitespace(parser.source[parser.index]))
        {
            parser.index += 1;
        }
    }

    fn parseArray(parser: *Parser) anyerror![]const Value {
        parser.index += 1;
        var values = std.array_list.Managed(Value).init(parser.allocator);
        while (true) {
            parser.skipCompositeWhitespace();
            if (parser.index >= parser.source.len) return error.UnexpectedEndOfToml;
            if (parser.source[parser.index] == ']') {
                parser.index += 1;
                return values.toOwnedSlice();
            }
            try values.append(try parser.parseValue());
            parser.skipCompositeWhitespace();
            if (parser.index >= parser.source.len) return error.UnexpectedEndOfToml;
            if (parser.source[parser.index] == ']') {
                parser.index += 1;
                return values.toOwnedSlice();
            }
            try parser.expect(',');
        }
    }

    fn parseInlineTable(parser: *Parser) anyerror!*Table {
        parser.index += 1;
        const table = try parser.allocator.create(Table);
        table.* = Table.init(parser.allocator);
        while (true) {
            parser.skipHorizontalWhitespace();
            if (parser.index >= parser.source.len) return error.UnexpectedEndOfToml;
            if (parser.source[parser.index] == '}') {
                parser.index += 1;
                return table;
            }
            const path = try parser.parseKeyPath('=');
            parser.skipHorizontalWhitespace();
            try parser.expect('=');
            parser.skipHorizontalWhitespace();
            const value = try parser.parseValue();
            const parent = try ensureTable(
                parser.allocator,
                table,
                path[0 .. path.len - 1],
            );
            const entry = try parent.getOrPut(path[path.len - 1]);
            if (entry.found_existing) return error.DuplicateTomlKey;
            entry.value_ptr.* = value;
            parser.skipHorizontalWhitespace();
            if (parser.index >= parser.source.len) return error.UnexpectedEndOfToml;
            if (parser.source[parser.index] == '}') {
                parser.index += 1;
                return table;
            }
            try parser.expect(',');
        }
    }

    fn parseBareValue(parser: *Parser) !Value {
        const start = parser.index;
        while (parser.index < parser.source.len) : (parser.index += 1) {
            switch (parser.source[parser.index]) {
                ',', ']', '}', '#', '\n', '\r' => break,
                else => {},
            }
        }
        const raw = std.mem.trim(u8, parser.source[start..parser.index], " \t");
        if (raw.len == 0) return error.ExpectedTomlValue;
        if (std.mem.eql(u8, raw, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, raw, "false")) return .{ .boolean = false };
        if (std.mem.eql(u8, raw, "inf") or std.mem.eql(u8, raw, "+inf")) {
            return .{ .float = std.math.inf(f64) };
        }
        if (std.mem.eql(u8, raw, "-inf")) return .{ .float = -std.math.inf(f64) };
        if (std.mem.eql(u8, raw, "nan") or std.mem.eql(u8, raw, "+nan")) {
            return .{ .float = std.math.nan(f64) };
        }
        if (std.mem.eql(u8, raw, "-nan")) return .{ .float = -std.math.nan(f64) };

        const normalized = try removeUnderscores(parser.allocator, raw);
        if (looksLikeInteger(normalized)) {
            if (std.fmt.parseInt(i64, normalized, 0)) |integer| {
                return .{ .integer = integer };
            } else |_| {}
        }
        if (std.fmt.parseFloat(f64, normalized)) |float| {
            return .{ .float = float };
        } else |_| {}
        return .{ .bare = try parser.allocator.dupe(u8, raw) };
    }

    fn skipDocumentWhitespace(parser: *Parser) void {
        while (parser.index < parser.source.len) {
            switch (parser.source[parser.index]) {
                ' ', '\t', '\r', '\n' => parser.index += 1,
                '#' => parser.skipComment(),
                else => return,
            }
        }
    }

    fn skipCompositeWhitespace(parser: *Parser) void {
        while (parser.index < parser.source.len) {
            switch (parser.source[parser.index]) {
                ' ', '\t', '\r', '\n' => parser.index += 1,
                '#' => parser.skipComment(),
                else => return,
            }
        }
    }

    fn skipHorizontalWhitespace(parser: *Parser) void {
        while (parser.index < parser.source.len and
            (parser.source[parser.index] == ' ' or parser.source[parser.index] == '\t'))
        {
            parser.index += 1;
        }
    }

    fn skipComment(parser: *Parser) void {
        while (parser.index < parser.source.len and
            parser.source[parser.index] != '\n')
        {
            parser.index += 1;
        }
    }

    fn consumeLineEnd(parser: *Parser) !void {
        parser.skipHorizontalWhitespace();
        if (parser.index < parser.source.len and parser.source[parser.index] == '#') {
            parser.skipComment();
        }
        if (parser.index >= parser.source.len) return;
        if (parser.source[parser.index] == '\r') {
            parser.index += 1;
            if (parser.index < parser.source.len and parser.source[parser.index] == '\n') {
                parser.index += 1;
            }
            return;
        }
        if (parser.source[parser.index] == '\n') {
            parser.index += 1;
            return;
        }
        return error.ExpectedTomlLineEnd;
    }

    fn expect(parser: *Parser, byte: u8) !void {
        if (parser.index >= parser.source.len) return error.UnexpectedEndOfToml;
        if (parser.source[parser.index] != byte) return error.UnexpectedTomlToken;
        parser.index += 1;
    }
};

fn ensureTable(
    allocator: std.mem.Allocator,
    root: *Table,
    path: []const []const u8,
) !*Table {
    var table = root;
    for (path) |part| {
        const entry = try table.getOrPut(part);
        if (!entry.found_existing) {
            const child = try allocator.create(Table);
            child.* = Table.init(allocator);
            entry.value_ptr.* = .{ .table = child };
        }
        table = entry.value_ptr.asTable() orelse return error.TomlTableConflict;
    }
    return table;
}

fn stripBom(source: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF"))
        source[3..]
    else
        source;
}

fn removeUnderscores(
    allocator: std.mem.Allocator,
    source: []const u8,
) ![]const u8 {
    if (std.mem.indexOfScalar(u8, source, '_') == null) return source;
    var result = try allocator.alloc(u8, source.len);
    var length: usize = 0;
    for (source) |byte| {
        if (byte == '_') continue;
        result[length] = byte;
        length += 1;
    }
    return result[0..length];
}

fn looksLikeInteger(source: []const u8) bool {
    if (std.mem.indexOfAny(u8, source, ".eE") != null) return false;
    for (source) |byte| {
        if (byte == '-' or byte == '+' or byte == 'x' or byte == 'o' or byte == 'b' or
            std.ascii.isHex(byte))
        {
            continue;
        }
        return false;
    }
    return true;
}

test "TOML parses install tables, dotted keys, arrays, and inline tables" {
    const testing = std.testing;
    var document = try parse(testing.allocator,
        \\install.saveTextLockfile = false
        \\[install]
        \\registry = { url = "https://registry.example/", token = "secret" }
        \\minimumReleaseAgeExcludes = [
        \\  "first",
        \\  "second",
        \\]
        \\[install.security]
        \\scanner = "./scanner.ts"
        \\[install.scopes]
        \\"@acme" = { url = "https://registry.example/acme/" }
    );
    defer document.deinit();

    const install = document.get("install").?.asTable().?;
    try testing.expectEqual(false, install.get("saveTextLockfile").?.asBool().?);
    const registry = install.get("registry").?.asTable().?;
    try testing.expectEqualStrings(
        "https://registry.example/",
        registry.get("url").?.asString().?,
    );
    try testing.expectEqual(
        @as(usize, 2),
        install.get("minimumReleaseAgeExcludes").?.asArray().?.len,
    );
    try testing.expectEqualStrings(
        "./scanner.ts",
        install.get("security").?.asTable().?.get("scanner").?.asString().?,
    );
}
