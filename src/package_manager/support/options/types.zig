const std = @import("std");

pub const default_registry_url = "https://registry.npmjs.org/";

pub const NodeLinker = enum {
    hoisted,
    isolated,

    pub fn parse(value: []const u8) ?NodeLinker {
        if (std.mem.eql(u8, value, "hoisted") or
            std.mem.eql(u8, value, "node-modules"))
        {
            return .hoisted;
        }
        if (std.mem.eql(u8, value, "isolated") or
            std.mem.eql(u8, value, "pnpm") or
            std.mem.eql(u8, value, "linked"))
        {
            return .isolated;
        }
        return null;
    }
};

pub const CertificateAuthorities = union(enum) {
    string: []const u8,
    list: []const []const u8,
};

pub const NpmRegistry = struct {
    url: []const u8 = "",
    username: []const u8 = "",
    password: []const u8 = "",
    token: []const u8 = "",
    email: []const u8 = "",

    pub fn authorization(
        registry: NpmRegistry,
        allocator: std.mem.Allocator,
    ) !?[]u8 {
        if (registry.token.len > 0) {
            return try std.fmt.allocPrint(allocator, "Bearer {s}", .{registry.token});
        }
        if (registry.username.len == 0 or registry.password.len == 0) return null;

        const credentials = try std.fmt.allocPrint(
            allocator,
            "{s}:{s}",
            .{ registry.username, registry.password },
        );
        defer allocator.free(credentials);
        const encoded = try allocator.alloc(
            u8,
            std.base64.standard.Encoder.calcSize(credentials.len),
        );
        defer allocator.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, credentials);
        return try std.fmt.allocPrint(allocator, "Basic {s}", .{encoded});
    }
};

pub const RegistryCredentialOption = enum {
    /// Base64-encoded "username:password".
    _auth,
    _authToken,
    username,
    /// Base64-encoded password.
    _password,
    email,
    certfile,
    keyfile,

    pub fn isBase64Encoded(option: RegistryCredentialOption) bool {
        return option == ._auth or option == ._password;
    }
};

pub const RegistryCredential = struct {
    registry_url: []const u8,
    option: RegistryCredentialOption,
    value: []const u8,
    line: usize,
};

