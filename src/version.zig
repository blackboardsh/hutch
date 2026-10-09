pub const version = "0.28.0-canary.6";

/// The Cottontail release this Hutch release was built and tested with.
/// Internal config/bundling helpers and explicitly selected experimental
/// Cottontail scripts use this pair unless a pragma or override selects one.
/// Normal scripts use the Bun pin in toolchain_store.zig. `hutch self update`
/// advances the paired tools; explicit Cottontail pins remain supported.
pub const paired_cottontail_version = "0.7.2-canary.6";

test "the paired cottontail version is an exact semantic version" {
    const std = @import("std");
    _ = try std.SemanticVersion.parse(paired_cottontail_version);
    _ = try std.SemanticVersion.parse(version);
}
