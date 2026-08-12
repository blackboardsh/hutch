const std = @import("std");
const builtin = @import("builtin");
const archive_util = @import("archive.zig");
const version_selector = @import("version_selector.zig");

const default_hutch_artifacts_base_url = "https://hutch.blackboard.sh";
const default_cottontail_artifacts_base_url = "https://electrobun-artifacts.blackboard.sh";
const manifest_schema = 1;
const max_manifest_bytes = 1024 * 1024;
const max_archive_bytes = 256 * 1024 * 1024;
const channel_cache_lifetime_ns = 6 * std.time.ns_per_hour;

pub const Product = enum {
    hutch,
    cottontail,

    pub fn name(self: Product) []const u8 {
        return switch (self) {
            .hutch => "hutch",
            .cottontail => "cottontail",
        };
    }

    fn metadataFileName(self: Product) []const u8 {
        return switch (self) {
            .hutch => "hutch-release.json",
            .cottontail => "cottontail-release.json",
        };
    }

    pub fn executableFileName(self: Product) []const u8 {
        return switch (self) {
            .hutch => if (builtin.os.tag == .windows) "hutch-engine.exe" else "hutch-engine",
            .cottontail => if (builtin.os.tag == .windows) "cottontail.exe" else "cottontail",
        };
    }

    fn defaultArtifactsBaseUrl(self: Product) []const u8 {
        return switch (self) {
            .hutch => default_hutch_artifacts_base_url,
            .cottontail => default_cottontail_artifacts_base_url,
        };
    }
};

pub const Options = struct {
    refresh: bool = false,
    offline: bool = false,
};

pub const Resolution = struct {
    root: []const u8,
    executable: []const u8,
    version: []const u8,
    revision: []const u8,
    installed: bool,
};

pub const AvailableUpdate = struct {
    current_version: []const u8,
    current_revision: []const u8,
    version: []const u8,
    revision: []const u8,
};

const Artifact = struct {
    version: []const u8,
    revision: []const u8,
    archive_url: []const u8,
    sha256: []const u8,
    size: usize,
};

const ChannelManifest = struct {
    version: []const u8,
    revision: []const u8,
    release_url: []const u8,
};

/// A persistent sibling lock coordinates cache writers across Hutch processes.
/// The lock file intentionally remains in place so a newly starting process
/// can never race another process between lock-file creation and acquisition.
pub const PersistentFileLock = struct {
    file: std.Io.File,
    contended: bool,

    pub fn close(self: PersistentFileLock, io: std.Io) void {
        self.file.close(io);
    }
};

pub fn acquirePersistentFileLock(
    io: std.Io,
    lock_path: []const u8,
) !PersistentFileLock {
    const parent = std.fs.path.dirname(lock_path) orelse return error.InvalidCachePath;
    try std.Io.Dir.cwd().createDirPath(io, parent);

    const initializer: ?std.Io.File = std.Io.Dir.cwd().createFile(io, lock_path, .{
        .read = true,
        .truncate = false,
        .exclusive = true,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => null,
        else => return err,
    };
    if (initializer) |file| file.close(io);

    const open_options: std.Io.Dir.OpenFileOptions = .{
        .mode = .read_write,
        .lock = .exclusive,
        .follow_symlinks = false,
    };
    const file = std.Io.Dir.cwd().openFile(io, lock_path, .{
        .mode = open_options.mode,
        .lock = open_options.lock,
        .lock_nonblocking = true,
        .follow_symlinks = open_options.follow_symlinks,
    }) catch |err| switch (err) {
        error.WouldBlock => {
            if (builtin.os.tag == .windows) {
                const waiting_file = try std.Io.Dir.cwd().openFile(io, lock_path, .{
                    .mode = open_options.mode,
                    .follow_symlinks = open_options.follow_symlinks,
                });
                errdefer waiting_file.close(io);
                while (!try waiting_file.tryLock(io, .exclusive)) {
                    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake);
                }
                return .{ .file = waiting_file, .contended = true };
            }
            return .{
                .file = try std.Io.Dir.cwd().openFile(io, lock_path, open_options),
                .contended = true,
            };
        },
        else => return err,
    };
    return .{ .file = file, .contended = false };
}

