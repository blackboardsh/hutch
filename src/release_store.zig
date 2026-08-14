const std = @import("std");
const builtin = @import("builtin");
const archive_util = @import("archive.zig");
const project_state = @import("project_state.zig");
const store_locks = @import("store_locks.zig");
const version_selector = @import("version_selector.zig");

const default_hutch_artifacts_base_url = "https://hutch.blackboard.sh";
const default_cottontail_artifacts_base_url = "https://electrobun-artifacts.blackboard.sh";
const manifest_schema = 1;
const max_manifest_bytes = 1024 * 1024;
const max_archive_bytes = 256 * 1024 * 1024;
const selections_schema_version = 1;
const max_selections_bytes = 64 * 1024;
const store_schema_version = 1;
const max_store_marker_bytes = 64 * 1024;
const update_check_interval_seconds: i64 = 6 * 60 * 60;

pub const releases_directory_name = "releases";
pub const state_directory_name = "state";
pub const selections_file_name = "selections.json";
pub const store_marker_file_name = "store.json";
pub const store_lock_file_name = "store.lock";

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
    archive_sha256: []const u8,
    installed: bool,
};

/// A validated managed release together with the shared sibling lock that
/// keeps it attached to the store while a caller uses it.
pub const LeasedResolution = struct {
    resolution: Resolution,
    lease: store_locks.ObjectLease,

    pub fn close(self: LeasedResolution, io: std.Io) void {
        self.lease.close(io);
    }
};

pub const AvailableUpdate = struct {
    current_version: []const u8,
    current_revision: []const u8,
    version: []const u8,
    revision: []const u8,
};

pub const Selection = struct {
    version: []const u8,
    revision: []const u8,
    platform: []const u8,
};

