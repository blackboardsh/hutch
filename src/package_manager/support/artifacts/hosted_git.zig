const std = @import("std");

pub const Representation = enum {
    shortcut,
    sshurl,
    ssh,
    https,
    git,
    http,
};

pub const HostProvider = enum {
    bitbucket,
    gist,
    github,
    gitlab,
    sourcehut,

    fn fromShortcut(value: []const u8) ?HostProvider {
        if (std.mem.eql(u8, value, "bitbucket")) return .bitbucket;
        if (std.mem.eql(u8, value, "gist")) return .gist;
        if (std.mem.eql(u8, value, "github")) return .github;
        if (std.mem.eql(u8, value, "gitlab")) return .gitlab;
        if (std.mem.eql(u8, value, "sourcehut")) return .sourcehut;
        return null;
    }

    fn fromDomain(value: []const u8) ?HostProvider {
        const domain = if (startsWithIgnoreCase(value, "www.")) value["www.".len..] else value;
        if (eqlIgnoreCase(domain, "bitbucket.org")) return .bitbucket;
        if (eqlIgnoreCase(domain, "gist.github.com")) return .gist;
        if (eqlIgnoreCase(domain, "github.com")) return .github;
        if (eqlIgnoreCase(domain, "gitlab.com")) return .gitlab;
        if (eqlIgnoreCase(domain, "git.sr.ht")) return .sourcehut;
        return null;
    }
};

pub const HostedGitInfo = struct {
    committish: ?[]const u8,
    project: []const u8,
    user: ?[]const u8,
    host_provider: HostProvider,
    default_representation: Representation,

    allocator: std.mem.Allocator,
    owned_user: ?[]u8,
    owned_project: []u8,
    owned_committish: ?[]u8,

    pub fn deinit(self: *const HostedGitInfo) void {
        if (self.owned_user) |value| self.allocator.free(value);
        self.allocator.free(self.owned_project);
        if (self.owned_committish) |value| self.allocator.free(value);
    }

    pub fn fromUrl(
        allocator: std.mem.Allocator,
        input: []const u8,
    ) error{ OutOfMemory, InvalidURL }!?HostedGitInfo {
        if (input.len == 0) return null;

        if (try parseShortcut(allocator, input)) |shortcut| return shortcut;
        const location = parseLocation(input) orelse return null;
        const provider = HostProvider.fromDomain(location.host) orelse return null;
        return build(
            allocator,
            provider,
            location.path,
            location.fragment,
            location.representation,
        );
    }
};

const Location = struct {
    host: []const u8,
    path: []const u8,
    fragment: ?[]const u8,
    representation: Representation,
};

fn parseShortcut(
    allocator: std.mem.Allocator,
    input: []const u8,
) error{ OutOfMemory, InvalidURL }!?HostedGitInfo {
    const colon = std.mem.indexOfScalar(u8, input, ':') orelse return null;
    if (std.mem.indexOf(u8, input[0..colon], "//") != null) return null;
    const provider = HostProvider.fromShortcut(input[0..colon]) orelse return null;

    const split = splitFragment(input[colon + 1 ..]);
    var path = split.value;
    if (std.mem.lastIndexOfScalar(u8, path, '@')) |at| path = path[at + 1 ..];
    path = std.mem.trim(u8, path, "/");
    return build(allocator, provider, path, split.fragment, .shortcut);
}

fn parseLocation(input: []const u8) ?Location {
    const split = splitFragment(input);
    var source = split.value;
    var representation: Representation = .ssh;

    if (startsWithIgnoreCase(source, "git+ssh://")) {
        representation = .sshurl;
        source = source["git+ssh://".len..];
    } else if (startsWithIgnoreCase(source, "git+https://")) {
        representation = .https;
        source = source["git+https://".len..];
    } else if (startsWithIgnoreCase(source, "git+http://")) {
        representation = .http;
        source = source["git+http://".len..];
    } else if (startsWithIgnoreCase(source, "ssh://")) {
        representation = .sshurl;
        source = source["ssh://".len..];
    } else if (startsWithIgnoreCase(source, "https://")) {
        representation = .https;
        source = source["https://".len..];
    } else if (startsWithIgnoreCase(source, "http://")) {
        representation = .http;
        source = source["http://".len..];
    } else if (startsWithIgnoreCase(source, "git://")) {
        representation = .git;
        source = source["git://".len..];
    } else {
        return parseScpLocation(source, split.fragment);
    }

    const query = std.mem.indexOfScalar(u8, source, '?');
    if (query) |index| source = source[0..index];

    const slash = std.mem.indexOfScalar(u8, source, '/');
    const colon = hostPathColon(source, slash);
    const authority_end = minOptional(slash, colon) orelse return null;
    const authority = source[0..authority_end];
    var path = source[authority_end + 1 ..];
    if (path.len == 0) return null;

    const host_with_port = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at|
        authority[at + 1 ..]
    else
        authority;
    const host = stripPort(host_with_port);
    if (host.len == 0) return null;
    path = std.mem.trim(u8, path, "/");

    return .{
        .host = host,
        .path = path,
        .fragment = split.fragment,
        .representation = representation,
    };
}