pub fn acquireCacheFileLock(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !PersistentFileLock {
    const lock_path = try std.mem.concat(allocator, u8, &.{ path, ".lock" });
    defer allocator.free(lock_path);
    return acquirePersistentFileLock(io, lock_path);
}

pub fn resolve(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    product: Product,
    selector: version_selector.Selector,
    options: Options,
) !Resolution {
    const home = try hutchHome(init, allocator);
    if (!options.refresh) {
        if (try activeMatchingResolution(
            init.io,
            allocator,
            home,
            product,
            selector,
        )) |active| {
            return active;
        }
    }
    const base_url = try artifactsBaseUrl(init, allocator, product);
    const artifact = try resolveArtifact(init, allocator, home, base_url, product, selector, options);
    const platform = try platformKey();
    const root = try std.fs.path.join(allocator, &.{
        home,
        "products",
        product.name(),
        artifact.version,
        artifact.revision,
        platform,
    });
    const executable = try std.fs.path.join(allocator, &.{
        root,
        "bin",
        product.executableFileName(),
    });

    if (try installationMatches(init.io, allocator, root, executable, artifact.sha256)) {
        const result: Resolution = .{
            .root = root,
            .executable = executable,
            .version = artifact.version,
            .revision = artifact.revision,
            .installed = false,
        };
        if (selector.channel()) |channel| {
            try activateChannel(init, allocator, product, channel, result);
        }
        return result;
    }

    try installArtifact(init, allocator, product, artifact, platform, root, executable);
    const result: Resolution = .{
        .root = root,
        .executable = executable,
        .version = artifact.version,
        .revision = artifact.revision,
        .installed = true,
    };
    if (selector.channel()) |channel| {
        try activateChannel(init, allocator, product, channel, result);
    }
    return result;
}

fn activeMatchingResolution(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    product: Product,
    selector: version_selector.Selector,
) !?Resolution {
    if (selector.channel()) |channel| {
        return activeResolution(io, allocator, home, product, channel);
    }

    for ([_][]const u8{ "production", "canary" }) |channel| {
        const active = (try activeResolution(
            io,
            allocator,
            home,
            product,
            channel,
        )) orelse continue;
        const matches = switch (selector.kind) {
            .version => std.mem.eql(u8, active.version, selector.value),
            .build => std.mem.eql(u8, active.revision, selector.value),
            .production, .canary => unreachable,
        };
        if (matches) return active;
    }
    return null;
}

pub fn activateChannel(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    product: Product,
    channel: []const u8,
    resolution: Resolution,
) !void {
    if (!std.mem.eql(u8, channel, "production") and !std.mem.eql(u8, channel, "canary")) {
        return error.InvalidReleaseChannel;
    }
    const home = try hutchHome(init, allocator);
    const pointer = try std.fs.path.join(allocator, &.{
        home,
        "channels",
        product.name(),
        channel,
    });
    const contents = try std.mem.concat(allocator, u8, &.{ resolution.root, "\n" });
    try writeCacheFile(init.io, allocator, pointer, contents);
}

pub fn checkForUpdate(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    product: Product,
    channel: []const u8,
) !?AvailableUpdate {
    if (!std.mem.eql(u8, channel, "production") and !std.mem.eql(u8, channel, "canary")) {
        return error.InvalidReleaseChannel;
    }
    const home = try hutchHome(init, allocator);
    const current = (try activeResolution(
        init.io,
        allocator,
        home,
        product,
        channel,
    )) orelse return null;
    const base_url = try artifactsBaseUrl(init, allocator, product);
    const selector = try version_selector.parse(channel);
    const channel_url = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}/channels/{s}.json",
        .{ base_url, product.name(), channel },
    );
    const bytes = try readManifest(
        init,
        allocator,
        home,
        base_url,
        product,
        selector,
        channel_url,
        .{},
    );
    const available = try parseChannelManifest(
        allocator,
        bytes,
        base_url,
        product,
        channel,
    );
    if (std.mem.eql(u8, current.revision, available.revision)) return null;
    if (try updateIsSkipped(
        init.io,
        allocator,
        home,
        product,
        channel,
        available.revision,
    )) return null;
    return .{
        .current_version = current.version,
        .current_revision = current.revision,
        .version = available.version,
        .revision = available.revision,
    };
}

pub fn skipUpdate(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    product: Product,
    channel: []const u8,
    revision: []const u8,
) !void {
    try validateRevision(revision);
    const home = try hutchHome(init, allocator);
    const path = try updateSkipPath(allocator, home, product, channel);
    const contents = try std.mem.concat(allocator, u8, &.{ revision, "\n" });
    try writeCacheFile(init.io, allocator, path, contents);
}

/// Which rule produced the resolved Hutch home. Diagnostic commands report
/// this so an unexpected store location is always attributable.
pub const HomeSource = enum {
    hutch_home,
    dash_home,
    default_home,

    /// The environment variable that selected the home, or `null` when the
    /// default `~/.hutch` path was used.
    pub fn environmentVariable(self: HomeSource) ?[]const u8 {
        return switch (self) {
            .hutch_home => "HUTCH_HOME",
            .dash_home => "DASH_HOME",
            .default_home => null,
        };
    }

    pub fn label(self: HomeSource) []const u8 {
        return self.environmentVariable() orelse "default";
    }

    pub fn deprecated(self: HomeSource) bool {
        return self == .dash_home;
    }
};

