// Hutch's lockfile. The format began as Bun's text lockfile and is now
// owned by Hutch; it may deviate without tracking upstream.
pub const file_name = "hutch.lock";

pub const lifecycle_script_names = [_][]const u8{
    "preinstall",
    "install",
    "postinstall",
    "preprepare",
    "prepare",
    "postprepare",
};


const std = @import("std");
const PackageName = @import("support/util/package_name.zig");
const Semver = @import("support/semver/root.zig");

const Value = std.json.Value;

pub const Kind = enum {
    npm,
    folder,
    symlink,
    workspace,
    local_tarball,
    remote_tarball,
    git,
    github,
    root,
};

pub const Provenance = enum {
    bun_text,
    npm,
    yarn,
    pnpm,
};

pub const ConfigVersion = enum(u32) {
    v0 = 0,
    v1 = 1,

    pub const current: ConfigVersion = .v1;

    fn parse(value: Value) !ConfigVersion {
        if (value != .integer or value.integer < 0) return error.InvalidConfigVersion;
        if (value.integer == 0) return .v0;
        return .v1;
    }
};

pub const Package = struct {
    key: []const u8,
    name: []const u8,
    resolution: []const u8,
    version: []const u8 = "",
    source: []const u8 = "",
    git_resolved: []const u8 = "",
    integrity: []const u8 = "",
    info: ?*const Value = null,
    kind: Kind,

    pub fn dependencySection(package: *const Package, section: []const u8) ?*const Value {
        const info = package.info orelse return null;
        if (info.* != .object) return null;
        const value = info.object.getPtr(section) orelse return null;
        return if (value.* == .object) value else null;
    }
};

pub const Graph = struct {
    document: Value,
    version: u32,
    config_version: ?ConfigVersion,
    provenance: Provenance,
    root_workspace: *const Value,
    workspaces: std.StringHashMap(*const Value),
    packages: std.StringHashMap(Package),
    package_json_changed: bool = false,
    // Set when at least one package entry was dropped because its integrity
    // digest could not be parsed; such packages must be re-resolved.
    dropped_invalid_integrity: bool = false,

    pub fn deinit(graph: *Graph) void {
        graph.workspaces.deinit();
        graph.packages.deinit();
    }

    pub fn get(graph: *const Graph, key: []const u8) ?*const Package {
        return graph.packages.getPtr(key);
    }

    pub fn rootMatchesPackageJSON(graph: *const Graph, package_json: *const Value) bool {
        return workspaceValueMatches(graph.root_workspace, package_json, false);
    }

    pub fn workspaceMatchesPackageJSON(graph: *const Graph, path: []const u8, package_json: *const Value) bool {
        const workspace = graph.workspaces.get(path) orelse return false;
        return workspaceValueMatches(workspace, package_json, true);
    }

    pub fn rootDependencySpec(graph: *const Graph, name: []const u8) ?[]const u8 {
        return workspaceDependencySpecValue(graph.root_workspace, name);
    }

    pub fn workspaceDependencySpec(graph: *const Graph, path: []const u8, name: []const u8) ?[]const u8 {
        const workspace = graph.workspaces.get(path) orelse return null;
        return workspaceDependencySpecValue(workspace, name);
    }

    fn workspaceDependencySpecValue(workspace: *const Value, name: []const u8) ?[]const u8 {
        for (dependency_sections) |section_name| {
            const section = workspace.object.get(section_name) orelse continue;
            if (section != .object) continue;
            const value = section.object.get(name) orelse continue;
            if (value == .string) return value.string;
        }
        return null;
    }

    pub fn migrated(graph: *const Graph) bool {
        return graph.provenance != .bun_text;
    }
};

const dependency_sections = [_][]const u8{
    "dependencies",
    "devDependencies",
    "optionalDependencies",
    "peerDependencies",
};

/// Dependency aliases become path components below node_modules. Keep this
/// deliberately narrower than npm's presentation-level name parser: neither
/// platform separator nor either dot component is ever a valid install edge.
pub fn packageNameIsSafe(name: []const u8) bool {
    if (!PackageName.isNPMPackageName(name) or std.fs.path.isAbsolute(name)) return false;
    if (name[0] == '@') {
        const slash = std.mem.indexOfScalar(u8, name, '/') orelse return false;
        if (slash <= 1 or slash + 1 >= name.len) return false;
        if (std.mem.indexOfAnyPos(u8, name, slash + 1, "/\\") != null) return false;
        return packageNameComponentIsSafe(name[1..slash]) and
            packageNameComponentIsSafe(name[slash + 1 ..]);
    }
    return std.mem.indexOfAny(u8, name, "/\\") == null and packageNameComponentIsSafe(name);
}

