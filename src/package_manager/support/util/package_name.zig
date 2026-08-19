const std = @import("std");

/// Implements Bun's npm package-name validation, including compatibility with
/// legacy uppercase package names and scoped names accepted by encodeURIComponent.
pub fn isNPMPackageName(name: []const u8) bool {
    if (name.len > 214) return false;
    return isNPMPackageNameIgnoreLength(name);
}

pub fn isNPMPackageNameIgnoreLength(name: []const u8) bool {
    if (name.len == 0) return false;

    const scoped = switch (name[0]) {
        'A'...'Z', 'a'...'z', '0'...'9', '$', '-' => false,
        '@' => true,
        else => return false,
    };

    var slash_index: usize = 0;
    for (name[1..], 0..) |character, index| {
        switch (character) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.' => {},
            '/' => {
                if (!scoped or slash_index > 0) return false;
                slash_index = index + 1;
            },
            '!', '~', '*', '\'', '(', ')' => {
                if (!scoped or slash_index > 0) return false;
            },
            else => return false,
        }
    }

    return !scoped or slash_index > 0 and slash_index + 1 < name.len;
}

test "npm package-name validation matches Bun compatibility rules" {
    const valid = [_][]const u8{
        "react",
        "React",
        "$legacy",
        "-legacy",
        "@scope/package",
        "@Scope/package_name.js",
        "@~3/svelte_mount",
        "@scope!~/package",
    };
    for (valid) |name| {
        try std.testing.expect(isNPMPackageName(name));
    }

    const invalid = [_][]const u8{
        "",
        "_unscoped",
        ".unscoped",
        "unscoped/name",
        "@scope",
        "@scope/",
        "@scope/package/extra",
        "has space",
        "package$name",
    };
    for (invalid) |name| {
        try std.testing.expect(!isNPMPackageName(name));
    }
}

test "npm package names enforce Bun's 214-byte limit" {
    const at_limit = "a" ** 214;
    const over_limit = "a" ** 215;
    try std.testing.expect(isNPMPackageName(at_limit));
    try std.testing.expect(!isNPMPackageName(over_limit));
    try std.testing.expect(isNPMPackageNameIgnoreLength(over_limit));
}
