const std = @import("std");

pub const Kind = enum {
    production,
    canary,
    version,
    build,
};

pub const Selector = struct {
    kind: Kind,
    value: []const u8,

    pub fn channel(self: Selector) ?[]const u8 {
        return switch (self.kind) {
            .production => "production",
            .canary => "canary",
            else => null,
        };
    }
};

pub fn normalizeChannel(value: []const u8) ![]const u8 {
    if (std.mem.eql(u8, value, "production") or std.mem.eql(u8, value, "stable")) {
        return "production";
    }
    if (std.mem.eql(u8, value, "canary")) return "canary";
    return error.InvalidReleaseChannel;
}

pub fn parse(value: []const u8) !Selector {
    if (value.len == 0 or value.len > 128) return error.InvalidVersionSelector;
    if (std.mem.eql(u8, value, "production") or std.mem.eql(u8, value, "stable")) {
        return .{ .kind = .production, .value = "production" };
    }
    if (std.mem.eql(u8, value, "canary")) return .{ .kind = .canary, .value = value };

    if (std.mem.startsWith(u8, value, "build:")) {
        const revision = value["build:".len..];
        if (revision.len != 40 and revision.len != 64) return error.InvalidBuildRevision;
        for (revision) |byte| {
            if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) {
                return error.InvalidBuildRevision;
            }
        }
        return .{ .kind = .build, .value = revision };
    }

    _ = std.SemanticVersion.parse(value) catch return error.InvalidSemanticVersion;
    return .{ .kind = .version, .value = value };
}

test "version selectors accept channels, semver, and full revisions" {
    try std.testing.expectEqual(Kind.production, (try parse("production")).kind);
    const stable = try parse("stable");
    try std.testing.expectEqual(Kind.production, stable.kind);
    try std.testing.expectEqualStrings("production", stable.value);
    try std.testing.expectEqualStrings("production", stable.channel().?);
    try std.testing.expectEqual(Kind.canary, (try parse("canary")).kind);
    try std.testing.expectEqual(Kind.version, (try parse("1.2.3-canary.4")).kind);

    const build = try parse("build:0123456789abcdef0123456789abcdef01234567");
    try std.testing.expectEqual(Kind.build, build.kind);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef01234567", build.value);
}

test "version selectors reject unknown aliases and abbreviated revisions" {
    try std.testing.expectError(error.InvalidSemanticVersion, parse("latest"));
    try std.testing.expectError(error.InvalidSemanticVersion, parse("v1.2.3"));
    try std.testing.expectError(error.InvalidBuildRevision, parse("build:0123456"));
    try std.testing.expectError(
        error.InvalidBuildRevision,
        parse("build:0123456789ABCDEF0123456789ABCDEF01234567"),
    );
}

test "release channels normalize the stable compatibility alias" {
    try std.testing.expectEqualStrings("production", try normalizeChannel("production"));
    try std.testing.expectEqualStrings("production", try normalizeChannel("stable"));
    try std.testing.expectEqualStrings("canary", try normalizeChannel("canary"));
    try std.testing.expectError(error.InvalidReleaseChannel, normalizeChannel("latest"));
}