fn packageNameComponentIsSafe(component: []const u8) bool {
    if (component.len == 0 or
        std.mem.eql(u8, component, ".") or
        std.mem.eql(u8, component, "..")) return false;
    for (component) |byte| {
        if (byte == 0 or byte < ' ' or byte == 0x7f) return false;
    }
    return true;
}

/// Lock keys are logical node_modules chains (for example
/// `parent/@scope/child`). Validate every package component before any caller
/// turns the key back into a filesystem destination.
pub fn packageKeyIsSafe(key: []const u8) bool {
    if (key.len == 0 or std.fs.path.isAbsolute(key) or std.mem.indexOfScalar(u8, key, '\\') != null) return false;
    var components = std.mem.splitScalar(u8, key, '/');
    while (components.next()) |component| {
        if (component.len == 0) return false;
        if (component[0] == '@') {
            const package = components.next() orelse return false;
            var scoped_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const scoped = std.fmt.bufPrint(&scoped_buffer, "{s}/{s}", .{ component, package }) catch return false;
            if (!packageNameIsSafe(scoped)) return false;
        } else if (!packageNameIsSafe(component)) {
            return false;
        }
    }
    return true;
}

pub fn validateDependencyAliases(value: *const Value) !void {
    if (value.* != .object) return;
    for (dependency_sections) |section_name| {
        const section = value.object.get(section_name) orelse continue;
        if (section != .object) continue;
        for (section.object.keys()) |alias| {
            if (!packageNameIsSafe(alias)) return error.InvalidDependencyAlias;
        }
    }
}

pub fn parseText(allocator: std.mem.Allocator, source: []const u8) !Graph {
    const json = try normalizeJsonc(allocator, source);
    var document = std.json.parseFromSliceLeaky(Value, allocator, json, .{}) catch return error.InvalidTextLockfile;
    if (document != .object) return error.InvalidTextLockfile;

    const version_value = document.object.get("lockfileVersion") orelse return error.MissingLockfileVersion;
    const version: u32 = switch (version_value) {
        .integer => |number| if (number >= 0 and number <= 1) @intCast(number) else return error.UnsupportedLockfileVersion,
        else => return error.InvalidLockfileVersion,
    };
    const config_version = if (document.object.get("configVersion")) |value|
        try ConfigVersion.parse(value)
    else
        null;

    const workspaces_value = document.object.getPtr("workspaces") orelse return error.MissingWorkspacesObject;
    if (workspaces_value.* != .object) return error.InvalidWorkspacesObject;
    const root_workspace = workspaces_value.object.getPtr("") orelse return error.MissingRootWorkspace;
    if (root_workspace.* != .object) return error.InvalidRootWorkspace;
    try validateDependencyAliases(root_workspace);

    var graph = Graph{
        .document = document,
        .version = version,
        .config_version = config_version,
        .provenance = .bun_text,
        .root_workspace = root_workspace,
        .workspaces = std.StringHashMap(*const Value).init(allocator),
        .packages = std.StringHashMap(Package).init(allocator),
    };
    errdefer graph.deinit();

    for (workspaces_value.object.keys(), workspaces_value.object.values()) |path, *workspace| {
        if (workspace.* != .object) return error.InvalidWorkspace;
        try validateDependencyAliases(workspace);
        try graph.workspaces.put(path, workspace);
    }

    if (document.object.getPtr("packages")) |packages_value| {
        if (packages_value.* != .object) return error.InvalidPackagesObject;
        for (packages_value.object.keys(), packages_value.object.values()) |key, *entry| {
            if (!packageKeyIsSafe(key)) return error.InvalidPackageKey;
            const package = try parsePackageEntry(key, entry);
            if ((package.kind == .root and package.name.len != 0) or
                (package.kind != .root and !packageNameIsSafe(package.name))) return error.InvalidPackageName;
            if (package.kind == .npm and !Semver.Version.parseUTF8(package.version).valid) {
                return error.InvalidPackageVersion;
            }
            if (package.info) |info| try validateDependencyAliases(info);
            // Bun validates lockfile integrity digests strictly; a package
            // whose integrity cannot be parsed is re-resolved from scratch.
            if (integrityIsMalformed(package.integrity)) {
                graph.dropped_invalid_integrity = true;
                continue;
            }
            try graph.packages.put(key, package);
        }
    }

    return graph;
}