pub const ResolvedHome = struct {
    path: []const u8,
    source: HomeSource,
};

/// Resolves Hutch's home directory.
///
/// Resolution order:
///   1. `HUTCH_HOME`
///   2. `DASH_HOME` (deprecated fallback, kept so existing installs and the
///      separate Dash Desktop product keep working)
///   3. `~/.hutch` (`HOME`, or `USERPROFILE` on Windows)
pub fn hutchHome(init: std.process.Init, allocator: std.mem.Allocator) ![]const u8 {
    return hutchHomeFromEnviron(init.environ_map, allocator);
}

/// Same resolution as `hutchHome`, additionally reporting which rule applied.
pub fn resolveHutchHome(
    init: std.process.Init,
    allocator: std.mem.Allocator,
) !ResolvedHome {
    return resolveHutchHomeFromEnviron(init.environ_map, allocator);
}

fn hutchHomeFromEnviron(
    environ_map: *const std.process.Environ.Map,
    allocator: std.mem.Allocator,
) ![]const u8 {
    return (try resolveHutchHomeFromEnviron(environ_map, allocator)).path;
}

fn resolveHutchHomeFromEnviron(
    environ_map: *const std.process.Environ.Map,
    allocator: std.mem.Allocator,
) !ResolvedHome {
    if (environ_map.get("HUTCH_HOME")) |home| {
        if (home.len == 0) return error.InvalidHutchHome;
        return .{ .path = try allocator.dupe(u8, home), .source = .hutch_home };
    }
    if (environ_map.get("DASH_HOME")) |home| {
        if (home.len == 0) return error.InvalidHutchHome;
        return .{ .path = try allocator.dupe(u8, home), .source = .dash_home };
    }
    if (environ_map.get("HOME")) |home| {
        return .{
            .path = try std.fs.path.join(allocator, &.{ home, ".hutch" }),
            .source = .default_home,
        };
    }
    if (builtin.os.tag == .windows) {
        if (environ_map.get("USERPROFILE")) |home| {
            return .{
                .path = try std.fs.path.join(allocator, &.{ home, ".hutch" }),
                .source = .default_home,
            };
        }
    }
    return error.MissingHomeDirectory;
}

test "the resolved home reports the rule that selected it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("HOME", "/users/example");

    const default_home = try resolveHutchHomeFromEnviron(&environ_map, allocator);
    try std.testing.expectEqual(HomeSource.default_home, default_home.source);
    try std.testing.expectEqualStrings("default", default_home.source.label());
    try std.testing.expect(default_home.source.environmentVariable() == null);
    try std.testing.expect(!default_home.source.deprecated());

    try environ_map.put("DASH_HOME", "/legacy/dash");
    const legacy = try resolveHutchHomeFromEnviron(&environ_map, allocator);
    try std.testing.expectEqual(HomeSource.dash_home, legacy.source);
    try std.testing.expectEqualStrings("/legacy/dash", legacy.path);
    try std.testing.expectEqualStrings("DASH_HOME", legacy.source.label());
    try std.testing.expect(legacy.source.deprecated());

    try environ_map.put("HUTCH_HOME", "/explicit/hutch");
    const explicit = try resolveHutchHomeFromEnviron(&environ_map, allocator);
    try std.testing.expectEqual(HomeSource.hutch_home, explicit.source);
    try std.testing.expectEqualStrings("/explicit/hutch", explicit.path);
    try std.testing.expectEqualStrings("HUTCH_HOME", explicit.source.label());
    try std.testing.expect(!explicit.source.deprecated());
}

test "HUTCH_HOME wins over the deprecated DASH_HOME fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("HOME", "/users/example");
    try environ_map.put("DASH_HOME", "/legacy/dash");
    try environ_map.put("HUTCH_HOME", "/explicit/hutch");

    try std.testing.expectEqualStrings(
        "/explicit/hutch",
        try hutchHomeFromEnviron(&environ_map, allocator),
    );
}

test "DASH_HOME remains a fallback when HUTCH_HOME is unset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("HOME", "/users/example");
    try environ_map.put("DASH_HOME", "/legacy/dash");

    try std.testing.expectEqualStrings(
        "/legacy/dash",
        try hutchHomeFromEnviron(&environ_map, allocator),
    );
}

test "the default home is ~/.hutch when no override is set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("HOME", "/users/example");

    try std.testing.expectEqualStrings(
        try std.fs.path.join(allocator, &.{ "/users/example", ".hutch" }),
        try hutchHomeFromEnviron(&environ_map, allocator),
    );
}

test "an empty home override is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("HOME", "/users/example");

    try environ_map.put("DASH_HOME", "");
    try std.testing.expectError(
        error.InvalidHutchHome,
        hutchHomeFromEnviron(&environ_map, allocator),
    );

    try environ_map.put("HUTCH_HOME", "");
    try std.testing.expectError(
        error.InvalidHutchHome,
        hutchHomeFromEnviron(&environ_map, allocator),
    );
}

