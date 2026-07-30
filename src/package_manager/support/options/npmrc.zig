const std = @import("std");
const Environment = @import("environment.zig").Environment;
const types = @import("types.zig");

const InstallOptions = types.InstallOptions;

pub const ParseOptions = struct {
    /// Cottontail parses hoist patterns itself when using
    /// `loadNpmrcWithoutMatchers`. Hutch's pure-Zig parser can retain them.
    parse_hoist_patterns: bool = true,
};

/// Apply one .npmrc file to `install`. The same InstallOptions may be passed to
/// multiple calls; registry credentials are retained so a user-level auth
/// entry can apply to a scope declared by a later project-level file.
pub fn parse(
    install: *InstallOptions,
    environment: *const Environment,
    source: []const u8,
    parse_options: ParseOptions,
) !void {
    var ca_values = std.array_list.Managed([]const u8).init(install.allocator);
    defer ca_values.deinit();
    var public_hoist_patterns = std.array_list.Managed([]const u8).init(install.allocator);
    defer public_hoist_patterns.deinit();
    var hoist_patterns = std.array_list.Managed([]const u8).init(install.allocator);
    defer hoist_patterns.deinit();

    var in_root = true;
    var lines = std.mem.splitScalar(u8, stripBom(source), '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw_line| {
        line_number += 1;
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            in_root = false;
            continue;
        }
        if (!in_root) continue;

        const equals = std.mem.indexOfScalar(u8, line, '=');
        const raw_key = if (equals) |index| line[0..index] else line;
        const key = std.mem.trim(u8, raw_key, " \t");
        if (key.len == 0 or std.mem.eql(u8, key, "__proto__")) continue;
        const raw_value = if (equals) |index| line[index + 1 ..] else "true";
        const value = try parseValue(install.allocator, environment, raw_value);
        defer install.allocator.free(value);

        if (try parseCredential(install, key, value, line_number)) continue;
        if (try parseScope(install, key, value)) continue;

        const is_array = std.mem.endsWith(u8, key, "[]");
        const name = if (is_array) key[0 .. key.len - 2] else key;
        if (std.mem.eql(u8, name, "registry")) {
            install.default_registry = try install.registryFromUrl(value);
        } else if (std.mem.eql(u8, name, "cache")) {
            if (parseBool(value)) |enabled| {
                install.disable_cache = !enabled;
                if (!enabled) install.cache_directory = null;
            } else {
                install.disable_cache = false;
                install.cache_directory = try install.own(value);
            }
        } else if (std.mem.eql(u8, name, "dry-run")) {
            install.dry_run = parseBool(value) orelse false;
        } else if (std.mem.eql(u8, name, "ca")) {
            try ca_values.append(try install.own(value));
        } else if (std.mem.eql(u8, name, "cafile")) {
            install.cafile = try install.own(value);
        } else if (std.mem.eql(u8, name, "omit")) {
            applyDependencySelection(install, value, false);
        } else if (std.mem.eql(u8, name, "include")) {
            applyDependencySelection(install, value, true);
        } else if (std.mem.eql(u8, name, "ignore-scripts")) {
            if (parseBool(value)) |boolean| install.ignore_scripts = boolean;
        } else if (std.mem.eql(u8, name, "link-workspace-packages")) {
            if (parseBool(value)) |boolean| install.link_workspace_packages = boolean;
        } else if (std.mem.eql(u8, name, "save-exact")) {
            if (parseBool(value)) |boolean| install.exact = boolean;
        } else if (std.mem.eql(u8, name, "install-strategy")) {
            if (types.NodeLinker.parse(value)) |linker| install.node_linker = linker;
        } else if (std.mem.eql(u8, name, "node-linker")) {
            if (types.NodeLinker.parse(value)) |linker| install.node_linker = linker;
        } else if (parse_options.parse_hoist_patterns and
            std.mem.eql(u8, name, "public-hoist-pattern"))
        {
            try public_hoist_patterns.append(try install.own(value));
        } else if (parse_options.parse_hoist_patterns and
            std.mem.eql(u8, name, "hoist-pattern"))
        {
            try hoist_patterns.append(try install.own(value));
        }
    }

    if (ca_values.items.len == 1) {
        install.ca = .{ .string = ca_values.items[0] };
    } else if (ca_values.items.len > 1) {
        install.ca = .{ .list = try install.ownList(ca_values.items) };
    }
    if (public_hoist_patterns.items.len > 0) {
        install.public_hoist_pattern = try install.ownList(public_hoist_patterns.items);
    }
    if (hoist_patterns.items.len > 0) {
        install.hoist_pattern = try install.ownList(hoist_patterns.items);
    }

    try install.applyRegistryCredentials();
}

