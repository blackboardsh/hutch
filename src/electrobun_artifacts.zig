const std = @import("std");
const builtin = @import("builtin");
const archive_util = @import("archive.zig");
const release_store = @import("release_store.zig");

const default_releases_base_url =
    "https://github.com/blackboardsh/electrobun/releases/download";
const artifact_index_file_name = "electrobun-artifacts.json";
const artifact_index_schema_version = 1;
const native_devkit_manifest_file_name = "native-devkit.json";
const native_devkit_schema_version = 1;
const supported_core_abi_version = 1;
const supported_sdk_abi_version = 1;
const max_artifact_index_bytes = 1024 * 1024;
const max_core_archive_bytes = 512 * 1024 * 1024;
const max_cef_archive_bytes = 1024 * 1024 * 1024;
const max_core_entries = 100_000;
const max_cef_entries = 250_000;
const max_core_file_bytes = 1024 * 1024 * 1024;
const max_cef_file_bytes = 2 * 1024 * 1024 * 1024;
const max_core_extracted_bytes = 2 * 1024 * 1024 * 1024;
const max_cef_extracted_bytes = 4 * 1024 * 1024 * 1024;

pub const Kind = enum {
    core,
    cef,

    fn name(self: Kind) []const u8 {
        return @tagName(self);
    }

    fn maxArchiveBytes(self: Kind) usize {
        return switch (self) {
            .core => max_core_archive_bytes,
            .cef => max_cef_archive_bytes,
        };
    }
};

const Artifact = struct {
    url: []const u8,
    sha256: []const u8,
    size: usize,
};

const Abi = struct {
    core_name: []const u8,
    core_version: usize,
    sdk_name: []const u8,
    sdk_version: usize,
};

const ArtifactSelection = struct {
    version: []const u8,
    target_os: []const u8,
    target_arch: []const u8,
    devkit_manifest: []const u8,
    devkit_schema_version: usize,
    abi: Abi,
    core: Artifact,
    cef: ?Artifact,

    fn artifact(self: ArtifactSelection, kind: Kind) !Artifact {
        return switch (kind) {
            .core => self.core,
            .cef => self.cef orelse error.ElectrobunCefArtifactUnavailable,
        };
    }
};

pub fn ensureCore(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    version: []const u8,
) ![]const u8 {
    return ensure(init, allocator, version, .core);
}

pub fn ensureCef(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    version: []const u8,
) ![]const u8 {
    _ = try ensure(init, allocator, version, .core);
    return ensure(init, allocator, version, .cef);
}

fn ensure(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    version: []const u8,
    kind: Kind,
) ![]const u8 {
    try validateVersion(version);
    const home = try release_store.dashHome(init, allocator);
    const platform = try platformKey();
    const root = try std.fs.path.join(allocator, &.{
        home,
        "products",
        "electrobun",
        version,
        platform,
    });
    const parent = std.fs.path.dirname(root) orelse return error.InvalidElectrobunInstallPath;
    try std.Io.Dir.cwd().createDirPath(init.io, parent);
    const lock_path = try std.mem.concat(allocator, u8, &.{ root, ".lock" });
    const lock = try release_store.acquirePersistentFileLock(init.io, lock_path);
    defer lock.close(init.io);

    const base_url = try releasesBaseUrl(init, allocator);
    const offline = environmentFlagEnabled(init.environ_map, "DASH_RELEASE_OFFLINE");
    const selection = try resolveArtifactSelection(
        init,
        allocator,
        home,
        base_url,
        version,
        platform,
        offline,
    );
    const artifact = try selection.artifact(kind);
    if (try installationMatches(init.io, allocator, root, kind, artifact.sha256)) return root;
    if (offline) return error.ElectrobunArtifactNotCached;

    std.debug.print(
        "hutch: downloading Electrobun {s} {s} for {s}\n",
        .{ version, kind.name(), platform },
    );
    const archive = try fetchArtifactBytes(
        init,
        allocator,
        artifact.url,
        artifact.size,
    );
    try validateArchiveBytes(artifact, archive);

    switch (kind) {
        .core => try installCore(init.io, allocator, root, archive, selection),
        .cef => try installCef(init.io, allocator, root, archive, selection),
    }
    return root;
}