fn parseScpLocation(source: []const u8, fragment: ?[]const u8) ?Location {
    const at = std.mem.lastIndexOfScalar(u8, source, '@');
    const colon = std.mem.indexOfScalarPos(u8, source, if (at) |index| index + 1 else 0, ':') orelse
        return null;
    if (colon + 1 >= source.len) return null;
    const authority = source[0..colon];
    if (std.mem.indexOfScalar(u8, authority, '/') != null) return null;
    const host = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |authority_at|
        authority[authority_at + 1 ..]
    else
        authority;
    if (host.len == 0) return null;
    return .{
        .host = host,
        .path = std.mem.trim(u8, source[colon + 1 ..], "/"),
        .fragment = fragment,
        .representation = .sshurl,
    };
}

fn build(
    allocator: std.mem.Allocator,
    provider: HostProvider,
    raw_path: []const u8,
    raw_fragment: ?[]const u8,
    representation: Representation,
) error{ OutOfMemory, InvalidURL }!?HostedGitInfo {
    var path = std.mem.trim(u8, raw_path, "/");
    if (path.len == 0) return null;

    var raw_user: ?[]const u8 = null;
    var raw_project: []const u8 = undefined;
    var committish = raw_fragment;

    switch (provider) {
        .github => {
            var parts = std.mem.splitScalar(u8, path, '/');
            raw_user = parts.next() orelse return null;
            raw_project = parts.next() orelse return null;
            if (parts.next()) |kind| {
                if (!std.mem.eql(u8, kind, "tree")) return null;
                committish = parts.next() orelse return null;
                if (parts.next() != null) return null;
            }
        },
        .bitbucket => {
            var parts = std.mem.splitScalar(u8, path, '/');
            raw_user = parts.next() orelse return null;
            raw_project = parts.next() orelse return null;
            if (parts.next()) |kind| {
                if (std.mem.eql(u8, kind, "get")) return null;
            }
        },
        .gitlab => {
            if (std.mem.indexOf(u8, path, "/-/") != null or
                std.mem.indexOf(u8, path, "/archive.tar.gz") != null) return null;
            const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
            raw_user = path[0..slash];
            raw_project = path[slash + 1 ..];
        },
        .gist => {
            var parts = std.mem.splitScalar(u8, path, '/');
            const first = parts.next() orelse return null;
            if (parts.next()) |second| {
                raw_user = first;
                raw_project = second;
                if (parts.next()) |kind| {
                    if (std.mem.eql(u8, kind, "raw")) return null;
                }
            } else {
                raw_project = first;
            }
        },
        .sourcehut => {
            var parts = std.mem.splitScalar(u8, path, '/');
            raw_user = parts.next() orelse return null;
            raw_project = parts.next() orelse return null;
            if (parts.next()) |kind| {
                if (std.mem.eql(u8, kind, "archive")) return null;
            }
        },
    }

    raw_project = trimGitSuffix(raw_project);
    if (raw_project.len == 0 or (raw_user != null and raw_user.?.len == 0)) return null;

    const user = if (raw_user) |value| try percentDecode(allocator, value) else null;
    errdefer if (user) |value| allocator.free(value);
    const project = try percentDecode(allocator, raw_project);
    errdefer allocator.free(project);
    const decoded_committish = if (committish) |value|
        if (value.len > 0) try percentDecode(allocator, value) else null
    else
        null;
    errdefer if (decoded_committish) |value| allocator.free(value);

    return .{
        .committish = decoded_committish,
        .project = project,
        .user = user,
        .host_provider = provider,
        .default_representation = representation,
        .allocator = allocator,
        .owned_user = user,
        .owned_project = project,
        .owned_committish = decoded_committish,
    };
}

fn splitFragment(input: []const u8) struct { value: []const u8, fragment: ?[]const u8 } {
    const hash = std.mem.indexOfScalar(u8, input, '#') orelse
        return .{ .value = input, .fragment = null };
    return .{
        .value = input[0..hash],
        .fragment = if (hash + 1 < input.len) input[hash + 1 ..] else null,
    };
}