fn integrityIsMalformed(integrity: []const u8) bool {
    if (integrity.len == 0) return false;
    var supported_token_count: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, integrity, " \t\r\n");
    while (tokens.next()) |token| {
        const dash = std.mem.indexOfScalar(u8, token, '-') orelse return true;
        const digest_len: ?usize = if (std.mem.eql(u8, token[0..dash], "sha1"))
            20
        else if (std.mem.eql(u8, token[0..dash], "sha256"))
            32
        else if (std.mem.eql(u8, token[0..dash], "sha384"))
            48
        else if (std.mem.eql(u8, token[0..dash], "sha512"))
            64
        else
            null;
        const supported_digest_len = digest_len orelse continue;
        supported_token_count += 1;
        const encoded = token[dash + 1 ..];
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return true;
        if (decoded_len != supported_digest_len) return true;
        var decoded: [64]u8 = undefined;
        std.base64.standard.Decoder.decode(decoded[0..supported_digest_len], encoded) catch return true;
    }
    return supported_token_count == 0;
}

test "integrity metadata ignores unsupported algorithms but validates supported digests" {
    const valid = "sha512-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==";
    try std.testing.expect(!integrityIsMalformed(valid));
    try std.testing.expect(!integrityIsMalformed("md5-ignored sha512-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="));
    try std.testing.expect(integrityIsMalformed("md5-ignored"));
    try std.testing.expect(integrityIsMalformed("md5-ignored sha512-not-base64"));
}

fn parsePackageEntry(key: []const u8, entry: *const Value) !Package {
    if (entry.* != .array or entry.array.items.len == 0) return error.InvalidPackageInfo;
    const resolution_value = &entry.array.items[0];
    if (resolution_value.* != .string) return error.InvalidPackageResolution;
    const split = try splitNameAndResolution(resolution_value.string);
    const kind = resolutionKind(split.resolution);

    var package = Package{
        .key = key,
        .name = split.name,
        .resolution = split.resolution,
        .kind = kind,
    };

    switch (kind) {
        .npm => {
            if (entry.array.items.len < 2 or entry.array.items[1] != .string) return error.MissingNpmRegistry;
            package.version = split.resolution;
            package.source = entry.array.items[1].string;
            package.info = objectAt(entry, 2);
            package.integrity = stringAt(entry, 3) orelse "";
        },
        .folder, .symlink => {
            package.source = split.resolution[std.mem.indexOfScalar(u8, split.resolution, ':').? + 1 ..];
            package.info = objectAt(entry, 1);
        },
        .workspace => {
            package.source = split.resolution["workspace:".len..];
            package.info = objectAt(entry, 1);
        },
        .local_tarball, .remote_tarball => {
            package.source = split.resolution;
            package.info = objectAt(entry, 1);
            package.integrity = stringAt(entry, 2) orelse "";
        },
        .git, .github => {
            package.source = split.resolution;
            package.info = objectAt(entry, 1);
            package.git_resolved = stringAt(entry, 2) orelse "";
            package.integrity = stringAt(entry, 3) orelse "";
        },
        .root => {
            package.info = objectAt(entry, 1);
        },
    }
    return package;
}

fn objectAt(entry: *const Value, index: usize) ?*const Value {
    if (index >= entry.array.items.len) return null;
    const value = &entry.array.items[index];
    return if (value.* == .object) value else null;
}

fn stringAt(entry: *const Value, index: usize) ?[]const u8 {
    if (index >= entry.array.items.len) return null;
    const value = entry.array.items[index];
    return if (value == .string) value.string else null;
}

