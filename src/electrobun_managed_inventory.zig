const std = @import("std");
const Allocator = std.mem.Allocator;

pub const File = struct {
    filename: []const u8,
    target: []const u8,
    path: []const u8,
    size: u64,
    sha256: []const u8,
};

pub const Release = struct {
    id: []const u8,
    channel: []const u8,
    version: []const u8,
    identifier: []const u8,
    targets: []const []const u8,
    files: []const File,
};

const channels = [_][]const u8{ "canary", "stable" };
const supported_targets = [_][]const u8{ "linux-arm64", "linux-x64", "macos-arm64", "macos-x64", "win-arm64", "win-x64" };
const max_manifest_bytes = 64 * 1024;
const max_safe_integer = 9_007_199_254_740_991;

const ManifestName = struct { channel: []const u8, target: []const u8, v2: bool };
const Manifest = struct { name: ManifestName, version: []const u8, identifier: []const u8, hash: []const u8, archive: []const u8, tar_sha256: ?[]const u8, tar_size: ?i64 };

/// Plans every release before an upload starts. Allocations, including returned
/// strings, belong to allocator; command callers normally supply their arena.
pub fn inventory(
    io: std.Io,
    allocator: Allocator,
    folder: []const u8,
    selected_channel: ?[]const u8,
    explicit_release_id: ?[]const u8,
    expected_targets: ?[]const []const u8,
) ![]const Release {
    if (selected_channel) |channel| {
        if (!contains(&channels, channel)) return error.InvalidManagedReleaseChannel;
    }
    if (explicit_release_id) |id| try validateReleaseId(id);
    if (expected_targets) |targets| {
        for (targets) |target| if (!contains(&supported_targets, target)) return error.InvalidManagedReleaseTarget;
    }
    const absolute_folder = try std.Io.Dir.cwd().realPathFileAlloc(io, folder, allocator);
    var directory = try std.Io.Dir.cwd().openDir(io, absolute_folder, .{ .iterate = true });
    defer directory.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| try names.append(allocator, try allocator.dupe(u8, entry.name));
    std.mem.sort([]const u8, names.items, {}, stringLessThan);

    var found_channels: [2]bool = .{ false, false };
    for (names.items) |filename| {
        const name = parseManifestName(filename) orelse continue;
        for (channels, 0..) |channel, i| {
            if (std.mem.eql(u8, channel, name.channel) and (selected_channel == null or std.mem.eql(u8, channel, selected_channel.?))) found_channels[i] = true;
        }
    }
    const count: usize = @intFromBool(found_channels[0]) + @as(usize, @intFromBool(found_channels[1]));
    if (count == 0) return error.NoManagedReleaseManifests;
    if (count > 1 and explicit_release_id != null) return error.MixedManagedReleaseChannelsRequireSeparateIds;
    var releases: std.ArrayList(Release) = .empty;
    for (channels, found_channels) |channel, found| {
        if (found) try releases.append(allocator, try inventoryChannel(io, allocator, directory, absolute_folder, names.items, channel, explicit_release_id, expected_targets));
    }
    return releases.toOwnedSlice(allocator);
}