fn resolveArtifactSelection(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    home: []const u8,
    base_url: []const u8,
    version: []const u8,
    platform: []const u8,
    offline: bool,
) !ArtifactSelection {
    const cache_path = try artifactIndexCachePath(allocator, home, version);
    const cache_parent = std.fs.path.dirname(cache_path) orelse
        return error.InvalidElectrobunArtifactIndexCachePath;
    try std.Io.Dir.cwd().createDirPath(init.io, cache_parent);
    const lock = try release_store.acquireCacheFileLock(init.io, allocator, cache_path);
    defer lock.close(init.io);

    var cached_too_large = false;
    const cached = std.Io.Dir.cwd().readFileAlloc(
        init.io,
        cache_path,
        allocator,
        .limited(max_artifact_index_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        error.StreamTooLong => blk: {
            cached_too_large = true;
            break :blk null;
        },
        else => |e| return e,
    };
    if (cached) |bytes| {
        const selection = parseArtifactIndex(
            allocator,
            bytes,
            base_url,
            version,
            platform,
        ) catch {
            if (offline) return error.ElectrobunArtifactIndexCacheInvalid;
            return refreshArtifactIndex(
                init,
                allocator,
                cache_path,
                base_url,
                version,
                platform,
                true,
            );
        };
        return selection;
    }
    if (offline) {
        return if (cached_too_large)
            error.ElectrobunArtifactIndexCacheInvalid
        else
            error.ElectrobunArtifactIndexNotCached;
    }
    return refreshArtifactIndex(
        init,
        allocator,
        cache_path,
        base_url,
        version,
        platform,
        cached_too_large,
    );
}

fn refreshArtifactIndex(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    cache_path: []const u8,
    base_url: []const u8,
    version: []const u8,
    platform: []const u8,
    quarantine_existing: bool,
) !ArtifactSelection {
    const url = try artifactIndexUrl(allocator, base_url, version);
    const downloaded = try fetchBoundedBytes(
        init,
        allocator,
        url,
        max_artifact_index_bytes,
    );
    const selection = try parseArtifactIndex(
        allocator,
        downloaded,
        base_url,
        version,
        platform,
    );
    if (quarantine_existing) {
        try quarantineCacheFile(init.io, allocator, cache_path);
    }
    // resolveArtifactSelection holds the persistent `<cache_path>.lock` lock.
    try release_store.writeCacheFileLocked(init.io, cache_path, downloaded);
    return selection;
}

fn quarantineCacheFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !void {
    const quarantine = try std.mem.concat(allocator, u8, &.{ path, ".invalid" });
    std.Io.Dir.cwd().deleteFile(io, quarantine) catch {};
    std.Io.Dir.cwd().rename(path, std.Io.Dir.cwd(), quarantine, io) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
}

fn parseArtifactIndex(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    base_url: []const u8,
    expected_version: []const u8,
    platform: []const u8,
) !ArtifactSelection {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
    });
    if (try jsonPositiveUsize(root, "schemaVersion") != artifact_index_schema_version) {
        return error.UnsupportedElectrobunArtifactIndexSchema;
    }

    const product = try jsonObject(root, "product");
    if (!std.mem.eql(u8, try jsonString(product, "name"), "electrobun")) {
        return error.ElectrobunArtifactProductMismatch;
    }
    const version = try jsonString(product, "version");
    try validateVersion(version);
    if (!std.mem.eql(u8, version, expected_version)) {
        return error.ElectrobunArtifactVersionMismatch;
    }

    const devkit = try jsonObject(root, "devkit");
    const devkit_manifest = try jsonString(devkit, "manifest");
    if (!std.mem.eql(u8, devkit_manifest, native_devkit_manifest_file_name)) {
        return error.InvalidElectrobunDevkitManifestPath;
    }
    const devkit_schema_version = try jsonPositiveUsize(devkit, "schemaVersion");
    if (devkit_schema_version != native_devkit_schema_version) {
        return error.UnsupportedElectrobunDevkitSchema;
    }

    const abi_value = try jsonObject(root, "abi");
    const core_abi = try jsonObject(abi_value, "core");
    const sdk_abi = try jsonObject(abi_value, "sdk");
    const abi: Abi = .{
        .core_name = try jsonString(core_abi, "name"),
        .core_version = try jsonPositiveUsize(core_abi, "version"),
        .sdk_name = try jsonString(sdk_abi, "name"),
        .sdk_version = try jsonPositiveUsize(sdk_abi, "version"),
    };
    if (!std.mem.eql(u8, abi.core_name, "electrobun-core") or
        !std.mem.eql(u8, abi.sdk_name, "electrobun-sdk"))
    {
        return error.InvalidElectrobunAbiIdentity;
    }
    if (abi.core_version != supported_core_abi_version) {
        return error.UnsupportedElectrobunCoreAbi;
    }
    if (abi.sdk_version != supported_sdk_abi_version) {
        return error.UnsupportedElectrobunSdkAbi;
    }

    const platforms = try jsonObject(root, "platforms");
    const platform_value = platforms.object.get(platform) orelse
        return error.ElectrobunArtifactPlatformMissing;
    if (platform_value != .object) return error.InvalidElectrobunArtifactIndex;
    const target = try jsonObject(platform_value, "target");
    const target_os = try jsonString(target, "os");
    const target_arch = try jsonString(target, "arch");
    if (!std.mem.eql(u8, target_os, targetOsName()) or
        !std.mem.eql(u8, target_arch, releaseArchName()))
    {
        return error.ElectrobunArtifactTargetMismatch;
    }

    const core = try parseArtifact(
        allocator,
        platform_value,
        "core",
        base_url,
        version,
        .core,
    );
    const cef = if (platform_value.object.get("cef") != null)
        try parseArtifact(allocator, platform_value, "cef", base_url, version, .cef)
    else
        null;

    return .{
        .version = version,
        .target_os = target_os,
        .target_arch = target_arch,
        .devkit_manifest = devkit_manifest,
        .devkit_schema_version = devkit_schema_version,
        .abi = abi,
        .core = core,
        .cef = cef,
    };
}

