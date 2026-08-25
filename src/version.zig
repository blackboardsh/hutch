pub const version = "0.26.0-canary.3";

/// The Cottontail release this Hutch release was built and tested with.
/// With no pragma and no shim-supplied default, this pair is what runs:
/// `hutch self update` therefore advances both halves atomically. Explicit
/// pins (pragma, `hutch cottontail pin`) remain the way to stop floating.
pub const paired_cottontail_version = "0.6.0-canary.11";

test "the paired cottontail version is an exact semantic version" {
    const std = @import("std");
    _ = try std.SemanticVersion.parse(paired_cottontail_version);
    _ = try std.SemanticVersion.parse(version);
}
