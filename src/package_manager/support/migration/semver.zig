const std = @import("std");

const Version = struct {
    major: u64 = 0,
    minor: u64 = 0,
    patch: u64 = 0,
    components: u2 = 0,
    prerelease: []const u8 = "",
    wildcard: bool = false,

    fn min(version: Version) Version {
        var result = version;
        result.components = 3;
        result.wildcard = false;
        return result;
    }

    fn upperForPartial(version: Version) ?Version {
        if (!version.wildcard and version.components == 3) return null;
        if (version.components <= 1) {
            return .{ .major = version.major +| 1, .components = 3 };
        }
        return .{
            .major = version.major,
            .minor = version.minor +| 1,
            .components = 3,
        };
    }
};

const Operator = enum {
    exact,
    gt,
    gte,
    lt,
    lte,
    caret,
    tilde,
};

pub fn satisfies(version_text: []const u8, range_text: []const u8) bool {
    const version = parseVersion(version_text) orelse return false;
    if (version.wildcard or version.components < 3) return false;

    var clauses = std.mem.splitSequence(u8, range_text, "||");
    while (clauses.next()) |raw_clause| {
        const clause = std.mem.trim(u8, raw_clause, " \t\r\n");
        if (clauseSatisfies(version, clause)) return true;
    }
    return false;
}

fn clauseSatisfies(version: Version, clause: []const u8) bool {
    if (version.prerelease.len > 0 and !clauseOptsIntoPrerelease(version, clause)) {
        return false;
    }
    if (clause.len == 0 or std.mem.eql(u8, clause, "*")) return true;

    if (std.mem.indexOf(u8, clause, " - ")) |hyphen| {
        const lower_text = std.mem.trim(u8, clause[0..hyphen], " \t");
        const upper_text = std.mem.trim(u8, clause[hyphen + 3 ..], " \t");
        const lower = parseVersion(lower_text) orelse return false;
        const upper = parseVersion(upper_text) orelse return false;
        if (compare(version, lower.min()) == .lt) return false;
        if (upper.upperForPartial()) |exclusive_upper| {
            return compare(version, exclusive_upper) == .lt;
        }
        return compare(version, upper.min()) != .gt;
    }

    var tokens = std.mem.tokenizeAny(u8, clause, " \t\r\n,");
    while (tokens.next()) |token| {
        if (operatorOnly(token)) |operator| {
            const operand = tokens.next() orelse return false;
            if (!tokenSatisfies(version, operator, operand)) return false;
            continue;
        }
        const parsed = parseOperator(token);
        if (!tokenSatisfies(version, parsed.operator, parsed.operand)) return false;
    }
    return true;
}

fn tokenSatisfies(version: Version, operator: Operator, operand: []const u8) bool {
    if (operand.len == 0 or std.mem.eql(u8, operand, "*") or
        std.ascii.eqlIgnoreCase(operand, "x"))
    {
        return operator == .exact or operator == .gte or operator == .lte;
    }

    const target = parseVersion(operand) orelse return false;
    const lower = target.min();
    return switch (operator) {
        .exact => if (target.upperForPartial()) |upper|
            compare(version, lower) != .lt and compare(version, upper) == .lt
        else
            compare(version, lower) == .eq,
        .gte => compare(version, lower) != .lt,
        .gt => if (target.upperForPartial()) |upper|
            compare(version, upper) != .lt
        else
            compare(version, lower) == .gt,
        .lt => compare(version, lower) == .lt,
        .lte => if (target.upperForPartial()) |upper|
            compare(version, upper) == .lt
        else
            compare(version, lower) != .gt,
        .tilde => {
            const upper = if (target.components <= 1)
                Version{ .major = target.major +| 1, .components = 3 }
            else
                Version{
                    .major = target.major,
                    .minor = target.minor +| 1,
                    .components = 3,
                };
            return compare(version, lower) != .lt and compare(version, upper) == .lt;
        },
        .caret => {
            const upper = if (target.major > 0 or target.components <= 1)
                Version{ .major = target.major +| 1, .components = 3 }
            else if (target.minor > 0 or target.components <= 2)
                Version{
                    .major = target.major,
                    .minor = target.minor +| 1,
                    .components = 3,
                }
            else
                Version{
                    .major = target.major,
                    .minor = target.minor,
                    .patch = target.patch +| 1,
                    .components = 3,
                };
            return compare(version, lower) != .lt and compare(version, upper) == .lt;
        },
    };
}

fn clauseOptsIntoPrerelease(version: Version, clause: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, clause, " \t\r\n,");
    while (tokens.next()) |raw_token| {
        if (std.mem.eql(u8, raw_token, "-")) continue;
        const operand = if (operatorOnly(raw_token) != null)
            tokens.next() orelse return false
        else
            parseOperator(raw_token).operand;
        const target = parseVersion(operand) orelse continue;
        if (target.prerelease.len > 0 and
            target.major == version.major and
            target.minor == version.minor and
            target.patch == version.patch)
        {
            return true;
        }
    }
    return false;
}

fn parseOperator(token: []const u8) struct { operator: Operator, operand: []const u8 } {
    const prefixes = [_]struct { text: []const u8, operator: Operator }{
        .{ .text = ">=", .operator = .gte },
        .{ .text = "<=", .operator = .lte },
        .{ .text = "~>", .operator = .tilde },
        .{ .text = ">", .operator = .gt },
        .{ .text = "<", .operator = .lt },
        .{ .text = "^", .operator = .caret },
        .{ .text = "~", .operator = .tilde },
        .{ .text = "=", .operator = .exact },
    };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, token, prefix.text)) {
            return .{ .operator = prefix.operator, .operand = token[prefix.text.len..] };
        }
    }
    return .{ .operator = .exact, .operand = token };
}

