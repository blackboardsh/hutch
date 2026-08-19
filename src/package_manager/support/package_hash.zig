const Semver = @import("semver/root.zig");

pub const TruncatedPackageNameHash = u32;

pub fn packageNameHash(name: []const u8) TruncatedPackageNameHash {
    return @truncate(Semver.String.Builder.stringHash(name));
}