fn parseArtifact(
    allocator: std.mem.Allocator,
    platform_value: std.json.Value,
    field_name: []const u8,
    base_url: []const u8,
    version: []const u8,
    kind: Kind,
) !Artifact {
    const value = try jsonObject(platform_value, field_name);
    const url = try jsonString(value, "url");
    const expected_url = try artifactUrl(allocator, base_url, version, kind);
    if (!std.mem.eql(u8, url, expected_url)) return error.UntrustedElectrobunArtifactUrl;
    const sha256 = try jsonString(value, "sha256");
    try validateSha256(sha256);
    const size = try jsonPositiveUsize(value, "size");
    if (size > kind.maxArchiveBytes()) return error.ElectrobunArtifactTooLarge;
    return .{ .url = url, .sha256 = sha256, .size = size };
}

fn validateArchiveBytes(artifact: Artifact, archive: []const u8) !void {
    if (archive.len != artifact.size) return error.ElectrobunArtifactSizeMismatch;
    if (!release_store.sha256Matches(archive, artifact.sha256)) {
        return error.ElectrobunArtifactChecksumMismatch;
    }
}

fn fetchArtifactBytes(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    url: []const u8,
    expected_size: usize,
) ![]const u8 {
    const buffer = try allocator.alloc(u8, expected_size);
    errdefer allocator.free(buffer);
    var writer: std.Io.Writer = .fixed(buffer);

    var client: std.http.Client = .{ .allocator = allocator, .io = init.io };
    defer client.deinit();
    client.initDefaultProxies(allocator, init.environ_map) catch {};

    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &writer,
        .keep_alive = builtin.os.tag != .windows,
    }) catch |err| switch (err) {
        error.WriteFailed => return error.ElectrobunArtifactSizeMismatch,
        else => |e| return e,
    };
    const status: u16 = @intFromEnum(result.status);
    if (status < 200 or status >= 300) return error.ReleaseDownloadFailed;
    if (writer.end != expected_size) return error.ElectrobunArtifactSizeMismatch;
    return buffer[0..writer.end];
}