pub const Selections = struct {
    hutch_production: ?Selection = null,
    hutch_canary: ?Selection = null,
    cottontail_production: ?Selection = null,
    cottontail_canary: ?Selection = null,

    pub fn get(self: Selections, product: Product, channel: []const u8) ?Selection {
        if (std.mem.eql(u8, channel, "production")) return switch (product) {
            .hutch => self.hutch_production,
            .cottontail => self.cottontail_production,
        };
        if (std.mem.eql(u8, channel, "canary")) return switch (product) {
            .hutch => self.hutch_canary,
            .cottontail => self.cottontail_canary,
        };
        return null;
    }

    fn set(self: *Selections, product: Product, channel: []const u8, value: Selection) !void {
        if (std.mem.eql(u8, channel, "production")) switch (product) {
            .hutch => self.hutch_production = value,
            .cottontail => self.cottontail_production = value,
        } else if (std.mem.eql(u8, channel, "canary")) switch (product) {
            .hutch => self.hutch_canary = value,
            .cottontail => self.cottontail_canary = value,
        } else return error.InvalidReleaseChannel;
    }
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

/// A persistent sibling lock coordinates state writers across Hutch processes.
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
    const parent = std.fs.path.dirname(lock_path) orelse return error.InvalidStatePath;
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

fn acquirePersistentFileLockAt(
    io: std.Io,
    directory: std.Io.Dir,
    name: []const u8,
) !PersistentFileLock {
    const initializer: ?std.Io.File = directory.createFile(io, name, .{
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
    const file = directory.openFile(io, name, .{
        .mode = open_options.mode,
        .lock = open_options.lock,
        .lock_nonblocking = true,
        .follow_symlinks = open_options.follow_symlinks,
    }) catch |err| switch (err) {
        error.WouldBlock => {
            if (builtin.os.tag == .windows) {
                const waiting_file = try directory.openFile(io, name, .{
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
                .file = try directory.openFile(io, name, open_options),
                .contended = true,
            };
        },
        else => return err,
    };
    return .{ .file = file, .contended = false };
}

pub fn acquireFileLock(
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
    // Diagnostic and update callers historically receive a bare Resolution.
    // Keep its lease open for the short-lived Hutch process rather than
    // reintroducing a detach window after returning the path.
    const leased = try resolveLeased(init, allocator, product, selector, options);
    return leased.resolution;
}

pub fn resolveLeased(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    product: Product,
    selector: version_selector.Selector,
    options: Options,
) !LeasedResolution {
    const home = try hutchHome(init, allocator);
    const lifecycle = try store_locks.acquireGraph(init.io, allocator, home, .shared);
    defer lifecycle.close(init.io);

    const resolution = try resolveUnderGraph(
        init,
        allocator,
        home,
        product,
        selector,
        options,
    );
    return .{
        .resolution = resolution,
        .lease = try store_locks.acquireObjectLease(
            init.io,
            allocator,
            home,
            resolution.root,
        ),
    };
}

fn resolveUnderGraph(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    home: []const u8,
    product: Product,
    selector: version_selector.Selector,
    options: Options,
) !Resolution {
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
        if (try installedMatchingResolution(
            init.io,
            allocator,
            home,
            product,
            selector,
        )) |installed| {
            if (selector.channel()) |channel| {
                try activateChannel(init, allocator, product, channel, installed);
            }
            return installed;
        }
    }
    const base_url = try artifactsBaseUrl(init, allocator, product);
    const artifact = try resolveArtifact(init, allocator, base_url, product, selector, options);
    const platform = try platformKey();
    const root = try std.fs.path.join(allocator, &.{
        home,
        releases_directory_name,
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

    if (try installedArtifactResolution(
        init.io,
        allocator,
        root,
        product,
        artifact,
        platform,
    )) |result| {
        if (selector.channel()) |channel| {
            try activateChannel(init, allocator, product, channel, result);
        }
        return result;
    }

    try installArtifact(init, allocator, product, artifact, platform, root);
    const result: Resolution = .{
        .root = root,
        .executable = executable,
        .version = artifact.version,
        .revision = artifact.revision,
        .archive_sha256 = artifact.sha256,
        .installed = true,
    };
    if (selector.channel()) |channel| {
        try activateChannel(init, allocator, product, channel, result);
    }
    return result;
}

/// Returns a shared lease when `executable` is the validated engine of an
/// installed Hutch release. Paths genuinely outside the managed Hutch release
/// tree return null; a path that claims that tree but is malformed or damaged
/// is rejected instead of silently running without protection.
pub fn leaseInstalledHutchExecutable(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    executable: []const u8,
) !?store_locks.ObjectLease {
    const home = try hutchHome(init, allocator);
    if (!try executableClaimsManagedHutchTree(
        init.io,
        allocator,
        home,
        executable,
    )) return null;
    _ = loadStoreIdentityAt(init.io, allocator, home) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const graph = try store_locks.acquireGraph(init.io, allocator, home, .shared);
    defer graph.close(init.io);
    return leaseInstalledHutchExecutableUnderGraph(
        init.io,
        allocator,
        home,
        executable,
    );
}

fn executableClaimsManagedHutchTree(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    executable: []const u8,
) !bool {
    const canonical_cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    const lexical_home = try std.fs.path.resolve(allocator, &.{ canonical_cwd, home });
    const lexical_executable = try std.fs.path.resolve(allocator, &.{ canonical_cwd, executable });
    const product_root = try std.fs.path.join(allocator, &.{
        lexical_home,
        releases_directory_name,
        Product.hutch.name(),
    });
    return pathHasParent(lexical_executable, product_root);
}

fn leaseInstalledHutchExecutableUnderGraph(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    executable: []const u8,
) !?store_locks.ObjectLease {
    const canonical_cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    const lexical_home = try std.fs.path.resolve(allocator, &.{ canonical_cwd, home });
    const lexical_executable = try std.fs.path.resolve(allocator, &.{ canonical_cwd, executable });
    const product_root = try std.fs.path.join(allocator, &.{
        lexical_home,
        releases_directory_name,
        Product.hutch.name(),
    });
    if (!pathHasParent(lexical_executable, product_root)) return null;

    if (!pathEqual(std.fs.path.basename(lexical_executable), Product.hutch.executableFileName())) {
        return error.InvalidManagedHutchExecutable;
    }
    const bin_root = std.fs.path.dirname(lexical_executable) orelse
        return error.InvalidManagedHutchExecutable;
    if (!pathEqual(std.fs.path.basename(bin_root), "bin")) {
        return error.InvalidManagedHutchExecutable;
    }
    const release_root = std.fs.path.dirname(bin_root) orelse
        return error.InvalidManagedHutchExecutable;
    const platform = std.fs.path.basename(release_root);
    const revision_root = std.fs.path.dirname(release_root) orelse
        return error.InvalidManagedHutchExecutable;
    const revision = std.fs.path.basename(revision_root);
    const version_root = std.fs.path.dirname(revision_root) orelse
        return error.InvalidManagedHutchExecutable;
    const version = std.fs.path.basename(version_root);
    const actual_product_root = std.fs.path.dirname(version_root) orelse
        return error.InvalidManagedHutchExecutable;
    if (!pathEqual(product_root, actual_product_root)) {
        return error.InvalidManagedHutchExecutable;
    }

    const parsed_version = version_selector.parse(version) catch
        return error.InvalidManagedHutchExecutable;
    if (parsed_version.kind != .version) return error.InvalidManagedHutchExecutable;
    validateRevision(revision) catch return error.InvalidManagedHutchExecutable;
    validatePlatformName(platform) catch return error.InvalidManagedHutchExecutable;
    if (!std.mem.eql(u8, platform, platformKey() catch return error.InvalidManagedHutchExecutable)) {
        return error.InvalidManagedHutchExecutable;
    }

    const executable_stat = std.Io.Dir.cwd().statFile(io, lexical_executable, .{
        .follow_symlinks = false,
    }) catch return error.InvalidManagedHutchExecutable;
    if (executable_stat.kind != .file) return error.InvalidManagedHutchExecutable;

    const resolution = (installedResolutionAt(
        io,
        allocator,
        release_root,
        .hutch,
        version,
        revision,
        platform,
    ) catch return error.InvalidManagedHutchExecutable) orelse
        return error.InvalidManagedHutchExecutable;
    const canonical_input = std.Io.Dir.cwd().realPathFileAlloc(
        io,
        lexical_executable,
        allocator,
    ) catch return error.InvalidManagedHutchExecutable;
    const canonical_validated = std.Io.Dir.cwd().realPathFileAlloc(
        io,
        resolution.executable,
        allocator,
    ) catch return error.InvalidManagedHutchExecutable;
    if (!pathEqual(canonical_input, canonical_validated)) {
        return error.InvalidManagedHutchExecutable;
    }

    return store_locks.acquireObjectLease(io, allocator, lexical_home, release_root) catch
        return error.InvalidManagedHutchExecutable;
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
    try writeSelection(init.io, allocator, home, product, channel, .{
        .version = resolution.version,
        .revision = resolution.revision,
        .platform = try platformKey(),
    });
}

/// Publishes a freshly extracted Hutch archive and merges it into the selected
/// channel. Installers execute a temporary copy of the staged engine so the
/// engine, rather than shell or PowerShell, owns the graph/object transaction.
pub fn bootstrapInstalledHutch(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    channel_value: []const u8,
    staged_root: []const u8,
) !void {
    const home = try hutchHome(init, allocator);
    var forbidden_roots: [2][]const u8 = undefined;
    var forbidden_roots_len: usize = 0;
    for ([_][]const u8{ "HOME", "USERPROFILE" }) |name| {
        const value = init.environ_map.get(name) orelse continue;
        if (value.len == 0) continue;
        forbidden_roots[forbidden_roots_len] = value;
        forbidden_roots_len += 1;
    }
    try bootstrapInstalledHutchAt(
        init.io,
        allocator,
        home,
        channel_value,
        staged_root,
        forbidden_roots[0..forbidden_roots_len],
    );
}

const StagedHutchArchive = struct {
    canonical_root: []const u8,
    version: []const u8,
    revision: []const u8,
    platform: []const u8,
    archive_sha256: []const u8,
};

fn bootstrapInstalledHutchAt(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    channel_value: []const u8,
    staged_root: []const u8,
    forbidden_unmarked_roots: []const []const u8,
) !void {
    const channel = try version_selector.normalizeChannel(channel_value);
    const staged = try validateStagedHutchArchive(io, allocator, home, staged_root);
    const canonical_home = try std.Io.Dir.cwd().realPathFileAlloc(io, home, allocator);
    if (loadStoreIdentityAt(io, allocator, canonical_home)) |_| {} else |err| switch (err) {
        error.FileNotFound => try validateUnmarkedInstallerHome(
            io,
            allocator,
            home,
            canonical_home,
            staged,
            forbidden_unmarked_roots,
        ),
        else => return err,
    }
    // Existing selection state must parse before the explicit installer claims
    // or publishes anything. The locked writer below revalidates it again.
    _ = try loadSelectionsAt(io, allocator, canonical_home);
    _ = try ensureManagedHomeAt(io, allocator, canonical_home);
    const final_root = try std.fs.path.join(allocator, &.{
        canonical_home,
        releases_directory_name,
        Product.hutch.name(),
        staged.version,
        staged.revision,
        staged.platform,
    });

    const graph = try store_locks.acquireGraph(io, allocator, canonical_home, .shared);
    defer graph.close(io);
    const object_lock_path = try std.mem.concat(allocator, u8, &.{ final_root, ".lock" });
    try store_locks.initializePersistentFile(io, object_lock_path);
    const object_lock = (try store_locks.tryAcquireObjectExclusive(
        io,
        allocator,
        final_root,
    )) orelse return error.InstalledHutchReleaseBusy;
    defer object_lock.close(io);

    // Revalidate after waiting for all locks so a caller cannot swap or alter
    // the stage while publication is queued behind a prune or another install.
    const current_stage = try validateStagedHutchArchive(
        io,
        allocator,
        canonical_home,
        staged.canonical_root,
    );
    if (!sameHutchArchive(staged, current_stage)) return error.InstalledHutchStageChanged;

    var published = false;
    var detached_root: ?[]const u8 = null;
    errdefer {
        if (published) {
            std.Io.Dir.cwd().rename(final_root, std.Io.Dir.cwd(), staged.canonical_root, io) catch {};
        }
        if (detached_root) |detached| {
            std.Io.Dir.cwd().rename(detached, std.Io.Dir.cwd(), final_root, io) catch {};
        }
    }
    const final_stat: ?std.Io.File.Stat = std.Io.Dir.cwd().statFile(io, final_root, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    var reuse_final = false;
    if (final_stat) |stat| {
        if (stat.kind == .directory) {
            if (validateHutchArchiveRoot(io, allocator, final_root)) |installed| {
                reuse_final = sameHutchArchive(staged, installed);
            } else |_| {}
        }
        if (!reuse_final) {
            const detached = try replacementRootPath(io, allocator, final_root);
            std.Io.Dir.cwd().rename(final_root, std.Io.Dir.cwd(), detached, io) catch |err| switch (err) {
                error.AccessDenied, error.PermissionDenied, error.FileBusy => return error.InstalledHutchReleaseBusy,
                else => return err,
            };
            detached_root = detached;
        }
    }
    if (!reuse_final) {
        try std.Io.Dir.cwd().rename(staged.canonical_root, std.Io.Dir.cwd(), final_root, io);
        published = true;
        const installed = try validateHutchArchiveRoot(io, allocator, final_root);
        if (!sameHutchArchive(staged, installed)) return error.InstalledHutchPublishMismatch;
    }

    try writeSelection(io, allocator, canonical_home, .hutch, channel, .{
        .version = staged.version,
        .revision = staged.revision,
        .platform = staged.platform,
    });

    if (detached_root) |detached| {
        deleteDetachedHutchRoot(io, detached);
        detached_root = null;
    }
}

fn replacementRootPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    final_root: []const u8,
) ![]const u8 {
    const parent = std.fs.path.dirname(final_root) orelse return error.InvalidInstallPath;
    const platform = std.fs.path.basename(final_root);
    for (0..32) |_| {
        var random: [12]u8 = undefined;
        io.random(&random);
        const suffix = std.fmt.bytesToHex(random, .lower);
        const candidate = try std.fmt.allocPrint(
            allocator,
            "{s}/.hutch-replaced-{s}-{s}",
            .{ parent, platform, &suffix },
        );
        std.Io.Dir.cwd().access(io, candidate, .{}) catch |err| switch (err) {
            error.FileNotFound => return candidate,
            else => return err,
        };
    }
    return error.InstalledHutchReplacementNameCollision;
}

fn deleteDetachedHutchRoot(io: std.Io, path: []const u8) void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return;
    switch (stat.kind) {
        .directory => std.Io.Dir.cwd().deleteTree(io, path) catch {},
        else => std.Io.Dir.cwd().deleteFile(io, path) catch {},
    }
}

fn validateUnmarkedInstallerHome(
    io: std.Io,
    allocator: std.mem.Allocator,
    requested_home: []const u8,
    canonical_home: []const u8,
    staged: StagedHutchArchive,
    forbidden_roots: []const []const u8,
) !void {
    const requested_stat = try std.Io.Dir.cwd().statFile(io, requested_home, .{
        .follow_symlinks = false,
    });
    if (requested_stat.kind != .directory) return error.UnsafeUnmarkedHutchHome;
    const parent = std.fs.path.dirname(canonical_home) orelse return error.UnsafeUnmarkedHutchHome;
    if (pathEqual(parent, canonical_home)) return error.UnsafeUnmarkedHutchHome;
    for (forbidden_roots) |forbidden| {
        const canonical_forbidden = std.Io.Dir.cwd().realPathFileAlloc(
            io,
            forbidden,
            allocator,
        ) catch continue;
        if (pathEqual(canonical_home, canonical_forbidden)) {
            return error.UnsafeUnmarkedHutchHome;
        }
    }

    var home_dir = try std.Io.Dir.cwd().openDir(io, canonical_home, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer home_dir.close(io);
    var saw_releases = false;
    var iterator = home_dir.iterate();
    while (try iterator.next(io)) |entry| {
        const kind = try resolvedEntryKind(io, home_dir, entry);
        if (std.mem.eql(u8, entry.name, releases_directory_name)) {
            if (kind != .directory or saw_releases) return error.UnsafeUnmarkedHutchHome;
            saw_releases = true;
            try validateUnmarkedReleaseAncestry(io, allocator, canonical_home, staged);
        } else if (std.mem.eql(u8, entry.name, state_directory_name)) {
            if (kind != .directory) return error.UnsafeUnmarkedHutchHome;
            try validateUnmarkedStatePlumbing(io, allocator, canonical_home);
        } else {
            return error.UnsafeUnmarkedHutchHome;
        }
    }
    if (!saw_releases) return error.UnsafeUnmarkedHutchHome;
}

fn validateUnmarkedReleaseAncestry(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    staged: StagedHutchArchive,
) !void {
    const releases = try std.fs.path.join(allocator, &.{ home, releases_directory_name });
    try requireOnlyDirectoryChild(io, releases, Product.hutch.name());
    const product = try std.fs.path.join(allocator, &.{ releases, Product.hutch.name() });
    try requireOnlyDirectoryChild(io, product, staged.version);
    const version = try std.fs.path.join(allocator, &.{ product, staged.version });
    try requireOnlyDirectoryChild(io, version, staged.revision);
    const revision = try std.fs.path.join(allocator, &.{ version, staged.revision });

    const stage_prefix = try std.fmt.allocPrint(
        allocator,
        ".hutch-install-{s}-",
        .{staged.platform},
    );
    const object_lock_name = try std.fmt.allocPrint(allocator, "{s}.lock", .{staged.platform});
    var revision_dir = try std.Io.Dir.cwd().openDir(io, revision, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer revision_dir.close(io);
    var saw_stage = false;
    var iterator = revision_dir.iterate();
    while (try iterator.next(io)) |entry| {
        const kind = try resolvedEntryKind(io, revision_dir, entry);
        if (std.mem.startsWith(u8, entry.name, stage_prefix) and
            entry.name.len > stage_prefix.len)
        {
            if (kind != .directory) return error.UnsafeUnmarkedHutchHome;
            for (entry.name[stage_prefix.len..]) |byte| {
                if (!std.ascii.isAlphanumeric(byte)) return error.UnsafeUnmarkedHutchHome;
            }
            if (pathEqual(entry.name, std.fs.path.basename(staged.canonical_root))) {
                saw_stage = true;
            }
        } else if (std.mem.eql(u8, entry.name, object_lock_name)) {
            if (kind != .file) return error.UnsafeUnmarkedHutchHome;
        } else {
            return error.UnsafeUnmarkedHutchHome;
        }
    }
    if (!saw_stage) return error.UnsafeUnmarkedHutchHome;
}

fn validateUnmarkedStatePlumbing(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
) !void {
    const state = try std.fs.path.join(allocator, &.{ home, state_directory_name });
    try requireOnlyDirectoryChild(io, state, "locks");
    const locks = try std.fs.path.join(allocator, &.{ state, "locks" });
    var locks_dir = try std.Io.Dir.cwd().openDir(io, locks, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer locks_dir.close(io);
    var iterator = locks_dir.iterate();
    while (try iterator.next(io)) |entry| {
        const allowed = std.mem.eql(u8, entry.name, "graph.lock") or
            std.mem.eql(u8, entry.name, store_lock_file_name) or
            std.mem.eql(u8, entry.name, "selections.lock");
        if (!allowed or try resolvedEntryKind(io, locks_dir, entry) != .file) {
            return error.UnsafeUnmarkedHutchHome;
        }
    }
}

fn requireOnlyDirectoryChild(
    io: std.Io,
    parent: []const u8,
    expected_name: []const u8,
) !void {
    var directory = try std.Io.Dir.cwd().openDir(io, parent, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer directory.close(io);
    var found = false;
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (found or !std.mem.eql(u8, entry.name, expected_name) or
            try resolvedEntryKind(io, directory, entry) != .directory)
        {
            return error.UnsafeUnmarkedHutchHome;
        }
        found = true;
    }
    if (!found) return error.UnsafeUnmarkedHutchHome;
}

fn resolvedEntryKind(
    io: std.Io,
    directory: std.Io.Dir,
    entry: std.Io.Dir.Entry,
) !std.Io.File.Kind {
    if (entry.kind != .unknown) return entry.kind;
    return (try directory.statFile(io, entry.name, .{ .follow_symlinks = false })).kind;
}

fn sameHutchArchive(lhs: StagedHutchArchive, rhs: StagedHutchArchive) bool {
    return std.mem.eql(u8, lhs.version, rhs.version) and
        std.mem.eql(u8, lhs.revision, rhs.revision) and
        std.mem.eql(u8, lhs.platform, rhs.platform) and
        std.mem.eql(u8, lhs.archive_sha256, rhs.archive_sha256);
}

fn validateStagedHutchArchive(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    root: []const u8,
) !StagedHutchArchive {
    const archive = try validateHutchArchiveRoot(io, allocator, root);
    const canonical_home = try std.Io.Dir.cwd().realPathFileAlloc(io, home, allocator);
    const expected_parent = try std.fs.path.join(allocator, &.{
        canonical_home,
        releases_directory_name,
        Product.hutch.name(),
        archive.version,
        archive.revision,
    });
    const canonical_parent = try std.Io.Dir.cwd().realPathFileAlloc(io, expected_parent, allocator);
    const actual_parent = std.fs.path.dirname(archive.canonical_root) orelse
        return error.InvalidInstalledHutchStage;
    if (!pathEqual(actual_parent, canonical_parent)) return error.InvalidInstalledHutchStage;

    const name = std.fs.path.basename(archive.canonical_root);
    const prefix = try std.fmt.allocPrint(allocator, ".hutch-install-{s}-", .{archive.platform});
    if (!std.mem.startsWith(u8, name, prefix) or name.len == prefix.len) {
        return error.InvalidInstalledHutchStage;
    }
    for (name[prefix.len..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte)) return error.InvalidInstalledHutchStage;
    }
    return archive;
}

fn validateHutchArchiveRoot(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
) !StagedHutchArchive {
    const root_stat = try std.Io.Dir.cwd().statFile(io, root, .{ .follow_symlinks = false });
    if (root_stat.kind != .directory) return error.InvalidInstalledHutchArchive;
    try validateArchiveTree(io, allocator, root, 0);

    const canonical_root = try std.Io.Dir.cwd().realPathFileAlloc(io, root, allocator);
    const metadata_path = try std.fs.path.join(allocator, &.{ root, Product.hutch.metadataFileName() });
    const metadata_bytes = try readFileNoFollowAlloc(
        io,
        allocator,
        metadata_path,
        max_manifest_bytes,
    );
    const metadata = std.json.parseFromSliceLeaky(std.json.Value, allocator, metadata_bytes, .{
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidInstalledHutchArchive;
    if ((jsonPositiveUsize(metadata, "schema") catch return error.InvalidInstalledHutchArchive) != manifest_schema or
        !std.mem.eql(u8, jsonString(metadata, "kind") catch return error.InvalidInstalledHutchArchive, "archive") or
        !std.mem.eql(u8, jsonString(metadata, "product") catch return error.InvalidInstalledHutchArchive, Product.hutch.name()))
    {
        return error.InvalidInstalledHutchArchive;
    }
    const version = jsonString(metadata, "version") catch return error.InvalidInstalledHutchArchive;
    const parsed_version = version_selector.parse(version) catch return error.InvalidInstalledHutchArchive;
    if (parsed_version.kind != .version) return error.InvalidInstalledHutchArchive;
    const revision = jsonString(metadata, "revision") catch return error.InvalidInstalledHutchArchive;
    validateRevision(revision) catch return error.InvalidInstalledHutchArchive;
    const platform = jsonString(metadata, "platform") catch return error.InvalidInstalledHutchArchive;
    if (!std.mem.eql(u8, platform, platformKey() catch return error.InvalidInstalledHutchArchive)) {
        return error.ReleasePlatformMismatch;
    }

    const launcher_name = if (builtin.os.tag == .windows) "hutch.exe" else "hutch";
    const expected_launcher = try std.fmt.allocPrint(allocator, "bin/{s}", .{launcher_name});
    const expected_engine = try std.fmt.allocPrint(
        allocator,
        "bin/{s}",
        .{Product.hutch.executableFileName()},
    );
    if (!std.mem.eql(u8, jsonString(metadata, "launcher") catch return error.InvalidInstalledHutchArchive, expected_launcher) or
        !std.mem.eql(u8, jsonString(metadata, "executable") catch return error.InvalidInstalledHutchArchive, expected_engine))
    {
        return error.InvalidInstalledHutchArchive;
    }

    try requireNonEmptyRegularFile(io, try std.fs.path.join(allocator, &.{ root, "bin", launcher_name }));
    try requireNonEmptyRegularFile(io, try std.fs.path.join(allocator, &.{
        root,
        "bin",
        Product.hutch.executableFileName(),
    }));
    const marker_path = try std.fs.path.join(allocator, &.{ root, ".dash-installed" });
    const marker = try readFileNoFollowAlloc(io, allocator, marker_path, 128);
    if (marker.len != 64) return error.InvalidInstalledHutchArchive;
    validateSha256(marker) catch return error.InvalidInstalledHutchArchive;

    return .{
        .canonical_root = canonical_root,
        .version = version,
        .revision = revision,
        .platform = platform,
        .archive_sha256 = marker,
    };
}

fn validateArchiveTree(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    depth: usize,
) !void {
    if (depth >= 64) return error.InvalidInstalledHutchArchive;
    var directory = std.Io.Dir.cwd().openDir(io, root, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return error.InvalidInstalledHutchArchive;
    defer directory.close(io);
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        var kind = entry.kind;
        if (kind == .unknown) {
            kind = (try directory.statFile(io, entry.name, .{ .follow_symlinks = false })).kind;
        }
        switch (kind) {
            .file => {},
            .directory => {
                const child = try std.fs.path.join(allocator, &.{ root, entry.name });
                try validateArchiveTree(io, allocator, child, depth + 1);
            },
            else => return error.InvalidInstalledHutchArchive,
        }
    }
}

fn requireNonEmptyRegularFile(io: std.Io, path: []const u8) !void {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != .file or stat.size == 0) return error.InvalidInstalledHutchArchive;
}

fn readFileNoFollowAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{
        .allow_directory = false,
        .follow_symlinks = false,
    });
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemainingAlignedSentinel(
        allocator,
        .limited(max_bytes),
        .of(u8),
        null,
    ) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
}

pub fn checkForUpdate(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    product: Product,
    channel: []const u8,
) !?AvailableUpdate {
    if (environmentFlagEnabled(init.environ_map, "DASH_RELEASE_OFFLINE")) return null;
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
    const check_path = try updateCheckPath(allocator, home, product, channel);
    const check_lock = try acquireFileLock(init.io, allocator, check_path);
    defer check_lock.close(init.io);
    const now = unixSeconds(init.io);
    if (!try updateCheckDueAt(init.io, allocator, check_path, now)) return null;

    const base_url = try artifactsBaseUrl(init, allocator, product);
    const channel_url = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}/channels/{s}.json",
        .{ base_url, product.name(), channel },
    );
    const bytes = try fetchManifest(init, allocator, channel_url, .{});
    const available = try parseChannelManifest(
        allocator,
        bytes,
        base_url,
        product,
        channel,
    );
    const checked_at = try std.fmt.allocPrint(allocator, "{d}\n", .{now});
    try writeAtomicFileLocked(init.io, check_path, checked_at);
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
    try writeAtomicFile(init.io, allocator, path, contents);
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

pub const StoreIdentity = struct {
    canonical_root: []const u8,
};

pub fn ensureManagedHome(
    init: std.process.Init,
    allocator: std.mem.Allocator,
) !StoreIdentity {
    const home = try hutchHome(init, allocator);
    return ensureManagedHomeAt(init.io, allocator, home);
}

pub fn loadStoreIdentity(
    init: std.process.Init,
    allocator: std.mem.Allocator,
) !StoreIdentity {
    const home = try hutchHome(init, allocator);
    return loadStoreIdentityAt(init.io, allocator, home);
}

fn ensureManagedHomeAt(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
) !StoreIdentity {
    try std.Io.Dir.cwd().createDirPath(io, home);
    var root_directory = try openStoreRootNoFollow(io, home);
    defer root_directory.close(io);
    root_directory.createDir(io, state_directory_name, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var state_directory = try openStoreStateNoFollow(io, root_directory);
    defer state_directory.close(io);
    state_directory.createDir(io, "locks", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var locks_directory = try openStoreChildDirectoryNoFollow(
        io,
        state_directory,
        "locks",
        error.InvalidHutchStoreStatePath,
    );
    defer locks_directory.close(io);
    const lock = try acquirePersistentFileLockAt(io, locks_directory, store_lock_file_name);
    defer lock.close(io);

    if (loadStoreIdentityFromOpenDirectories(
        io,
        allocator,
        root_directory,
        state_directory,
    )) |identity| return identity else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const canonical_root = try root_directory.realPathFileAlloc(io, ".", allocator);
    var marker: std.json.ObjectMap = .empty;
    try marker.put(allocator, "schemaVersion", .{ .integer = store_schema_version });
    try marker.put(allocator, "kind", .{ .string = "hutch-store" });
    try marker.put(allocator, "canonicalRoot", .{ .string = canonical_root });
    const encoded = try jsonBytes(allocator, .{ .object = marker });
    try project_state.atomicWrite(
        io,
        allocator,
        state_directory,
        store_marker_file_name,
        encoded,
    );
    return .{ .canonical_root = canonical_root };
}

fn loadStoreIdentityAt(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
) !StoreIdentity {
    var root_directory = try openStoreRootNoFollow(io, home);
    defer root_directory.close(io);
    var state_directory = try openStoreStateNoFollow(io, root_directory);
    defer state_directory.close(io);
    return loadStoreIdentityFromOpenDirectories(
        io,
        allocator,
        root_directory,
        state_directory,
    );
}

fn loadStoreIdentityFromOpenDirectories(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_directory: std.Io.Dir,
    state_directory: std.Io.Dir,
) !StoreIdentity {
    const marker_stat = state_directory.statFile(io, store_marker_file_name, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return err,
        else => return error.InvalidHutchStoreMarker,
    };
    if (marker_stat.kind != .file) return error.InvalidHutchStoreMarker;
    const bytes = project_state.readFileAlloc(
        io,
        allocator,
        state_directory,
        store_marker_file_name,
        .limited(max_store_marker_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound, error.OutOfMemory => return err,
        else => return error.InvalidHutchStoreMarker,
    };
    const root = std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidHutchStoreMarker;
    if (root != .object or root.object.count() != 3) return error.InvalidHutchStoreMarker;
    if ((jsonPositiveUsize(root, "schemaVersion") catch return error.InvalidHutchStoreMarker) != store_schema_version) {
        return error.UnsupportedHutchStoreSchema;
    }
    if (!std.mem.eql(u8, jsonString(root, "kind") catch return error.InvalidHutchStoreMarker, "hutch-store")) {
        return error.InvalidHutchStoreMarker;
    }
    const stored_root = jsonString(root, "canonicalRoot") catch return error.InvalidHutchStoreMarker;
    if (!std.fs.path.isAbsolute(stored_root)) return error.InvalidHutchStoreMarker;
    const canonical_root = try root_directory.realPathFileAlloc(io, ".", allocator);
    if (!pathEqual(stored_root, canonical_root)) return error.HutchStoreRootMismatch;
    return .{ .canonical_root = canonical_root };
}

fn openStoreRootNoFollow(io: std.Io, home: []const u8) !std.Io.Dir {
    const stat = std.Io.Dir.cwd().statFile(io, home, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return err,
        else => return error.InvalidHutchStoreRoot,
    };
    if (stat.kind == .sym_link) return error.HutchStoreRootIsSymbolicLink;
    if (stat.kind != .directory) return error.InvalidHutchStoreRoot;
    return std.Io.Dir.cwd().openDir(io, home, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.SymLinkLoop => return error.HutchStoreRootIsSymbolicLink,
        error.NotDir => return error.InvalidHutchStoreRoot,
        else => return err,
    };
}

fn openStoreStateNoFollow(io: std.Io, root: std.Io.Dir) !std.Io.Dir {
    return openStoreChildDirectoryNoFollow(
        io,
        root,
        state_directory_name,
        error.InvalidHutchStoreStatePath,
    );
}

fn openStoreChildDirectoryNoFollow(
    io: std.Io,
    parent: std.Io.Dir,
    name: []const u8,
    comptime invalid_error: anyerror,
) !std.Io.Dir {
    const stat = parent.statFile(io, name, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return err,
        else => return invalid_error,
    };
    if (stat.kind != .directory) return invalid_error;
    return parent.openDir(io, name, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.NotDir, error.SymLinkLoop => return invalid_error,
        else => return err,
    };
}

fn storeMarkerPath(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{
        home,
        state_directory_name,
        store_marker_file_name,
    });
}

pub fn loadSelections(
    init: std.process.Init,
    allocator: std.mem.Allocator,
) !Selections {
    const home = try hutchHome(init, allocator);
    return loadSelectionsAt(init.io, allocator, home);
}

fn loadSelectionsAt(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
) !Selections {
    const path = try selectionsPath(allocator, home);
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(max_selections_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    const root = std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidSelectionsState;
    if (root != .object or root.object.count() != 3) return error.InvalidSelectionsState;
    if ((jsonPositiveUsize(root, "schemaVersion") catch return error.InvalidSelectionsState) != selections_schema_version) {
        return error.UnsupportedSelectionsSchema;
    }
    if (!std.mem.eql(u8, jsonString(root, "kind") catch return error.InvalidSelectionsState, "hutch-selections")) {
        return error.InvalidSelectionsState;
    }
    const products = jsonObject(root, "products") catch return error.InvalidSelectionsState;
    if (!objectKeysAllowed(products, &.{ "hutch", "cottontail" })) return error.InvalidSelectionsState;

    var selections: Selections = .{};
    try parseProductSelections(&selections, products, .hutch);
    try parseProductSelections(&selections, products, .cottontail);
    return selections;
}

fn parseProductSelections(
    selections: *Selections,
    products: std.json.Value,
    product: Product,
) !void {
    const value = products.object.get(product.name()) orelse return;
    if (!objectKeysAllowed(value, &.{ "production", "canary" })) return error.InvalidSelectionsState;
    for ([_][]const u8{ "production", "canary" }) |channel| {
        const entry = value.object.get(channel) orelse continue;
        if (entry != .object or entry.object.count() != 3) return error.InvalidSelectionsState;
        const version = jsonString(entry, "version") catch return error.InvalidSelectionsState;
        const parsed = version_selector.parse(version) catch return error.InvalidSelectionsState;
        if (parsed.kind != .version) return error.InvalidSelectionsState;
        const revision = jsonString(entry, "revision") catch return error.InvalidSelectionsState;
        validateRevision(revision) catch return error.InvalidSelectionsState;
        const platform = jsonString(entry, "platform") catch return error.InvalidSelectionsState;
        validatePlatformName(platform) catch return error.InvalidSelectionsState;
        try selections.set(product, channel, .{
            .version = version,
            .revision = revision,
            .platform = platform,
        });
    }
}

fn writeSelection(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    product: Product,
    channel: []const u8,
    selection: Selection,
) !void {
    const parsed = try version_selector.parse(selection.version);
    if (parsed.kind != .version) return error.InvalidReleaseVersion;
    try validateRevision(selection.revision);
    try validatePlatformName(selection.platform);
    const state = try std.fs.path.join(allocator, &.{ home, state_directory_name });
    try std.Io.Dir.cwd().createDirPath(io, state);
    const locks = try std.fs.path.join(allocator, &.{ state, "locks" });
    try std.Io.Dir.cwd().createDirPath(io, locks);
    const lock_path = try std.fs.path.join(allocator, &.{ locks, "selections.lock" });
    const lock = try acquirePersistentFileLock(io, lock_path);
    defer lock.close(io);

    var selections = try loadSelectionsAt(io, allocator, home);
    try selections.set(product, channel, selection);
    try writeSelectionsLocked(io, allocator, home, selections);
}

fn writeSelectionsLocked(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    selections: Selections,
) !void {
    const encoded = try selectionsJson(allocator, selections);
    try writeAtomicFileLocked(io, try selectionsPath(allocator, home), encoded);
}

fn selectionsJson(allocator: std.mem.Allocator, selections: Selections) ![]const u8 {
    var products: std.json.ObjectMap = .empty;
    try products.put(allocator, "hutch", try productSelectionsJson(allocator, selections, .hutch));
    try products.put(allocator, "cottontail", try productSelectionsJson(allocator, selections, .cottontail));

    var root: std.json.ObjectMap = .empty;
    try root.put(allocator, "schemaVersion", .{ .integer = selections_schema_version });
    try root.put(allocator, "kind", .{ .string = "hutch-selections" });
    try root.put(allocator, "products", .{ .object = products });
    return jsonBytes(allocator, .{ .object = root });
}

fn productSelectionsJson(
    allocator: std.mem.Allocator,
    selections: Selections,
    product: Product,
) !std.json.Value {
    var channels: std.json.ObjectMap = .empty;
    for ([_][]const u8{ "production", "canary" }) |channel| {
        const selection = selections.get(product, channel) orelse continue;
        var entry: std.json.ObjectMap = .empty;
        try entry.put(allocator, "version", .{ .string = selection.version });
        try entry.put(allocator, "revision", .{ .string = selection.revision });
        try entry.put(allocator, "platform", .{ .string = selection.platform });
        try channels.put(allocator, channel, .{ .object = entry });
    }
    return .{ .object = channels };
}

fn selectionsPath(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{
        home,
        state_directory_name,
        selections_file_name,
    });
}

fn jsonBytes(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    const compact = try std.json.Stringify.valueAlloc(allocator, value, .{});
    return std.mem.concat(allocator, u8, &.{ compact, "\n" });
}

fn objectKeysAllowed(value: std.json.Value, allowed: []const []const u8) bool {
    if (value != .object) return false;
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        var known = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) {
                known = true;
                break;
            }
        }
        if (!known) return false;
    }
    return true;
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
    const selections = loadSelectionsAt(io, allocator, home) catch return null;
    const selection = selections.get(product, channel) orelse return null;
    const platform = platformKey() catch return null;
    if (!std.mem.eql(u8, selection.platform, platform)) return null;
    const root = try std.fs.path.join(allocator, &.{
        home,
        releases_directory_name,
        product.name(),
        selection.version,
        selection.revision,
        platform,
    });
    return installedResolutionAt(
        io,
        allocator,
        root,
        product,
        selection.version,
        selection.revision,
        platform,
    );
}

fn installedResolutionAt(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    product: Product,
    expected_version: []const u8,
    expected_revision: []const u8,
    expected_platform: []const u8,
) !?Resolution {
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
    const archive_sha256 = std.mem.trim(u8, marker, " \t\r\n");
    validateSha256(archive_sha256) catch return null;

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
    const version = jsonString(metadata, "version") catch return null;
    const revision = jsonString(metadata, "revision") catch return null;
    const platform = jsonString(metadata, "platform") catch return null;
    const parsed_version = version_selector.parse(version) catch return null;
    if (parsed_version.kind != .version) return null;
    validateRevision(revision) catch return null;
    if (!std.mem.eql(u8, version, expected_version) or
        !std.mem.eql(u8, revision, expected_revision) or
        !std.mem.eql(u8, platform, expected_platform)) return null;

    return .{
        .root = root,
        .executable = executable,
        .version = version,
        .revision = revision,
        .archive_sha256 = archive_sha256,
        .installed = false,
    };
}

fn installedMatchingResolution(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    product: Product,
    selector: version_selector.Selector,
) !?Resolution {
    const platform = try platformKey();
    return switch (selector.kind) {
        .production, .canary => null,
        .version => try installedVersionResolution(
            io,
            allocator,
            home,
            product,
            selector.value,
            platform,
        ),
        .build => try installedBuildResolution(
            io,
            allocator,
            home,
            product,
            selector.value,
            platform,
        ),
    };
}

fn installedVersionResolution(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    product: Product,
    version: []const u8,
    platform: []const u8,
) !?Resolution {
    const version_root = try std.fs.path.join(allocator, &.{
        home,
        releases_directory_name,
        product.name(),
        version,
    });
    var directory = std.Io.Dir.cwd().openDir(io, version_root, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer directory.close(io);

    var found: ?Resolution = null;
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        validateRevision(entry.name) catch continue;
        const root = try std.fs.path.join(allocator, &.{ version_root, entry.name, platform });
        const candidate = (try installedResolutionAt(
            io,
            allocator,
            root,
            product,
            version,
            entry.name,
            platform,
        )) orelse continue;
        if (found != null) return null;
        found = candidate;
    }
    return found;
}

fn installedBuildResolution(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    product: Product,
    revision: []const u8,
    platform: []const u8,
) !?Resolution {
    const product_root = try std.fs.path.join(allocator, &.{
        home,
        releases_directory_name,
        product.name(),
    });
    var directory = std.Io.Dir.cwd().openDir(io, product_root, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer directory.close(io);

    var found: ?Resolution = null;
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const parsed = version_selector.parse(entry.name) catch continue;
        if (parsed.kind != .version) continue;
        const root = try std.fs.path.join(allocator, &.{
            product_root,
            entry.name,
            revision,
            platform,
        });
        const candidate = (try installedResolutionAt(
            io,
            allocator,
            root,
            product,
            entry.name,
            revision,
            platform,
        )) orelse continue;
        if (found != null) return null;
        found = candidate;
    }
    return found;
}

fn resolveArtifact(
    init: std.process.Init,
    allocator: std.mem.Allocator,
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
            const channel_bytes = try fetchManifest(init, allocator, channel_url, options);
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

    const manifest_bytes = if (selector.kind == .production or selector.kind == .canary)
        try fetchReleaseManifest(
            init,
            allocator,
            base_url,
            product,
            artifact_manifest_url,
            options,
        )
    else
        try fetchManifest(init, allocator, artifact_manifest_url, options);
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

fn fetchManifest(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    url: []const u8,
    options: Options,
) ![]const u8 {
    if (options.offline) return error.ReleaseMetadataUnavailableOffline;
    return fetchBytes(init, allocator, url, max_manifest_bytes);
}

fn fetchReleaseManifest(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    base_url: []const u8,
    product: Product,
    url: []const u8,
    options: Options,
) ![]const u8 {
    try validateProductUrl(allocator, base_url, product, url);
    const version = releaseVersionFromUrl(url) orelse return error.InvalidReleaseManifestUrl;
    const selector = try version_selector.parse(version);
    if (selector.kind != .version) return error.InvalidReleaseManifestUrl;
    return fetchManifest(init, allocator, url, options);
}

pub fn writeAtomicFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    bytes: []const u8,
) !void {
    const file_lock = try acquireFileLock(io, allocator, path);
    defer file_lock.close(io);
    return writeAtomicFileLocked(io, path, bytes);
}

/// Atomically publishes a file while the caller holds its persistent
/// `<path>.lock` lock. The temporary file is unique and lives beside the final
/// path, so independent writers do not collide and replacement is atomic.
pub fn writeAtomicFileLocked(
    io: std.Io,
    path: []const u8,
    bytes: []const u8,
) !void {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidStatePath;
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
        state_directory_name,
        "update-skip",
        product.name(),
        channel,
    });
}

fn updateCheckPath(
    allocator: std.mem.Allocator,
    home: []const u8,
    product: Product,
    channel: []const u8,
) ![]const u8 {
    return std.fs.path.join(allocator, &.{
        home,
        state_directory_name,
        "update-checks",
        product.name(),
        channel,
    });
}

fn updateCheckDueAt(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    now: i64,
) !bool {
    if (now < 0) return true;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(128),
    ) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => return err,
    };
    const value = std.mem.trim(u8, bytes, " \t\r\n");
    const checked_at = std.fmt.parseInt(i64, value, 10) catch return true;
    if (checked_at < 0 or checked_at > now) return true;
    return now - checked_at >= update_check_interval_seconds;
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

fn validatePlatformName(platform: []const u8) !void {
    for ([_][]const u8{ "macos-arm64", "linux-x64", "linux-arm64", "windows-x64" }) |supported| {
        if (std.mem.eql(u8, platform, supported)) return;
    }
    return error.UnsupportedReleasePlatform;
}

fn pathEqual(lhs: []const u8, rhs: []const u8) bool {
    return if (builtin.os.tag == .windows)
        std.ascii.eqlIgnoreCase(lhs, rhs)
    else
        std.mem.eql(u8, lhs, rhs);
}

fn pathHasParent(child: []const u8, parent: []const u8) bool {
    if (child.len <= parent.len or !pathEqual(child[0..parent.len], parent)) return false;
    return std.fs.path.isSep(child[parent.len]);
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
) !void {
    const parent = std.fs.path.dirname(root) orelse return error.InvalidInstallPath;
    try std.Io.Dir.cwd().createDirPath(init.io, parent);
    const lock_path = try std.mem.concat(allocator, u8, &.{ root, ".lock" });
    const lock = try acquirePersistentFileLock(init.io, lock_path);
    defer lock.close(init.io);

    if (try installedArtifactResolution(
        init.io,
        allocator,
        root,
        product,
        artifact,
        platform,
    ) != null) return;

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

fn installedArtifactResolution(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    product: Product,
    artifact: Artifact,
    platform: []const u8,
) !?Resolution {
    const resolution = (try installedResolutionAt(
        io,
        allocator,
        root,
        product,
        artifact.version,
        artifact.revision,
        platform,
    )) orelse return null;
    if (!std.mem.eql(u8, resolution.archive_sha256, artifact.sha256)) return null;
    return resolution;
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

fn environmentFlagEnabled(environment: *const std.process.Environ.Map, name: []const u8) bool {
    const value = environment.get(name) orelse return false;
    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes");
}

fn unixSeconds(io: std.Io) i64 {
    return @intCast(@divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
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

fn testAbsoluteRoot(
    io: std.Io,
    allocator: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
) ![]const u8 {
    const relative = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    return std.Io.Dir.cwd().realPathFileAlloc(io, relative, allocator);
}

test "selections merge exact identities without creating cache channel or ownership state" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ root, "home" });
    try std.Io.Dir.cwd().createDirPath(io, home);

    try writeSelection(io, allocator, home, .hutch, "production", .{
        .version = "0.8.0",
        .revision = "0123456789abcdef0123456789abcdef01234567",
        .platform = "macos-arm64",
    });
    try writeSelection(io, allocator, home, .cottontail, "canary", .{
        .version = "0.4.4",
        .revision = "abcdef0123456789abcdef0123456789abcdef01",
        .platform = "linux-x64",
    });

    const selections = try loadSelectionsAt(io, allocator, home);
    try std.testing.expectEqualStrings("0.8.0", selections.hutch_production.?.version);
    try std.testing.expectEqualStrings("macos-arm64", selections.hutch_production.?.platform);
    try std.testing.expectEqualStrings("0.4.4", selections.cottontail_canary.?.version);
    try std.testing.expect(!pathExists(io, try std.fs.path.join(allocator, &.{ home, "cache" })));
    try std.testing.expect(!pathExists(io, try std.fs.path.join(allocator, &.{ home, "channels" })));
    try std.testing.expect(!pathExists(io, try storeMarkerPath(allocator, home)));
}

test "selection writes preserve corrupt and unsupported state" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ root, "home" });
    const state = try std.fs.path.join(allocator, &.{ home, state_directory_name });
    try std.Io.Dir.cwd().createDirPath(io, state);
    const path = try selectionsPath(allocator, home);
    const selection: Selection = .{
        .version = "0.8.0",
        .revision = "0123456789abcdef0123456789abcdef01234567",
        .platform = "macos-arm64",
    };

    const corrupt = "{not-json\n";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = corrupt });
    try std.testing.expectError(
        error.InvalidSelectionsState,
        writeSelection(io, allocator, home, .hutch, "production", selection),
    );
    const corrupt_after = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(max_selections_bytes),
    );
    try std.testing.expectEqualStrings(corrupt, corrupt_after);

    const unsupported =
        "{\"schemaVersion\":2,\"kind\":\"hutch-selections\",\"products\":{}}\n";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = unsupported });
    try std.testing.expectError(
        error.UnsupportedSelectionsSchema,
        writeSelection(io, allocator, home, .cottontail, "canary", selection),
    );
    const unsupported_after = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(max_selections_bytes),
    );
    try std.testing.expectEqualStrings(unsupported, unsupported_after);
}

