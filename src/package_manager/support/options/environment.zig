const std = @import("std");
const builtin = @import("builtin");

const EnvironmentContext = struct {
    pub fn hash(_: EnvironmentContext, key: []const u8) u64 {
        if (builtin.os.tag != .windows) return std.hash.Wyhash.hash(0, key);
        var hasher = std.hash.Wyhash.init(0);
        for (key) |byte| {
            const lower = std.ascii.toLower(byte);
            hasher.update(&.{lower});
        }
        return hasher.final();
    }

    pub fn eql(_: EnvironmentContext, left: []const u8, right: []const u8) bool {
        return if (builtin.os.tag == .windows)
            std.ascii.eqlIgnoreCase(left, right)
        else
            std.mem.eql(u8, left, right);
    }
};

const Map = std.HashMap(
    []const u8,
    []const u8,
    EnvironmentContext,
    std.hash_map.default_max_load_percentage,
);

pub const Environment = struct {
    allocator: std.mem.Allocator,
    map: Map,
    owned_strings: std.array_list.Managed([]u8),

    pub fn init(allocator: std.mem.Allocator) Environment {
        return .{
            .allocator = allocator,
            .map = Map.init(allocator),
            .owned_strings = .init(allocator),
        };
    }

    pub fn deinit(environment: *Environment) void {
        environment.map.deinit();
        for (environment.owned_strings.items) |string| {
            environment.allocator.free(string);
        }
        environment.owned_strings.deinit();
        environment.* = undefined;
    }

    pub fn get(environment: *const Environment, key: []const u8) ?[]const u8 {
        return environment.map.get(key);
    }

    pub fn put(
        environment: *Environment,
        key: []const u8,
        value: []const u8,
        overwrite: bool,
    ) !void {
        if (!overwrite and environment.map.contains(key)) return;
        const owned_key = try environment.own(key);
        const owned_value = try environment.own(value);
        try environment.map.put(owned_key, owned_value);
    }

    pub fn loadProcessMap(
        environment: *Environment,
        process: *const std.process.Environ.Map,
    ) !void {
        var iterator = process.iterator();
        while (iterator.next()) |entry| {
            try environment.put(entry.key_ptr.*, entry.value_ptr.*, true);
        }
    }

    pub fn loadDotEnv(
        environment: *Environment,
        source: []const u8,
        overwrite: bool,
    ) !void {
        var lines = std.mem.splitScalar(u8, stripBom(source), '\n');
        while (lines.next()) |raw_line| {
            var line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (std.mem.startsWith(u8, line, "export ")) {
                line = std.mem.trimStart(u8, line["export ".len..], " \t");
            }
            const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..equals], " \t");
            if (!validKey(key)) continue;

            const parsed = try environment.parseDotEnvValue(line[equals + 1 ..]);
            defer environment.allocator.free(parsed);
            try environment.put(key, parsed, overwrite);
        }
    }

    /// Expand npm-style `${NAME}` substitutions. Missing required variables
    /// remain literal; `${NAME?}` expands to an empty string when missing.
    pub fn expand(
        environment: *const Environment,
        allocator: std.mem.Allocator,
        source: []const u8,
    ) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();

        var index: usize = 0;
        while (index < source.len) {
            if (source[index] == '\\' and index + 2 < source.len and
                source[index + 1] == '$' and source[index + 2] == '{')
            {
                try output.writer.writeByte('$');
                index += 2;
                continue;
            }
            if (source[index] != '$' or index + 2 >= source.len or
                source[index + 1] != '{')
            {
                try output.writer.writeByte(source[index]);
                index += 1;
                continue;
            }

            const close = std.mem.indexOfScalarPos(
                u8,
                source,
                index + 2,
                '}',
            ) orelse {
                try output.writer.writeByte(source[index]);
                index += 1;
                continue;
            };
            const raw_name = source[index + 2 .. close];
            const optional = raw_name.len > 0 and raw_name[raw_name.len - 1] == '?';
            const name = if (optional) raw_name[0 .. raw_name.len - 1] else raw_name;
            if (environment.get(name)) |value| {
                try output.writer.writeAll(value);
            } else if (!optional) {
                try output.writer.writeAll(source[index .. close + 1]);
            }
            index = close + 1;
        }
        return output.toOwnedSlice();
    }

    fn parseDotEnvValue(
        environment: *const Environment,
        raw_value: []const u8,
    ) ![]u8 {
        var value = std.mem.trim(u8, raw_value, " \t\r");
        if (value.len == 0) return environment.allocator.dupe(u8, "");

        if (value[0] == '\'') {
            const end = std.mem.lastIndexOfScalar(u8, value[1..], '\'') orelse
                return error.UnterminatedDotEnvString;
            return environment.allocator.dupe(u8, value[1 .. end + 1]);
        }
        if (value[0] == '"') {
            const closing = findClosingDoubleQuote(value) orelse
                return error.UnterminatedDotEnvString;
            const unescaped = try unescapeDoubleQuoted(environment.allocator, value[1..closing]);
            defer environment.allocator.free(unescaped);
            return environment.expand(environment.allocator, unescaped);
        }

        if (std.mem.indexOfScalar(u8, value, '#')) |comment| {
            value = std.mem.trimEnd(u8, value[0..comment], " \t");
        }
        return environment.expand(environment.allocator, value);
    }

    fn own(environment: *Environment, value: []const u8) ![]const u8 {
        if (value.len == 0) return "";
        const copy = try environment.allocator.dupe(u8, value);
        errdefer environment.allocator.free(copy);
        try environment.owned_strings.append(copy);
        return copy;
    }
};

fn stripBom(source: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF"))
        source[3..]
    else
        source;
}

fn validKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '.') return false;
    }
    return true;
}

fn findClosingDoubleQuote(value: []const u8) ?usize {
    var escaped = false;
    var index: usize = 1;
    while (index < value.len) : (index += 1) {
        if (value[index] == '"' and !escaped) return index;
        if (value[index] == '\\' and !escaped) {
            escaped = true;
        } else {
            escaped = false;
        }
    }
    return null;
}

fn unescapeDoubleQuoted(
    allocator: std.mem.Allocator,
    value: []const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        if (value[index] != '\\' or index + 1 >= value.len) {
            try output.writer.writeByte(value[index]);
            continue;
        }
        index += 1;
        try output.writer.writeByte(switch (value[index]) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            else => value[index],
        });
    }
    return output.toOwnedSlice();
}

test "dotenv preserves process values and expands npm substitutions" {
    const testing = std.testing;
    var environment = Environment.init(testing.allocator);
    defer environment.deinit();

    try environment.put("TOKEN", "from-process", true);
    try environment.loadDotEnv(
        \\TOKEN=from-file
        \\HOST=registry.example.test
        \\PATH="/${HOST}/packages"
        \\LITERAL='${TOKEN}'
    , false);

    try testing.expectEqualStrings("from-process", environment.get("TOKEN").?);
    try testing.expectEqualStrings(
        "/registry.example.test/packages",
        environment.get("PATH").?,
    );
    try testing.expectEqualStrings("${TOKEN}", environment.get("LITERAL").?);

    const expanded = try environment.expand(
        testing.allocator,
        "https://${HOST}/${MISSING?}/${MISSING}/\\${TOKEN}",
    );
    defer testing.allocator.free(expanded);
    try testing.expectEqualStrings(
        "https://registry.example.test//${MISSING}/${TOKEN}",
        expanded,
    );
}