fn fetchBoundedBytes(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    url: []const u8,
    max_size: usize,
) ![]const u8 {
    const capacity = std.math.add(usize, max_size, 1) catch return error.OutOfMemory;
    const buffer = try allocator.alloc(u8, capacity);
    errdefer allocator.free(buffer);
    var writer: std.Io.Writer = .fixed(buffer);

    var client: std.http.Client = .{ .allocator = allocator, .io = init.io };
    defer client.deinit();
    client.initDefaultProxies(allocator, init.environ_map) catch {};

    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &writer,
        .keep_alive = builtin.os.tag != .windows,
    }) catch |err| switch (err) {
        error.WriteFailed => return error.ReleaseDownloadTooLarge,
        else => |e| return e,
    };
    const status: u16 = @intFromEnum(result.status);
    if (status < 200 or status >= 300) return error.ReleaseDownloadFailed;
    if (writer.end > max_size) return error.ReleaseDownloadTooLarge;
    return buffer[0..writer.end];
}

fn installCore(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    archive: []const u8,
    selection: ArtifactSelection,
) !void {
    const temporary = try std.mem.concat(allocator, u8, &.{ root, ".core-tmp" });
    std.Io.Dir.cwd().deleteTree(io, temporary) catch {};
    try std.Io.Dir.cwd().createDirPath(io, temporary);
    errdefer std.Io.Dir.cwd().deleteTree(io, temporary) catch {};

    {
        var destination = try std.Io.Dir.cwd().openDir(io, temporary, .{});
        defer destination.close(io);
        try archive_util.extractTarGzip(
            io,
            allocator,
            destination,
            archive,
            .{
                .strip_components = 0,
                .max_entries = max_core_entries,
                .max_file_bytes = max_core_file_bytes,
                .max_total_file_bytes = max_core_extracted_bytes,
            },
        );
    }
    try validateCoreFiles(io, allocator, temporary);
    try validateNativeDevkitIdentity(io, allocator, temporary, selection);
    try writeMarker(io, allocator, temporary, .core, selection.core.sha256);

    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), root, io);
}

fn installCef(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    archive: []const u8,
    selection: ArtifactSelection,
) !void {
    if (!try installationMatches(io, allocator, root, .core, selection.core.sha256)) {
        return error.ElectrobunCoreNotInstalled;
    }
    const cef_artifact = selection.cef orelse return error.ElectrobunCefArtifactUnavailable;

    const temporary = try std.mem.concat(allocator, u8, &.{ root, ".cef-tmp" });
    std.Io.Dir.cwd().deleteTree(io, temporary) catch {};
    try std.Io.Dir.cwd().createDirPath(io, temporary);
    defer std.Io.Dir.cwd().deleteTree(io, temporary) catch {};

    {
        var destination = try std.Io.Dir.cwd().openDir(io, temporary, .{});
        defer destination.close(io);
        try archive_util.extractTarGzip(
            io,
            allocator,
            destination,
            archive,
            .{
                .strip_components = 0,
                .max_entries = max_cef_entries,
                .max_file_bytes = max_cef_file_bytes,
                .max_total_file_bytes = max_cef_extracted_bytes,
            },
        );
    }

    const extracted_cef = try std.fs.path.join(allocator, &.{ temporary, "cef" });
    if (!pathIsDirectory(io, extracted_cef)) return error.ElectrobunCefArchiveInvalid;
    const installed_cef = try std.fs.path.join(allocator, &.{ root, "cef" });
    std.Io.Dir.cwd().deleteTree(io, installed_cef) catch {};
    try std.Io.Dir.cwd().rename(extracted_cef, std.Io.Dir.cwd(), installed_cef, io);
    try writeMarker(io, allocator, root, .cef, cef_artifact.sha256);
}

fn installationMatches(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    kind: Kind,
    expected_sha256: []const u8,
) !bool {
    switch (kind) {
        .core => validateCoreFiles(io, allocator, root) catch return false,
        .cef => {
            const cef = try std.fs.path.join(allocator, &.{ root, "cef" });
            if (!pathIsDirectory(io, cef)) return false;
        },
    }

    const marker = try markerPath(allocator, root, kind);
    const value = std.Io.Dir.cwd().readFileAlloc(
        io,
        marker,
        allocator,
        .limited(128),
    ) catch return false;
    return std.mem.eql(
        u8,
        std.mem.trim(u8, value, " \t\r\n"),
        expected_sha256,
    );
}

fn validateCoreFiles(io: std.Io, allocator: std.mem.Allocator, root: []const u8) !void {
    const required = [_][]const u8{
        launcherFileName(),
        coreLibraryFileName(),
        nativeWrapperFileName(),
        asarLibraryFileName(),
        native_devkit_manifest_file_name,
    };
    for (required) |name| {
        const path = try std.fs.path.join(allocator, &.{ root, name });
        if (!pathExists(io, path)) return error.ElectrobunCoreArchiveInvalid;
    }
}

