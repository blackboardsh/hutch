const std = @import("std");
const String = @import("package_manager/support/semver/string.zig").String;

// Keep the package-cache naming tests in the standard release test run too.
comptime {
    _ = @import("package_manager/support/util/package_cache.zig");
}

test "semver strings retain their persisted eight-byte representation" {
    const buffer = "prefix:long-prerelease-identifier";
    const external = String.init(buffer, buffer[7..]);
    try std.testing.expect(!external.isInline());
    // Existing lockfiles encode native little-endian offset/length words,
    // with the high bit marking a reference into the shared string buffer.
    const persisted = [_]u8{ 7, 0, 0, 0, 26, 0, 0, 0x80 };
    try std.testing.expectEqualSlices(u8, &persisted, std.mem.asBytes(&external));
    const restored = std.mem.bytesToValue(String, &persisted);
    try std.testing.expectEqual(@as(usize, 26), restored.len());
    try std.testing.expectEqualStrings(buffer[7..], restored.slice(buffer));

    const ascii = "12345678";
    for (0..ascii.len + 1) |len| {
        const value = String.init(ascii, ascii[0..len]);
        try std.testing.expect(value.isInline());
        try std.testing.expectEqual(len, value.len());
        try std.testing.expectEqualStrings(ascii[0..len], value.slice(ascii));
    }

    // Eight bytes ending in a non-ASCII byte must use the external form;
    // otherwise the inline payload could be mistaken for the reference tag.
    const unicode = "abcdefé";
    const value = String.init(unicode, unicode);
    try std.testing.expect(!value.isInline());
    try std.testing.expectEqualStrings(unicode, value.slice(unicode));
}