test "interactive update checks persist only a six-hour timestamp gate" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testAbsoluteRoot(io, allocator, &tmp);
    const path = try std.fs.path.join(allocator, &.{ root, "state", "update-check" });
    const parent = std.fs.path.dirname(path).?;
    try std.Io.Dir.cwd().createDirPath(io, parent);

    try std.testing.expect(try updateCheckDueAt(io, allocator, path, 100_000));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "100000\n" });
    try std.testing.expect(!try updateCheckDueAt(io, allocator, path, 100_000));
    try std.testing.expect(!try updateCheckDueAt(
        io,
        allocator,
        path,
        100_000 + update_check_interval_seconds - 1,
    ));
    try std.testing.expect(try updateCheckDueAt(
        io,
        allocator,
        path,
        100_000 + update_check_interval_seconds,
    ));

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "not-a-timestamp\n" });
    try std.testing.expect(try updateCheckDueAt(io, allocator, path, 100_000));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "100001\n" });
    try std.testing.expect(try updateCheckDueAt(io, allocator, path, 100_000));
}

test "the installer bootstrap marker strictly owns its canonical Hutch root" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ root, "home" });

    const created = try ensureManagedHomeAt(io, allocator, home);
    const loaded = try loadStoreIdentityAt(io, allocator, home);
    try std.testing.expectEqualStrings(created.canonical_root, loaded.canonical_root);
    try std.testing.expect(pathExists(io, try std.fs.path.join(allocator, &.{
        home,
        state_directory_name,
        "locks",
        store_lock_file_name,
    })));

    try writeAtomicFile(io, allocator, try storeMarkerPath(allocator, home), "{\"schemaVersion\":1,\"kind\":\"hutch-store\",\"canonicalRoot\":\"/wrong\"}\n");
    try std.testing.expectError(
        error.HutchStoreRootMismatch,
        loadStoreIdentityAt(io, allocator, home),
    );
}