fn validateNativeDevkitIdentity(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    selection: ArtifactSelection,
) !void {
    const path = try std.fs.path.join(allocator, &.{ root, selection.devkit_manifest });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(max_artifact_index_bytes),
    );
    const manifest = try std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
    });
    if (try jsonPositiveUsize(manifest, "schemaVersion") != selection.devkit_schema_version) {
        return error.ElectrobunDevkitIdentityMismatch;
    }
    const product = try jsonObject(manifest, "product");
    if (!std.mem.eql(u8, try jsonString(product, "name"), "electrobun") or
        !std.mem.eql(u8, try jsonString(product, "version"), selection.version))
    {
        return error.ElectrobunDevkitIdentityMismatch;
    }
    const target = try jsonObject(manifest, "target");
    if (!std.mem.eql(u8, try jsonString(target, "os"), selection.target_os) or
        !std.mem.eql(u8, try jsonString(target, "arch"), selection.target_arch))
    {
        return error.ElectrobunDevkitIdentityMismatch;
    }
    const abi = try jsonObject(manifest, "abi");
    const core = try jsonObject(abi, "core");
    const sdk = try jsonObject(abi, "sdk");
    if (!std.mem.eql(u8, try jsonString(core, "name"), selection.abi.core_name) or
        try jsonPositiveUsize(core, "version") != selection.abi.core_version or
        !std.mem.eql(u8, try jsonString(sdk, "name"), selection.abi.sdk_name) or
        try jsonPositiveUsize(sdk, "version") != selection.abi.sdk_version)
    {
        return error.ElectrobunDevkitIdentityMismatch;
    }
}

fn writeMarker(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    kind: Kind,
    sha256: []const u8,
) !void {
    const marker = try markerPath(allocator, root, kind);
    const value = try std.mem.concat(allocator, u8, &.{ sha256, "\n" });
    try release_store.writeCacheFile(io, allocator, marker, value);
}

fn markerPath(allocator: std.mem.Allocator, root: []const u8, kind: Kind) ![]const u8 {
    return switch (kind) {
        .core => std.fs.path.join(allocator, &.{ root, ".core-complete" }),
        // Keep the CEF identity inside its independently managed root. This
        // lets cache pruning detach CEF without mutating or invalidating core.
        .cef => std.fs.path.join(allocator, &.{ root, "cef", ".cef-complete" }),
    };
}

test "CEF completion identity is stored inside its independently managed root" {
    const allocator = std.testing.allocator;
    const root = try std.fs.path.join(allocator, &.{ "cache", "electrobun", "2.0.0", "platform" });
    defer allocator.free(root);
    const core = try markerPath(allocator, root, .core);
    defer allocator.free(core);
    const cef = try markerPath(allocator, root, .cef);
    defer allocator.free(cef);
    const expected_core = try std.fs.path.join(allocator, &.{ root, ".core-complete" });
    defer allocator.free(expected_core);
    const expected_cef = try std.fs.path.join(allocator, &.{ root, "cef", ".cef-complete" });
    defer allocator.free(expected_cef);
    try std.testing.expectEqualStrings(expected_core, core);
    try std.testing.expectEqualStrings(expected_cef, cef);
}

fn artifactIndexCachePath(
    allocator: std.mem.Allocator,
    home: []const u8,
    version: []const u8,
) ![]const u8 {
    return std.fs.path.join(allocator, &.{
        home,
        "cache",
        "electrobun",
        "releases",
        version,
        artifact_index_file_name,
    });
}

fn artifactIndexUrl(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    version: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}/v{s}/{s}",
        .{ base_url, version, artifact_index_file_name },
    );
}

fn artifactUrl(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    version: []const u8,
    kind: Kind,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}/v{s}/electrobun-{s}-{s}-{s}.tar.gz",
        .{ base_url, version, kind.name(), releasePlatformName(), releaseArchName() },
    );
}