fn inventoryChannel(io: std.Io, allocator: Allocator, directory: std.Io.Dir, folder: []const u8, names: []const []const u8, channel: []const u8, explicit_id: ?[]const u8, expected_targets: ?[]const []const u8) !Release {
    var manifests: [supported_targets.len]?Manifest = @splat(null);
    var version: ?[]const u8 = null;
    var identifier: ?[]const u8 = null;
    for (names) |filename| {
        const name = parseManifestName(filename) orelse continue;
        if (!std.mem.eql(u8, name.channel, channel)) continue;
        const manifest = try readManifest(io, allocator, directory, filename, name);
        if (version) |existing| {
            if (!std.mem.eql(u8, existing, manifest.version) or !std.mem.eql(u8, identifier.?, manifest.identifier)) return error.ManagedReleaseIdentityMismatch;
        } else {
            version = manifest.version;
            identifier = manifest.identifier;
        }
        const index = targetIndex(name.target).?;
        if (manifests[index]) |existing| {
            if (!std.mem.eql(u8, existing.hash, manifest.hash) or !std.mem.eql(u8, existing.archive, manifest.archive)) return error.ManagedUpdateManifestsDisagree;
            if (existing.tar_sha256 != null and manifest.tar_sha256 != null and
                (!std.mem.eql(u8, existing.tar_sha256.?, manifest.tar_sha256.?) or existing.tar_size.? != manifest.tar_size.?)) return error.ManagedUpdateManifestsDisagree;
        }
        manifests[index] = manifest;
    }
    var targets: std.ArrayList([]const u8) = .empty;
    for (manifests) |maybe_manifest| {
        const manifest = maybe_manifest orelse continue;
        if (!contains(names, manifest.archive)) return error.MissingManagedReleaseArchive;
        if (expected_targets) |expected| {
            if (!contains(expected, manifest.name.target)) return error.ManagedTargetExcludedFromExpectedTargets;
        }
        try targets.append(allocator, manifest.name.target);
    }
    if (targets.items.len == 0) return error.NoManagedReleaseManifests;
    const id = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ channel, version.? });
    try validateReleaseId(id);
    if (explicit_id) |value| if (!std.mem.eql(u8, id, value)) return error.ManagedReleaseIdMismatch;

    var files: std.ArrayList(File) = .empty;
    for (names) |filename| {
        if (!safeFileName(filename) or !supportedArtifactSuffix(filename)) continue;
        const target = artifactTarget(filename, channel, targets.items) orelse continue;
        if (std.mem.endsWith(u8, filename, "-checksum.json")) {
            try validateChecksum(io, allocator, directory, filename, manifests[targetIndex(target).?].?);
        }
        try checkRegularPath(io, directory, filename);
        const file = try directory.openFile(io, filename, .{ .follow_symlinks = false });
        defer file.close(io);
        const stat = try regularFileStat(io, directory, filename, file);
        const sha256 = try hashFile(io, allocator, file, stat);
        try files.append(allocator, .{
            .filename = filename,
            .target = target,
            .path = try std.fs.path.join(allocator, &.{ folder, filename }),
            .size = stat.size,
            .sha256 = sha256,
        });
    }
    std.mem.sort(File, files.items, {}, fileLessThan);
    return .{ .id = id, .channel = channel, .version = version.?, .identifier = identifier.?, .targets = try targets.toOwnedSlice(allocator), .files = try files.toOwnedSlice(allocator) };
}

fn readManifest(io: std.Io, allocator: Allocator, directory: std.Io.Dir, filename: []const u8, name: ManifestName) !Manifest {
    try checkRegularPath(io, directory, filename);
    const file = try directory.openFile(io, filename, .{ .follow_symlinks = false });
    defer file.close(io);
    const stat = try regularFileStat(io, directory, filename, file);
    if (stat.size > max_manifest_bytes) return error.ManagedReleaseManifestTooLarge;
    const bytes = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(bytes);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len or !sameStat(stat, try file.stat(io))) return error.ManagedReleaseArtifactChanged;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return error.InvalidManagedUpdateManifest;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidManagedUpdateManifest;
    const schema = root.object.get("schemaVersion") orelse return error.InvalidManagedUpdateManifest;
    if (schema != .integer or schema.integer != 1) return error.InvalidManagedUpdateManifest;
    const dash = std.mem.indexOfScalar(u8, name.target, '-').?;
    if (!std.mem.eql(u8, try stringField(root, "channel"), name.channel) or
        !std.mem.eql(u8, try stringField(root, "platform"), name.target[0..dash]) or
        !std.mem.eql(u8, try stringField(root, "arch"), name.target[dash + 1 ..])) return error.ManagedReleaseManifestTargetMismatch;
    const version = try stringField(root, "version");
    const identifier = try stringField(root, "identifier");
    const hash = try stringField(root, "hash");
    for (hash) |byte| if (!std.ascii.isAlphanumeric(byte)) return error.InvalidManagedUpdateManifest;
    const artifact = root.object.get("artifact") orelse return error.InvalidManagedUpdateManifest;
    const archive = try stringField(artifact, "file");
    if (!safeFileName(archive) or !std.mem.endsWith(u8, archive, ".tar.zst") or artifactTarget(archive, name.channel, &.{name.target}) == null or !std.mem.startsWith(u8, archive, name.channel)) return error.InvalidManagedReleaseArchiveName;
    var tar_sha256: ?[]const u8 = null;
    var tar_size: ?i64 = null;
    if (name.v2 or artifact.object.contains("tarSha256") or artifact.object.contains("tarSize")) {
        const checksum = stringField(artifact, "tarSha256") catch return error.InvalidManagedTarIntegrity;
        if (checksum.len != 64) return error.InvalidManagedTarIntegrity;
        for (checksum) |byte| if (!std.ascii.isHex(byte)) return error.InvalidManagedTarIntegrity;
        const size = artifact.object.get("tarSize") orelse return error.InvalidManagedTarIntegrity;
        if (size != .integer or size.integer <= 0 or size.integer > max_safe_integer) return error.InvalidManagedTarIntegrity;
        tar_sha256 = try allocator.dupe(u8, checksum);
        tar_size = size.integer;
    }
    return .{ .name = name, .version = try allocator.dupe(u8, version), .identifier = try allocator.dupe(u8, identifier), .hash = try allocator.dupe(u8, hash), .archive = try allocator.dupe(u8, archive), .tar_sha256 = tar_sha256, .tar_size = tar_size };
}

