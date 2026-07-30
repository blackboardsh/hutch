const std = @import("std");

const Value = std.json.Value;

pub const ParseError = error{InvalidYaml} || std.mem.Allocator.Error;

const Line = struct {
    indent: usize,
    text: []const u8,
};

/// Parse the YAML subset emitted by pnpm for pnpm-lock.yaml files.
///
/// Pnpm lockfiles use block maps and sequences plus inline maps, inline
/// sequences, and YAML scalar quoting. They do not use aliases, tags, complex
/// keys, or block scalar strings, so those general-purpose YAML features stay
/// out of this package-manager-only parser.
pub fn parse(allocator: std.mem.Allocator, source_raw: []const u8) ParseError!Value {
    var parser = Parser{
        .allocator = allocator,
        .source = if (std.mem.startsWith(u8, source_raw, "\xEF\xBB\xBF"))
            source_raw[3..]
        else
            source_raw,
        .lines = .init(allocator),
    };
    defer parser.lines.deinit();

    try parser.collectLines();
    if (parser.lines.items.len == 0) return .null;

    const root_indent = parser.lines.items[0].indent;
    const value = try parser.parseBlock(root_indent);
    if (parser.index != parser.lines.items.len) return error.InvalidYaml;
    return value;
}

const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    lines: std.array_list.Managed(Line),
    index: usize = 0,

    fn collectLines(parser: *Parser) ParseError!void {
        var iterator = std.mem.splitScalar(u8, parser.source, '\n');
        var document_started = false;
        var document_ended = false;

        while (iterator.next()) |raw_with_cr| {
            const raw = if (raw_with_cr.len > 0 and raw_with_cr[raw_with_cr.len - 1] == '\r')
                raw_with_cr[0 .. raw_with_cr.len - 1]
            else
                raw_with_cr;

            var indent: usize = 0;
            while (indent < raw.len and raw[indent] == ' ') : (indent += 1) {}
            if (indent < raw.len and raw[indent] == '\t') return error.InvalidYaml;

            const without_comment = stripComment(raw[indent..]);
            const text = std.mem.trimEnd(u8, without_comment, " \t");
            if (text.len == 0) continue;

            if (std.mem.eql(u8, text, "---")) {
                if (document_started or document_ended or parser.lines.items.len != 0) {
                    return error.InvalidYaml;
                }
                document_started = true;
                continue;
            }
            if (std.mem.eql(u8, text, "...")) {
                if (document_ended) return error.InvalidYaml;
                document_ended = true;
                continue;
            }
            if (document_ended) return error.InvalidYaml;
            if (text[0] == '%') return error.InvalidYaml;

            try parser.lines.append(.{
                .indent = indent,
                .text = text,
            });
        }
    }

    fn parseBlock(parser: *Parser, indent: usize) ParseError!Value {
        if (parser.index >= parser.lines.items.len) return error.InvalidYaml;
        const line = parser.lines.items[parser.index];
        if (line.indent != indent) return error.InvalidYaml;
        return if (isSequenceLine(line.text))
            parser.parseSequence(indent)
        else
            parser.parseMap(indent);
    }

    fn parseMap(parser: *Parser, indent: usize) ParseError!Value {
        var object: std.json.ObjectMap = .empty;

        while (parser.index < parser.lines.items.len) {
            const line = parser.lines.items[parser.index];
            if (line.indent < indent) break;
            if (line.indent > indent or isSequenceLine(line.text)) return error.InvalidYaml;

            parser.index += 1;
            try parser.appendMapEntry(&object, indent, line.text);
        }

        return .{ .object = object };
    }

    fn parseSequence(parser: *Parser, indent: usize) ParseError!Value {
        var array = std.json.Array.init(parser.allocator);

        while (parser.index < parser.lines.items.len) {
            const line = parser.lines.items[parser.index];
            if (line.indent < indent) break;
            if (line.indent > indent or !isSequenceLine(line.text)) return error.InvalidYaml;

            var content_offset: usize = 1;
            while (content_offset < line.text.len and
                (line.text[content_offset] == ' ' or line.text[content_offset] == '\t'))
            {
                content_offset += 1;
            }
            const content = line.text[content_offset..];
            parser.index += 1;

            if (content.len == 0) {
                if (parser.index < parser.lines.items.len and
                    parser.lines.items[parser.index].indent > indent)
                {
                    try array.append(try parser.parseBlock(parser.lines.items[parser.index].indent));
                } else {
                    try array.append(.null);
                }
                continue;
            }

            if (splitMapping(content) != null and content[0] != '{' and content[0] != '[') {
                const map_indent = indent + content_offset;
                try array.append(try parser.parseCompactMap(map_indent, content));
                continue;
            }

            try array.append(try parseInline(parser.allocator, content));
            if (parser.index < parser.lines.items.len and
                parser.lines.items[parser.index].indent > indent)
            {
                return error.InvalidYaml;
            }
        }

        return .{ .array = array };
    }

    fn parseCompactMap(parser: *Parser, indent: usize, first: []const u8) ParseError!Value {
        var object: std.json.ObjectMap = .empty;
        try parser.appendMapEntry(&object, indent, first);

        while (parser.index < parser.lines.items.len) {
            const line = parser.lines.items[parser.index];
            if (line.indent < indent) break;
            if (line.indent > indent or isSequenceLine(line.text)) return error.InvalidYaml;
            parser.index += 1;
            try parser.appendMapEntry(&object, indent, line.text);
        }

        return .{ .object = object };
    }

    fn appendMapEntry(
        parser: *Parser,
        object: *std.json.ObjectMap,
        indent: usize,
        text: []const u8,
    ) ParseError!void {
        const pair = splitMapping(text) orelse return error.InvalidYaml;
        const key = try parseKey(parser.allocator, pair.key);

        const value = if (pair.value.len != 0)
            try parseInline(parser.allocator, pair.value)
        else if (parser.index < parser.lines.items.len and
            parser.lines.items[parser.index].indent > indent)
            try parser.parseBlock(parser.lines.items[parser.index].indent)
        else
            Value.null;

        try object.put(parser.allocator, key, value);
    }
};