fn releasesBaseUrl(init: std.process.Init, allocator: std.mem.Allocator) ![]const u8 {
    const configured = init.environ_map.get("ELECTROBUN_RELEASES_BASE_URL") orelse
        default_releases_base_url;
    const value = std.mem.trimEnd(u8, configured, "/");
    if (!std.mem.startsWith(u8, value, "https://") and
        !std.mem.startsWith(u8, value, "http://127.0.0.1") and
        !std.mem.startsWith(u8, value, "http://localhost"))
    {
        return error.InvalidElectrobunReleasesBaseUrl;
    }
    return allocator.dupe(u8, value);
}

fn environmentFlagEnabled(environ_map: *const std.process.Environ.Map, name: []const u8) bool {
    const value = environ_map.get(name) orelse return false;
    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes");
}

fn validateVersion(version: []const u8) !void {
    if (version.len == 0 or version.len > 128) return error.InvalidElectrobunVersion;
    _ = std.SemanticVersion.parse(version) catch return error.InvalidElectrobunVersion;
}

fn validateSha256(value: []const u8) !void {
    if (value.len != 64) return error.InvalidElectrobunArtifactChecksum;
    for (value) |byte| {
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) {
            return error.InvalidElectrobunArtifactChecksum;
        }
    }
}

fn jsonObject(value: std.json.Value, name: []const u8) !std.json.Value {
    if (value != .object) return error.InvalidElectrobunArtifactIndex;
    const field = value.object.get(name) orelse return error.InvalidElectrobunArtifactIndex;
    if (field != .object) return error.InvalidElectrobunArtifactIndex;
    return field;
}

fn jsonString(value: std.json.Value, name: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidElectrobunArtifactIndex;
    const field = value.object.get(name) orelse return error.InvalidElectrobunArtifactIndex;
    if (field != .string or field.string.len == 0) return error.InvalidElectrobunArtifactIndex;
    return field.string;
}

fn jsonPositiveUsize(value: std.json.Value, name: []const u8) !usize {
    if (value != .object) return error.InvalidElectrobunArtifactIndex;
    const field = value.object.get(name) orelse return error.InvalidElectrobunArtifactIndex;
    if (field != .integer or field.integer <= 0) return error.InvalidElectrobunArtifactIndex;
    return std.math.cast(usize, field.integer) orelse error.InvalidElectrobunArtifactIndex;
}

pub fn platformKey() ![]const u8 {
    return switch (builtin.os.tag) {
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => "macos-arm64",
            .x86_64 => "macos-x64",
            else => error.UnsupportedElectrobunPlatform,
        },
        .linux => switch (builtin.cpu.arch) {
            .aarch64 => "linux-arm64",
            .x86_64 => "linux-x64",
            else => error.UnsupportedElectrobunPlatform,
        },
        .windows => "windows-x64",
        else => error.UnsupportedElectrobunPlatform,
    };
}

fn targetOsName() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "win",
        else => "unsupported",
    };
}

fn releasePlatformName() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        .windows => "win",
        else => "unsupported",
    };
}

fn releaseArchName() []const u8 {
    if (builtin.os.tag == .windows) return "x64";
    return switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        else => "x64",
    };
}

fn launcherFileName() []const u8 {
    return if (builtin.os.tag == .windows) "launcher.exe" else "launcher";
}

fn coreLibraryFileName() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "ElectrobunCore.dll",
        .macos => "libElectrobunCore.dylib",
        else => "libElectrobunCore.so",
    };
}

fn nativeWrapperFileName() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "libNativeWrapper.dll",
        .macos => "libNativeWrapper.dylib",
        else => "libNativeWrapper.so",
    };
}

fn asarLibraryFileName() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "libasar.dll",
        .macos => "libasar.dylib",
        else => "libasar.so",
    };
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn pathIsDirectory(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .directory;
}