fn validateChecksum(io: std.Io, allocator: Allocator, directory: std.Io.Dir, filename: []const u8, manifest: Manifest) !void {
    const expected = try std.fmt.allocPrint(allocator, "{s}-{s}-{s}-checksum.json", .{ manifest.name.channel, manifest.name.target, manifest.hash });
    defer allocator.free(expected);
    if (!std.mem.eql(u8, filename, expected)) return error.ManagedChecksumBuildMismatch;
    try checkRegularPath(io, directory, filename);
    const file = try directory.openFile(io, filename, .{ .follow_symlinks = false });
    defer file.close(io);
    const stat = try regularFileStat(io, directory, filename, file);
    if (stat.size > max_manifest_bytes) return error.ManagedReleaseManifestTooLarge;
    const bytes = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(bytes);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len or !sameStat(stat, try file.stat(io))) return error.ManagedReleaseArtifactChanged;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return error.InvalidManagedChecksum;
    defer parsed.deinit();
    const checksum = stringField(parsed.value, "tarSha256") catch return error.InvalidManagedChecksum;
    if (checksum.len != 64) return error.InvalidManagedChecksum;
    for (checksum) |byte| if (!std.ascii.isHex(byte)) return error.InvalidManagedChecksum;
    const size = parsed.value.object.get("tarSize") orelse return error.InvalidManagedChecksum;
    if (size != .integer or size.integer <= 0 or size.integer > max_safe_integer) return error.InvalidManagedChecksum;
    if (manifest.tar_sha256) |inline_checksum| {
        if (!std.mem.eql(u8, checksum, inline_checksum) or size.integer != manifest.tar_size.?) return error.ManagedUpdateChecksumsDisagree;
    }
}

fn regularFileStat(io: std.Io, directory: std.Io.Dir, filename: []const u8, file: std.Io.File) !std.Io.File.Stat {
    const path_stat = try directory.statFile(io, filename, .{ .follow_symlinks = false });
    const stat = try file.stat(io);
    if (path_stat.kind != .file or stat.kind != .file or stat.size == 0 or stat.size > max_safe_integer) return error.InvalidManagedReleaseArtifact;
    if (!sameStat(path_stat, stat)) return error.ManagedReleaseArtifactChanged;
    return stat;
}

fn checkRegularPath(io: std.Io, directory: std.Io.Dir, filename: []const u8) !void {
    const stat = try directory.statFile(io, filename, .{ .follow_symlinks = false });
    if (stat.kind != .file or stat.size == 0 or stat.size > max_safe_integer) return error.InvalidManagedReleaseArtifact;
}

fn hashFile(io: std.Io, allocator: Allocator, file: std.Io.File, expected: std.Io.File.Stat) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < expected.size) {
        const wanted: usize = @intCast(@min(buffer.len, expected.size - offset));
        const count = try file.readPositionalAll(io, buffer[0..wanted], offset);
        if (count != wanted) return error.ManagedReleaseArtifactChanged;
        hasher.update(buffer[0..count]);
        offset += count;
    }
    if (!sameStat(expected, try file.stat(io))) return error.ManagedReleaseArtifactChanged;
    const hex = std.fmt.bytesToHex(hasher.finalResult(), .lower);
    return allocator.dupe(u8, &hex);
}