fn parseCredential(
    install: *InstallOptions,
    key: []const u8,
    value: []const u8,
    line: usize,
) !bool {
    if (!std.mem.startsWith(u8, key, "//")) return false;
    const candidates = [_]types.RegistryCredentialOption{
        ._authToken,
        .username,
        ._password,
        ._auth,
        .email,
        .certfile,
        .keyfile,
    };
    inline for (candidates) |option| {
        const suffix = ":" ++ @tagName(option);
        if (std.mem.endsWith(u8, key, suffix)) {
            const registry_url = key[2 .. key.len - suffix.len];
            try install.appendCredential(.{
                .registry_url = registry_url,
                .option = option,
                .value = value,
                .line = line,
            });
            return true;
        }
    }
    return false;
}

fn parseScope(
    install: *InstallOptions,
    key: []const u8,
    value: []const u8,
) !bool {
    if (key.len <= "@:registry".len or key[0] != '@' or
        !std.mem.endsWith(u8, key, ":registry"))
    {
        return false;
    }
    const scope = key[1 .. key.len - ":registry".len];
    if (scope.len == 0) return false;
    try install.putScope(scope, try install.registryFromUrl(value));
    return true;
}

fn applyDependencySelection(
    install: *InstallOptions,
    value: []const u8,
    included: bool,
) void {
    var values = std.mem.tokenizeAny(u8, value, ", \t");
    while (values.next()) |dependency_type| {
        if (std.mem.eql(u8, dependency_type, "dev")) {
            install.save_dev = included;
        } else if (std.mem.eql(u8, dependency_type, "peer")) {
            install.save_peer = included;
        } else if (std.mem.eql(u8, dependency_type, "optional")) {
            install.save_optional = included;
        }
    }
}

fn parseBool(value: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(value, "true")) return true;
    if (std.ascii.eqlIgnoreCase(value, "false")) return false;
    return null;
}

fn parseValue(
    allocator: std.mem.Allocator,
    environment: *const Environment,
    raw_value: []const u8,
) ![]u8 {
    var value = std.mem.trim(u8, raw_value, " \t\r");
    if (value.len == 0) return allocator.dupe(u8, "");

    if (value[0] == '"' or value[0] == '\'') {
        const quote = value[0];
        const closing = findClosingQuote(value, quote) orelse
            return error.UnterminatedNpmrcString;
        value = value[1..closing];
        const decoded = if (quote == '"')
            try unescapeDoubleQuoted(allocator, value)
        else
            try allocator.dupe(u8, value);
        defer allocator.free(decoded);
        return environment.expand(allocator, decoded);
    }

    const content_end = findUnescapedComment(value);
    const without_comment = std.mem.trimEnd(u8, value[0..content_end], " \t");
    const expanded = try environment.expand(allocator, without_comment);
    defer allocator.free(expanded);
    return unescapeUnquoted(allocator, expanded);
}

fn findClosingQuote(value: []const u8, quote: u8) ?usize {
    var escaped = false;
    var index: usize = 1;
    while (index < value.len) : (index += 1) {
        if (value[index] == quote and (!escaped or quote == '\'')) return index;
        if (value[index] == '\\' and !escaped) {
            escaped = true;
        } else {
            escaped = false;
        }
    }
    return null;
}

fn findUnescapedComment(value: []const u8) usize {
    var escaped = false;
    for (value, 0..) |byte, index| {
        if ((byte == '#' or byte == ';') and !escaped) return index;
        if (byte == '\\' and !escaped) {
            escaped = true;
        } else {
            escaped = false;
        }
    }
    return value.len;
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
            'b' => 0x08,
            'f' => 0x0c,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            else => value[index],
        });
    }
    return output.toOwnedSlice();
}

fn unescapeUnquoted(
    allocator: std.mem.Allocator,
    value: []const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        if (value[index] == '\\' and index + 1 < value.len) {
            const next = value[index + 1];
            if (next == '\\' or next == '#' or next == ';' or next == '$') {
                index += 1;
                try output.writer.writeByte(next);
                continue;
            }
        }
        try output.writer.writeByte(value[index]);
    }
    return output.toOwnedSlice();
}

