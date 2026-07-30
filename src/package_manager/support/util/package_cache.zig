const std = @import("std");

pub const cache_version = 1;

/// Formats Bun's extracted npm-package cache basename. `version` must expose
/// major/minor/patch and tag.hasPre()/hasBuild() with pre/build hash fields.
pub fn cachedNPMPackageFolderPrintBasename(
    buffer: []u8,
    name: []const u8,
    version: anytype,
    patch_hash: ?u64,
    include_cache_version: bool,
) [:0]const u8 {
    const cache_suffix = if (include_cache_version) "@@@1" else "";

    if (version.tag.hasPre()) {
        if (version.tag.hasBuild()) {
            if (patch_hash) |hash| {
                return std.fmt.bufPrintZ(buffer, "{s}@{d}.{d}.{d}-{x}+{X}{s}_patch_hash={x}", .{
                    name,
                    version.major,
                    version.minor,
                    version.patch,
                    version.tag.pre.hash,
                    version.tag.build.hash,
                    cache_suffix,
                    hash,
                }) catch unreachable;
            }
            return std.fmt.bufPrintZ(buffer, "{s}@{d}.{d}.{d}-{x}+{X}{s}", .{
                name,
                version.major,
                version.minor,
                version.patch,
                version.tag.pre.hash,
                version.tag.build.hash,
                cache_suffix,
            }) catch unreachable;
        }

        if (patch_hash) |hash| {
            return std.fmt.bufPrintZ(buffer, "{s}@{d}.{d}.{d}-{x}{s}_patch_hash={x}", .{
                name,
                version.major,
                version.minor,
                version.patch,
                version.tag.pre.hash,
                cache_suffix,
                hash,
            }) catch unreachable;
        }
        return std.fmt.bufPrintZ(buffer, "{s}@{d}.{d}.{d}-{x}{s}", .{
            name,
            version.major,
            version.minor,
            version.patch,
            version.tag.pre.hash,
            cache_suffix,
        }) catch unreachable;
    }

    if (version.tag.hasBuild()) {
        if (patch_hash) |hash| {
            return std.fmt.bufPrintZ(buffer, "{s}@{d}.{d}.{d}+{X}{s}_patch_hash={x}", .{
                name,
                version.major,
                version.minor,
                version.patch,
                version.tag.build.hash,
                cache_suffix,
                hash,
            }) catch unreachable;
        }
        return std.fmt.bufPrintZ(buffer, "{s}@{d}.{d}.{d}+{X}{s}", .{
            name,
            version.major,
            version.minor,
            version.patch,
            version.tag.build.hash,
            cache_suffix,
        }) catch unreachable;
    }

    if (patch_hash) |hash| {
        return std.fmt.bufPrintZ(buffer, "{s}@{d}.{d}.{d}{s}_patch_hash={x}", .{
            name,
            version.major,
            version.minor,
            version.patch,
            cache_suffix,
            hash,
        }) catch unreachable;
    }
    return std.fmt.bufPrintZ(buffer, "{s}@{d}.{d}.{d}{s}", .{
        name,
        version.major,
        version.minor,
        version.patch,
        cache_suffix,
    }) catch unreachable;
}

const TestTag = struct {
    const Hash = struct {
        hash: u64 = 0,
    };

    pre: Hash = .{},
    build: Hash = .{},
    has_pre: bool = false,
    has_build: bool = false,

    fn hasPre(self: TestTag) bool {
        return self.has_pre;
    }

    fn hasBuild(self: TestTag) bool {
        return self.has_build;
    }
};

const TestVersion = struct {
    major: u32,
    minor: u32,
    patch: u32,
    tag: TestTag = .{},
};

test "cached npm package basenames include cache and patch suffixes" {
    var buffer: [256]u8 = undefined;
    const version: TestVersion = .{ .major = 1, .minor = 2, .patch = 3 };

    try std.testing.expectEqualStrings(
        "react@1.2.3@@@1",
        cachedNPMPackageFolderPrintBasename(&buffer, "react", version, null, true),
    );
    try std.testing.expectEqualStrings(
        "@scope/pkg@1.2.3_patch_hash=abcdef",
        cachedNPMPackageFolderPrintBasename(&buffer, "@scope/pkg", version, 0xabcdef, false),
    );
}

test "cached npm package basenames encode prerelease and build hashes" {
    var buffer: [256]u8 = undefined;
    const version: TestVersion = .{
        .major = 4,
        .minor = 5,
        .patch = 6,
        .tag = .{
            .pre = .{ .hash = 0xdeadbeef },
            .build = .{ .hash = 0xcafe },
            .has_pre = true,
            .has_build = true,
        },
    };

    try std.testing.expectEqualStrings(
        "pkg@4.5.6-deadbeef+CAFE@@@1_patch_hash=1234",
        cachedNPMPackageFolderPrintBasename(&buffer, "pkg", version, 0x1234, true),
    );
}