test "a missing home directory has no fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();

    try std.testing.expectError(
        error.MissingHomeDirectory,
        hutchHomeFromEnviron(&environ_map, allocator),
    );
}

pub fn platformKey() ![]const u8 {
    return switch (builtin.os.tag) {
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => "macos-arm64",
            else => error.UnsupportedReleasePlatform,
        },
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => "linux-x64",
            .aarch64 => "linux-arm64",
            else => error.UnsupportedReleasePlatform,
        },
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => "windows-x64",
            else => error.UnsupportedReleasePlatform,
        },
        else => error.UnsupportedReleasePlatform,
    };
}

fn artifactsBaseUrl(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    product: Product,
) ![]const u8 {
    const configured = init.environ_map.get("DASH_ARTIFACTS_BASE_URL") orelse
        product.defaultArtifactsBaseUrl();
    const trimmed = std.mem.trimEnd(u8, configured, "/");
    if (!std.mem.startsWith(u8, trimmed, "https://") and
        !std.mem.startsWith(u8, trimmed, "http://127.0.0.1") and
        !std.mem.startsWith(u8, trimmed, "http://localhost"))
    {
        return error.InvalidArtifactsBaseUrl;
    }
    return allocator.dupe(u8, trimmed);
}

test "products use their canonical artifact origins by default" {
    try std.testing.expectEqualStrings(
        "https://hutch.blackboard.sh",
        Product.hutch.defaultArtifactsBaseUrl(),
    );
    try std.testing.expectEqualStrings(
        "https://electrobun-artifacts.blackboard.sh",
        Product.cottontail.defaultArtifactsBaseUrl(),
    );
}

fn activeResolution(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    product: Product,
    channel: []const u8,
) !?Resolution {
    const pointer = try std.fs.path.join(allocator, &.{
        home,
        "channels",
        product.name(),
        channel,
    });
    const pointer_bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        pointer,
        allocator,
        .limited(std.fs.max_path_bytes + 2),
    ) catch return null;
    const root_value = std.mem.trim(u8, pointer_bytes, " \t\r\n");
    if (root_value.len == 0 or !std.fs.path.isAbsolute(root_value)) return null;
    const root = try allocator.dupe(u8, root_value);
    const executable = try std.fs.path.join(allocator, &.{
        root,
        "bin",
        product.executableFileName(),
    });
    if (!pathExists(io, executable)) return null;

    const marker_path = try std.fs.path.join(allocator, &.{ root, ".dash-installed" });
    const marker = std.Io.Dir.cwd().readFileAlloc(
        io,
        marker_path,
        allocator,
        .limited(128),
    ) catch return null;
    validateSha256(std.mem.trim(u8, marker, " \t\r\n")) catch return null;

    const metadata_path = try std.fs.path.join(allocator, &.{
        root,
        product.metadataFileName(),
    });
    const metadata_bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        metadata_path,
        allocator,
        .limited(max_manifest_bytes),
    ) catch return null;
    const metadata = std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        metadata_bytes,
        .{ .duplicate_field_behavior = .@"error" },
    ) catch return null;
    const schema = jsonPositiveUsize(metadata, "schema") catch return null;
    if (schema != manifest_schema) return null;
    if (!std.mem.eql(u8, jsonString(metadata, "kind") catch return null, "archive")) return null;
    if (!std.mem.eql(u8, jsonString(metadata, "product") catch return null, product.name())) return null;
    if (!std.mem.eql(u8, jsonString(metadata, "channel") catch return null, channel)) return null;
    const version = jsonString(metadata, "version") catch return null;
    const revision = jsonString(metadata, "revision") catch return null;
    const platform = jsonString(metadata, "platform") catch return null;
    _ = version_selector.parse(version) catch return null;
    validateRevision(revision) catch return null;
    if (!std.mem.eql(u8, platform, platformKey() catch return null)) return null;

    return .{
        .root = root,
        .executable = executable,
        .version = version,
        .revision = revision,
        .installed = false,
    };
}