fn sameStat(a: std.Io.File.Stat, b: std.Io.File.Stat) bool {
    return a.kind == b.kind and a.size == b.size and a.inode == b.inode and a.mtime.nanoseconds == b.mtime.nanoseconds and a.ctime.nanoseconds == b.ctime.nanoseconds;
}

pub fn validateReleaseId(value: []const u8) !void {
    if (value.len == 0 or value.len > 128 or !std.ascii.isAlphanumeric(value[0]) or std.mem.endsWith(u8, value, ".") or std.mem.indexOf(u8, value, "..") != null) return error.InvalidManagedReleaseId;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "._+-", byte) == null) return error.InvalidManagedReleaseId;
}

fn parseManifestName(filename: []const u8) ?ManifestName {
    for (channels) |channel| {
        if (!std.mem.startsWith(u8, filename, channel) or filename.len <= channel.len or filename[channel.len] != '-') continue;
        const rest = filename[channel.len + 1 ..];
        for (supported_targets) |target| {
            if (!std.mem.startsWith(u8, rest, target)) continue;
            const suffix = rest[target.len..];
            if (std.mem.eql(u8, suffix, "-update.json")) return .{ .channel = channel, .target = target, .v2 = false };
            if (std.mem.eql(u8, suffix, "-update-v2.json")) return .{ .channel = channel, .target = target, .v2 = true };
        }
    }
    return null;
}

fn artifactTarget(filename: []const u8, channel: []const u8, targets: []const []const u8) ?[]const u8 {
    const suffix = if (std.mem.startsWith(u8, filename, channel) and filename.len > channel.len and filename[channel.len] == '-') filename[channel.len + 1 ..] else if (std.mem.eql(u8, channel, "stable")) filename else return null;
    for (targets) |target| {
        if (std.mem.startsWith(u8, suffix, target) and suffix.len > target.len and suffix[target.len] == '-') return target;
    }
    return null;
}

fn targetIndex(target: []const u8) ?usize {
    for (supported_targets, 0..) |value, i| if (std.mem.eql(u8, value, target)) return i;
    return null;
}

fn safeFileName(value: []const u8) bool {
    if (value.len == 0 or value.len > 255 or std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return false;
    for (value) |byte| if (byte == '/' or byte == '\\' or byte < 32 or byte == 127) return false;
    return true;
}

fn supportedArtifactSuffix(filename: []const u8) bool {
    for ([_][]const u8{ "-update.json", "-update-v2.json", "-checksum.json", ".tar.zst", ".patch", ".dmg", ".zip", ".exe", ".tar.gz" }) |suffix| if (std.mem.endsWith(u8, filename, suffix)) return true;
    return false;
}

fn stringField(value: std.json.Value, name: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidManagedUpdateManifest;
    const field = value.object.get(name) orelse return error.InvalidManagedUpdateManifest;
    if (field != .string or field.string.len == 0) return error.InvalidManagedUpdateManifest;
    return field.string;
}

fn contains(values: []const []const u8, value: []const u8) bool {
    for (values) |existing| if (std.mem.eql(u8, existing, value)) return true;
    return false;
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn fileLessThan(_: void, a: File, b: File) bool {
    const a_order: u8 = if (parseManifestName(a.filename) != null) 2 else if (std.mem.endsWith(u8, a.filename, "-checksum.json")) 1 else 0;
    const b_order: u8 = if (parseManifestName(b.filename) != null) 2 else if (std.mem.endsWith(u8, b.filename, "-checksum.json")) 1 else 0;
    if (a_order != b_order) return a_order < b_order;
    return std.mem.lessThan(u8, a.filename, b.filename);
}

fn fixture(allocator: Allocator, dir: std.Io.Dir, channel: []const u8, target: []const u8, version: []const u8, hash: []const u8) !void {
    const dash = std.mem.indexOfScalar(u8, target, '-').?;
    const prefix = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ channel, target });
    const archive = try std.fmt.allocPrint(allocator, "{s}-Example.app.tar.zst", .{prefix});
    try dir.writeFile(std.testing.io, .{ .sub_path = archive, .data = "archive-bytes" });
    const json = try std.json.Stringify.valueAlloc(allocator, .{
        .schemaVersion = 1,
        .channel = channel,
        .platform = target[0..dash],
        .arch = target[dash + 1 ..],
        .version = version,
        .identifier = "dev.example.App",
        .hash = hash,
        .artifact = .{ .file = archive, .tarSha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .tarSize = 123 },
    }, .{});
    try dir.writeFile(std.testing.io, .{ .sub_path = try std.fmt.allocPrint(allocator, "{s}-update.json", .{prefix}), .data = json });
}