fn hostPathColon(source: []const u8, slash: ?usize) ?usize {
    const authority_end = slash orelse source.len;
    const at = std.mem.lastIndexOfScalar(u8, source[0..authority_end], '@');
    const host_start = if (at) |index| index + 1 else 0;
    const colon = std.mem.indexOfScalarPos(u8, source, host_start, ':') orelse return null;
    if (colon >= authority_end) return null;

    const suffix = source[colon + 1 .. authority_end];
    if (suffix.len > 0 and allDigits(suffix) and slash != null) return null;
    return colon;
}

fn stripPort(authority: []const u8) []const u8 {
    if (authority.len > 0 and authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return authority;
        return authority[0 .. close + 1];
    }
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse return authority;
    if (allDigits(authority[colon + 1 ..])) return authority[0..colon];
    return authority;
}

fn minOptional(left: ?usize, right: ?usize) ?usize {
    if (left) |lhs| {
        if (right) |rhs| return @min(lhs, rhs);
        return lhs;
    }
    return right;
}

fn trimGitSuffix(value: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, value, ".git"))
        value[0 .. value.len - ".git".len]
    else
        value;
}

fn percentDecode(allocator: std.mem.Allocator, input: []const u8) error{ OutOfMemory, InvalidURL }![]u8 {
    var decoded_len: usize = 0;
    var read: usize = 0;
    while (read < input.len) {
        if (input[read] == '%') {
            if (read + 2 >= input.len) return error.InvalidURL;
            _ = std.fmt.charToDigit(input[read + 1], 16) catch return error.InvalidURL;
            _ = std.fmt.charToDigit(input[read + 2], 16) catch return error.InvalidURL;
            read += 3;
        } else {
            read += 1;
        }
        decoded_len += 1;
    }

    const output = try allocator.alloc(u8, decoded_len);
    read = 0;
    var write: usize = 0;
    while (read < input.len) {
        if (input[read] == '%') {
            const high = std.fmt.charToDigit(input[read + 1], 16) catch unreachable;
            const low = std.fmt.charToDigit(input[read + 2], 16) catch unreachable;
            output[write] = @intCast(high * 16 + low);
            read += 3;
        } else {
            output[write] = input[read];
            read += 1;
        }
        write += 1;
    }
    return output;
}

fn allDigits(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn eqlIgnoreCase(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and eqlIgnoreCase(value[0..prefix.len], prefix);
}

test "hosted Git shortcuts and transports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const bitbucket = (try HostedGitInfo.fromUrl(allocator, "bitbucket:foo/bar.git#branch")).?;
    try std.testing.expectEqual(HostProvider.bitbucket, bitbucket.host_provider);
    try std.testing.expectEqual(Representation.shortcut, bitbucket.default_representation);
    try std.testing.expectEqualStrings("foo", bitbucket.user.?);
    try std.testing.expectEqualStrings("bar", bitbucket.project);
    try std.testing.expectEqualStrings("branch", bitbucket.committish.?);

    const gitlab = (try HostedGitInfo.fromUrl(
        allocator,
        "git+ssh://git@gitlab.com/group/subgroup/project.git#abcdef0",
    )).?;
    try std.testing.expectEqualStrings("group/subgroup", gitlab.user.?);
    try std.testing.expectEqualStrings("project", gitlab.project);

    const gist = (try HostedGitInfo.fromUrl(allocator, "https://gist.github.com/feedbeef.git")).?;
    try std.testing.expectEqual(HostProvider.gist, gist.host_provider);
    try std.testing.expectEqual(@as(?[]const u8, null), gist.user);
    try std.testing.expectEqualStrings("feedbeef", gist.project);

    const sourcehut = (try HostedGitInfo.fromUrl(allocator, "sourcehut:~foo/bar")).?;
    try std.testing.expectEqualStrings("~foo", sourcehut.user.?);

    const authenticated = (try HostedGitInfo.fromUrl(
        allocator,
        ":password@bitbucket.org:foo/bar#lk/br@nch.t#st",
    )).?;
    try std.testing.expectEqual(Representation.sshurl, authenticated.default_representation);
    try std.testing.expectEqualStrings("lk/br@nch.t#st", authenticated.committish.?);
}

test "hosted Git decodes path and branch components" {
    var info = (try HostedGitInfo.fromUrl(
        std.testing.allocator,
        "https://github.com/foo%20bar/project/tree/feature%2Fone",
    )).?;
    defer info.deinit();
    try std.testing.expectEqualStrings("foo bar", info.user.?);
    try std.testing.expectEqualStrings("project", info.project);
    try std.testing.expectEqualStrings("feature/one", info.committish.?);
}