test "store identity never follows the home state or marker through symlinks" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ root, "home" });
    _ = try ensureManagedHomeAt(io, allocator, home);

    const home_link = try std.fs.path.join(allocator, &.{ root, "home-link" });
    try std.Io.Dir.cwd().symLink(io, home, home_link, .{ .is_directory = true });
    try std.testing.expectError(
        error.HutchStoreRootIsSymbolicLink,
        loadStoreIdentityAt(io, allocator, home_link),
    );

    const marker_path = try storeMarkerPath(allocator, home);
    const outside_marker = try std.fs.path.join(allocator, &.{ root, "outside-marker.json" });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = outside_marker,
        .data = "{}\n",
    });
    try std.Io.Dir.cwd().deleteFile(io, marker_path);
    try std.Io.Dir.cwd().symLink(io, outside_marker, marker_path, .{});
    try std.testing.expectError(
        error.InvalidHutchStoreMarker,
        loadStoreIdentityAt(io, allocator, home),
    );

    const other_home = try std.fs.path.join(allocator, &.{ root, "other-home" });
    const outside_state = try std.fs.path.join(allocator, &.{ root, "outside-state" });
    try std.Io.Dir.cwd().createDirPath(io, other_home);
    try std.Io.Dir.cwd().createDirPath(io, outside_state);
    try std.Io.Dir.cwd().symLink(
        io,
        outside_state,
        try std.fs.path.join(allocator, &.{ other_home, state_directory_name }),
        .{ .is_directory = true },
    );
    try std.testing.expectError(
        error.InvalidHutchStoreStatePath,
        ensureManagedHomeAt(io, allocator, other_home),
    );
    try std.testing.expect(!pathExists(
        io,
        try std.fs.path.join(allocator, &.{ outside_state, store_marker_file_name }),
    ));

    const locks_home = try std.fs.path.join(allocator, &.{ root, "locks-home" });
    const locks_state = try std.fs.path.join(allocator, &.{ locks_home, state_directory_name });
    const outside_locks = try std.fs.path.join(allocator, &.{ root, "outside-locks" });
    try std.Io.Dir.cwd().createDirPath(io, locks_state);
    try std.Io.Dir.cwd().createDirPath(io, outside_locks);
    try std.Io.Dir.cwd().symLink(
        io,
        outside_locks,
        try std.fs.path.join(allocator, &.{ locks_state, "locks" }),
        .{ .is_directory = true },
    );
    try std.testing.expectError(
        error.InvalidHutchStoreStatePath,
        ensureManagedHomeAt(io, allocator, locks_home),
    );
    try std.testing.expect(!pathExists(
        io,
        try std.fs.path.join(allocator, &.{ outside_locks, store_lock_file_name }),
    ));
}

