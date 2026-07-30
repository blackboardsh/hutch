const std = @import("std");

const Value = std.json.Value;

pub const Span = struct {
    start: usize,
    end: usize,
};

pub const Property = struct {
    key: []const u8,
    key_span: Span,
    value: *const Node,
};

pub const Node = struct {
    span: Span,
    data: union(enum) {
        scalar,
        array: []const *const Node,
        object: []const Property,
    },

    pub fn get(self: *const Node, key: []const u8) ?*const Node {
        const property = self.getProperty(key) orelse return null;
        return property.value;
    }

    pub fn getProperty(self: *const Node, key: []const u8) ?*const Property {
        const properties = switch (self.data) {
            .object => |properties| properties,
            else => return null,
        };

        // std.json keeps the last value for duplicate keys, so source lookup
        // follows the same rule.
        var index = properties.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, properties[index].key, key)) {
                return &properties[index];
            }
        }
        return null;
    }
};

pub const Document = struct {
    value: Value,
    root: *const Node,
};

pub const Failure = struct {
    offset: usize = 0,
    reason: Reason = .syntax,

    pub const Reason = enum {
        syntax,
        unexpected_end,
        unterminated_comment,
    };
};

pub fn parse(
    allocator: std.mem.Allocator,
    source: []const u8,
    failure: *Failure,
) !Document {
    const normalized = try normalize(allocator, source, failure);
    defer allocator.free(normalized);

    var scanner = std.json.Scanner.initCompleteInput(allocator, normalized);
    defer scanner.deinit();

    var diagnostics: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diagnostics);

    const value = std.json.parseFromTokenSourceLeaky(
        Value,
        allocator,
        &scanner,
        .{},
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        const byte_offset = diagnostics.getByteOffset();
        const offset = if (byte_offset > source.len) source.len else @as(usize, @intCast(byte_offset));
        failure.* = .{
            .offset = beginningOfToken(source, offset),
            .reason = if (err == error.UnexpectedEndOfInput) .unexpected_end else .syntax,
        };
        return error.InvalidJson;
    };

    var location_parser = LocationParser{
        .allocator = allocator,
        .source = normalized,
    };
    const root = location_parser.parseNode() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            failure.* = .{
                .offset = @min(location_parser.index, source.len),
                .reason = .syntax,
            };
            return error.InvalidJson;
        },
    };

    return .{
        .value = value,
        .root = root,
    };
}

pub fn unexpectedToken(source: []const u8, failure: Failure) []const u8 {
    if (source.len == 0 or failure.offset >= source.len) return "";

    var start = failure.offset;
    if (isIdentifierByte(source[start])) {
        while (start > 0 and isIdentifierByte(source[start - 1])) start -= 1;

        var end = failure.offset + 1;
        while (end < source.len and isIdentifierByte(source[end])) end += 1;
        return source[start..end];
    }

    return source[start .. start + 1];
}