fn splitNameAndResolution(input: []const u8) !struct { name: []const u8, resolution: []const u8 } {
    if (std.mem.eql(u8, input, "@root:")) return .{ .name = "", .resolution = "root:" };

    const separator = if (std.mem.startsWith(u8, input, "@")) blk: {
        const slash = std.mem.indexOfScalar(u8, input, '/') orelse return error.InvalidPackageResolution;
        break :blk std.mem.indexOfScalarPos(u8, input, slash + 1, '@') orelse return error.InvalidPackageResolution;
    } else std.mem.indexOfScalar(u8, input, '@') orelse return error.InvalidPackageResolution;

    if (separator == 0 or separator + 1 >= input.len) return error.InvalidPackageResolution;
    return .{ .name = input[0..separator], .resolution = input[separator + 1 ..] };
}

fn resolutionKind(resolution: []const u8) Kind {
    if (std.mem.eql(u8, resolution, "root:")) return .root;
    if (std.mem.startsWith(u8, resolution, "workspace:")) return .workspace;
    if (std.mem.startsWith(u8, resolution, "link:")) return .symlink;
    if (std.mem.startsWith(u8, resolution, "file:")) return .folder;
    if (std.mem.startsWith(u8, resolution, "github:")) return .github;
    if (std.mem.startsWith(u8, resolution, "git+") or
        std.mem.startsWith(u8, resolution, "git://") or
        std.mem.startsWith(u8, resolution, "ssh://") or
        std.mem.startsWith(u8, resolution, "git@") or
        isScpLikeGitResolution(resolution)) return .git;
    if (std.mem.startsWith(u8, resolution, "http://") or std.mem.startsWith(u8, resolution, "https://")) return .remote_tarball;
    if (isTarballPath(resolution)) return .local_tarball;
    return .npm;
}

fn isTarballPath(path: []const u8) bool {
    const without_fragment = if (std.mem.indexOfScalar(u8, path, '#')) |index| path[0..index] else path;
    const without_query = if (std.mem.indexOfScalar(u8, without_fragment, '?')) |index| without_fragment[0..index] else without_fragment;
    return std.mem.endsWith(u8, without_query, ".tgz") or std.mem.endsWith(u8, without_query, ".tar.gz");
}

fn isScpLikeGitResolution(resolution: []const u8) bool {
    const source = if (std.mem.indexOfScalar(u8, resolution, '#')) |hash| resolution[0..hash] else resolution;
    const colon = std.mem.indexOfScalar(u8, source, ':') orelse return false;
    if (colon == 0 or colon + 1 >= source.len or std.mem.indexOfScalar(u8, source[0..colon], '/') != null) return false;
    return std.mem.indexOfScalar(u8, source[0..colon], '@') != null and
        std.mem.indexOfScalar(u8, source[colon + 1 ..], '/') != null;
}

fn optionalLockStringMatchesManifest(left: *const Value, right: *const Value, key: []const u8) bool {
    const left_value = left.object.get(key);
    if (left_value == null or left_value.? != .string) return true;
    const right_value = right.object.get(key);
    return right_value != null and right_value.? == .string and std.mem.eql(u8, left_value.?.string, right_value.?.string);
}

fn workspaceValueMatches(workspace: *const Value, package_json: *const Value, compare_name: bool) bool {
    if (package_json.* != .object or workspace.* != .object) return false;
    if (compare_name and !optionalLockStringMatchesManifest(workspace, package_json, "name")) return false;
    for (dependency_sections) |section| {
        if (!stringObjectEqual(workspace, package_json, section)) return false;
    }
    return true;
}

fn stringObjectEqual(left: *const Value, right: *const Value, key: []const u8) bool {
    const left_value = left.object.get(key);
    const right_value = right.object.get(key);
    const left_count = if (left_value != null and left_value.? == .object) left_value.?.object.count() else 0;
    const right_count = if (right_value != null and right_value.? == .object) right_value.?.object.count() else 0;
    if (left_count != right_count) return false;
    if (left_count == 0) return true;
    if (left_value == null or left_value.? != .object or right_value == null or right_value.? != .object) return false;

    for (left_value.?.object.keys(), left_value.?.object.values()) |name, expected| {
        if (expected != .string) return false;
        const actual = right_value.?.object.get(name) orelse return false;
        if (actual != .string or !std.mem.eql(u8, expected.string, actual.string)) return false;
    }
    return true;
}