const Mapping = struct {
    key: []const u8,
    value: []const u8,
};

fn splitMapping(text_raw: []const u8) ?Mapping {
    const text = std.mem.trim(u8, text_raw, " \t");
    var single_quoted = false;
    var escaped_single_quote = false;
    var double_quoted = false;
    var escaped = false;
    var flow_depth: usize = 0;

    for (text, 0..) |byte, index| {
        if (double_quoted) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                double_quoted = false;
            }
            continue;
        }
        if (single_quoted) {
            if (escaped_single_quote) {
                escaped_single_quote = false;
                continue;
            }
            if (byte == '\'') {
                if (index + 1 < text.len and text[index + 1] == '\'') {
                    escaped_single_quote = true;
                } else {
                    single_quoted = false;
                }
            }
            continue;
        }

        switch (byte) {
            '\'' => single_quoted = true,
            '"' => double_quoted = true,
            '{', '[' => flow_depth += 1,
            '}', ']' => {
                if (flow_depth == 0) return null;
                flow_depth -= 1;
            },
            ':' => {
                const separated = index + 1 == text.len or
                    text[index + 1] == ' ' or
                    text[index + 1] == '\t';
                if (flow_depth == 0 and separated) {
                    const key = std.mem.trim(u8, text[0..index], " \t");
                    if (key.len == 0) return null;
                    return .{
                        .key = key,
                        .value = std.mem.trim(u8, text[index + 1 ..], " \t"),
                    };
                }
            },
            else => {},
        }
    }
    return null;
}

fn isSequenceLine(text: []const u8) bool {
    return text.len > 0 and text[0] == '-' and
        (text.len == 1 or text[1] == ' ' or text[1] == '\t');
}