test "selected and exact installed releases resolve without remote metadata" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ root, "home" });
    const version = "9.8.7";
    const revision = "0123456789abcdef0123456789abcdef01234567";
    const checksum = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const platform = try platformKey();
    const release_root = try std.fs.path.join(allocator, &.{
        home,
        releases_directory_name,
        "cottontail",
        version,
        revision,
        platform,
    });
    const bin = try std.fs.path.join(allocator, &.{ release_root, "bin" });
    try std.Io.Dir.cwd().createDirPath(io, bin);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ bin, Product.cottontail.executableFileName() }),
        .data = "fixture",
    });
    const metadata = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":1,\"kind\":\"archive\",\"product\":\"cottontail\",\"channel\":\"canary\",\"version\":\"{s}\",\"revision\":\"{s}\",\"platform\":\"{s}\"}}\n",
        .{ version, revision, platform },
    );
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ release_root, Product.cottontail.metadataFileName() }),
        .data = metadata,
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ release_root, ".dash-installed" }),
        .data = checksum,
    });
    try writeSelection(io, allocator, home, .cottontail, "production", .{
        .version = version,
        .revision = revision,
        .platform = platform,
    });

    const selected = (try activeResolution(io, allocator, home, .cottontail, "production")).?;
    try std.testing.expectEqualStrings(release_root, selected.root);
    try std.testing.expectEqualStrings(checksum, selected.archive_sha256);
    const exact = (try installedVersionResolution(
        io,
        allocator,
        home,
        .cottontail,
        version,
        platform,
    )).?;
    try std.testing.expectEqualStrings(release_root, exact.root);
}