pub const InstallOptions = struct {
    allocator: std.mem.Allocator,
    owned_strings: std.array_list.Managed([]u8),
    owned_lists: std.array_list.Managed([]const []const u8),

    default_registry: ?NpmRegistry = null,
    scopes: std.StringHashMap(NpmRegistry),
    registry_credentials: std.array_list.Managed(RegistryCredential),

    cache_directory: ?[]const u8 = null,
    disable_cache: ?bool = null,
    dry_run: ?bool = null,
    save_dev: ?bool = null,
    save_optional: ?bool = null,
    save_peer: ?bool = null,
    ignore_scripts: ?bool = null,
    link_workspace_packages: ?bool = null,
    exact: ?bool = null,
    frozen_lockfile: ?bool = null,
    save_text_lockfile: ?bool = null,
    node_linker: ?NodeLinker = null,
    concurrent_scripts: ?u32 = null,

    global_dir: ?[]const u8 = null,
    global_bin_dir: ?[]const u8 = null,
    cafile: ?[]const u8 = null,
    ca: ?CertificateAuthorities = null,
    security_scanner: ?[]const u8 = null,
    minimum_release_age_ms: ?f64 = null,
    minimum_release_age_excludes: ?[]const []const u8 = null,
    public_hoist_pattern: ?[]const []const u8 = null,
    hoist_pattern: ?[]const []const u8 = null,

    pub fn init(allocator: std.mem.Allocator) InstallOptions {
        return .{
            .allocator = allocator,
            .owned_strings = .init(allocator),
            .owned_lists = .init(allocator),
            .scopes = std.StringHashMap(NpmRegistry).init(allocator),
            .registry_credentials = .init(allocator),
        };
    }

    pub fn deinit(options: *InstallOptions) void {
        options.registry_credentials.deinit();
        options.scopes.deinit();
        for (options.owned_lists.items) |list| options.allocator.free(list);
        options.owned_lists.deinit();
        for (options.owned_strings.items) |string| options.allocator.free(string);
        options.owned_strings.deinit();
        options.* = undefined;
    }

    pub fn own(options: *InstallOptions, value: []const u8) ![]const u8 {
        if (value.len == 0) return "";
        const copy = try options.allocator.dupe(u8, value);
        errdefer options.allocator.free(copy);
        try options.owned_strings.append(copy);
        return copy;
    }

    pub fn ownList(
        options: *InstallOptions,
        values: []const []const u8,
    ) ![]const []const u8 {
        const result = try options.allocator.alloc([]const u8, values.len);
        errdefer options.allocator.free(result);
        for (values, 0..) |value, index| {
            result[index] = try options.own(value);
        }
        try options.owned_lists.append(result);
        return result;
    }

    pub fn ownRegistry(
        options: *InstallOptions,
        registry: NpmRegistry,
    ) !NpmRegistry {
        return .{
            .url = try options.own(registry.url),
            .username = try options.own(registry.username),
            .password = try options.own(registry.password),
            .token = try options.own(registry.token),
            .email = try options.own(registry.email),
        };
    }

    pub fn registryFromUrl(
        options: *InstallOptions,
        raw_url: []const u8,
    ) !NpmRegistry {
        var registry: NpmRegistry = .{ .url = try options.own(raw_url) };
        const scheme = std.mem.indexOf(u8, raw_url, "://") orelse return registry;
        const authority_start = scheme + 3;
        const authority_end = std.mem.indexOfAnyPos(
            u8,
            raw_url,
            authority_start,
            "/?#",
        ) orelse raw_url.len;
        const authority = raw_url[authority_start..authority_end];
        const at = std.mem.lastIndexOfScalar(u8, authority, '@') orelse return registry;
        const user_info = authority[0..at];
        const colon = std.mem.indexOfScalar(u8, user_info, ':') orelse return registry;

        const username = try decodeUriComponent(options, user_info[0..colon]);
        const password = try decodeUriComponent(options, user_info[colon + 1 ..]);
        if (username.len == 0 and password.len > 0) {
            registry.token = password;
        } else if (username.len > 0 and password.len > 0) {
            registry.username = username;
            registry.password = password;
        } else {
            return registry;
        }

        const clean_url = try std.fmt.allocPrint(
            options.allocator,
            "{s}{s}",
            .{ raw_url[0..authority_start], raw_url[authority_start + at + 1 ..] },
        );
        errdefer options.allocator.free(clean_url);
        try options.owned_strings.append(clean_url);
        registry.url = clean_url;
        return registry;
    }

    pub fn putScope(
        options: *InstallOptions,
        raw_scope: []const u8,
        registry: NpmRegistry,
    ) !void {
        const scope = if (raw_scope.len > 0 and raw_scope[0] == '@')
            raw_scope[1..]
        else
            raw_scope;
        if (scope.len == 0) return;
        try options.scopes.put(
            try options.own(scope),
            try options.ownRegistry(registry),
        );
    }

    pub fn appendCredential(
        options: *InstallOptions,
        credential: RegistryCredential,
    ) !void {
        try options.registry_credentials.append(.{
            .registry_url = try options.own(credential.registry_url),
            .option = credential.option,
            .value = try options.own(credential.value),
            .line = credential.line,
        });
    }

    pub fn applyRegistryCredentials(options: *InstallOptions) !void {
        for (options.registry_credentials.items) |credential| {
            if (options.default_registry) |*registry| {
                if (registryAddressesEqual(registry.url, credential.registry_url)) {
                    try options.applyCredential(registry, credential);
                }
            } else if (registryAddressesEqual(default_registry_url, credential.registry_url)) {
                options.default_registry = .{ .url = default_registry_url };
                try options.applyCredential(&options.default_registry.?, credential);
            }

            var values = options.scopes.valueIterator();
            while (values.next()) |registry| {
                if (registryAddressesEqual(registry.url, credential.registry_url)) {
                    try options.applyCredential(registry, credential);
                }
            }
        }
    }

    fn applyCredential(
        options: *InstallOptions,
        registry: *NpmRegistry,
        credential: RegistryCredential,
    ) !void {
        switch (credential.option) {
            ._authToken => registry.token = try options.own(credential.value),
            .username => registry.username = try options.own(credential.value),
            .email => registry.email = try options.own(credential.value),
            ._password => registry.password = try decodeBase64Owned(options, credential.value),
            ._auth => {
                const decoded = try decodeBase64Temporary(options.allocator, credential.value);
                defer options.allocator.free(decoded);
                const colon = std.mem.indexOfScalar(u8, decoded, ':') orelse
                    return error.InvalidRegistryAuth;
                if (colon == 0 or colon + 1 >= decoded.len) return error.InvalidRegistryAuth;
                registry.username = try options.own(decoded[0..colon]);
                registry.password = try options.own(decoded[colon + 1 ..]);
            },
            .certfile, .keyfile => {},
        }
    }
};