fn stripComment(text: []const u8) []const u8 {
    var single_quoted = false;
    var double_quoted = false;
    var escaped = false;
    var index: usize = 0;

    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (double_quoted) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                double_quoted = false;
            }
            continue;
        }
        if (single_quoted) {
            if (byte == '\'' and index + 1 < text.len and text[index + 1] == '\'') {
                index += 1;
            } else if (byte == '\'') {
                single_quoted = false;
            }
            continue;
        }

        if (byte == '\'') {
            single_quoted = true;
        } else if (byte == '"') {
            double_quoted = true;
        } else if (byte == '#' and
            (index == 0 or text[index - 1] == ' ' or text[index - 1] == '\t'))
        {
            return text[0..index];
        }
    }
    return text;
}

fn parseKey(allocator: std.mem.Allocator, source: []const u8) ParseError![]const u8 {
    const value = try parseInline(allocator, source);
    return if (value == .string) value.string else error.InvalidYaml;
}

fn parseInline(allocator: std.mem.Allocator, source: []const u8) ParseError!Value {
    var parser = InlineParser{
        .allocator = allocator,
        .source = std.mem.trim(u8, source, " \t"),
    };
    const value = try parser.parseValue();
    parser.skipWhitespace();
    if (parser.index != parser.source.len) return error.InvalidYaml;
    return value;
}

const InlineParser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    index: usize = 0,

    fn parseValue(parser: *InlineParser) ParseError!Value {
        parser.skipWhitespace();
        if (parser.index >= parser.source.len) return error.InvalidYaml;

        return switch (parser.source[parser.index]) {
            '{' => parser.parseFlowMap(),
            '[' => parser.parseFlowSequence(),
            '\'' => .{ .string = try parser.parseSingleQuoted() },
            '"' => .{ .string = try parser.parseDoubleQuoted() },
            '|', '>' => error.InvalidYaml,
            else => parser.parsePlain(),
        };
    }

    fn parseFlowMap(parser: *InlineParser) ParseError!Value {
        parser.index += 1;
        var object: std.json.ObjectMap = .empty;
        parser.skipWhitespace();
        if (parser.consume('}')) return .{ .object = object };

        while (true) {
            const key = try parser.parseFlowKey();
            parser.skipWhitespace();
            if (!parser.consume(':')) return error.InvalidYaml;
            parser.skipWhitespace();

            const value = if (parser.index < parser.source.len and
                (parser.source[parser.index] == ',' or parser.source[parser.index] == '}'))
                Value.null
            else
                try parser.parseValue();
            try object.put(parser.allocator, key, value);

            parser.skipWhitespace();
            if (parser.consume('}')) break;
            if (!parser.consume(',')) return error.InvalidYaml;
            parser.skipWhitespace();
            if (parser.index >= parser.source.len or parser.source[parser.index] == '}') {
                return error.InvalidYaml;
            }
        }

        return .{ .object = object };
    }

    fn parseFlowSequence(parser: *InlineParser) ParseError!Value {
        parser.index += 1;
        var array = std.json.Array.init(parser.allocator);
        parser.skipWhitespace();
        if (parser.consume(']')) return .{ .array = array };

        while (true) {
            try array.append(try parser.parseValue());
            parser.skipWhitespace();
            if (parser.consume(']')) break;
            if (!parser.consume(',')) return error.InvalidYaml;
            parser.skipWhitespace();
            if (parser.index >= parser.source.len or parser.source[parser.index] == ']') {
                return error.InvalidYaml;
            }
        }

        return .{ .array = array };
    }

    fn parseFlowKey(parser: *InlineParser) ParseError![]const u8 {
        parser.skipWhitespace();
        if (parser.index >= parser.source.len) return error.InvalidYaml;
        if (parser.source[parser.index] == '\'') return parser.parseSingleQuoted();
        if (parser.source[parser.index] == '"') return parser.parseDoubleQuoted();

        const start = parser.index;
        while (parser.index < parser.source.len and parser.source[parser.index] != ':') {
            if (parser.source[parser.index] == ',' or
                parser.source[parser.index] == '}' or
                parser.source[parser.index] == '[' or
                parser.source[parser.index] == '{')
            {
                return error.InvalidYaml;
            }
            parser.index += 1;
        }
        const text = std.mem.trim(u8, parser.source[start..parser.index], " \t");
        if (text.len == 0) return error.InvalidYaml;
        const value = scalarValue(parser.allocator, text) catch |err| return err;
        return if (value == .string) value.string else error.InvalidYaml;
    }

    fn parsePlain(parser: *InlineParser) ParseError!Value {
        const start = parser.index;
        while (parser.index < parser.source.len) {
            switch (parser.source[parser.index]) {
                ',', ']', '}' => break,
                else => parser.index += 1,
            }
        }
        const text = std.mem.trim(u8, parser.source[start..parser.index], " \t");
        if (text.len == 0) return error.InvalidYaml;
        return scalarValue(parser.allocator, text);
    }

    fn parseSingleQuoted(parser: *InlineParser) ParseError![]const u8 {
        parser.index += 1;
        var output = std.array_list.Managed(u8).init(parser.allocator);

        while (parser.index < parser.source.len) {
            const byte = parser.source[parser.index];
            parser.index += 1;
            if (byte != '\'') {
                try output.append(byte);
                continue;
            }
            if (parser.index < parser.source.len and parser.source[parser.index] == '\'') {
                parser.index += 1;
                try output.append('\'');
                continue;
            }
            return output.toOwnedSlice();
        }

        return error.InvalidYaml;
    }

    fn parseDoubleQuoted(parser: *InlineParser) ParseError![]const u8 {
        const start = parser.index;
        parser.index += 1;
        var escaped = false;

        while (parser.index < parser.source.len) {
            const byte = parser.source[parser.index];
            parser.index += 1;
            if (escaped) {
                escaped = false;
                continue;
            }
            if (byte == '\\') {
                escaped = true;
                continue;
            }
            if (byte == '"') {
                const encoded = parser.source[start..parser.index];
                const value = std.json.parseFromSliceLeaky(
                    Value,
                    parser.allocator,
                    encoded,
                    .{},
                ) catch return error.InvalidYaml;
                return if (value == .string) value.string else error.InvalidYaml;
            }
        }

        return error.InvalidYaml;
    }

    fn skipWhitespace(parser: *InlineParser) void {
        while (parser.index < parser.source.len and
            (parser.source[parser.index] == ' ' or parser.source[parser.index] == '\t'))
        {
            parser.index += 1;
        }
    }

    fn consume(parser: *InlineParser, expected: u8) bool {
        if (parser.index >= parser.source.len or parser.source[parser.index] != expected) {
            return false;
        }
        parser.index += 1;
        return true;
    }
};