fn resolveArtifact(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    home: []const u8,
    base_url: []const u8,
    product: Product,
    selector: version_selector.Selector,
    options: Options,
) !Artifact {
    const artifact_manifest_url = switch (selector.kind) {
        .production, .canary => blk: {
            const channel = selector.channel().?;
            const channel_url = try std.fmt.allocPrint(
                allocator,
                "{s}/{s}/channels/{s}.json",
                .{ base_url, product.name(), channel },
            );
            const channel_bytes = try readManifest(
                init,
                allocator,
                home,
                base_url,
                product,
                selector,
                channel_url,
                options,
            );
            const channel_manifest = try parseChannelManifest(
                allocator,
                channel_bytes,
                base_url,
                product,
                channel,
            );
            break :blk channel_manifest.release_url;
        },
        .version => try std.fmt.allocPrint(
            allocator,
            "{s}/{s}/releases/{s}/manifest.json",
            .{ base_url, product.name(), selector.value },
        ),
        .build => try std.fmt.allocPrint(
            allocator,
            "{s}/{s}/builds/{s}/manifest.json",
            .{ base_url, product.name(), selector.value },
        ),
    };

    const manifest_selector: version_selector.Selector = switch (selector.kind) {
        .production, .canary => .{ .kind = .version, .value = artifact_manifest_url },
        else => selector,
    };
    const manifest_bytes = if (selector.kind == .production or selector.kind == .canary)
        try fetchAndCacheReleaseManifest(
            init,
            allocator,
            home,
            base_url,
            product,
            artifact_manifest_url,
            options,
        )
    else
        try readManifest(
            init,
            allocator,
            home,
            base_url,
            product,
            manifest_selector,
            artifact_manifest_url,
            options,
        );
    const artifact = try parseArtifactManifest(
        allocator,
        manifest_bytes,
        base_url,
        product,
        try platformKey(),
    );

    switch (selector.kind) {
        .version => if (!std.mem.eql(u8, selector.value, artifact.version)) {
            return error.ReleaseVersionMismatch;
        },
        .build => if (!std.mem.eql(u8, selector.value, artifact.revision)) {
            return error.ReleaseRevisionMismatch;
        },
        .production, .canary => {},
    }
    return artifact;
}

fn readManifest(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    home: []const u8,
    base_url: []const u8,
    product: Product,
    selector: version_selector.Selector,
    url: []const u8,
    options: Options,
) ![]const u8 {
    const cache_path = try manifestCachePath(allocator, home, product, selector);
    const cache_lock = try acquireCacheFileLock(init.io, allocator, cache_path);
    defer cache_lock.close(init.io);

    // Re-read only after acquiring the persistent per-path lock. A concurrent
    // cold resolver may have populated this exact cache while we waited.
    const cached = std.Io.Dir.cwd().readFileAlloc(
        init.io,
        cache_path,
        allocator,
        .limited(max_manifest_bytes),
    ) catch null;
    const cached_is_valid = if (cached) |bytes|
        cachedManifestMatches(allocator, bytes, base_url, product, selector)
    else
        false;

    const cache_is_current = if (cached_is_valid and !options.refresh) switch (selector.kind) {
        .production, .canary => manifestCacheIsCurrent(init.io, cache_path),
        .version, .build => true,
    } else false;
    if (cache_is_current) return cached.?;
    if (options.offline) {
        if (cached_is_valid) return cached.?;
        return if (cached == null)
            error.ReleaseManifestNotCached
        else
            error.ReleaseManifestCacheInvalid;
    }

    const downloaded = fetchBytes(init, allocator, url, max_manifest_bytes) catch |err| {
        if (cached_is_valid) return cached.?;
        return err;
    };
    // Do not publish malformed or mismatched responses into the shared cache.
    // The caller still parses the response and returns its specific contract
    // error, but a later offline resolver cannot mistake it for a cache hit.
    if (cachedManifestMatches(allocator, downloaded, base_url, product, selector)) {
        try writeCacheFileLocked(init.io, cache_path, downloaded);
    }
    return downloaded;
}

fn cachedManifestMatches(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    base_url: []const u8,
    product: Product,
    selector: version_selector.Selector,
) bool {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        bytes,
        .{ .duplicate_field_behavior = .@"error" },
    ) catch return false;
    defer parsed.deinit();
    const root = parsed.value;
    if ((jsonPositiveUsize(root, "schema") catch return false) != manifest_schema) return false;
    if (!std.mem.eql(u8, jsonString(root, "product") catch return false, product.name())) return false;

    const kind = jsonString(root, "kind") catch return false;
    return switch (selector.kind) {
        .production, .canary => blk: {
            if (!std.mem.eql(u8, kind, "channel")) break :blk false;
            _ = parseChannelManifest(
                allocator,
                bytes,
                base_url,
                product,
                selector.channel().?,
            ) catch break :blk false;
            break :blk true;
        },
        .version, .build => blk: {
            const expected_kind = if (selector.kind == .version) "release" else "build";
            if (!std.mem.eql(u8, kind, expected_kind)) break :blk false;
            const artifact = parseArtifactManifest(
                allocator,
                bytes,
                base_url,
                product,
                platformKey() catch break :blk false,
            ) catch break :blk false;
            break :blk if (selector.kind == .version)
                std.mem.eql(u8, artifact.version, selector.value)
            else
                std.mem.eql(u8, artifact.revision, selector.value);
        },
    };
}