fn testFolder(allocator: Allocator, dir: std.Io.Dir) ![]const u8 {
    return dir.realPathFileAlloc(std.testing.io, ".", allocator);
}

test "inventory infers both channels and includes only their own patches and installers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir, "canary", "macos-arm64", "1.2.3-canary.4", "canaryHash");
    try fixture(a, tmp.dir, "stable", "macos-arm64", "1.2.3", "stableHash");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "canary-macos-arm64-previous.patch", .data = "patch" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "macos-arm64-Example.dmg", .data = "installer" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "canary-linux-x64-unbuilt.tar.zst", .data = "other-target" });
    const releases = try inventory(std.testing.io, a, try testFolder(a, tmp.dir), null, null, null);
    try std.testing.expectEqual(@as(usize, 2), releases.len);
    try std.testing.expectEqualStrings("canary-1.2.3-canary.4", releases[0].id);
    try std.testing.expectEqualStrings("stable-1.2.3", releases[1].id);
    for (releases) |release| {
        try std.testing.expectEqual(@as(usize, 3), release.files.len);
        try std.testing.expectEqualStrings("macos-arm64", release.targets[0]);
        try std.testing.expect(std.mem.endsWith(u8, release.files[2].filename, ".json"));
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash("archive-bytes", &digest, .{});
        const checksum = std.fmt.bytesToHex(digest, .lower);
        for (release.files) |file| {
            if (std.mem.endsWith(u8, file.filename, ".tar.zst")) try std.testing.expectEqualStrings(&checksum, file.sha256);
            if (std.mem.eql(u8, release.channel, "canary")) try std.testing.expect(std.mem.startsWith(u8, file.filename, "canary-"));
        }
    }
    try std.testing.expectError(error.MixedManagedReleaseChannelsRequireSeparateIds, inventory(std.testing.io, a, try testFolder(a, tmp.dir), null, "release-1", null));
    const stable = try inventory(std.testing.io, a, try testFolder(a, tmp.dir), "stable", "stable-1.2.3", null);
    try std.testing.expectEqual(@as(usize, 1), stable.len);
    try std.testing.expectEqualStrings("stable-1.2.3", stable[0].id);
    for ([_][]const u8{ "1.2.3+build.1", "canary-1.2.3", "stable-1.2.4", "release-1" }) |alias| {
        try std.testing.expectError(error.ManagedReleaseIdMismatch, inventory(std.testing.io, a, try testFolder(a, tmp.dir), "stable", alias, null));
    }
}

test "independent runner artifacts share a canonical channel version without changing build metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mac = std.testing.tmpDir(.{});
    defer mac.cleanup();
    var linux = std.testing.tmpDir(.{});
    defer linux.cleanup();
    const version = "2.0.0-beta.3+build.42";
    try fixture(a, mac.dir, "canary", "macos-arm64", version, "macHash");
    try fixture(a, linux.dir, "canary", "linux-x64", version, "linuxHash");
    const mac_releases = try inventory(std.testing.io, a, try testFolder(a, mac.dir), null, null, null);
    const linux_releases = try inventory(std.testing.io, a, try testFolder(a, linux.dir), null, null, null);
    try std.testing.expectEqualStrings("canary-2.0.0-beta.3+build.42", mac_releases[0].id);
    try std.testing.expectEqualStrings(mac_releases[0].id, linux_releases[0].id);
    try std.testing.expectEqualStrings(version, linux_releases[0].version);
}

test "inventory accepts ordinary update manifests and rejects missing archives and excluded targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir, "canary", "linux-x64", "1.2.3", "hash1");
    const folder = try testFolder(a, tmp.dir);
    try std.testing.expectError(error.ManagedTargetExcludedFromExpectedTargets, inventory(std.testing.io, a, folder, null, null, &.{"macos-arm64"}));
    const releases = try inventory(std.testing.io, a, folder, null, null, null);
    try std.testing.expectEqual(@as(usize, 1), releases.len);
    try std.testing.expectEqualStrings("canary-1.2.3", releases[0].id);
    try std.testing.expectEqualStrings("linux-x64", releases[0].targets[0]);
    try std.testing.expectEqual(@as(usize, 2), releases[0].files.len);
    try tmp.dir.deleteFile(std.testing.io, "canary-linux-x64-Example.app.tar.zst");
    try std.testing.expectError(error.MissingManagedReleaseArchive, inventory(std.testing.io, a, folder, null, null, null));
}