fn normalize(
    allocator: std.mem.Allocator,
    source: []const u8,
    failure: *Failure,
) ![]u8 {
    const output = try allocator.dupe(u8, source);

    if (std.mem.startsWith(u8, output, "\xEF\xBB\xBF")) {
        @memset(output[0..3], ' ');
    }

    var index: usize = 0;
    while (index < output.len) {
        if (output[index] == '"') {
            index += 1;
            while (index < output.len) {
                switch (output[index]) {
                    '\\' => index += @min(@as(usize, 2), output.len - index),
                    '"' => {
                        index += 1;
                        break;
                    },
                    else => index += 1,
                }
            }
            continue;
        }

        if (output[index] != '/' or index + 1 >= output.len) {
            index += 1;
            continue;
        }

        if (output[index + 1] == '/') {
            output[index] = ' ';
            output[index + 1] = ' ';
            index += 2;
            while (index < output.len and output[index] != '\n' and output[index] != '\r') {
                output[index] = ' ';
                index += 1;
            }
            continue;
        }

        if (output[index + 1] == '*') {
            const comment_start = index;
            output[index] = ' ';
            output[index + 1] = ' ';
            index += 2;

            var closed = false;
            while (index < output.len) {
                if (index + 1 < output.len and output[index] == '*' and output[index + 1] == '/') {
                    output[index] = ' ';
                    output[index + 1] = ' ';
                    index += 2;
                    closed = true;
                    break;
                }
                if (output[index] != '\n' and output[index] != '\r') output[index] = ' ';
                index += 1;
            }

            if (!closed) {
                allocator.free(output);
                failure.* = .{
                    .offset = comment_start,
                    .reason = .unterminated_comment,
                };
                return error.InvalidJson;
            }
            continue;
        }

        index += 1;
    }

    index = 0;
    while (index < output.len) {
        if (output[index] == '"') {
            index += 1;
            while (index < output.len) {
                switch (output[index]) {
                    '\\' => index += @min(@as(usize, 2), output.len - index),
                    '"' => {
                        index += 1;
                        break;
                    },
                    else => index += 1,
                }
            }
            continue;
        }

        if (output[index] == ',') {
            var next = index + 1;
            while (next < output.len and std.ascii.isWhitespace(output[next])) next += 1;
            if (next < output.len and (output[next] == '}' or output[next] == ']')) {
                var previous = index;
                while (previous > 0 and std.ascii.isWhitespace(output[previous - 1])) previous -= 1;
                if (previous > 0) {
                    switch (output[previous - 1]) {
                        '{', '[', ',', ':' => {},
                        else => output[index] = ' ',
                    }
                }
            }
        }
        index += 1;
    }

    return output;
}

fn isIdentifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '$' or byte == '-';
}

fn beginningOfToken(source: []const u8, requested_offset: usize) usize {
    if (source.len == 0) return 0;

    var offset = @min(requested_offset, source.len);
    if (offset == source.len or !isIdentifierByte(source[offset])) {
        if (offset == 0 or !isIdentifierByte(source[offset - 1])) return offset;
        offset -= 1;
    }
    while (offset > 0 and isIdentifierByte(source[offset - 1])) offset -= 1;
    return offset;
}