fn fetchAndCacheReleaseManifest(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    home: []const u8,
    base_url: []const u8,
    product: Product,
    url: []const u8,
    options: Options,
) ![]const u8 {
    try validateProductUrl(allocator, base_url, product, url);
    const version = releaseVersionFromUrl(url) orelse return error.InvalidReleaseManifestUrl;
    const selector = try version_selector.parse(version);
    if (selector.kind != .version) return error.InvalidReleaseManifestUrl;
    return readManifest(init, allocator, home, base_url, product, selector, url, options);
}

fn manifestCachePath(
    allocator: std.mem.Allocator,
    home: []const u8,
    product: Product,
    selector: version_selector.Selector,
) ![]const u8 {
    const section = switch (selector.kind) {
        .production, .canary => "channels",
        .version => "releases",
        .build => "builds",
    };
    const name = switch (selector.kind) {
        .production => "production",
        .canary => "canary",
        .version, .build => selector.value,
    };
    return std.fs.path.join(allocator, &.{
        home,
        "cache",
        product.name(),
        section,
        try std.mem.concat(allocator, u8, &.{ name, ".json" }),
    });
}

fn manifestCacheIsCurrent(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    const now = std.Io.Clock.real.now(io).nanoseconds;
    if (now < stat.mtime.nanoseconds) return false;
    return now - stat.mtime.nanoseconds <= channel_cache_lifetime_ns;
}

pub fn writeCacheFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    bytes: []const u8,
) !void {
    const cache_lock = try acquireCacheFileLock(io, allocator, path);
    defer cache_lock.close(io);
    return writeCacheFileLocked(io, path, bytes);
}

/// Atomically publishes a cache file while the caller holds its persistent
/// `<path>.lock` lock. The temporary file is unique and lives beside the final
/// path, so independent cache keys do not collide and replacement is atomic.
pub fn writeCacheFileLocked(
    io: std.Io,
    path: []const u8,
    bytes: []const u8,
) !void {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidCachePath;
    try std.Io.Dir.cwd().createDirPath(io, parent);

    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic_file.deinit(io);

    var write_buffer: [64 * 1024]u8 = undefined;
    var writer = atomic_file.file.writer(io, &write_buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    try atomic_file.file.sync(io);
    try atomic_file.replace(io);
}

pub fn fetchBytes(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    url: []const u8,
    max_bytes: usize,
) ![]const u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = init.io };
    defer client.deinit();
    client.initDefaultProxies(allocator, init.environ_map) catch {};

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &output.writer,
        .keep_alive = builtin.os.tag != .windows,
    });
    const status: u16 = @intFromEnum(result.status);
    if (status < 200 or status >= 300) return error.ReleaseDownloadFailed;
    if (output.written().len > max_bytes) return error.ReleaseDownloadTooLarge;
    return output.toOwnedSlice();
}

fn parseChannelManifest(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    base_url: []const u8,
    product: Product,
    channel: []const u8,
) !ChannelManifest {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
    });
    try validateManifestBase(root, "channel", product);
    if (!std.mem.eql(u8, try jsonString(root, "channel"), channel)) {
        return error.ReleaseChannelMismatch;
    }
    const version = try jsonString(root, "version");
    _ = try version_selector.parse(version);
    const revision = try jsonString(root, "revision");
    try validateRevision(revision);
    const release = try jsonObject(root, "release");
    const url = try jsonString(release, "url");
    try validateProductUrl(allocator, base_url, product, url);
    return .{
        .version = version,
        .revision = revision,
        .release_url = url,
    };
}

fn updateSkipPath(
    allocator: std.mem.Allocator,
    home: []const u8,
    product: Product,
    channel: []const u8,
) ![]const u8 {
    return std.fs.path.join(allocator, &.{
        home,
        "update-skip",
        product.name(),
        channel,
    });
}

fn updateIsSkipped(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    product: Product,
    channel: []const u8,
    revision: []const u8,
) !bool {
    const path = try updateSkipPath(allocator, home, product, channel);
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(128),
    ) catch return false;
    return std.mem.eql(u8, std.mem.trim(u8, bytes, " \t\r\n"), revision);
}

fn parseArtifactManifest(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    base_url: []const u8,
    product: Product,
    platform: []const u8,
) !Artifact {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
    });
    const kind = try jsonString(root, "kind");
    if (!std.mem.eql(u8, kind, "release") and !std.mem.eql(u8, kind, "build")) {
        return error.InvalidReleaseManifestKind;
    }
    try validateManifestBase(root, kind, product);
    const version = try jsonString(root, "version");
    const parsed_version = try version_selector.parse(version);
    if (parsed_version.kind != .version) return error.InvalidReleaseVersion;
    const revision = try jsonString(root, "revision");
    try validateRevision(revision);

    const platforms = try jsonObject(root, "platforms");
    const platform_value = platforms.object.get(platform) orelse return error.ReleasePlatformMissing;
    if (platform_value != .object) return error.InvalidReleaseManifest;
    const archive = try jsonObject(platform_value, "archive");
    const url = try jsonString(archive, "url");
    try validateProductUrl(allocator, base_url, product, url);
    const checksum = try jsonString(archive, "sha256");
    try validateSha256(checksum);
    const size = try jsonPositiveUsize(archive, "size");
    if (size > max_archive_bytes) return error.ReleaseArchiveTooLarge;

    return .{
        .version = version,
        .revision = revision,
        .archive_url = url,
        .sha256 = checksum,
        .size = size,
    };
}