fn createTestStagedHutchArchive(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    version: []const u8,
    revision: []const u8,
    checksum: []const u8,
    suffix: []const u8,
) ![]const u8 {
    const platform = try platformKey();
    const parent = try std.fs.path.join(allocator, &.{
        home,
        releases_directory_name,
        Product.hutch.name(),
        version,
        revision,
    });
    try std.Io.Dir.cwd().createDirPath(io, parent);
    const stage_name = try std.fmt.allocPrint(
        allocator,
        ".hutch-install-{s}-{s}",
        .{ platform, suffix },
    );
    const stage = try std.fs.path.join(allocator, &.{ parent, stage_name });
    const bin = try std.fs.path.join(allocator, &.{ stage, "bin" });
    try std.Io.Dir.cwd().createDirPath(io, bin);

    const launcher_name = if (builtin.os.tag == .windows) "hutch.exe" else "hutch";
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ bin, launcher_name }),
        .data = "launcher",
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ bin, Product.hutch.executableFileName() }),
        .data = "engine",
    });
    const metadata = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":1,\"kind\":\"archive\",\"product\":\"hutch\",\"channel\":\"production\",\"version\":\"{s}\",\"platform\":\"{s}\",\"revision\":\"{s}\",\"launcher\":\"bin/{s}\",\"executable\":\"bin/{s}\"}}\n",
        .{ version, platform, revision, launcher_name, Product.hutch.executableFileName() },
    );
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ stage, Product.hutch.metadataFileName() }),
        .data = metadata,
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ stage, ".dash-installed" }),
        .data = checksum,
    });
    return stage;
}