fn operatorOnly(token: []const u8) ?Operator {
    if (std.mem.eql(u8, token, ">=")) return .gte;
    if (std.mem.eql(u8, token, "<=")) return .lte;
    if (std.mem.eql(u8, token, "~>")) return .tilde;
    if (std.mem.eql(u8, token, ">")) return .gt;
    if (std.mem.eql(u8, token, "<")) return .lt;
    if (std.mem.eql(u8, token, "^")) return .caret;
    if (std.mem.eql(u8, token, "~")) return .tilde;
    if (std.mem.eql(u8, token, "=")) return .exact;
    return null;
}

fn parseVersion(raw: []const u8) ?Version {
    var input = std.mem.trim(u8, raw, " \t\r\n");
    while (input.len > 0 and (input[0] == 'v' or input[0] == 'V' or input[0] == '=')) {
        input = std.mem.trimStart(u8, input[1..], " \t");
    }
    if (input.len == 0) return null;

    const build = std.mem.indexOfScalar(u8, input, '+') orelse input.len;
    input = input[0..build];
    var prerelease: []const u8 = "";
    if (std.mem.indexOfScalar(u8, input, '-')) |hyphen| {
        prerelease = input[hyphen + 1 ..];
        input = input[0..hyphen];
        if (prerelease.len == 0) return null;
    }

    var result = Version{ .prerelease = prerelease };
    var parts = std.mem.splitScalar(u8, input, '.');
    var index: usize = 0;
    while (parts.next()) |part| : (index += 1) {
        if (index >= 3 or part.len == 0) return null;
        if (std.mem.eql(u8, part, "*") or std.ascii.eqlIgnoreCase(part, "x")) {
            result.wildcard = true;
            while (parts.next()) |remaining| {
                if (!(std.mem.eql(u8, remaining, "*") or std.ascii.eqlIgnoreCase(remaining, "x"))) {
                    return null;
                }
            }
            break;
        }
        const number = std.fmt.parseInt(u64, part, 10) catch return null;
        switch (index) {
            0 => result.major = number,
            1 => result.minor = number,
            2 => result.patch = number,
            else => unreachable,
        }
        result.components = @intCast(index + 1);
    }
    if (result.components == 0 and !result.wildcard) return null;
    return result;
}

fn compare(lhs: Version, rhs: Version) std.math.Order {
    if (lhs.major != rhs.major) return std.math.order(lhs.major, rhs.major);
    if (lhs.minor != rhs.minor) return std.math.order(lhs.minor, rhs.minor);
    if (lhs.patch != rhs.patch) return std.math.order(lhs.patch, rhs.patch);
    if (lhs.prerelease.len == 0) return if (rhs.prerelease.len == 0) .eq else .gt;
    if (rhs.prerelease.len == 0) return .lt;

    var left = std.mem.splitScalar(u8, lhs.prerelease, '.');
    var right = std.mem.splitScalar(u8, rhs.prerelease, '.');
    while (true) {
        const left_part = left.next();
        const right_part = right.next();
        if (left_part == null) return if (right_part == null) .eq else .lt;
        if (right_part == null) return .gt;
        if (std.mem.eql(u8, left_part.?, right_part.?)) continue;

        const left_numeric = numericIdentifier(left_part.?);
        const right_numeric = numericIdentifier(right_part.?);
        if (left_numeric and !right_numeric) return .lt;
        if (!left_numeric and right_numeric) return .gt;
        if (!left_numeric) return std.mem.order(u8, left_part.?, right_part.?);

        const left_trimmed = std.mem.trimStart(u8, left_part.?, "0");
        const right_trimmed = std.mem.trimStart(u8, right_part.?, "0");
        if (left_trimmed.len != right_trimmed.len) {
            return std.math.order(left_trimmed.len, right_trimmed.len);
        }
        return std.mem.order(u8, left_trimmed, right_trimmed);
    }
}

fn numericIdentifier(identifier: []const u8) bool {
    if (identifier.len == 0) return false;
    for (identifier) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

test "supports npm ranges used by Yarn peer dependencies" {
    try std.testing.expect(satisfies("1.5.0", "^1.2.3"));
    try std.testing.expect(!satisfies("2.0.0", "^1.2.3"));
    try std.testing.expect(satisfies("0.2.9", "^0.2.3"));
    try std.testing.expect(!satisfies("0.3.0", "^0.2.3"));
    try std.testing.expect(satisfies("1.2.9", "~1.2.3"));
    try std.testing.expect(!satisfies("1.3.0", "~1.2.3"));
    try std.testing.expect(satisfies("2.4.1", ">=2 <3"));
    try std.testing.expect(satisfies("1.2.99", "1.2.x"));
    try std.testing.expect(satisfies("1.5.0", "1.2.3 - 2.0.0"));
    try std.testing.expect(satisfies("3.1.0", "^1.2.3 || >=3"));
}

test "prereleases require a comparator with the same release tuple" {
    try std.testing.expect(!satisfies("1.5.0-beta.1", "^1.2.3"));
    try std.testing.expect(satisfies("1.5.0-beta.2", ">=1.5.0-beta.1 <2"));
    try std.testing.expect(!satisfies("1.6.0-beta.1", ">=1.5.0-beta.1 <2"));
}