fn validateManifestBase(root: std.json.Value, kind: []const u8, product: Product) !void {
    if (try jsonPositiveUsize(root, "schema") != manifest_schema) {
        return error.UnsupportedReleaseManifestSchema;
    }
    if (!std.mem.eql(u8, try jsonString(root, "kind"), kind)) {
        return error.InvalidReleaseManifestKind;
    }
    if (!std.mem.eql(u8, try jsonString(root, "product"), product.name())) {
        return error.ReleaseProductMismatch;
    }
}

fn validateProductUrl(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    product: Product,
    url: []const u8,
) !void {
    const prefix_value = try std.fmt.allocPrint(allocator, "{s}/{s}/", .{ base_url, product.name() });
    if (!std.mem.startsWith(u8, url, prefix_value)) return error.UntrustedReleaseUrl;
}

fn releaseVersionFromUrl(url: []const u8) ?[]const u8 {
    const marker = "/releases/";
    const start = (std.mem.indexOf(u8, url, marker) orelse return null) + marker.len;
    const end = std.mem.indexOfPos(u8, url, start, "/manifest.json") orelse return null;
    if (end + "/manifest.json".len != url.len or end == start) return null;
    return url[start..end];
}

fn validateRevision(revision: []const u8) !void {
    if (revision.len != 40 and revision.len != 64) return error.InvalidReleaseRevision;
    for (revision) |byte| {
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) {
            return error.InvalidReleaseRevision;
        }
    }
}

fn validateSha256(value: []const u8) !void {
    if (value.len != 64) return error.InvalidReleaseChecksum;
    for (value) |byte| {
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) {
            return error.InvalidReleaseChecksum;
        }
    }
}

fn jsonObject(value: std.json.Value, name: []const u8) !std.json.Value {
    if (value != .object) return error.InvalidReleaseManifest;
    const field = value.object.get(name) orelse return error.InvalidReleaseManifest;
    if (field != .object) return error.InvalidReleaseManifest;
    return field;
}

fn jsonString(value: std.json.Value, name: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidReleaseManifest;
    const field = value.object.get(name) orelse return error.InvalidReleaseManifest;
    if (field != .string) return error.InvalidReleaseManifest;
    return field.string;
}

fn jsonPositiveUsize(value: std.json.Value, name: []const u8) !usize {
    if (value != .object) return error.InvalidReleaseManifest;
    const field = value.object.get(name) orelse return error.InvalidReleaseManifest;
    if (field != .integer or field.integer <= 0) return error.InvalidReleaseManifest;
    return std.math.cast(usize, field.integer) orelse error.InvalidReleaseManifest;
}

fn installArtifact(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    product: Product,
    artifact: Artifact,
    platform: []const u8,
    root: []const u8,
    executable: []const u8,
) !void {
    const parent = std.fs.path.dirname(root) orelse return error.InvalidInstallPath;
    try std.Io.Dir.cwd().createDirPath(init.io, parent);
    const lock_path = try std.mem.concat(allocator, u8, &.{ root, ".lock" });
    const lock = try acquirePersistentFileLock(init.io, lock_path);
    defer lock.close(init.io);

    if (try installationMatches(init.io, allocator, root, executable, artifact.sha256)) return;

    std.debug.print(
        "hutch: downloading {s} {s} for {s}\n",
        .{ product.name(), artifact.version, platform },
    );
    const archive = try fetchBytes(init, allocator, artifact.archive_url, max_archive_bytes);
    if (archive.len != artifact.size) return error.ReleaseArchiveSizeMismatch;
    if (!sha256Matches(archive, artifact.sha256)) return error.ReleaseArchiveChecksumMismatch;

    const temporary = try std.mem.concat(allocator, u8, &.{ root, ".tmp" });
    std.Io.Dir.cwd().deleteTree(init.io, temporary) catch {};
    try std.Io.Dir.cwd().createDirPath(init.io, temporary);
    errdefer std.Io.Dir.cwd().deleteTree(init.io, temporary) catch {};

    {
        var destination = try std.Io.Dir.cwd().openDir(init.io, temporary, .{});
        defer destination.close(init.io);
        try archive_util.extractTarGzip(init.io, allocator, destination, archive, .{
            .strip_components = 1,
        });
    }
    try validateArchiveMetadata(init.io, allocator, temporary, product, artifact, platform);

    const temporary_executable = try std.fs.path.join(allocator, &.{
        temporary,
        "bin",
        product.executableFileName(),
    });
    if (!pathExists(init.io, temporary_executable)) return error.ReleaseExecutableMissing;
    const marker = try std.fs.path.join(allocator, &.{ temporary, ".dash-installed" });
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = marker,
        .data = artifact.sha256,
    });

    std.Io.Dir.cwd().deleteTree(init.io, root) catch {};
    try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), root, init.io);
}