fn scalarValue(allocator: std.mem.Allocator, text: []const u8) ParseError!Value {
    if (std.mem.eql(u8, text, "~") or
        std.mem.eql(u8, text, "null") or
        std.mem.eql(u8, text, "Null") or
        std.mem.eql(u8, text, "NULL"))
    {
        return .null;
    }
    if (std.mem.eql(u8, text, "true") or
        std.mem.eql(u8, text, "True") or
        std.mem.eql(u8, text, "TRUE"))
    {
        return .{ .bool = true };
    }
    if (std.mem.eql(u8, text, "false") or
        std.mem.eql(u8, text, "False") or
        std.mem.eql(u8, text, "FALSE"))
    {
        return .{ .bool = false };
    }
    if (parseNumber(text)) |number| return number;
    return .{ .string = try allocator.dupe(u8, text) };
}

fn parseNumber(text: []const u8) ?Value {
    if (text.len == 0) return null;

    const negative = text[0] == '-';
    const unsigned = if (text[0] == '+' or negative) text[1..] else text;
    if (unsigned.len == 0) return null;

    if (std.mem.eql(u8, unsigned, ".inf") or
        std.mem.eql(u8, unsigned, ".Inf") or
        std.mem.eql(u8, unsigned, ".INF"))
    {
        return .{ .float = if (negative) -std.math.inf(f64) else std.math.inf(f64) };
    }
    if (!negative and
        (std.mem.eql(u8, unsigned, ".nan") or
            std.mem.eql(u8, unsigned, ".NaN") or
            std.mem.eql(u8, unsigned, ".NAN")))
    {
        return .{ .float = std.math.nan(f64) };
    }

    if (std.mem.startsWith(u8, unsigned, "0x") or
        std.mem.startsWith(u8, unsigned, "0X") or
        std.mem.startsWith(u8, unsigned, "0o") or
        std.mem.startsWith(u8, unsigned, "0O"))
    {
        const magnitude = std.fmt.parseUnsigned(u64, unsigned, 0) catch return null;
        if (negative) {
            if (magnitude > @as(u64, @intCast(std.math.maxInt(i64))) + 1) return null;
            if (magnitude == @as(u64, @intCast(std.math.maxInt(i64))) + 1) {
                return .{ .integer = std.math.minInt(i64) };
            }
            return .{ .integer = -@as(i64, @intCast(magnitude)) };
        }
        if (magnitude <= std.math.maxInt(i64)) {
            return .{ .integer = @intCast(magnitude) };
        }
        return .{ .float = @floatFromInt(magnitude) };
    }

    for (unsigned) |byte| {
        switch (byte) {
            '0'...'9', '.', 'e', 'E', '+', '-' => {},
            else => return null,
        }
    }
    if (unsigned[0] != '.' and (unsigned[0] < '0' or unsigned[0] > '9')) return null;

    const number = std.fmt.parseFloat(f64, text) catch return null;
    if (std.math.isFinite(number) and
        number == @trunc(number) and
        number >= @as(f64, @floatFromInt(std.math.minInt(i64))) and
        number <= @as(f64, @floatFromInt(std.math.maxInt(i64))))
    {
        return .{ .integer = @intFromFloat(number) };
    }
    return .{ .float = number };
}