test "a downloaded artifact identity does not trust marker and executable alone" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture = try testAbsoluteRoot(io, allocator, &tmp);
    const version = "9.8.7";
    const revision = "0123456789abcdef0123456789abcdef01234567";
    const checksum = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const platform = try platformKey();
    const release_root = try std.fs.path.join(allocator, &.{ fixture, "release" });
    const bin = try std.fs.path.join(allocator, &.{ release_root, "bin" });
    try std.Io.Dir.cwd().createDirPath(io, bin);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ bin, Product.cottontail.executableFileName() }),
        .data = "fixture",
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ release_root, ".dash-installed" }),
        .data = checksum,
    });
    const artifact: Artifact = .{
        .version = version,
        .revision = revision,
        .archive_url = "https://artifacts.test/cottontail.tar.gz",
        .sha256 = checksum,
        .size = 42,
    };
    const metadata_path = try std.fs.path.join(allocator, &.{
        release_root,
        Product.cottontail.metadataFileName(),
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = metadata_path,
        .data = "{\"schema\":1,\"kind\":\"archive\",\"product\":\"hutch\",\"version\":\"9.8.7\",\"revision\":\"0123456789abcdef0123456789abcdef01234567\",\"platform\":\"macos-arm64\"}\n",
    });
    try std.testing.expect((try installedArtifactResolution(
        io,
        allocator,
        release_root,
        .cottontail,
        artifact,
        platform,
    )) == null);

    const valid_metadata = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":1,\"kind\":\"archive\",\"product\":\"cottontail\",\"version\":\"{s}\",\"revision\":\"{s}\",\"platform\":\"{s}\"}}\n",
        .{ version, revision, platform },
    );
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = metadata_path,
        .data = valid_metadata,
    });
    const installed = (try installedArtifactResolution(
        io,
        allocator,
        release_root,
        .cottontail,
        artifact,
        platform,
    )).?;
    try std.testing.expectEqualStrings(release_root, installed.root);
    try std.testing.expectEqualStrings(checksum, installed.archive_sha256);
}