fn installationMatches(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    executable: []const u8,
    checksum: []const u8,
) !bool {
    if (!pathExists(io, executable)) return false;
    const marker = try std.fs.path.join(allocator, &.{ root, ".dash-installed" });
    const contents = std.Io.Dir.cwd().readFileAlloc(
        io,
        marker,
        allocator,
        .limited(128),
    ) catch return false;
    return std.mem.eql(u8, contents, checksum);
}

fn validateArchiveMetadata(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    product: Product,
    artifact: Artifact,
    platform: []const u8,
) !void {
    const metadata_path = try std.fs.path.join(allocator, &.{
        root,
        product.metadataFileName(),
    });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        metadata_path,
        allocator,
        .limited(max_manifest_bytes),
    );
    const metadata = try std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
    });
    if (try jsonPositiveUsize(metadata, "schema") != manifest_schema) {
        return error.UnsupportedReleaseArchiveSchema;
    }
    if (!std.mem.eql(u8, try jsonString(metadata, "kind"), "archive")) {
        return error.InvalidReleaseArchive;
    }
    if (!std.mem.eql(u8, try jsonString(metadata, "product"), product.name())) {
        return error.ReleaseProductMismatch;
    }
    if (!std.mem.eql(u8, try jsonString(metadata, "version"), artifact.version)) {
        return error.ReleaseVersionMismatch;
    }
    if (!std.mem.eql(u8, try jsonString(metadata, "revision"), artifact.revision)) {
        return error.ReleaseRevisionMismatch;
    }
    if (!std.mem.eql(u8, try jsonString(metadata, "platform"), platform)) {
        return error.ReleasePlatformMismatch;
    }
}

pub fn sha256Matches(bytes: []const u8, expected: []const u8) bool {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);
    return std.mem.eql(u8, &actual, expected);
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

test "release manifests select and validate the current platform artifact" {
    const platform = try platformKey();
    const json = try std.fmt.allocPrint(
        std.testing.allocator,
        \\{{
        \\  "schema": 1,
        \\  "kind": "release",
        \\  "product": "cottontail",
        \\  "channel": "canary",
        \\  "version": "1.2.3-canary.4",
        \\  "revision": "0123456789abcdef0123456789abcdef01234567",
        \\  "platforms": {{
        \\    "{s}": {{
        \\      "archive": {{
        \\        "url": "https://artifacts.test/cottontail/builds/0123456789abcdef0123456789abcdef01234567/{s}/cottontail.tar.gz",
        \\        "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\        "size": 42
        \\      }}
        \\    }}
        \\  }}
        \\}}
    ,
        .{ platform, platform },
    );
    defer std.testing.allocator.free(json);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const artifact = try parseArtifactManifest(
        arena.allocator(),
        json,
        "https://artifacts.test",
        .cottontail,
        platform,
    );
    try std.testing.expectEqualStrings("1.2.3-canary.4", artifact.version);
    try std.testing.expectEqual(@as(usize, 42), artifact.size);
}

test "release manifests reject cross-product artifact URLs" {
    const platform = try platformKey();
    const json = try std.fmt.allocPrint(
        std.testing.allocator,
        \\{{"schema":1,"kind":"build","product":"cottontail","version":"1.0.0","revision":"0123456789abcdef0123456789abcdef01234567","platforms":{{"{s}":{{"archive":{{"url":"https://artifacts.test/hutch/builds/bad/archive.tar.gz","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":42}}}}}}}}
    ,
        .{platform},
    );
    defer std.testing.allocator.free(json);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.UntrustedReleaseUrl,
        parseArtifactManifest(
            arena.allocator(),
            json,
            "https://artifacts.test",
            .cottontail,
            platform,
        ),
    );
}

test "tar paths cannot escape the version store" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "bin/cottontail",
        buffer[0..try archive_util.sanitizeTarPath(&buffer, "root/bin/cottontail", 1)],
    );
    try std.testing.expectError(error.Invalid, archive_util.sanitizeTarPath(&buffer, "root/../escape", 1));
    try std.testing.expectError(error.Invalid, archive_util.sanitizeTarPath(&buffer, "/absolute", 1));
}