test "parse pnpm lockfile scalar and collection subset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const document = try parse(arena.allocator(),
        \\lockfileVersion: '9.0'
        \\settings:
        \\  autoInstallPeers: true
        \\  ignored: null
        \\importers:
        \\  .:
        \\    dependencies:
        \\      '@scope/pkg':
        \\        specifier: ^1.0.0
        \\        version: 1.2.3(peer@2.0.0)
        \\packages:
        \\  '@scope/pkg@1.2.3':
        \\    resolution: {integrity: sha512-ab#cd==}
        \\    os: [darwin, linux]
        \\    cpu:
        \\      - x64
        \\      - arm64 # generated comment
        \\snapshots:
        \\  '@scope/pkg@1.2.3(peer@2.0.0)': {}
        \\
    );

    try std.testing.expect(document == .object);
    try std.testing.expectEqualStrings(
        "9.0",
        document.object.get("lockfileVersion").?.string,
    );
    try std.testing.expect(document.object.get("settings").?.object.get("autoInstallPeers").?.bool);

    const package = document.object.get("packages").?.object.get("@scope/pkg@1.2.3").?;
    try std.testing.expectEqualStrings(
        "sha512-ab#cd==",
        package.object.get("resolution").?.object.get("integrity").?.string,
    );
    try std.testing.expectEqual(@as(usize, 2), package.object.get("os").?.array.items.len);
    try std.testing.expectEqualStrings("arm64", package.object.get("cpu").?.array.items[1].string);
}

test "parse quoted scalars and compact sequence maps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const document = try parse(arena.allocator(),
        \\single: 'it''s text'
        \\double: "line\n\u263a"
        \\items:
        \\  - name: first
        \\    values: [1, false, ~]
        \\  - name:
        \\      nested: value
        \\
    );

    try std.testing.expectEqualStrings("it's text", document.object.get("single").?.string);
    try std.testing.expectEqualStrings("line\n☺", document.object.get("double").?.string);
    const items = document.object.get("items").?.array;
    try std.testing.expectEqualStrings("first", items.items[0].object.get("name").?.string);
    try std.testing.expectEqual(
        @as(i64, 1),
        items.items[0].object.get("values").?.array.items[0].integer,
    );
    try std.testing.expectEqualStrings(
        "value",
        items.items[1].object.get("name").?.object.get("nested").?.string,
    );
}

test "reject malformed indentation and multiple documents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.InvalidYaml,
        parse(arena.allocator(), "root:\n child: value\n  extra: value\n"),
    );
    try std.testing.expectError(
        error.InvalidYaml,
        parse(arena.allocator(), "one: 1\n---\ntwo: 2\n"),
    );
}