fn stripBom(source: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF"))
        source[3..]
    else
        source;
}

test ".npmrc parses environment, install options, registry auth, and scopes" {
    const testing = std.testing;
    var environment = Environment.init(testing.allocator);
    defer environment.deinit();
    try environment.put("REGISTRY_HOST", "registry.example.test", true);
    try environment.put("TOKEN", "root-token", true);
    try environment.put("CACHE_DIR", "./npm-cache", true);

    var install = InstallOptions.init(testing.allocator);
    defer install.deinit();
    try parse(&install, &environment,
        \\registry=https://${REGISTRY_HOST}/
        \\//registry.example.test/:_authToken=${TOKEN}
        \\@acme:registry=https://${REGISTRY_HOST}/acme/
        \\//registry.example.test/acme/:username=alice
        \\//registry.example.test/acme/:_password=cmFiYml0
        \\cache=${CACHE_DIR}
        \\save-exact=true
        \\ignore-scripts=true
        \\link-workspace-packages=false
        \\node-linker=pnpm
        \\omit=dev, optional
        \\include=optional
        \\ca[]=first cert
        \\ca[]=second cert
        \\public-hoist-pattern[]=@types/*
        \\public-hoist-pattern[]=!private-*
    , .{});

    try testing.expectEqualStrings(
        "https://registry.example.test/",
        install.default_registry.?.url,
    );
    const default_auth = try install.default_registry.?.authorization(testing.allocator);
    defer testing.allocator.free(default_auth.?);
    try testing.expectEqualStrings("Bearer root-token", default_auth.?);

    const acme = install.scopes.get("acme").?;
    const scoped_auth = try acme.authorization(testing.allocator);
    defer testing.allocator.free(scoped_auth.?);
    try testing.expectEqualStrings("Basic YWxpY2U6cmFiYml0", scoped_auth.?);

    try testing.expectEqualStrings("./npm-cache", install.cache_directory.?);
    try testing.expectEqual(true, install.exact.?);
    try testing.expectEqual(true, install.ignore_scripts.?);
    try testing.expectEqual(false, install.link_workspace_packages.?);
    try testing.expectEqual(.isolated, install.node_linker.?);
    try testing.expectEqual(false, install.save_dev.?);
    try testing.expectEqual(true, install.save_optional.?);
    try testing.expectEqual(@as(usize, 2), install.ca.?.list.len);
    try testing.expectEqual(@as(usize, 2), install.public_hoist_pattern.?.len);
}

test ".npmrc credentials survive across user and project files" {
    const testing = std.testing;
    var environment = Environment.init(testing.allocator);
    defer environment.deinit();

    var install = InstallOptions.init(testing.allocator);
    defer install.deinit();

    try parse(&install, &environment,
        \\//registry.example.test/acme/:_authToken=from-home
    , .{ .parse_hoist_patterns = false });
    try parse(&install, &environment,
        \\@acme:registry=https://registry.example.test/acme/
    , .{});

    try testing.expectEqualStrings(
        "from-home",
        install.scopes.get("acme").?.token,
    );
}

test ".npmrc auth creates the implicit default registry and decodes _auth" {
    const testing = std.testing;
    var environment = Environment.init(testing.allocator);
    defer environment.deinit();

    var install = InstallOptions.init(testing.allocator);
    defer install.deinit();
    try parse(&install, &environment,
        \\//registry.npmjs.org/:_auth=YWxpY2U6cmFiYml0
        \\//registry.npmjs.org/:email=alice@example.test
    , .{});

    try testing.expectEqualStrings(types.default_registry_url, install.default_registry.?.url);
    try testing.expectEqualStrings("alice", install.default_registry.?.username);
    try testing.expectEqualStrings("rabbit", install.default_registry.?.password);
    try testing.expectEqualStrings("alice@example.test", install.default_registry.?.email);
}

test ".npmrc leaves required missing substitutions and removes optional ones" {
    const testing = std.testing;
    var environment = Environment.init(testing.allocator);
    defer environment.deinit();
    var install = InstallOptions.init(testing.allocator);
    defer install.deinit();

    try parse(&install, &environment,
        \\registry="https://${MISSING}/${OPTIONAL?}/"
    , .{});
    try testing.expectEqualStrings(
        "https://${MISSING}//",
        install.default_registry.?.url,
    );
}