test "installer bootstrap atomically publishes a staged Hutch release" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ fixture, "home" });
    try std.Io.Dir.cwd().createDirPath(io, home);
    const version = "0.8.0";
    const revision = "0123456789abcdef0123456789abcdef01234567";
    const checksum = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const stage = try createTestStagedHutchArchive(
        io,
        allocator,
        home,
        version,
        revision,
        checksum,
        "aaaaaaaaaaaa",
    );

    try bootstrapInstalledHutchAt(io, allocator, home, "stable", stage, &.{});

    const final_root = try std.fs.path.join(allocator, &.{
        home,
        releases_directory_name,
        Product.hutch.name(),
        version,
        revision,
        try platformKey(),
    });
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(io, stage, .{}),
    );
    const installed = try validateHutchArchiveRoot(io, allocator, final_root);
    try std.testing.expectEqualStrings(checksum, installed.archive_sha256);
    _ = try loadStoreIdentityAt(io, allocator, home);
    const selections = try loadSelectionsAt(io, allocator, home);
    try std.testing.expectEqualStrings(version, selections.hutch_production.?.version);
    try std.testing.expect(pathExists(io, try std.mem.concat(allocator, u8, &.{ final_root, ".lock" })));
}

test "installer bootstrap fails closed on damaged selections before publication" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ fixture, "home" });
    try std.Io.Dir.cwd().createDirPath(io, home);
    _ = try ensureManagedHomeAt(io, allocator, home);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try selectionsPath(allocator, home),
        .data = "{ damaged selections\n",
    });
    const version = "0.8.0";
    const revision = "0123456789abcdef0123456789abcdef01234567";
    const stage = try createTestStagedHutchArchive(
        io,
        allocator,
        home,
        version,
        revision,
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "bbbbbbbbbbbb",
    );

    try std.testing.expectError(
        error.InvalidSelectionsState,
        bootstrapInstalledHutchAt(io, allocator, home, "production", stage, &.{}),
    );
    try std.Io.Dir.cwd().access(io, stage, .{});
    const final_root = try std.fs.path.join(allocator, &.{
        home,
        releases_directory_name,
        Product.hutch.name(),
        version,
        revision,
        try platformKey(),
    });
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(io, final_root, .{}),
    );
    try std.testing.expect(pathExists(io, try storeMarkerPath(allocator, home)));
}

test "installer bootstrap rejects symlinks anywhere in a staged archive" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ fixture, "home" });
    try std.Io.Dir.cwd().createDirPath(io, home);
    const stage = try createTestStagedHutchArchive(
        io,
        allocator,
        home,
        "0.8.0",
        "0123456789abcdef0123456789abcdef01234567",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "cccccccccccc",
    );
    const outside = try std.fs.path.join(allocator, &.{ fixture, "outside" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = outside, .data = "outside" });
    try std.Io.Dir.cwd().symLink(
        io,
        outside,
        try std.fs.path.join(allocator, &.{ stage, "unsafe-link" }),
        .{},
    );

    try std.testing.expectError(
        error.InvalidInstalledHutchArchive,
        bootstrapInstalledHutchAt(io, allocator, home, "production", stage, &.{}),
    );
}

test "installer bootstrap refuses to claim an arbitrary unmarked home" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ fixture, "home" });
    try std.Io.Dir.cwd().createDirPath(io, home);
    const sentinel = try std.fs.path.join(allocator, &.{ home, "must-survive.txt" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sentinel, .data = "keep" });
    const stage = try createTestStagedHutchArchive(
        io,
        allocator,
        home,
        "0.8.0",
        "0123456789abcdef0123456789abcdef01234567",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "dddddddddddd",
    );

    try std.testing.expectError(
        error.UnsafeUnmarkedHutchHome,
        bootstrapInstalledHutchAt(io, allocator, home, "production", stage, &.{}),
    );
    try std.testing.expectEqualStrings(
        "keep",
        try std.Io.Dir.cwd().readFileAlloc(io, sentinel, allocator, .limited(16)),
    );
    try std.testing.expect(!pathExists(io, try storeMarkerPath(allocator, home)));
    try std.testing.expect(!pathExists(io, try std.fs.path.join(allocator, &.{ home, state_directory_name })));
}

test "installer bootstrap never claims the user home itself" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const home = try testAbsoluteRoot(io, allocator, &tmp);
    const stage = try createTestStagedHutchArchive(
        io,
        allocator,
        home,
        "0.8.0",
        "0123456789abcdef0123456789abcdef01234567",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "eeeeeeeeeeee",
    );

    try std.testing.expectError(
        error.UnsafeUnmarkedHutchHome,
        bootstrapInstalledHutchAt(io, allocator, home, "production", stage, &.{home}),
    );
    try std.testing.expect(!pathExists(io, try storeMarkerPath(allocator, home)));
}

test "installer bootstrap repairs a damaged exact release under its object lock" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ fixture, "home" });
    try std.Io.Dir.cwd().createDirPath(io, home);
    const version = "0.8.0";
    const revision = "0123456789abcdef0123456789abcdef01234567";
    const checksum = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const first_stage = try createTestStagedHutchArchive(
        io,
        allocator,
        home,
        version,
        revision,
        checksum,
        "ffffffffffff",
    );
    try bootstrapInstalledHutchAt(io, allocator, home, "production", first_stage, &.{});
    const final_root = try std.fs.path.join(allocator, &.{
        home,
        releases_directory_name,
        Product.hutch.name(),
        version,
        revision,
        try platformKey(),
    });
    try std.Io.Dir.cwd().deleteFile(
        io,
        try std.fs.path.join(allocator, &.{ final_root, "bin", Product.hutch.executableFileName() }),
    );
    const repair_stage = try createTestStagedHutchArchive(
        io,
        allocator,
        home,
        version,
        revision,
        checksum,
        "gggggggggggg",
    );

    try bootstrapInstalledHutchAt(io, allocator, home, "canary", repair_stage, &.{});
    _ = try validateHutchArchiveRoot(io, allocator, final_root);
    const selections = try loadSelectionsAt(io, allocator, home);
    try std.testing.expectEqualStrings(revision, selections.hutch_canary.?.revision);
}

test "a validated installed Hutch engine holds its release object lease" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ fixture, "home" });
    const version = "9.8.7";
    const revision = "0123456789abcdef0123456789abcdef01234567";
    const checksum = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const platform = try platformKey();
    const release_root = try std.fs.path.join(allocator, &.{
        home,
        releases_directory_name,
        "hutch",
        version,
        revision,
        platform,
    });
    const bin = try std.fs.path.join(allocator, &.{ release_root, "bin" });
    try std.Io.Dir.cwd().createDirPath(io, bin);
    const executable = try std.fs.path.join(allocator, &.{ bin, Product.hutch.executableFileName() });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = executable, .data = "fixture" });
    const metadata = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":1,\"kind\":\"archive\",\"product\":\"hutch\",\"channel\":\"production\",\"version\":\"{s}\",\"revision\":\"{s}\",\"platform\":\"{s}\"}}\n",
        .{ version, revision, platform },
    );
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ release_root, Product.hutch.metadataFileName() }),
        .data = metadata,
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ release_root, ".dash-installed" }),
        .data = checksum,
    });

    const graph = try store_locks.acquireGraph(io, allocator, home, .shared);
    const lease = (try leaseInstalledHutchExecutableUnderGraph(
        io,
        allocator,
        home,
        executable,
    )).?;
    graph.close(io);
    try std.testing.expect((try store_locks.tryAcquireObjectExclusive(
        io,
        allocator,
        release_root,
    )) == null);

    lease.close(io);
    const exclusive = (try store_locks.tryAcquireObjectExclusive(
        io,
        allocator,
        release_root,
    )).?;
    exclusive.close(io);

    const external = try std.fs.path.join(allocator, &.{ fixture, "outside", "hutch-engine" });
    try std.testing.expect((try leaseInstalledHutchExecutableUnderGraph(
        io,
        allocator,
        home,
        external,
    )) == null);
}