test "inventory validates every platform and every channel before returning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir, "canary", "macos-arm64", "1.2.3", "hash1");
    try fixture(a, tmp.dir, "canary", "win-x64", "1.2.4", "hash2");
    const folder = try testFolder(a, tmp.dir);
    try std.testing.expectError(error.ManagedReleaseIdentityMismatch, inventory(std.testing.io, a, folder, null, null, null));
    try fixture(a, tmp.dir, "canary", "win-x64", "1.2.3", "hash2");
    const valid = try inventory(std.testing.io, a, folder, null, null, null);
    try std.testing.expectEqual(@as(usize, 2), valid[0].targets.len);
    try fixture(a, tmp.dir, "stable", "linux-x64", "1.2.3", "hash3");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "stable-linux-x64-update-v2.json", .data = "{" });
    try std.testing.expectError(error.InvalidManagedUpdateManifest, inventory(std.testing.io, a, folder, null, null, null));
}

test "inventory rejects symlink archives" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir, "canary", "macos-arm64", "1.2.3", "hash1");
    try tmp.dir.deleteFile(std.testing.io, "canary-macos-arm64-Example.app.tar.zst");
    try tmp.dir.symLink(std.testing.io, "canary-macos-arm64-update.json", "canary-macos-arm64-Example.app.tar.zst", .{});
    const result = inventory(std.testing.io, a, try testFolder(a, tmp.dir), null, null, null);
    if (result) |_| return error.TestExpectedError else |_| {}
}

test "inventory validates canonical metadata and its agreement with a legacy companion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir, "canary", "macos-arm64", "1.2.3", "hash1");
    const folder = try testFolder(a, tmp.dir);
    const filename = "canary-macos-arm64-update.json";
    const original = try tmp.dir.readFileAlloc(std.testing.io, filename, a, .limited(max_manifest_bytes));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "canary-macos-arm64-update-v2.json", .data = original });
    const Case = struct { before: []const u8, after: []const u8, expected: anyerror };
    for ([_]Case{
        .{ .before = "\"hash1\"", .after = "\"hash2\"", .expected = error.ManagedUpdateManifestsDisagree },
        .{ .before = "\"channel\":\"canary\"", .after = "\"channel\":\"stable\"", .expected = error.ManagedReleaseManifestTargetMismatch },
        .{ .before = "\"schemaVersion\":1", .after = "\"schemaVersion\":2", .expected = error.InvalidManagedUpdateManifest },
        .{ .before = "canary-macos-arm64-Example.app.tar.zst", .after = "../Example.app.tar.zst", .expected = error.InvalidManagedReleaseArchiveName },
        .{ .before = "canary-macos-arm64-Example.app.tar.zst", .after = "stable-macos-arm64-Example.app.tar.zst", .expected = error.InvalidManagedReleaseArchiveName },
        .{ .before = "\"tarSize\":123", .after = "\"tarSize\":0", .expected = error.InvalidManagedTarIntegrity },
        .{ .before = ",\"tarSize\":123", .after = "", .expected = error.InvalidManagedTarIntegrity },
        .{ .before = ",\"tarSha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"", .after = "", .expected = error.InvalidManagedTarIntegrity },
        .{ .before = "\"tarSize\":123", .after = "\"tarSize\":124", .expected = error.ManagedUpdateManifestsDisagree },
        .{ .before = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .after = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz", .expected = error.InvalidManagedTarIntegrity },
        .{ .before = "dev.example.App", .after = "dev.other.App", .expected = error.ManagedReleaseIdentityMismatch },
    }) |case| {
        const modified = try std.mem.replaceOwned(u8, a, original, case.before, case.after);
        try std.testing.expect(!std.mem.eql(u8, original, modified));
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = filename, .data = modified });
        try std.testing.expectError(case.expected, inventory(std.testing.io, a, folder, null, null, null));
    }
}

