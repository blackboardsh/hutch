const std = @import("std");
const semver = @import("root.zig");

const testing = std.testing;

fn parseVersion(input: []const u8) !semver.Version {
    const parsed = semver.Version.parseUTF8(input);
    try testing.expect(parsed.valid);
    return parsed.version.min();
}

fn expectOrder(
    expected: std.math.Order,
    lhs_input: []const u8,
    rhs_input: []const u8,
) !void {
    const lhs = try parseVersion(lhs_input);
    const rhs = try parseVersion(rhs_input);
    try testing.expectEqual(expected, lhs.order(rhs, lhs_input, rhs_input));
}

fn expectSatisfies(expected: bool, version_input: []const u8, range_input: []const u8) !void {
    const version = try parseVersion(version_input);
    var query = try semver.Query.parse(
        testing.allocator,
        range_input,
        semver.SlicedString.init(range_input, range_input),
    );
    defer query.deinit();

    try testing.expectEqual(
        expected,
        query.satisfies(version, range_input, version_input),
    );
}

test "version parsing preserves Bun-compatible loose syntax" {
    const parsed = semver.Version.parseUTF8(" v=1.2.3-beta.4+build.9");
    try testing.expect(parsed.valid);
    try testing.expectEqual(@as(u64, 1), parsed.version.major.?);
    try testing.expectEqual(@as(u64, 2), parsed.version.minor.?);
    try testing.expectEqual(@as(u64, 3), parsed.version.patch.?);
    try testing.expectEqualStrings("beta.4", parsed.version.tag.pre.slice(" v=1.2.3-beta.4+build.9"));
    try testing.expectEqualStrings("build.9", parsed.version.tag.build.slice(" v=1.2.3-beta.4+build.9"));

    const wildcard = semver.Version.parseUTF8("1.2.x");
    try testing.expect(wildcard.valid);
    try testing.expectEqual(.patch, wildcard.wildcard);
    try testing.expectEqual(@as(u64, 1), wildcard.version.major.?);
    try testing.expectEqual(@as(u64, 2), wildcard.version.minor.?);
    try testing.expectEqual(null, wildcard.version.patch);
}

test "version ordering follows semver prerelease precedence" {
    try expectOrder(.lt, "1.0.0", "2.0.0");
    try expectOrder(.lt, "1.0.0-alpha", "1.0.0");
    try expectOrder(.lt, "1.0.0-alpha.1", "1.0.0-alpha.beta");
    try expectOrder(.lt, "1.0.0-beta.2", "1.0.0-beta.11");
    try expectOrder(.gt, "1.0.0-rc.1", "1.0.0-beta.11");

    const with_build = try parseVersion("1.2.3+one");
    const other_build = try parseVersion("1.2.3+two");
    try testing.expectEqual(
        .eq,
        with_build.orderWithoutBuild(other_build, "1.2.3+one", "1.2.3+two"),
    );
}

test "version pin and tag classification preserves package-manager behavior" {
    try testing.expectEqual(.major, semver.Version.whichVersionIsPinned("^1.2.3"));
    try testing.expectEqual(.minor, semver.Version.whichVersionIsPinned("~1.2.3"));
    try testing.expectEqual(.patch, semver.Version.whichVersionIsPinned("1.2.3"));
    try testing.expectEqual(.major, semver.Version.whichVersionIsPinned("1"));
    try testing.expectEqual(.minor, semver.Version.whichVersionIsPinned("1.2"));

    try testing.expect(semver.Version.isTaggedVersionOnly("latest"));
    try testing.expect(semver.Version.isTaggedVersionOnly("next2"));
    try testing.expect(!semver.Version.isTaggedVersionOnly("1.2.3"));
    try testing.expect(!semver.Version.isTaggedVersionOnly("next-tag"));
}

test "query supports npm caret tilde comparator wildcard hyphen and union ranges" {
    try expectSatisfies(true, "1.5.0", "^1.2.3");
    try expectSatisfies(false, "2.0.0", "^1.2.3");
    try expectSatisfies(true, "0.2.9", "^0.2.3");
    try expectSatisfies(false, "0.3.0", "^0.2.3");

    try expectSatisfies(true, "1.2.9", "~1.2.3");
    try expectSatisfies(false, "1.3.0", "~1.2.3");
    try expectSatisfies(true, "2.4.1", ">=2 <3");
    try expectSatisfies(false, "3.0.0", ">=2 <3");

    try expectSatisfies(true, "1.2.99", "1.2.x");
    try expectSatisfies(false, "1.3.0", "1.2.x");
    try expectSatisfies(true, "1.5.0", "1.2.3 - 2.0.0");
    try expectSatisfies(true, "2.0.0", "1.2.3 - 2.0.0");
    try expectSatisfies(false, "2.0.1", "1.2.3 - 2.0.0");

    try expectSatisfies(true, "1.4.0", "^1.2.3 || >=3");
    try expectSatisfies(false, "2.0.0", "^1.2.3 || >=3");
    try expectSatisfies(true, "3.1.0", "^1.2.3 || >=3");
}

test "query excludes prereleases unless a matching comparator opts in" {
    try expectSatisfies(false, "1.5.0-beta.1", "^1.2.3");
    try expectSatisfies(true, "1.5.0-beta.2", ">=1.5.0-beta.1 <2");
    try expectSatisfies(false, "1.6.0-beta.1", ">=1.5.0-beta.1 <2");
}

test "semver string keeps inline and external representations stable" {
    var inline_value = semver.String.init("short", "short");
    try testing.expect(inline_value.isInline());
    try testing.expectEqualStrings("short", inline_value.slice(""));

    const external_buffer = "a-long-semver-tag";
    var external_value = semver.String.init(external_buffer, external_buffer);
    try testing.expect(!external_value.isInline());
    try testing.expectEqualStrings(external_buffer, external_value.slice(external_buffer));
    try testing.expectEqual(@as(usize, external_buffer.len), external_value.len());

    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(testing.allocator);
    const appended = try semver.String.initAppendIfNeeded(
        testing.allocator,
        &list,
        "another-long-tag",
    );
    var appended_value = appended;
    try testing.expectEqualStrings("another-long-tag", appended_value.slice(list.items));
}

test "semver string builder hashes and interns external strings" {
    try testing.expectEqual(
        @as(u64, 0x58cd09ec70c64344),
        semver.String.Builder.stringHash("hello"),
    );

    var builder = semver.String.Builder{
        .string_pool = semver.String.Builder.StringPool.init(testing.allocator),
    };
    defer builder.string_pool.deinit();

    const value = "a-package-name-that-does-not-inline";
    builder.count(value);
    try builder.allocate(testing.allocator);
    defer testing.allocator.free(builder.allocatedSlice());

    var first = builder.append(semver.ExternalString, value);
    var second = builder.append(semver.ExternalString, value);
    try testing.expectEqual(first.hash, second.hash);
    try testing.expectEqualStrings(value, first.slice(builder.allocatedSlice()));
    try testing.expectEqualStrings(value, second.slice(builder.allocatedSlice()));
    try testing.expectEqual(
        semver.String.Builder.stringHash(value),
        first.hash,
    );
}