pub fn normalizeJsonc(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var without_comments = std.array_list.Managed(u8).init(allocator);
    try without_comments.ensureTotalCapacity(source.len);

    const State = enum { normal, string, line_comment, block_comment };
    var state: State = .normal;
    var escaped = false;
    var index: usize = 0;
    while (index < source.len) : (index += 1) {
        const byte = source[index];
        switch (state) {
            .normal => {
                if (byte == '"') {
                    state = .string;
                    try without_comments.append(byte);
                } else if (byte == '/' and index + 1 < source.len and source[index + 1] == '/') {
                    state = .line_comment;
                    try without_comments.appendSlice("  ");
                    index += 1;
                } else if (byte == '/' and index + 1 < source.len and source[index + 1] == '*') {
                    state = .block_comment;
                    try without_comments.appendSlice("  ");
                    index += 1;
                } else {
                    try without_comments.append(byte);
                }
            },
            .string => {
                try without_comments.append(byte);
                if (escaped) {
                    escaped = false;
                } else if (byte == '\\') {
                    escaped = true;
                } else if (byte == '"') {
                    state = .normal;
                }
            },
            .line_comment => {
                if (byte == '\n' or byte == '\r') {
                    state = .normal;
                    try without_comments.append(byte);
                } else {
                    try without_comments.append(' ');
                }
            },
            .block_comment => {
                if (byte == '*' and index + 1 < source.len and source[index + 1] == '/') {
                    state = .normal;
                    try without_comments.appendSlice("  ");
                    index += 1;
                } else {
                    try without_comments.append(if (byte == '\n' or byte == '\r') byte else ' ');
                }
            },
        }
    }
    if (state == .string or state == .block_comment) return error.InvalidTextLockfile;

    const normalized = without_comments.items;
    state = .normal;
    escaped = false;
    index = 0;
    while (index < normalized.len) : (index += 1) {
        const byte = normalized[index];
        if (state == .string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                state = .normal;
            }
            continue;
        }
        if (byte == '"') {
            state = .string;
            continue;
        }
        if (byte != ',') continue;
        var next = index + 1;
        while (next < normalized.len and std.ascii.isWhitespace(normalized[next])) : (next += 1) {}
        if (next < normalized.len and (normalized[next] == '}' or normalized[next] == ']')) normalized[index] = ' ';
    }
    return normalized;
}

test "parse Bun text lockfile graph and package metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = try parseText(allocator,
        \\{
        \\  // Bun text lockfiles are JSONC.
        \\  "lockfileVersion": 1,
        \\  "workspaces": {
        \\    "": { "name": "app", "dependencies": { "foo": "^1.0.0" }, },
        \\  },
        \\  "packages": {
        \\    "foo": ["foo@1.2.3", "", { "dependencies": { "bar": "2.0.0" } }, "sha512-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="],
        \\    "foo/bar": ["bar@2.0.0", "https://registry.example/bar.tgz", {}, "sha512-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="],
        \\  },
        \\}
    );
    defer graph.deinit();

    try std.testing.expectEqual(@as(u32, 1), graph.version);
    const foo = graph.get("foo").?;
    try std.testing.expectEqual(Kind.npm, foo.kind);
    try std.testing.expectEqualStrings("1.2.3", foo.version);
    try std.testing.expectEqualStrings("2.0.0", foo.dependencySection("dependencies").?.object.get("bar").?.string);
    try std.testing.expectEqualStrings("https://registry.example/bar.tgz", graph.get("foo/bar").?.source);
}

test "frozen root comparison is order independent and exact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = try parseText(allocator,
        \\{"lockfileVersion":1,"workspaces":{"":{"name":"app","dependencies":{"a":"^1","b":"2"}}},"packages":{}}
    );
    defer graph.deinit();

    const matching = try std.json.parseFromSliceLeaky(Value, allocator,
        \\{"dependencies":{"b":"2","a":"^1"},"name":"app"}
    , .{});
    const changed = try std.json.parseFromSliceLeaky(Value, allocator,
        \\{"name":"app","dependencies":{"a":"^2","b":"2"}}
    , .{});
    const renamed = try std.json.parseFromSliceLeaky(Value, allocator,
        \\{"name":"renamed-app","dependencies":{"a":"^1","b":"2"}}
    , .{});
    var graph_without_locked_name = try parseText(allocator,
        \\{"lockfileVersion":1,"workspaces":{"":{"dependencies":{"a":"^1","b":"2"}}},"packages":{}}
    );
    defer graph_without_locked_name.deinit();
    try std.testing.expect(graph.rootMatchesPackageJSON(&matching));
    try std.testing.expect(graph.rootMatchesPackageJSON(&renamed));
    try std.testing.expect(!graph.rootMatchesPackageJSON(&changed));
    try std.testing.expect(graph_without_locked_name.rootMatchesPackageJSON(&matching));
}