fn decodeUriComponent(
    options: *InstallOptions,
    source: []const u8,
) ![]const u8 {
    if (std.mem.indexOfScalar(u8, source, '%') == null) return options.own(source);
    const buffer = try options.allocator.dupe(u8, source);
    errdefer options.allocator.free(buffer);
    const decoded = std.Uri.percentDecodeInPlace(buffer);
    if (decoded.len != buffer.len) {
        const compact = try options.allocator.dupe(u8, decoded);
        errdefer options.allocator.free(compact);
        options.allocator.free(buffer);
        try options.owned_strings.append(compact);
        return compact;
    }
    try options.owned_strings.append(buffer);
    return buffer;
}

fn decodeBase64Temporary(
    allocator: std.mem.Allocator,
    source: []const u8,
) ![]u8 {
    if (source.len == 0) return error.InvalidRegistryAuth;
    const size = std.base64.standard.Decoder.calcSizeForSlice(source) catch
        return error.InvalidRegistryAuth;
    const result = try allocator.alloc(u8, size);
    errdefer allocator.free(result);
    std.base64.standard.Decoder.decode(result, source) catch
        return error.InvalidRegistryAuth;
    return result;
}

fn decodeBase64Owned(
    options: *InstallOptions,
    source: []const u8,
) ![]const u8 {
    const decoded = try decodeBase64Temporary(options.allocator, source);
    errdefer options.allocator.free(decoded);
    try options.owned_strings.append(decoded);
    return decoded;
}

const RegistryAddress = struct {
    host: []const u8,
    path: []const u8,

    fn parse(raw: []const u8) RegistryAddress {
        var source = std.mem.trim(u8, raw, " \t\r\n");
        if (std.mem.startsWith(u8, source, "//")) {
            source = source[2..];
        } else if (std.mem.indexOf(u8, source, "://")) |scheme| {
            source = source[scheme + 3 ..];
        }
        if (std.mem.lastIndexOfScalar(u8, source, '@')) |at| {
            const authority_end = std.mem.indexOfAny(u8, source, "/?#") orelse source.len;
            if (at < authority_end) source = source[at + 1 ..];
        }
        const host_end = std.mem.indexOfAny(u8, source, "/?#") orelse source.len;
        const path_end = std.mem.indexOfAnyPos(u8, source, host_end, "?#") orelse source.len;
        return .{
            .host = source[0..host_end],
            .path = std.mem.trim(u8, source[host_end..path_end], "/"),
        };
    }
};

fn registryAddressesEqual(left_raw: []const u8, right_raw: []const u8) bool {
    const left = RegistryAddress.parse(left_raw);
    const right = RegistryAddress.parse(right_raw);
    return std.ascii.eqlIgnoreCase(left.host, right.host) and
        std.mem.eql(u8, left.path, right.path);
}

test "registry authorization prefers tokens and encodes basic credentials" {
    const testing = std.testing;

    const bearer = try (NpmRegistry{ .token = "secret" }).authorization(testing.allocator);
    defer testing.allocator.free(bearer.?);
    try testing.expectEqualStrings("Bearer secret", bearer.?);

    const basic = try (NpmRegistry{
        .username = "alice",
        .password = "rabbit",
    }).authorization(testing.allocator);
    defer testing.allocator.free(basic.?);
    try testing.expectEqualStrings("Basic YWxpY2U6cmFiYml0", basic.?);
}

test "registry URL credentials and npmrc credentials are applied" {
    const testing = std.testing;
    var options = InstallOptions.init(testing.allocator);
    defer options.deinit();

    const registry = try options.registryFromUrl("https://alice:rabbit@example.test/npm/");
    try testing.expectEqualStrings("https://example.test/npm/", registry.url);
    try testing.expectEqualStrings("alice", registry.username);
    try testing.expectEqualStrings("rabbit", registry.password);

    options.default_registry = try options.ownRegistry(.{
        .url = "https://registry.example.test/",
    });
    try options.appendCredential(.{
        .registry_url = "registry.example.test/",
        .option = ._authToken,
        .value = "token-value",
        .line = 1,
    });
    try options.applyRegistryCredentials();
    try testing.expectEqualStrings("token-value", options.default_registry.?.token);
}