test "inventory accepts legacy canonical manifests with an optional build bound checksum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir, "canary", "macos-arm64", "1.2.3", "hash1");
    const filename = "canary-macos-arm64-update.json";
    const original = try tmp.dir.readFileAlloc(std.testing.io, filename, a, .limited(max_manifest_bytes));
    const legacy = try std.mem.replaceOwned(u8, a, original, ",\"tarSha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"tarSize\":123", "");
    try std.testing.expect(!std.mem.eql(u8, original, legacy));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = filename, .data = legacy });
    const releases = try inventory(std.testing.io, a, try testFolder(a, tmp.dir), null, null, null);
    try std.testing.expectEqual(@as(usize, 2), releases[0].files.len);
    const checksum_name = "canary-macos-arm64-hash1-checksum.json";
    const checksum_json = "{\"tarSha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"tarSize\":123}";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = checksum_name, .data = checksum_json });
    const with_checksum = try inventory(std.testing.io, a, try testFolder(a, tmp.dir), null, null, null);
    try std.testing.expectEqual(@as(usize, 3), with_checksum[0].files.len);
    try std.testing.expectEqualStrings(checksum_name, with_checksum[0].files[1].filename);
    try std.testing.expectEqualStrings(filename, with_checksum[0].files[2].filename);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(checksum_json, &digest, .{});
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(digest, .lower), with_checksum[0].files[1].sha256);
}

test "inventory rejects checksum files for another build or invalid checksum content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir, "canary", "macos-arm64", "1.2.3", "hash1");
    const folder = try testFolder(a, tmp.dir);
    const checksum_json = "{\"tarSha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"tarSize\":123}";
    const wrong_name = "canary-macos-arm64-otherhash-checksum.json";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = wrong_name, .data = checksum_json });
    try std.testing.expectError(error.ManagedChecksumBuildMismatch, inventory(std.testing.io, a, folder, null, null, null));
    try tmp.dir.deleteFile(std.testing.io, wrong_name);
    const filename = "canary-macos-arm64-hash1-checksum.json";
    for ([_][]const u8{
        "{",
        "null",
        "[]",
        "{}",
        "{\"tarSize\":123}",
        "{\"tarSha256\":\"invalid\",\"tarSize\":123}",
        "{\"tarSha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}",
        "{\"tarSha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"tarSize\":0}",
        "{\"tarSha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"tarSize\":9007199254740992}",
    }) |invalid| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = filename, .data = invalid });
        try std.testing.expectError(error.InvalidManagedChecksum, inventory(std.testing.io, a, folder, null, null, null));
    }
    const conflicting = try std.mem.replaceOwned(u8, a, checksum_json, "123", "124");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = filename, .data = conflicting });
    try std.testing.expectError(error.ManagedUpdateChecksumsDisagree, inventory(std.testing.io, a, folder, null, null, null));
}

test "inventory rejects checksum symlinks before reading their content" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir, "canary", "macos-arm64", "1.2.3", "hash1");
    try tmp.dir.symLink(std.testing.io, "canary-macos-arm64-update.json", "canary-macos-arm64-hash1-checksum.json", .{});
    try std.testing.expectError(error.InvalidManagedReleaseArtifact, inventory(std.testing.io, a, try testFolder(a, tmp.dir), null, null, null));
}

test "inventory streams checksums across multiple read buffers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir, "stable", "linux-x64", "1.2.3", "hash1");
    const bytes = try a.alloc(u8, 150 * 1024 + 13);
    for (bytes, 0..) |*byte, i| byte.* = @truncate(i);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "stable-linux-x64-Example.app.tar.zst", .data = bytes });
    const releases = try inventory(std.testing.io, a, try testFolder(a, tmp.dir), null, null, null);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const checksum = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(&checksum, releases[0].files[0].sha256);
    try std.testing.expectEqual(@as(u64, bytes.len), releases[0].files[0].size);
}

test "release ids and manifest names cannot introduce channels or traversal" {
    for ([_][]const u8{ "", "../release", "release..other", "release.", "release/other", "release\\other" }) |id| try std.testing.expectError(error.InvalidManagedReleaseId, validateReleaseId(id));
    try validateReleaseId("stable-1.2.3+build.4");
    try std.testing.expect(parseManifestName("preview-macos-arm64-update.json") == null);
    try std.testing.expect(parseManifestName("stable-macos-arm64-update-v2.json").?.v2);
}