test "parse scoped and non-registry resolutions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = try parseText(allocator,
        \\{"lockfileVersion":1,"workspaces":{"":{}},"packages":{
        \\  "@scope/pkg":["@scope/pkg@workspace:packages/pkg"],
        \\  "linked":["linked@link:../linked",{}],
        \\  "archive":["archive@./archive.tgz",{},"sha512-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="],
        \\  "ssh-git":["ssh-git@ssh://git@example.com/owner/repo.git#abcdef012345",{},"abcdef012345"],
        \\  "scp-git":["scp-git@git@example.com:owner/repo.git#abcdef012345",{},"abcdef012345"]
        \\}}
    );
    defer graph.deinit();

    try std.testing.expectEqual(Kind.workspace, graph.get("@scope/pkg").?.kind);
    try std.testing.expectEqualStrings("packages/pkg", graph.get("@scope/pkg").?.source);
    try std.testing.expectEqual(Kind.symlink, graph.get("linked").?.kind);
    try std.testing.expectEqual(Kind.local_tarball, graph.get("archive").?.kind);
    try std.testing.expectEqual(Kind.git, graph.get("ssh-git").?.kind);
    try std.testing.expectEqual(Kind.git, graph.get("scp-git").?.kind);
}

test "frozen workspace comparison covers workspace dependency graphs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = try parseText(allocator,
        \\{"lockfileVersion":1,"workspaces":{
        \\  "": {"name":"app"},
        \\  "packages/api":{"name":"@app/api","dependencies":{"foo":"1.0.0"}}
        \\},"packages":{}}
    );
    defer graph.deinit();

    const matching = try std.json.parseFromSliceLeaky(Value, allocator,
        \\{"dependencies":{"foo":"1.0.0"},"name":"@app/api"}
    , .{});
    const changed = try std.json.parseFromSliceLeaky(Value, allocator,
        \\{"name":"@app/api","dependencies":{"foo":"2.0.0"}}
    , .{});
    try std.testing.expect(graph.workspaceMatchesPackageJSON("packages/api", &matching));
    try std.testing.expect(!graph.workspaceMatchesPackageJSON("packages/api", &changed));
}

test "package aliases and logical lock keys cannot escape node_modules" {
    try std.testing.expect(packageNameIsSafe("plain"));
    try std.testing.expect(packageNameIsSafe("@scope/pkg"));
    try std.testing.expect(packageKeyIsSafe("parent/@scope/pkg/child"));
    try std.testing.expect(!packageNameIsSafe("../outside"));
    try std.testing.expect(!packageNameIsSafe("@scope/.."));
    try std.testing.expect(!packageNameIsSafe("scope\\outside"));
    try std.testing.expect(!packageNameIsSafe("has space"));
    try std.testing.expect(!packageNameIsSafe("has:colon"));
    try std.testing.expect(!packageNameIsSafe("a" ** 215));
    try std.testing.expect(!packageKeyIsSafe("parent/../../outside"));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.InvalidDependencyAlias,
        parseText(arena.allocator(),
            \\{"lockfileVersion":1,"workspaces":{"":{}},"packages":{
            \\  "safe":["safe@1.0.0","",{"dependencies":{"@scope/..":"1"}},""],
            \\}}
        ),
    );
    try std.testing.expectError(
        error.InvalidPackageKey,
        parseText(arena.allocator(),
            \\{"lockfileVersion":1,"workspaces":{"":{}},"packages":{
            \\  "../../outside":["outside@1.0.0","",{},""],
            \\}}
        ),
    );
    try std.testing.expectError(
        error.InvalidPackageVersion,
        parseText(arena.allocator(),
            \\{"lockfileVersion":1,"workspaces":{"":{}},"packages":{
            \\  "safe":["safe@../../outside","",{},""],
            \\}}
        ),
    );
    try std.testing.expectError(
        error.InvalidPackageName,
        parseText(arena.allocator(),
            \\{"lockfileVersion":1,"workspaces":{"":{}},"packages":{
            \\  "safe":["@scope/..@root:",{}],
            \\}}
        ),
    );
}
