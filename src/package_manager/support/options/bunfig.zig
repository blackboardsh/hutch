const std = @import("std");
const toml = @import("toml.zig");
const types = @import("types.zig");

const InstallOptions = types.InstallOptions;
const NpmRegistry = types.NpmRegistry;
const Value = toml.Value;

/// Parse only the bunfig values consumed by Hutch's package manager. Other
/// valid tables are retained by the TOML reader but intentionally ignored.
pub fn parse(options: *InstallOptions, source: []const u8) !void {
    var document = try toml.parse(options.allocator, source);
    defer document.deinit();

    const install_value = document.get("install") orelse return;
    const install = install_value.asTable() orelse return error.InvalidInstallTable;

    try setOptionalString(options, &options.global_dir, install.get("globalDir"));
    try setOptionalString(options, &options.global_bin_dir, install.get("globalBinDir"));
    try setOptionalString(options, &options.cafile, install.get("cafile"));

    if (install.get("ca")) |value| {
        options.ca = switch (value) {
            .string => |string| .{ .string = try options.own(string) },
            .array => |array| .{ .list = try ownStringArray(options, array) },
            else => return error.InvalidCertificateAuthorities,
        };
    }

    if (install.get("registry")) |value| {
        const registry = try registryFromValue(options, value);
        if (registry.url.len > 0) options.default_registry = registry;
    }

    if (install.get("minimumReleaseAge")) |value| {
        const seconds = value.asNumber() orelse return error.InvalidMinimumReleaseAge;
        const milliseconds = seconds * std.time.ms_per_s;
        if (!std.math.isFinite(seconds) or seconds < 0 or
            !std.math.isFinite(milliseconds))
        {
            return error.InvalidMinimumReleaseAge;
        }
        options.minimum_release_age_ms = milliseconds;
    }

    if (install.get("concurrentScripts")) |value| {
        const jobs = value.asNumber() orelse return error.InvalidConcurrentScripts;
        if (!std.math.isFinite(jobs) or jobs <= 0 or
            jobs > @as(f64, @floatFromInt(std.math.maxInt(u32))))
        {
            return error.InvalidConcurrentScripts;
        }
        options.concurrent_scripts = @intFromFloat(jobs);
    }

    if (install.get("minimumReleaseAgeExcludes")) |value| {
        const array = value.asArray() orelse return error.InvalidMinimumReleaseAgeExcludes;
        options.minimum_release_age_excludes = try ownStringArray(options, array);
    }

    if (install.get("cache")) |value| {
        switch (value) {
            .boolean => |enabled| {
                options.disable_cache = !enabled;
                if (!enabled) options.cache_directory = null;
            },
            .string => |directory| {
                options.disable_cache = false;
                options.cache_directory = try options.own(directory);
            },
            .table => |cache| {
                if (cache.get("disable")) |disable| {
                    options.disable_cache = disable.asBool() orelse
                        return error.InvalidCacheConfiguration;
                }
                if (cache.get("dir")) |directory| {
                    options.cache_directory = try options.own(
                        directory.asString() orelse return error.InvalidCacheConfiguration,
                    );
                }
            },
            else => return error.InvalidCacheConfiguration,
        }
    }

    try setOptionalBool(&options.save_optional, install.get("optional"));
    try setOptionalBool(&options.save_dev, install.get("dev"));
    try setOptionalBool(&options.save_peer, install.get("peer"));
    try setOptionalBool(&options.exact, install.get("exact"));
    try setOptionalBool(&options.frozen_lockfile, install.get("frozenLockfile"));
    try setOptionalBool(&options.save_text_lockfile, install.get("saveTextLockfile"));
    try setOptionalBool(
        &options.link_workspace_packages,
        install.get("linkWorkspacePackages"),
    );

    if (install.get("linker")) |value| {
        options.node_linker = types.NodeLinker.parse(
            value.asString() orelse return error.InvalidNodeLinker,
        ) orelse return error.InvalidNodeLinker;
    }

    if (install.get("publicHoistPattern")) |value| {
        options.public_hoist_pattern = try ownStringOrArray(options, value);
    }
    if (install.get("hoistPattern")) |value| {
        options.hoist_pattern = try ownStringOrArray(options, value);
    }

    if (install.get("security")) |value| {
        if (value.asTable()) |security| {
            if (security.get("scanner")) |scanner| {
                const path = scanner.asString() orelse return error.InvalidSecurityScanner;
                if (path.len > 0) options.security_scanner = try options.own(path);
            }
        } else {
            return error.InvalidSecurityConfiguration;
        }
    }

    if (install.get("scopes")) |value| {
        const scopes = value.asTable() orelse return error.InvalidScopesConfiguration;
        var iterator = scopes.iterator();
        while (iterator.next()) |entry| {
            if (entry.key_ptr.len == 0) continue;
            var registry = try registryFromValue(options, entry.value_ptr.*);
            if (registry.url.len == 0) {
                registry.url = try options.own(if (options.default_registry) |configured|
                    configured.url
                else
                    types.default_registry_url);
            }
            try options.putScope(entry.key_ptr.*, registry);
        }
    }
}