fn validIndexJson(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    version: []const u8,
) ![]const u8 {
    const platform = try platformKey();
    const core_url = try artifactUrl(allocator, base_url, version, .core);
    defer allocator.free(core_url);
    const cef_url = try artifactUrl(allocator, base_url, version, .cef);
    defer allocator.free(cef_url);
    return std.fmt.allocPrint(allocator,
        \\{{
        \\  "schemaVersion": 1,
        \\  "product": {{"name":"electrobun","version":"{s}"}},
        \\  "devkit": {{"manifest":"native-devkit.json","schemaVersion":1}},
        \\  "abi": {{
        \\    "core": {{"name":"electrobun-core","version":1}},
        \\    "sdk": {{"name":"electrobun-sdk","version":1}}
        \\  }},
        \\  "platforms": {{
        \\    "{s}": {{
        \\      "target": {{"os":"{s}","arch":"{s}"}},
        \\      "core": {{"url":"{s}","size":4,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},
        \\      "cef": {{"url":"{s}","size":3,"sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}
        \\    }}
        \\  }}
        \\}}
    , .{ version, platform, targetOsName(), releaseArchName(), core_url, cef_url });
}

test "Electrobun artifact indexes select an exact verified platform asset" {
    const allocator = std.testing.allocator;
    const base_url = "https://releases.example.test";
    const version = "2.0.0-beta.17";
    const json = try validIndexJson(allocator, base_url, version);
    defer allocator.free(json);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const selection = try parseArtifactIndex(
        arena.allocator(),
        json,
        base_url,
        version,
        try platformKey(),
    );
    try std.testing.expectEqualStrings(version, selection.version);
    try std.testing.expectEqual(@as(usize, 4), selection.core.size);
    try std.testing.expect(selection.cef != null);
}

test "Electrobun artifact indexes reject URLs outside the exact release" {
    const allocator = std.testing.allocator;
    const base_url = "https://releases.example.test";
    const version = "2.0.0";
    const valid = try validIndexJson(allocator, base_url, version);
    defer allocator.free(valid);
    const expected = try artifactUrl(allocator, base_url, version, .core);
    defer allocator.free(expected);
    const hostile = try std.mem.replaceOwned(
        u8,
        allocator,
        valid,
        expected,
        "https://attacker.example/electrobun-core.tar.gz",
    );
    defer allocator.free(hostile);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.UntrustedElectrobunArtifactUrl,
        parseArtifactIndex(
            arena.allocator(),
            hostile,
            base_url,
            version,
            try platformKey(),
        ),
    );
}

test "Electrobun artifact indexes reject unsupported ABI identities before download" {
    const allocator = std.testing.allocator;
    const base_url = "https://releases.example.test";
    const version = "2.0.0";
    const valid = try validIndexJson(allocator, base_url, version);
    defer allocator.free(valid);
    const unsupported = try std.mem.replaceOwned(
        u8,
        allocator,
        valid,
        "\"core\": {\"name\":\"electrobun-core\",\"version\":1}",
        "\"core\": {\"name\":\"electrobun-core\",\"version\":2}",
    );
    defer allocator.free(unsupported);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.UnsupportedElectrobunCoreAbi,
        parseArtifactIndex(
            arena.allocator(),
            unsupported,
            base_url,
            version,
            try platformKey(),
        ),
    );
}

test "Electrobun artifact archives must match both declared size and SHA-256" {
    const bytes = "core";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const checksum = std.fmt.bytesToHex(digest, .lower);
    try validateArchiveBytes(.{
        .url = "https://releases.example.test/core.tar.gz",
        .sha256 = &checksum,
        .size = bytes.len,
    }, bytes);
    try std.testing.expectError(
        error.ElectrobunArtifactSizeMismatch,
        validateArchiveBytes(.{
            .url = "https://releases.example.test/core.tar.gz",
            .sha256 = &checksum,
            .size = bytes.len + 1,
        }, bytes),
    );
    try std.testing.expectError(
        error.ElectrobunArtifactChecksumMismatch,
        validateArchiveBytes(.{
            .url = "https://releases.example.test/core.tar.gz",
            .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            .size = bytes.len,
        }, bytes),
    );
}

test "Electrobun index URLs and versions cannot escape the shared cache" {
    const url = try artifactIndexUrl(
        std.testing.allocator,
        "https://releases.example.test",
        "2.0.0-beta.17",
    );
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://releases.example.test/v2.0.0-beta.17/electrobun-artifacts.json",
        url,
    );
    try validateVersion("2.0.0-beta.17");
    try std.testing.expectError(error.InvalidElectrobunVersion, validateVersion("."));
    try std.testing.expectError(error.InvalidElectrobunVersion, validateVersion(".."));
    try std.testing.expectError(error.InvalidElectrobunVersion, validateVersion("../../other"));
    try std.testing.expectError(error.InvalidElectrobunVersion, validateVersion("2.0.0/path"));
}