const LocationParser = struct {
    const Error = error{ InvalidJson, OutOfMemory };

    allocator: std.mem.Allocator,
    source: []const u8,
    index: usize = 0,

    fn parseNode(self: *LocationParser) Error!*const Node {
        self.skipWhitespace();
        if (self.index >= self.source.len) return error.InvalidJson;

        const start = self.index;
        return switch (self.source[self.index]) {
            '{' => self.parseObject(start),
            '[' => self.parseArray(start),
            '"' => blk: {
                try self.skipString();
                break :blk self.createNode(.{
                    .span = .{ .start = start, .end = self.index },
                    .data = .scalar,
                });
            },
            else => blk: {
                while (self.index < self.source.len) {
                    switch (self.source[self.index]) {
                        ' ', '\t', '\r', '\n', ',', '}', ']' => break,
                        else => self.index += 1,
                    }
                }
                if (self.index == start) return error.InvalidJson;
                break :blk self.createNode(.{
                    .span = .{ .start = start, .end = self.index },
                    .data = .scalar,
                });
            },
        };
    }

    fn parseObject(self: *LocationParser, start: usize) Error!*const Node {
        self.index += 1;
        var properties: std.array_list.Managed(Property) = .init(self.allocator);
        defer properties.deinit();

        while (true) {
            self.skipWhitespace();
            if (self.index >= self.source.len) return error.InvalidJson;
            if (self.source[self.index] == '}') {
                self.index += 1;
                break;
            }
            if (self.source[self.index] != '"') return error.InvalidJson;

            const key_start = self.index;
            try self.skipString();
            const key_end = self.index;
            const key = std.json.parseFromSliceLeaky(
                []const u8,
                self.allocator,
                self.source[key_start..key_end],
                .{ .allocate = .alloc_always },
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidJson,
            };

            self.skipWhitespace();
            if (self.index >= self.source.len or self.source[self.index] != ':') {
                return error.InvalidJson;
            }
            self.index += 1;

            const value = try self.parseNode();
            try properties.append(.{
                .key = key,
                .key_span = .{ .start = key_start, .end = key_end },
                .value = value,
            });

            self.skipWhitespace();
            if (self.index >= self.source.len) return error.InvalidJson;
            if (self.source[self.index] == ',') {
                self.index += 1;
                continue;
            }
            if (self.source[self.index] == '}') {
                self.index += 1;
                break;
            }
            return error.InvalidJson;
        }

        return self.createNode(.{
            .span = .{ .start = start, .end = self.index },
            .data = .{ .object = try properties.toOwnedSlice() },
        });
    }

    fn parseArray(self: *LocationParser, start: usize) Error!*const Node {
        self.index += 1;
        var items: std.array_list.Managed(*const Node) = .init(self.allocator);
        defer items.deinit();

        while (true) {
            self.skipWhitespace();
            if (self.index >= self.source.len) return error.InvalidJson;
            if (self.source[self.index] == ']') {
                self.index += 1;
                break;
            }

            try items.append(try self.parseNode());
            self.skipWhitespace();
            if (self.index >= self.source.len) return error.InvalidJson;
            if (self.source[self.index] == ',') {
                self.index += 1;
                continue;
            }
            if (self.source[self.index] == ']') {
                self.index += 1;
                break;
            }
            return error.InvalidJson;
        }

        return self.createNode(.{
            .span = .{ .start = start, .end = self.index },
            .data = .{ .array = try items.toOwnedSlice() },
        });
    }

    fn skipString(self: *LocationParser) Error!void {
        if (self.index >= self.source.len or self.source[self.index] != '"') {
            return error.InvalidJson;
        }
        self.index += 1;

        while (self.index < self.source.len) {
            switch (self.source[self.index]) {
                '\\' => {
                    if (self.index + 1 >= self.source.len) return error.InvalidJson;
                    self.index += 2;
                },
                '"' => {
                    self.index += 1;
                    return;
                },
                else => self.index += 1,
            }
        }
        return error.InvalidJson;
    }

    fn skipWhitespace(self: *LocationParser) void {
        while (self.index < self.source.len and std.ascii.isWhitespace(self.source[self.index])) {
            self.index += 1;
        }
    }

    fn createNode(self: *LocationParser, node: Node) Error!*const Node {
        const result = try self.allocator.create(Node);
        result.* = node;
        return result;
    }
};

test "JSONC parser accepts comments, trailing commas, and a UTF-8 BOM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        "\xEF\xBB\xBF{\n" ++
        "  // package metadata\n" ++
        "  \"name\": \"demo\",\n" ++
        "  \"dependencies\": {\n" ++
        "    \"left-pad\": \"1.3.0\", /* retained */\n" ++
        "  },\n" ++
        "}\n";
    var failure: Failure = .{};
    const document = try parse(arena.allocator(), source, &failure);

    try std.testing.expectEqualStrings("demo", document.value.object.get("name").?.string);
    try std.testing.expectEqualStrings(
        "1.3.0",
        document.value.object.get("dependencies").?.object.get("left-pad").?.string,
    );
    try std.testing.expectEqual(
        std.mem.indexOf(u8, source, "\"demo\"").?,
        document.root.get("name").?.span.start,
    );
}

test "JSONC parser reports the beginning of an unexpected identifier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var failure: Failure = .{};
    try std.testing.expectError(error.InvalidJson, parse(arena.allocator(), "foo", &failure));
    try std.testing.expectEqual(@as(usize, 0), failure.offset);
    try std.testing.expectEqualStrings("foo", unexpectedToken("foo", failure));
}

test "JSONC parser does not turn a leading comma into an empty container" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var failure: Failure = .{};
    try std.testing.expectError(error.InvalidJson, parse(arena.allocator(), "[,]", &failure));
    try std.testing.expectError(error.InvalidJson, parse(arena.allocator(), "{,}", &failure));
}