fn registryFromValue(
    options: *InstallOptions,
    value: Value,
) !NpmRegistry {
    return switch (value) {
        .string => |url| options.registryFromUrl(url),
        .table => |table| options.ownRegistry(.{
            .url = stringField(table, "url"),
            .username = stringField(table, "username"),
            .password = stringField(table, "password"),
            .token = stringField(table, "token"),
            .email = stringField(table, "email"),
        }),
        else => error.InvalidRegistryConfiguration,
    };
}

fn stringField(table: *toml.Table, key: []const u8) []const u8 {
    const value = table.get(key) orelse return "";
    return value.asString() orelse "";
}

fn setOptionalString(
    options: *InstallOptions,
    destination: *?[]const u8,
    value: ?Value,
) !void {
    const configured = value orelse return;
    destination.* = try options.own(
        configured.asString() orelse return error.ExpectedString,
    );
}

fn setOptionalBool(destination: *?bool, value: ?Value) !void {
    const configured = value orelse return;
    destination.* = configured.asBool() orelse return error.ExpectedBoolean;
}

fn ownStringOrArray(
    options: *InstallOptions,
    value: Value,
) ![]const []const u8 {
    return switch (value) {
        .string => |string| blk: {
            const temporary = [_][]const u8{string};
            break :blk try options.ownList(&temporary);
        },
        .array => |array| ownStringArray(options, array),
        else => error.ExpectedStringOrArray,
    };
}

fn ownStringArray(
    options: *InstallOptions,
    values: []const Value,
) ![]const []const u8 {
    const temporary = try options.allocator.alloc([]const u8, values.len);
    defer options.allocator.free(temporary);
    for (values, 0..) |value, index| {
        temporary[index] = value.asString() orelse return error.ExpectedString;
    }
    return options.ownList(temporary);
}

test "bunfig parses install options, registry auth, and scopes" {
    const testing = std.testing;
    var options = InstallOptions.init(testing.allocator);
    defer options.deinit();

    try parse(&options,
        \\[install]
        \\globalDir = "./global"
        \\globalBinDir = "./bin"
        \\registry = { url = "https://registry.example.test/", token = "root-token" }
        \\linker = "isolated"
        \\saveTextLockfile = false
        \\exact = true
        \\frozenLockfile = true
        \\dev = false
        \\optional = false
        \\peer = true
        \\linkWorkspacePackages = false
        \\minimumReleaseAge = 86_400
        \\minimumReleaseAgeExcludes = ["always-new", "@scope/exempt"]
        \\concurrentScripts = 12
        \\publicHoistPattern = ["@types/*", "!private-*"]
        \\hoistPattern = "eslint"
        \\cache = { disable = false, dir = "./cache" }
        \\ca = ["first cert", "second cert"]
        \\cafile = "./ca.pem"
        \\[install.security]
        \\scanner = "./scanner.ts"
        \\[install.scopes]
        \\"@acme" = { url = "https://registry.example.test/acme/", username = "alice", password = "rabbit" }
        \\"@inherited" = { token = "scope-token" }
    );

    try testing.expectEqualStrings("./global", options.global_dir.?);
    try testing.expectEqualStrings("./bin", options.global_bin_dir.?);
    try testing.expectEqual(.isolated, options.node_linker.?);
    try testing.expectEqual(false, options.save_text_lockfile.?);
    try testing.expectEqual(true, options.exact.?);
    try testing.expectEqual(false, options.save_dev.?);
    try testing.expectEqual(false, options.save_optional.?);
    try testing.expectEqual(@as(f64, 86_400_000), options.minimum_release_age_ms.?);
    try testing.expectEqual(@as(u32, 12), options.concurrent_scripts.?);
    try testing.expectEqualStrings("./cache", options.cache_directory.?);
    try testing.expectEqualStrings("./scanner.ts", options.security_scanner.?);
    try testing.expectEqual(@as(usize, 2), options.minimum_release_age_excludes.?.len);
    try testing.expectEqual(@as(usize, 2), options.public_hoist_pattern.?.len);
    try testing.expectEqualStrings("eslint", options.hoist_pattern.?[0]);

    const root_auth = try options.default_registry.?.authorization(testing.allocator);
    defer testing.allocator.free(root_auth.?);
    try testing.expectEqualStrings("Bearer root-token", root_auth.?);

    const acme = options.scopes.get("acme").?;
    const acme_auth = try acme.authorization(testing.allocator);
    defer testing.allocator.free(acme_auth.?);
    try testing.expectEqualStrings("Basic YWxpY2U6cmFiYml0", acme_auth.?);

    const inherited = options.scopes.get("inherited").?;
    try testing.expectEqualStrings(
        "https://registry.example.test/",
        inherited.url,
    );
    try testing.expectEqualStrings("scope-token", inherited.token);
}

test "bunfig supports dotted install assignments" {
    const testing = std.testing;
    var options = InstallOptions.init(testing.allocator);
    defer options.deinit();

    try parse(&options,
        \\install.globalDir = "/tmp/global"
        \\install.saveTextLockfile = true
        \\install.security.scanner = "scanner-package"
    );
    try testing.expectEqualStrings("/tmp/global", options.global_dir.?);
    try testing.expectEqual(true, options.save_text_lockfile.?);
    try testing.expectEqualStrings("scanner-package", options.security_scanner.?);
}
