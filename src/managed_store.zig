const std = @import("std");
const builtin = @import("builtin");
const store_locks = @import("store_locks.zig");
const project_state = @import("project_state.zig");
const release_store = @import("release_store.zig");
const toolchain_store = @import("toolchain_store.zig");
const version_selector = @import("version_selector.zig");

const schema_version = 1;
const project_lock_kind = "hutch-project-dependencies";
const registration_kind = "hutch-project-registration";
const state_relative_root = store_locks.state_relative_root;
const max_state_file_bytes = 1024 * 1024;

pub const automatic_retention_seconds: i64 = 10 * 24 * 60 * 60;

pub const ManagedObject = struct {
    kind: Kind,
    relative_root: []const u8,
    version: []const u8,
    platform: []const u8,
    toolchain_kind: ?[]const u8 = null,
    core_sha256: ?[]const u8 = null,
    cef_sha256: ?[]const u8 = null,
    source_manifest_sha256: ?[]const u8 = null,
    release_product: ?[]const u8 = null,
    revision: ?[]const u8 = null,
    archive_sha256: ?[]const u8 = null,

    pub const Kind = enum {
        electrobun,
        electrobun_cef,
        release,
        toolchain,
    };
};

pub const GraphLock = store_locks.GraphLock;
pub const ObjectLease = store_locks.ObjectLease;

pub const PruneOptions = struct {
    dry_run: bool = false,
    now_unix_seconds: ?i64 = null,
    /// Additional exact managed roots to retain for this sweep. Production
    /// callers normally rely on selections, project locks, process leases, and
    /// automatic current-engine detection instead.
    protected_relative_roots: []const []const u8 = &.{},
};

pub const PruneAction = struct {
    relative_root: []const u8,
};

pub const PruneResult = struct {
    actions: []const PruneAction,
    scanned: usize,
    reachable: usize,
    retention_kept: usize,
    eligible: usize,
    expired_registrations: usize,
    pruned: usize,
};

const Candidate = struct {
    kind: ManagedObject.Kind,
    absolute_root: []const u8,
    lock_root: []const u8,
    relative_root: []const u8,
    version: []const u8,
    platform: []const u8,
    toolchain_kind: ?[]const u8 = null,
};

const CandidateDisposition = enum {
    reachable,
    retention_kept,
    eligible,
};

const RegistrationScan = struct {
    reachable: std.ArrayList([]const u8) = .empty,
    expired_paths: std.ArrayList([]const u8) = .empty,
};

const PruneKind = enum {
    manual,
    automatic,
};

pub fn acquireUsageLock(
    init: std.process.Init,
    allocator: std.mem.Allocator,
) !GraphLock {
    const home = try release_store.hutchHome(init, allocator);
    return store_locks.acquireGraph(init.io, allocator, home, .shared);
}

/// Leases the exact Hutch release containing the running engine. The graph is
/// held from structural discovery through lease acquisition, then released;
/// callers retain the returned lease for the process lifetime. Development or
/// otherwise external engines return null.
pub fn acquireCurrentHutchLease(
    init: std.process.Init,
    allocator: std.mem.Allocator,
) !?ObjectLease {
    const home = try release_store.hutchHome(init, allocator);
    const executable = try std.process.executablePathAlloc(init.io, allocator);
    validateStoreOwnership(init.io, allocator, home) catch |err| switch (err) {
        error.FileNotFound, error.StoreRootMismatch => return null,
        else => return err,
    };
    const graph = try store_locks.acquireGraph(init.io, allocator, home, .shared);
    defer graph.close(init.io);

    var candidates: std.ArrayList(Candidate) = .empty;
    try collectReleaseCandidates(init.io, allocator, home, "hutch", &candidates);
    for (candidates.items) |candidate| {
        if (!try candidateContainsAbsolutePath(init.io, allocator, candidate, executable)) continue;
        return try store_locks.acquireObjectLease(
            init.io,
            allocator,
            home,
            candidate.absolute_root,
        );
    }
    return null;
}

fn acquireGraphLockAt(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    mode: std.Io.File.Lock,
) !GraphLock {
    return store_locks.acquireGraph(io, allocator, home, mode);
}

pub fn managedElectrobunObjects(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    root: []const u8,
    version: []const u8,
    source_manifest_sha256: []const u8,
    uses_cef: bool,
) ![2]?ManagedObject {
    const home = try release_store.hutchHome(init, allocator);
    return managedElectrobunObjectsAt(
        init.io,
        allocator,
        home,
        root,
        version,
        source_manifest_sha256,
        uses_cef,
    );
}

fn managedElectrobunObjectsAt(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    root: []const u8,
    version: []const u8,
    source_manifest_sha256: []const u8,
    uses_cef: bool,
) ![2]?ManagedObject {
    try validateSegment(version);
    try validateSha256(source_manifest_sha256);
    const platform = std.fs.path.basename(root);
    validateSegment(platform) catch return .{ null, null };
    const expected = try std.fs.path.join(allocator, &.{ home, "releases", "electrobun", version, platform });
    if (!std.mem.eql(u8, expected, root)) return .{ null, null };
    try validatePlatform(platform);

    const core_sha256 = try readSha256Marker(io, allocator, root, ".core-complete");
    const core: ManagedObject = .{
        .kind = .electrobun,
        .relative_root = try std.fmt.allocPrint(allocator, "releases/electrobun/{s}/{s}", .{ version, platform }),
        .version = try allocator.dupe(u8, version),
        .platform = try allocator.dupe(u8, platform),
        .core_sha256 = core_sha256,
        .source_manifest_sha256 = try allocator.dupe(u8, source_manifest_sha256),
    };
    if (!uses_cef) return .{ core, null };

    const cef_root = try std.fs.path.join(allocator, &.{ root, "cef" });
    const cef: ManagedObject = .{
        .kind = .electrobun_cef,
        .relative_root = try std.fmt.allocPrint(allocator, "releases/electrobun/{s}/{s}/cef", .{ version, platform }),
        .version = try allocator.dupe(u8, version),
        .platform = try allocator.dupe(u8, platform),
        .cef_sha256 = try readSha256Marker(io, allocator, cef_root, ".cef-complete"),
    };
    return .{ core, cef };
}

pub fn managedToolchainObject(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    kind: toolchain_store.Kind,
    resolution: toolchain_store.Resolution,
) !?ManagedObject {
    const home = try release_store.hutchHome(init, allocator);
    return managedToolchainObjectAt(init.io, allocator, home, kind, resolution);
}

/// Converts a healthy immutable Hutch/Cottontail release into an exact
/// project-reachability object. `path_within_release` may be the release root,
/// its executable, or another existing path beneath it.
pub fn managedReleaseObject(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    product: release_store.Product,
    path_within_release: []const u8,
) !?ManagedObject {
    const home = try release_store.hutchHome(init, allocator);
    return managedReleaseObjectAt(
        init.io,
        allocator,
        home,
        product,
        path_within_release,
    );
}

fn managedReleaseObjectAt(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    product: release_store.Product,
    path_within_release: []const u8,
) !?ManagedObject {
    var candidates: std.ArrayList(Candidate) = .empty;
    try collectReleaseCandidates(io, allocator, home, product.name(), &candidates);
    for (candidates.items) |candidate| {
        if (!try candidateContainsAbsolutePath(io, allocator, candidate, path_within_release)) continue;
        return releaseManagedObjectFromCandidate(io, allocator, product, candidate) catch null;
    }
    return null;
}

fn managedToolchainObjectAt(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    kind: toolchain_store.Kind,
    resolution: toolchain_store.Resolution,
) !?ManagedObject {
    if (resolution.system) return null;
    const root = resolution.root orelse return error.ManagedToolchainRootMissing;
    const version = resolution.version;
    try validateSegment(version);
    const platform = std.fs.path.basename(root);
    validateSegment(platform) catch return null;
    const expected = try std.fs.path.join(allocator, &.{ home, "toolchains", kind.name(), version, platform });
    if (!std.mem.eql(u8, expected, root)) return null;
    try validatePlatform(platform);

    const marker = try std.fs.path.join(allocator, &.{ root, ".hutch-toolchain" });
    const marker_value = try readTrimmedFile(io, allocator, marker, 256);
    if (!std.mem.eql(u8, marker_value, version)) return error.ToolchainMarkerMismatch;
    return .{
        .kind = .toolchain,
        .relative_root = try std.fmt.allocPrint(allocator, "toolchains/{s}/{s}/{s}", .{ kind.name(), version, platform }),
        .version = try allocator.dupe(u8, version),
        .platform = try allocator.dupe(u8, platform),
        .toolchain_kind = kind.name(),
    };
}

/// The caller must hold `acquireUsageLock` from before artifact resolution
/// until this registration has been committed.
pub fn registerPreparedProject(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    canonical_project_root: []const u8,
    objects_input: []const ManagedObject,
) !void {
    const home = try release_store.hutchHome(init, allocator);
    return registerProjectAt(
        init.io,
        allocator,
        home,
        canonical_project_root,
        objects_input,
        unixSeconds(init.io),
    );
}

/// Updates only the exact Hutch/Cottontail portion of a project's graph. A
/// verified existing lock contributes its Electrobun/CEF/toolchain objects;
/// missing or damaged state contributes nothing.
pub fn registerProjectReleases(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    canonical_project_root: []const u8,
    releases: []const ManagedObject,
) !void {
    const home = try release_store.hutchHome(init, allocator);
    const graph = try store_locks.acquireGraph(init.io, allocator, home, .shared);
    defer graph.close(init.io);

    var merged: std.ArrayList(ManagedObject) = .empty;
    if (try registeredProjectObjectsIfVerified(
        init.io,
        allocator,
        home,
        canonical_project_root,
    )) |existing| {
        for (existing) |object| {
            if (object.kind == .release) continue;
            try merged.append(allocator, object);
        }
    }
    for (releases, 0..) |object, index| {
        if (object.kind != .release) return error.ExpectedManagedRelease;
        try validateManagedObject(allocator, object);
        for (releases[0..index]) |prior| {
            if (std.mem.eql(u8, prior.release_product.?, object.release_product.?)) {
                return error.DuplicateManagedReleaseProduct;
            }
        }
        try merged.append(allocator, object);
    }
    return registerProjectAt(
        init.io,
        allocator,
        home,
        canonical_project_root,
        merged.items,
        unixSeconds(init.io),
    );
}

fn registeredProjectObjectsIfVerified(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    canonical_project_root: []const u8,
) !?[]const ManagedObject {
    const path = try projectRegistrationPath(allocator, home, canonical_project_root);
    const stat = std.Io.Dir.cwd().statFile(io, path, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (stat.kind != .file) return null;
    const registration = parseRegistration(
        io,
        allocator,
        home,
        path,
        std.fs.path.basename(path),
    ) catch return null;
    if (!pathEqual(registration.canonical_root, canonical_project_root)) return null;
    return projectLockObjectsIfMatches(
        io,
        allocator,
        canonical_project_root,
        registration.lock_sha256,
    ) catch null;
}

fn registerProjectAt(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    canonical_project_root: []const u8,
    objects_input: []const ManagedObject,
    now: i64,
) !void {
    if (!std.fs.path.isAbsolute(canonical_project_root)) return error.ProjectRootNotAbsolute;
    if (now < 0) return error.InvalidRegistrationTimestamp;
    const registration_path = try projectRegistrationPath(allocator, home, canonical_project_root);
    try ensureDirectoryWithin(
        io,
        allocator,
        home,
        std.fs.path.dirname(registration_path) orelse return error.InvalidStoreStatePath,
        error.InvalidStoreStatePath,
    );
    const registration_lock_path = try projectRegistrationLockPath(allocator, home, canonical_project_root);
    try ensureDirectoryWithin(
        io,
        allocator,
        home,
        std.fs.path.dirname(registration_lock_path) orelse return error.InvalidStoreStatePath,
        error.InvalidStoreStatePath,
    );
    try store_locks.initializePersistentFile(io, registration_lock_path);
    if (!try pathResolvesWithin(io, allocator, home, registration_lock_path)) return error.InvalidStoreStatePath;
    const registration_lock = try std.Io.Dir.cwd().openFile(io, registration_lock_path, .{
        .mode = .read_write,
        .lock = .exclusive,
        .follow_symlinks = false,
    });
    defer registration_lock.close(io);

    const objects = try allocator.dupe(ManagedObject, objects_input);
    std.mem.sort(ManagedObject, objects, {}, managedObjectLessThan);
    for (objects) |object| try validateManagedObject(allocator, object);

    const object_values = try objectsJson(allocator, objects);

    var project_lock: std.json.ObjectMap = .empty;
    try project_lock.put(allocator, "schemaVersion", .{ .integer = schema_version });
    try project_lock.put(allocator, "kind", .{ .string = project_lock_kind });
    try project_lock.put(allocator, "objects", .{ .array = object_values });
    const project_lock_bytes = try stringifyJson(allocator, .{ .object = project_lock });
    var project_state_dir = try project_state.open(io, canonical_project_root, .create, .{});
    defer project_state_dir.close(io);
    try project_state.atomicWrite(io, allocator, project_state_dir, "dependencies.lock", project_lock_bytes);

    var lock_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(project_lock_bytes, &lock_digest, .{});
    const lock_digest_hex = std.fmt.bytesToHex(lock_digest, .lower);

    var registration: std.json.ObjectMap = .empty;
    try registration.put(allocator, "schemaVersion", .{ .integer = schema_version });
    try registration.put(allocator, "kind", .{ .string = registration_kind });
    try registration.put(allocator, "canonicalRoot", .{ .string = canonical_project_root });
    try registration.put(allocator, "projectLockSha256", .{ .string = try allocator.dupe(u8, &lock_digest_hex) });
    try registration.put(allocator, "lastSeenUnixSeconds", .{ .integer = now });
    const registration_bytes = try stringifyJson(allocator, .{ .object = registration });

    try atomicWrite(io, allocator, registration_path, registration_bytes);
}

fn managedObjectLessThan(_: void, lhs: ManagedObject, rhs: ManagedObject) bool {
    return std.mem.order(u8, lhs.relative_root, rhs.relative_root) == .lt;
}

fn objectsJson(allocator: std.mem.Allocator, objects: []const ManagedObject) !std.json.Array {
    var values = std.json.Array.init(allocator);
    for (objects) |object| try values.append(try objectJson(allocator, object));
    return values;
}

fn objectJson(allocator: std.mem.Allocator, object: ManagedObject) !std.json.Value {
    var value: std.json.ObjectMap = .empty;
    try value.put(allocator, "type", .{ .string = switch (object.kind) {
        .electrobun => "electrobun",
        .electrobun_cef => "electrobun-cef",
        .release => "release",
        .toolchain => "toolchain",
    } });
    try value.put(allocator, "relativeRoot", .{ .string = object.relative_root });
    try value.put(allocator, "version", .{ .string = object.version });
    try value.put(allocator, "platform", .{ .string = object.platform });
    switch (object.kind) {
        .electrobun => {
            try value.put(allocator, "product", .{ .string = "electrobun" });
            try value.put(allocator, "coreSha256", .{ .string = object.core_sha256.? });
            try value.put(allocator, "sourceManifestSha256", .{ .string = object.source_manifest_sha256.? });
        },
        .electrobun_cef => {
            try value.put(allocator, "product", .{ .string = "electrobun" });
            try value.put(allocator, "cefSha256", .{ .string = object.cef_sha256.? });
        },
        .release => {
            try value.put(allocator, "product", .{ .string = object.release_product.? });
            try value.put(allocator, "revision", .{ .string = object.revision.? });
            try value.put(allocator, "archiveSha256", .{ .string = object.archive_sha256.? });
        },
        .toolchain => try value.put(allocator, "toolchain", .{ .string = object.toolchain_kind.? }),
    }
    return .{ .object = value };
}

fn stringifyJson(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
    return std.mem.concat(allocator, u8, &.{ bytes, "\n" });
}

/// A managed object as discovered by a read-only inventory pass.
pub const InventoryObject = struct {
    kind: ManagedObject.Kind,
    relative_root: []const u8,
    absolute_root: []const u8,
    version: []const u8,
    platform: []const u8,
    toolchain_kind: ?[]const u8 = null,
    unreachable_since_unix_seconds: ?i64 = null,
    /// Referenced by a verified project lock, a strict selection, or an
    /// explicitly protected current invocation root.
    reachable: bool = false,
    /// A live process holds the object lease, so the object cannot be detached
    /// right now. An unreadable lock file is reported the same way, because a
    /// pruner could not detach it either.
    in_use: bool = false,
};

pub const InventoryProject = struct {
    canonical_root: []const u8,
    registration_path: []const u8,
    project_exists: bool,
    /// The project's own `.hutch/dependencies.lock` matched the digest recorded
    /// in the global registration, so it is the live source of truth.
    lock_verified: bool,
    last_seen_unix_seconds: i64,
    objects: []const ManagedObject,
};

pub const Inventory = struct {
    objects: []const InventoryObject,
    projects: []const InventoryProject,
    /// Entries that could not be read or parsed. An inventory reports damage
    /// instead of failing, because it never mutates the store.
    issues: []const []const u8,
};

/// Read-only view of the managed object graph.
///
/// Unlike `prune`, this never takes the graph lock and never creates state
/// directories, so it is safe against a store that is missing, read-only, or
/// concurrently mutated. The result is a best-effort snapshot.
pub fn inventory(init: std.process.Init, allocator: std.mem.Allocator) !Inventory {
    const home = try release_store.hutchHome(init, allocator);
    return inventoryAt(init.io, allocator, home);
}

fn inventoryAt(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
) !Inventory {
    var issues: std.ArrayList([]const u8) = .empty;
    var projects: std.ArrayList(InventoryProject) = .empty;
    var reachable: std.ArrayList([]const u8) = .empty;
    try inventoryRegistrations(io, allocator, home, &projects, &reachable, &issues);
    collectSelectionRoots(io, allocator, home, &reachable) catch |err| {
        try appendIssue(allocator, &issues, "state/selections.json", err);
    };

    var candidates: std.ArrayList(Candidate) = .empty;
    collectReleaseCandidates(io, allocator, home, "hutch", &candidates) catch |err| {
        try appendIssue(allocator, &issues, "releases/hutch", err);
    };
    collectReleaseCandidates(io, allocator, home, "cottontail", &candidates) catch |err| {
        try appendIssue(allocator, &issues, "releases/cottontail", err);
    };
    collectElectrobunCandidates(io, allocator, home, &candidates) catch |err| {
        try appendIssue(allocator, &issues, "releases/electrobun", err);
    };
    collectToolchainCandidates(io, allocator, home, &candidates) catch |err| {
        try appendIssue(allocator, &issues, "toolchains", err);
    };
    std.mem.sort(Candidate, candidates.items, {}, candidateLessThan);

    var objects: std.ArrayList(InventoryObject) = .empty;
    for (candidates.items) |candidate| {
        try objects.append(allocator, .{
            .kind = candidate.kind,
            .relative_root = candidate.relative_root,
            .absolute_root = candidate.absolute_root,
            .version = candidate.version,
            .platform = candidate.platform,
            .toolchain_kind = candidate.toolchain_kind,
            .unreachable_since_unix_seconds = readUnreachableSince(io, allocator, home, candidate.relative_root) catch blk: {
                try appendIssue(allocator, &issues, candidate.relative_root, error.InvalidUnreachableSinceMarker);
                break :blk null;
            },
            .reachable = candidateIsReachable(reachable.items, candidate),
            .in_use = objectInUse(io, allocator, candidate.lock_root) catch false,
        });
    }

    return .{
        .objects = try objects.toOwnedSlice(allocator),
        .projects = try projects.toOwnedSlice(allocator),
        .issues = try issues.toOwnedSlice(allocator),
    };
}

fn inventoryRegistrations(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    projects: *std.ArrayList(InventoryProject),
    reachable: *std.ArrayList([]const u8),
    issues: *std.ArrayList([]const u8),
) !void {
    const projects_root = try std.fs.path.join(allocator, &.{ home, state_relative_root, "projects" });
    var directory = std.Io.Dir.cwd().openDir(io, projects_root, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            try appendIssue(allocator, issues, projects_root, err);
            return;
        },
    };
    defer directory.close(io);

    var iterator = directory.iterate();
    while (iterator.next(io) catch |err| {
        try appendIssue(allocator, issues, projects_root, err);
        return;
    }) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const path = try std.fs.path.join(allocator, &.{ projects_root, entry.name });
        const project = inventoryRegistration(io, allocator, home, path, entry.name) catch |err| {
            try appendIssue(allocator, issues, path, err);
            continue;
        };
        for (project.objects) |object| {
            if (!containsPath(reachable.items, object.relative_root)) {
                try reachable.append(allocator, object.relative_root);
            }
        }
        try projects.append(allocator, project);
    }

    std.mem.sort(InventoryProject, projects.items, {}, inventoryProjectLessThan);
}

fn inventoryProjectLessThan(_: void, lhs: InventoryProject, rhs: InventoryProject) bool {
    return std.mem.order(u8, lhs.canonical_root, rhs.canonical_root) == .lt;
}

fn inventoryRegistration(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    path: []const u8,
    file_name: []const u8,
) !InventoryProject {
    const registration = try parseRegistration(io, allocator, home, path, file_name);
    const locked = projectLockObjectsIfMatches(
        io,
        allocator,
        registration.canonical_root,
        registration.lock_sha256,
    ) catch null;
    return .{
        .canonical_root = registration.canonical_root,
        .registration_path = path,
        .project_exists = pathExists(io, registration.canonical_root),
        .lock_verified = locked != null,
        .last_seen_unix_seconds = registration.last_seen_unix_seconds,
        .objects = locked orelse &.{},
    };
}

/// Probes the object lease without waiting. A held lease means some process is
/// using the object right now.
fn objectInUse(io: std.Io, allocator: std.mem.Allocator, lock_root: []const u8) !bool {
    const lock_path = try std.mem.concat(allocator, u8, &.{ lock_root, ".lock" });
    if (!pathExists(io, lock_path)) return false;
    const exclusive = (try store_locks.tryAcquireObjectExclusive(io, allocator, lock_root)) orelse return true;
    exclusive.close(io);
    return false;
}

fn appendIssue(
    allocator: std.mem.Allocator,
    issues: *std.ArrayList([]const u8),
    subject: []const u8,
    err: anyerror,
) !void {
    try issues.append(allocator, try std.fmt.allocPrint(
        allocator,
        "{s}: {s}",
        .{ subject, @errorName(err) },
    ));
}

pub fn prune(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: PruneOptions,
) !PruneResult {
    const home = try release_store.hutchHome(init, allocator);
    try validateDestructiveHome(init, allocator, home);
    const executable = std.process.executablePathAlloc(init.io, allocator) catch null;
    return (try pruneAtMode(
        init.io,
        allocator,
        home,
        options,
        .manual,
        executable,
    )).?;
}

/// Runs the bounded, best-effort maintenance sweep used by ordinary Hutch
/// invocations. It never waits for the graph lock and intentionally suppresses
/// all maintenance errors: a prune problem must not break the user's command.
pub fn pruneAutomatic(init: std.process.Init, allocator: std.mem.Allocator) void {
    const home = release_store.hutchHome(init, allocator) catch return;
    validateDestructiveHome(init, allocator, home) catch return;
    const executable = std.process.executablePathAlloc(init.io, allocator) catch null;
    _ = pruneAtMode(
        init.io,
        allocator,
        home,
        .{},
        .automatic,
        executable,
    ) catch return;
}

fn pruneAt(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    options: PruneOptions,
) !PruneResult {
    return (try pruneAtMode(io, allocator, home, options, .manual, null)).?;
}

fn pruneAutomaticAt(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    now: i64,
    protected_relative_roots: []const []const u8,
) !?PruneResult {
    return pruneAtMode(io, allocator, home, .{
        .now_unix_seconds = now,
        .protected_relative_roots = protected_relative_roots,
    }, .automatic, null);
}

fn pruneAtMode(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    options: PruneOptions,
    kind: PruneKind,
    current_executable: ?[]const u8,
) !?PruneResult {
    const now = options.now_unix_seconds orelse unixSeconds(io);
    if (now < 0) return error.InvalidPruneTimestamp;
    try validateStoreOwnership(io, allocator, home);

    // A preview is deliberately lock-free. Acquiring the persistent graph
    // lock would create state files and violate the dry-run contract.
    if (options.dry_run) {
        return try sweep(
            io,
            allocator,
            home,
            options,
            kind,
            current_executable,
            now,
            false,
            null,
        );
    }

    var trash_root: ?[]const u8 = null;
    var stale_trash: std.ArrayList([]const u8) = .empty;
    var final_result: PruneResult = undefined;
    {
        const graph_lock = switch (kind) {
            .manual => try acquireGraphLockAt(io, allocator, home, .exclusive),
            .automatic => (try store_locks.tryAcquireGraphExclusive(io, allocator, home)) orelse return null,
        };
        defer graph_lock.close(io);

        try collectTrashRoots(io, allocator, home, &stale_trash);
        final_result = try sweep(
            io,
            allocator,
            home,
            options,
            kind,
            current_executable,
            now,
            true,
            &trash_root,
        );
    }

    // Candidates were detached atomically under the graph lock. Slow recursive
    // deletion happens afterward; crash trash is safe to remove on a later run.
    for (stale_trash.items) |path| std.Io.Dir.cwd().deleteTree(io, path) catch {};
    if (trash_root) |path| std.Io.Dir.cwd().deleteTree(io, path) catch {};
    return final_result;
}

fn sweep(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    options: PruneOptions,
    kind: PruneKind,
    current_executable: ?[]const u8,
    now: i64,
    mutating: bool,
    trash_root: ?*?[]const u8,
) !PruneResult {
    const registrations = try scanRegistrations(io, allocator, home);
    var reachable_roots: std.ArrayList([]const u8) = .empty;
    try reachable_roots.appendSlice(allocator, registrations.reachable.items);
    try collectSelectionRoots(io, allocator, home, &reachable_roots);
    for (options.protected_relative_roots) |root| {
        try validateManagedRelativeRoot(root);
        if (!containsPath(reachable_roots.items, root)) try reachable_roots.append(allocator, root);
    }

    var candidates: std.ArrayList(Candidate) = .empty;
    try collectReleaseCandidates(io, allocator, home, "hutch", &candidates);
    try collectReleaseCandidates(io, allocator, home, "cottontail", &candidates);
    try collectElectrobunCandidates(io, allocator, home, &candidates);
    try collectToolchainCandidates(io, allocator, home, &candidates);
    std.mem.sort(Candidate, candidates.items, {}, candidateLessThan);

    const dispositions = try allocator.alloc(CandidateDisposition, candidates.items.len);
    for (candidates.items, 0..) |candidate, index| {
        const explicitly_reachable = candidateIsReachable(reachable_roots.items, candidate) or
            (current_executable != null and try candidateContainsAbsolutePath(
                io,
                allocator,
                candidate,
                current_executable.?,
            ));
        const leased = try objectInUse(io, allocator, candidate.lock_root);
        if (explicitly_reachable or leased) {
            dispositions[index] = .reachable;
            if (mutating) {
                try deleteUnreachableSince(io, allocator, home, candidate.relative_root);
            }
            continue;
        }

        if (kind == .manual) {
            dispositions[index] = .eligible;
            continue;
        }

        const unreachable_since = readUnreachableSince(
            io,
            allocator,
            home,
            candidate.relative_root,
        ) catch null;
        if (unreachable_since == null or now < unreachable_since.?) {
            dispositions[index] = .retention_kept;
            if (mutating) try writeUnreachableSince(io, allocator, home, candidate.relative_root, now);
            continue;
        }
        if (now - unreachable_since.? < automatic_retention_seconds) {
            dispositions[index] = .retention_kept;
            continue;
        }
        dispositions[index] = .eligible;
    }

    // CEF is independently collectible, but collecting its core necessarily
    // collects CEF too. Keep the parent whenever a descendant is protected or
    // still inside automatic retention.
    for (candidates.items, 0..) |candidate, index| {
        if (candidate.kind != .electrobun or dispositions[index] != .eligible) continue;
        for (candidates.items, dispositions) |other, disposition| {
            if (!candidateContains(candidate, other) or disposition == .eligible) continue;
            dispositions[index] = disposition;
            break;
        }
    }

    var eligible_actions: std.ArrayList(PruneAction) = .empty;
    var reachable_count: usize = 0;
    var retention_kept: usize = 0;
    for (candidates.items, dispositions, 0..) |candidate, disposition, index| {
        switch (disposition) {
            .reachable => reachable_count += 1,
            .retention_kept => retention_kept += 1,
            .eligible => if (!candidateHasEligibleAncestor(candidates.items, dispositions, index)) {
                try eligible_actions.append(allocator, .{
                    .relative_root = try allocator.dupe(u8, candidate.relative_root),
                });
            },
        }
    }

    if (!mutating) {
        const eligible_count = eligible_actions.items.len;
        return .{
            .actions = try eligible_actions.toOwnedSlice(allocator),
            .scanned = candidates.items.len,
            .reachable = reachable_count,
            .retention_kept = retention_kept,
            .eligible = eligible_count,
            .expired_registrations = registrations.expired_paths.items.len,
            .pruned = 0,
        };
    }

    for (registrations.expired_paths.items) |path| {
        std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    var pruned_actions: std.ArrayList(PruneAction) = .empty;
    for (eligible_actions.items) |action| {
        const candidate = findCandidate(candidates.items, action.relative_root) orelse continue;
        if (!try candidateStillOwned(io, allocator, home, candidate)) continue;
        {
            const object_lock = try tryAcquireCandidateLock(
                io,
                allocator,
                home,
                candidate.lock_root,
            ) orelse continue;
            defer object_lock.close(io);
            const batch = trash_root.?.* orelse blk: {
                const created = try createTrashRoot(io, allocator, home);
                trash_root.?.* = created;
                break :blk created;
            };
            const destination = try relativeRootPath(allocator, batch, candidate.relative_root);
            const destination_parent = std.fs.path.dirname(destination) orelse return error.InvalidStoreTrashPath;
            try std.Io.Dir.cwd().createDirPath(io, destination_parent);
            std.Io.Dir.cwd().rename(candidate.absolute_root, std.Io.Dir.cwd(), destination, io) catch |err| switch (err) {
                error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.FileBusy => continue,
                else => return err,
            };
        }
        try deleteUnreachableSince(io, allocator, home, candidate.relative_root);
        if (candidate.kind != .electrobun_cef) {
            const lock_path = try std.mem.concat(allocator, u8, &.{ candidate.lock_root, ".lock" });
            std.Io.Dir.cwd().deleteFile(io, lock_path) catch {};
        }
        removeEmptyManagedParents(io, allocator, home, candidate) catch {};
        try pruned_actions.append(allocator, action);
    }
    const pruned_count = pruned_actions.items.len;
    return .{
        .actions = try pruned_actions.toOwnedSlice(allocator),
        .scanned = candidates.items.len,
        .reachable = reachable_count,
        .retention_kept = retention_kept,
        .eligible = eligible_actions.items.len,
        .expired_registrations = registrations.expired_paths.items.len,
        .pruned = pruned_count,
    };
}

fn collectTrashRoots(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    output: *std.ArrayList([]const u8),
) !void {
    const root = try std.fs.path.join(allocator, &.{ home, state_relative_root, "trash" });
    var directory = std.Io.Dir.cwd().openDir(io, root, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        error.NotDir => return error.InvalidStoreTrashPath,
        else => return err,
    };
    defer directory.close(io);
    if (!try pathResolvesWithin(io, allocator, home, root)) return error.InvalidStoreTrashPath;
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        validateTrashName(entry.name) catch continue;
        try output.append(allocator, try std.fs.path.join(allocator, &.{ root, entry.name }));
    }
}

fn scanRegistrations(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
) !RegistrationScan {
    var result: RegistrationScan = .{};
    const projects_root = try std.fs.path.join(allocator, &.{ home, state_relative_root, "projects" });
    var directory = std.Io.Dir.cwd().openDir(io, projects_root, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return result,
        error.NotDir => return error.InvalidStoreStatePath,
        else => return err,
    };
    defer directory.close(io);
    if (!try pathResolvesWithin(io, allocator, home, projects_root)) return error.InvalidStoreStatePath;
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        // Never follow registration aliases. Non-files protect nothing and are
        // left for reset rather than turning one damaged entry into a global
        // fail-closed root.
        if (entry.kind != .file) continue;
        const path = try std.fs.path.join(allocator, &.{ projects_root, entry.name });
        const parsed = parseRegistration(io, allocator, home, path, entry.name) catch {
            try result.expired_paths.append(allocator, path);
            continue;
        };
        const project_objects = projectLockObjectsIfMatches(
            io,
            allocator,
            parsed.canonical_root,
            parsed.lock_sha256,
        ) catch null;
        if (project_objects == null) {
            try result.expired_paths.append(allocator, path);
            continue;
        }
        for (project_objects.?) |managed| {
            if (!containsPath(result.reachable.items, managed.relative_root)) {
                try result.reachable.append(allocator, managed.relative_root);
            }
        }
    }
    return result;
}

const ParsedRegistration = struct {
    canonical_root: []const u8,
    lock_sha256: []const u8,
    last_seen_unix_seconds: i64,
};

fn parseRegistration(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    path: []const u8,
    file_name: []const u8,
) !ParsedRegistration {
    if (!try pathResolvesWithin(io, allocator, home, path)) return error.InvalidProjectRegistration;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_state_file_bytes));
    const registration = std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidProjectRegistration;
    const object = try requiredObject(registration);
    if (object.count() != 5) return error.InvalidProjectRegistration;
    _ = try readableSchemaVersion(object);
    if (!std.mem.eql(u8, try requiredString(object, "kind"), registration_kind)) {
        return error.InvalidProjectRegistration;
    }
    const canonical_root = try requiredString(object, "canonicalRoot");
    if (!std.fs.path.isAbsolute(canonical_root)) return error.InvalidProjectRegistration;
    const expected_name = try projectRegistrationName(allocator, canonical_root);
    if (!std.mem.eql(u8, expected_name, file_name)) return error.InvalidProjectRegistration;
    const lock_sha256 = try requiredString(object, "projectLockSha256");
    try validateSha256(lock_sha256);
    const last_seen = try requiredInteger(object, "lastSeenUnixSeconds");
    if (last_seen < 0) return error.InvalidProjectRegistration;
    return .{
        .canonical_root = canonical_root,
        .lock_sha256 = lock_sha256,
        .last_seen_unix_seconds = last_seen,
    };
}

fn projectLockObjectsIfMatches(
    io: std.Io,
    allocator: std.mem.Allocator,
    canonical_root: []const u8,
    expected_sha256: []const u8,
) !?[]const ManagedObject {
    var project_state_dir = project_state.open(io, canonical_root, .existing, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer project_state_dir.close(io);
    const bytes = project_state.readFileAlloc(
        io,
        allocator,
        project_state_dir,
        "dependencies.lock",
        .limited(max_state_file_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &actual, expected_sha256)) return null;

    const project_lock = std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidProjectDependencyLock;
    const object = requiredObject(project_lock) catch return error.InvalidProjectDependencyLock;
    if (object.count() != 3) return error.InvalidProjectDependencyLock;
    _ = readableSchemaVersion(object) catch return error.InvalidProjectDependencyLock;
    if (!std.mem.eql(u8, requiredString(object, "kind") catch return error.InvalidProjectDependencyLock, project_lock_kind)) {
        return error.InvalidProjectDependencyLock;
    }
    const values = object.get("objects") orelse return error.InvalidProjectDependencyLock;
    if (values != .array) return error.InvalidProjectDependencyLock;
    var objects: std.ArrayList(ManagedObject) = .empty;
    for (values.array.items) |value| {
        appendParsedManagedObject(allocator, &objects, value) catch return error.InvalidProjectDependencyLock;
    }
    const owned = try objects.toOwnedSlice(allocator);
    return @as(?[]const ManagedObject, owned);
}

fn readableSchemaVersion(object: std.json.ObjectMap) !usize {
    const value = try requiredInteger(object, "schemaVersion");
    if (value != schema_version) {
        return error.UnsupportedStoreSchema;
    }
    return @intCast(value);
}

fn appendParsedManagedObject(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(ManagedObject),
    value: std.json.Value,
) !void {
    const object = try requiredObject(value);
    const kind_name = try requiredString(object, "type");
    const relative_root = try requiredString(object, "relativeRoot");
    const version = try requiredString(object, "version");
    const platform = try requiredString(object, "platform");
    try validateSegment(version);
    try validatePlatform(platform);
    if (std.mem.eql(u8, kind_name, "electrobun")) {
        if (!std.mem.eql(u8, try requiredString(object, "product"), "electrobun")) return error.InvalidProjectRegistration;
        const expected = try std.fmt.allocPrint(allocator, "releases/electrobun/{s}/{s}", .{ version, platform });
        if (!std.mem.eql(u8, expected, relative_root)) return error.InvalidProjectRegistration;
        const core_sha256 = try requiredString(object, "coreSha256");
        const source_sha256 = try requiredString(object, "sourceManifestSha256");
        try validateSha256(core_sha256);
        try validateSha256(source_sha256);
        try output.append(allocator, .{
            .kind = .electrobun,
            .relative_root = relative_root,
            .version = version,
            .platform = platform,
            .core_sha256 = core_sha256,
            .source_manifest_sha256 = source_sha256,
        });
        if (object.get("cefSha256") != null) return error.InvalidProjectRegistration;
        return;
    }
    if (std.mem.eql(u8, kind_name, "electrobun-cef")) {
        if (!std.mem.eql(u8, try requiredString(object, "product"), "electrobun")) return error.InvalidProjectRegistration;
        const expected = try std.fmt.allocPrint(allocator, "releases/electrobun/{s}/{s}/cef", .{ version, platform });
        if (!std.mem.eql(u8, expected, relative_root)) return error.InvalidProjectRegistration;
        const cef_sha256 = try requiredString(object, "cefSha256");
        try validateSha256(cef_sha256);
        try output.append(allocator, .{
            .kind = .electrobun_cef,
            .relative_root = relative_root,
            .version = version,
            .platform = platform,
            .cef_sha256 = cef_sha256,
        });
        return;
    }
    if (std.mem.eql(u8, kind_name, "release")) {
        const product = try requiredString(object, "product");
        try validateReleaseProduct(product);
        const revision = try requiredString(object, "revision");
        try validateRevision(revision);
        const archive_sha256 = try requiredString(object, "archiveSha256");
        try validateSha256(archive_sha256);
        const expected = try std.fmt.allocPrint(
            allocator,
            "releases/{s}/{s}/{s}/{s}",
            .{ product, version, revision, platform },
        );
        if (!std.mem.eql(u8, expected, relative_root)) return error.InvalidProjectRegistration;
        try output.append(allocator, .{
            .kind = .release,
            .relative_root = relative_root,
            .version = version,
            .platform = platform,
            .release_product = product,
            .revision = revision,
            .archive_sha256 = archive_sha256,
        });
        return;
    }
    if (std.mem.eql(u8, kind_name, "toolchain")) {
        const toolchain_kind = try requiredString(object, "toolchain");
        try validateToolchainKind(toolchain_kind);
        const expected = try std.fmt.allocPrint(allocator, "toolchains/{s}/{s}/{s}", .{ toolchain_kind, version, platform });
        if (!std.mem.eql(u8, expected, relative_root)) return error.InvalidProjectRegistration;
        try output.append(allocator, .{
            .kind = .toolchain,
            .relative_root = relative_root,
            .version = version,
            .platform = platform,
            .toolchain_kind = toolchain_kind,
        });
        return;
    }
    return error.InvalidProjectRegistration;
}

fn collectSelectionRoots(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    output: *std.ArrayList([]const u8),
) !void {
    const path = try std.fs.path.join(allocator, &.{
        home,
        state_relative_root,
        release_store.selections_file_name,
    });
    const stat = std.Io.Dir.cwd().statFile(io, path, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind != .file or !try pathResolvesWithin(io, allocator, home, path)) {
        return error.InvalidSelectionsState;
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024));
    const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidSelectionsState;
    if (value != .object or value.object.count() != 3) return error.InvalidSelectionsState;
    const schema = requiredInteger(value.object, "schemaVersion") catch return error.InvalidSelectionsState;
    if (schema != 1) return error.UnsupportedSelectionsSchema;
    const marker_kind = requiredString(value.object, "kind") catch return error.InvalidSelectionsState;
    if (!std.mem.eql(u8, marker_kind, "hutch-selections")) return error.InvalidSelectionsState;
    const products = value.object.get("products") orelse return error.InvalidSelectionsState;
    if (products != .object or !objectHasOnlyKeys(products.object, &.{ "hutch", "cottontail" })) {
        return error.InvalidSelectionsState;
    }

    for ([_][]const u8{ "hutch", "cottontail" }) |product| {
        const channels = products.object.get(product) orelse continue;
        if (channels != .object or !objectHasOnlyKeys(channels.object, &.{ "production", "canary" })) {
            return error.InvalidSelectionsState;
        }
        for ([_][]const u8{ "production", "canary" }) |channel| {
            const selected = channels.object.get(channel) orelse continue;
            if (selected != .object or selected.object.count() != 3) return error.InvalidSelectionsState;
            const version = requiredString(selected.object, "version") catch return error.InvalidSelectionsState;
            const parsed = version_selector.parse(version) catch return error.InvalidSelectionsState;
            if (parsed.kind != .version) return error.InvalidSelectionsState;
            const revision = requiredString(selected.object, "revision") catch return error.InvalidSelectionsState;
            validateRevision(revision) catch return error.InvalidSelectionsState;
            const platform = requiredString(selected.object, "platform") catch return error.InvalidSelectionsState;
            validatePlatform(platform) catch return error.InvalidSelectionsState;
            const root = try std.fmt.allocPrint(
                allocator,
                "releases/{s}/{s}/{s}/{s}",
                .{ product, version, revision, platform },
            );
            if (!containsPath(output.items, root)) try output.append(allocator, root);
        }
    }
}

fn objectHasOnlyKeys(object: std.json.ObjectMap, allowed: []const []const u8) bool {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var recognized = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) {
                recognized = true;
                break;
            }
        }
        if (!recognized) return false;
    }
    return true;
}

fn collectReleaseCandidates(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    product: []const u8,
    output: *std.ArrayList(Candidate),
) !void {
    try validateReleaseProduct(product);
    const root = try std.fs.path.join(allocator, &.{ home, "releases", product });
    var versions = std.Io.Dir.cwd().openDir(io, root, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer versions.close(io);
    if (!try pathResolvesWithin(io, allocator, home, root)) return error.InvalidManagedObjectPath;

    var version_iterator = versions.iterate();
    while (try version_iterator.next(io)) |version_entry| {
        if (version_entry.kind != .directory) continue;
        const parsed_version = version_selector.parse(version_entry.name) catch continue;
        if (parsed_version.kind != .version) continue;
        const version_root = try std.fs.path.join(allocator, &.{ root, version_entry.name });
        var revisions = std.Io.Dir.cwd().openDir(io, version_root, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch continue;
        defer revisions.close(io);
        var revision_iterator = revisions.iterate();
        while (try revision_iterator.next(io)) |revision_entry| {
            if (revision_entry.kind != .directory) continue;
            validateRevision(revision_entry.name) catch continue;
            const revision_root = try std.fs.path.join(allocator, &.{ version_root, revision_entry.name });
            var platforms = std.Io.Dir.cwd().openDir(io, revision_root, .{
                .iterate = true,
                .follow_symlinks = false,
            }) catch continue;
            defer platforms.close(io);
            var platform_iterator = platforms.iterate();
            while (try platform_iterator.next(io)) |platform_entry| {
                if (platform_entry.kind != .directory) continue;
                validatePlatform(platform_entry.name) catch continue;
                const absolute = try std.fs.path.join(allocator, &.{ revision_root, platform_entry.name });
                if (!try pathResolvesWithin(io, allocator, home, absolute)) continue;
                try output.append(allocator, .{
                    .kind = .release,
                    .absolute_root = absolute,
                    .lock_root = absolute,
                    .relative_root = try std.fmt.allocPrint(
                        allocator,
                        "releases/{s}/{s}/{s}/{s}",
                        .{ product, version_entry.name, revision_entry.name, platform_entry.name },
                    ),
                    .version = try allocator.dupe(u8, version_entry.name),
                    .platform = try allocator.dupe(u8, platform_entry.name),
                    .toolchain_kind = null,
                });
            }
        }
    }
}

fn releaseManagedObjectFromCandidate(
    io: std.Io,
    allocator: std.mem.Allocator,
    product: release_store.Product,
    candidate: Candidate,
) !ManagedObject {
    if (candidate.kind != .release) return error.ExpectedManagedRelease;
    var parts = std.mem.splitScalar(u8, candidate.relative_root, '/');
    if (!std.mem.eql(u8, parts.next() orelse return error.InvalidManagedObjectPath, "releases")) {
        return error.InvalidManagedObjectPath;
    }
    if (!std.mem.eql(u8, parts.next() orelse return error.InvalidManagedObjectPath, product.name())) {
        return error.InvalidManagedObjectPath;
    }
    const version = parts.next() orelse return error.InvalidManagedObjectPath;
    const revision = parts.next() orelse return error.InvalidManagedObjectPath;
    const platform = parts.next() orelse return error.InvalidManagedObjectPath;
    if (parts.next() != null) return error.InvalidManagedObjectPath;

    const marker = try readTrimmedFile(
        io,
        allocator,
        try std.fs.path.join(allocator, &.{ candidate.absolute_root, ".dash-installed" }),
        128,
    );
    try validateSha256(marker);
    const executable = try std.fs.path.join(allocator, &.{
        candidate.absolute_root,
        "bin",
        product.executableFileName(),
    });
    if (!pathExists(io, executable)) return error.ManagedReleaseExecutableMissing;

    const metadata_name = switch (product) {
        .hutch => "hutch-release.json",
        .cottontail => "cottontail-release.json",
    };
    const metadata_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        try std.fs.path.join(allocator, &.{ candidate.absolute_root, metadata_name }),
        allocator,
        .limited(max_state_file_bytes),
    );
    const metadata = try std.json.parseFromSliceLeaky(std.json.Value, allocator, metadata_bytes, .{
        .duplicate_field_behavior = .@"error",
    });
    if (metadata != .object) return error.InvalidManagedReleaseMetadata;
    if ((requiredInteger(metadata.object, "schema") catch return error.InvalidManagedReleaseMetadata) != 1) {
        return error.InvalidManagedReleaseMetadata;
    }
    if (!std.mem.eql(u8, requiredString(metadata.object, "kind") catch return error.InvalidManagedReleaseMetadata, "archive") or
        !std.mem.eql(u8, requiredString(metadata.object, "product") catch return error.InvalidManagedReleaseMetadata, product.name()) or
        !std.mem.eql(u8, requiredString(metadata.object, "version") catch return error.InvalidManagedReleaseMetadata, version) or
        !std.mem.eql(u8, requiredString(metadata.object, "revision") catch return error.InvalidManagedReleaseMetadata, revision) or
        !std.mem.eql(u8, requiredString(metadata.object, "platform") catch return error.InvalidManagedReleaseMetadata, platform))
    {
        return error.InvalidManagedReleaseMetadata;
    }

    return .{
        .kind = .release,
        .relative_root = try allocator.dupe(u8, candidate.relative_root),
        .version = try allocator.dupe(u8, version),
        .platform = try allocator.dupe(u8, platform),
        .release_product = product.name(),
        .revision = try allocator.dupe(u8, revision),
        .archive_sha256 = try allocator.dupe(u8, marker),
    };
}

fn collectElectrobunCandidates(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    output: *std.ArrayList(Candidate),
) !void {
    const root = try std.fs.path.join(allocator, &.{ home, "releases", "electrobun" });
    var versions = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer versions.close(io);
    if (!try pathResolvesWithin(io, allocator, home, root)) return error.InvalidManagedObjectPath;
    var version_iterator = versions.iterate();
    while (try version_iterator.next(io)) |version_entry| {
        if (version_entry.kind != .directory) continue;
        validateSegment(version_entry.name) catch continue;
        const version_root = try std.fs.path.join(allocator, &.{ root, version_entry.name });
        var platforms = try std.Io.Dir.cwd().openDir(io, version_root, .{ .iterate = true });
        defer platforms.close(io);
        var platform_iterator = platforms.iterate();
        while (try platform_iterator.next(io)) |platform_entry| {
            if (platform_entry.kind != .directory) continue;
            validatePlatform(platform_entry.name) catch continue;
            const absolute = try std.fs.path.join(allocator, &.{ version_root, platform_entry.name });
            const candidate: Candidate = .{
                .kind = .electrobun,
                .absolute_root = absolute,
                .lock_root = absolute,
                .relative_root = try std.fmt.allocPrint(allocator, "releases/electrobun/{s}/{s}", .{ version_entry.name, platform_entry.name }),
                .version = try allocator.dupe(u8, version_entry.name),
                .platform = try allocator.dupe(u8, platform_entry.name),
            };
            if (try pathResolvesWithin(io, allocator, home, absolute)) {
                try output.append(allocator, candidate);
            }

            const cef_absolute = try std.fs.path.join(allocator, &.{ absolute, "cef" });
            const cef_candidate: Candidate = .{
                .kind = .electrobun_cef,
                .absolute_root = cef_absolute,
                // Core and CEF publication share the platform-root lock.
                .lock_root = absolute,
                .relative_root = try std.fmt.allocPrint(allocator, "releases/electrobun/{s}/{s}/cef", .{ version_entry.name, platform_entry.name }),
                .version = try allocator.dupe(u8, version_entry.name),
                .platform = try allocator.dupe(u8, platform_entry.name),
            };
            const cef_stat = std.Io.Dir.cwd().statFile(io, cef_absolute, .{
                .follow_symlinks = false,
            }) catch continue;
            if (cef_stat.kind == .directory and
                try pathResolvesWithin(io, allocator, home, cef_absolute))
            {
                try output.append(allocator, cef_candidate);
            }
        }
    }
}

fn collectToolchainCandidates(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    output: *std.ArrayList(Candidate),
) !void {
    const root = try std.fs.path.join(allocator, &.{ home, "toolchains" });
    var kinds = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer kinds.close(io);
    if (!try pathResolvesWithin(io, allocator, home, root)) return error.InvalidManagedObjectPath;
    var kind_iterator = kinds.iterate();
    while (try kind_iterator.next(io)) |kind_entry| {
        if (kind_entry.kind != .directory) continue;
        validateToolchainKind(kind_entry.name) catch continue;
        const kind_root = try std.fs.path.join(allocator, &.{ root, kind_entry.name });
        var versions = try std.Io.Dir.cwd().openDir(io, kind_root, .{ .iterate = true });
        defer versions.close(io);
        var version_iterator = versions.iterate();
        while (try version_iterator.next(io)) |version_entry| {
            if (version_entry.kind != .directory) continue;
            validateSegment(version_entry.name) catch continue;
            const version_root = try std.fs.path.join(allocator, &.{ kind_root, version_entry.name });
            var platforms = try std.Io.Dir.cwd().openDir(io, version_root, .{ .iterate = true });
            defer platforms.close(io);
            var platform_iterator = platforms.iterate();
            while (try platform_iterator.next(io)) |platform_entry| {
                if (platform_entry.kind != .directory) continue;
                validatePlatform(platform_entry.name) catch continue;
                const absolute = try std.fs.path.join(allocator, &.{ version_root, platform_entry.name });
                const candidate: Candidate = .{
                    .kind = .toolchain,
                    .absolute_root = absolute,
                    .lock_root = absolute,
                    .relative_root = try std.fmt.allocPrint(allocator, "toolchains/{s}/{s}/{s}", .{ kind_entry.name, version_entry.name, platform_entry.name }),
                    .version = try allocator.dupe(u8, version_entry.name),
                    .platform = try allocator.dupe(u8, platform_entry.name),
                    .toolchain_kind = try allocator.dupe(u8, kind_entry.name),
                };
                if (try pathResolvesWithin(io, allocator, home, absolute)) {
                    try output.append(allocator, candidate);
                }
            }
        }
    }
}

fn candidateLessThan(_: void, lhs: Candidate, rhs: Candidate) bool {
    return std.mem.order(u8, lhs.relative_root, rhs.relative_root) == .lt;
}

fn candidateStillOwned(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    candidate: Candidate,
) !bool {
    try validateManagedRelativeRoot(candidate.relative_root);
    const expected = try relativeRootPath(allocator, home, candidate.relative_root);
    if (!pathEqual(expected, candidate.absolute_root)) return false;
    const stat = std.Io.Dir.cwd().statFile(io, candidate.absolute_root, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return stat.kind == .directory and
        try pathResolvesWithin(io, allocator, home, candidate.absolute_root);
}

fn findCandidate(candidates: []const Candidate, relative_root: []const u8) ?Candidate {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.relative_root, relative_root)) return candidate;
    }
    return null;
}

fn containsPath(paths: []const []const u8, needle: []const u8) bool {
    for (paths) |path| if (std.mem.eql(u8, path, needle)) return true;
    return false;
}

fn candidateIsReachable(paths: []const []const u8, candidate: Candidate) bool {
    if (containsPath(paths, candidate.relative_root)) return true;
    if (candidate.kind != .electrobun) return false;
    for (paths) |path| {
        if (path.len > candidate.relative_root.len and
            std.mem.startsWith(u8, path, candidate.relative_root) and
            path[candidate.relative_root.len] == '/')
        {
            return true;
        }
    }
    return false;
}

fn candidateContains(parent: Candidate, child: Candidate) bool {
    return child.relative_root.len > parent.relative_root.len and
        std.mem.startsWith(u8, child.relative_root, parent.relative_root) and
        child.relative_root[parent.relative_root.len] == '/';
}

fn candidateContainsAbsolutePath(
    io: std.Io,
    allocator: std.mem.Allocator,
    candidate: Candidate,
    path: []const u8,
) !bool {
    const canonical_root = try std.Io.Dir.cwd().realPathFileAlloc(io, candidate.absolute_root, allocator);
    const canonical_path = std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator) catch return false;
    return pathEqual(canonical_path, canonical_root) or pathHasParent(canonical_path, canonical_root);
}

fn candidateHasEligibleAncestor(
    candidates: []const Candidate,
    dispositions: []const CandidateDisposition,
    child_index: usize,
) bool {
    for (candidates, dispositions, 0..) |candidate, disposition, index| {
        if (index == child_index or disposition != .eligible) continue;
        if (candidateContains(candidate, candidates[child_index])) return true;
    }
    return false;
}

fn tryAcquireCandidateLock(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    candidate_root: []const u8,
) !?std.Io.File {
    const lock_path = try std.mem.concat(allocator, u8, &.{ candidate_root, ".lock" });
    try store_locks.initializePersistentFile(io, lock_path);
    if (!try pathResolvesWithin(io, allocator, home, lock_path)) {
        return error.InvalidManagedObjectPath;
    }
    return store_locks.tryAcquireObjectExclusive(io, allocator, candidate_root);
}

fn removeEmptyManagedParents(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    candidate: Candidate,
) !void {
    var parts = std.mem.splitScalar(u8, candidate.relative_root, '/');
    const namespace = parts.next() orelse return;
    const owner = parts.next() orelse return;
    const stop = if (std.mem.eql(u8, namespace, "releases"))
        try std.fs.path.join(allocator, &.{ home, "releases", owner })
    else if (std.mem.eql(u8, namespace, "toolchains"))
        try std.fs.path.join(allocator, &.{ home, "toolchains", owner })
    else
        return;
    if (!try pathResolvesWithin(io, allocator, home, stop)) return;

    var current = std.fs.path.dirname(candidate.absolute_root) orelse return;
    while (!pathEqual(current, stop) and pathHasParent(current, stop)) {
        std.Io.Dir.cwd().deleteDir(io, current) catch return;
        current = std.fs.path.dirname(current) orelse return;
    }
}

fn createTrashRoot(io: std.Io, allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
    var random: [12]u8 = undefined;
    io.random(&random);
    const suffix = std.fmt.bytesToHex(random, .lower);
    const trash_parent = try std.fs.path.join(allocator, &.{ home, state_relative_root, "trash" });
    try ensureDirectoryWithin(io, allocator, home, trash_parent, error.InvalidStoreTrashPath);
    const root = try std.fs.path.join(allocator, &.{ trash_parent, &suffix });
    try std.Io.Dir.cwd().createDirPath(io, root);
    if (!try pathResolvesWithin(io, allocator, home, root)) return error.InvalidStoreTrashPath;
    return root;
}

fn relativeRootPath(allocator: std.mem.Allocator, base: []const u8, relative_root: []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    try parts.append(allocator, base);
    var iterator = std.mem.splitScalar(u8, relative_root, '/');
    while (iterator.next()) |part| {
        try validateSegment(part);
        try parts.append(allocator, part);
    }
    return std.fs.path.join(allocator, parts.items);
}

fn validateManagedRelativeRoot(relative_root: []const u8) !void {
    var parts: [6][]const u8 = undefined;
    var count: usize = 0;
    var iterator = std.mem.splitScalar(u8, relative_root, '/');
    while (iterator.next()) |part| {
        if (count == parts.len) return error.InvalidManagedObjectPath;
        try validateSegment(part);
        parts[count] = part;
        count += 1;
    }

    if (count == 4 and std.mem.eql(u8, parts[0], "toolchains")) {
        try validateToolchainKind(parts[1]);
        const parsed = try version_selector.parse(parts[2]);
        if (parsed.kind != .version) return error.InvalidManagedObjectPath;
        return validatePlatform(parts[3]);
    }
    if (count == 4 and
        std.mem.eql(u8, parts[0], "releases") and
        std.mem.eql(u8, parts[1], "electrobun"))
    {
        const parsed = try version_selector.parse(parts[2]);
        if (parsed.kind != .version) return error.InvalidManagedObjectPath;
        return validatePlatform(parts[3]);
    }
    if (count == 5 and
        std.mem.eql(u8, parts[0], "releases") and
        std.mem.eql(u8, parts[1], "electrobun") and
        std.mem.eql(u8, parts[4], "cef"))
    {
        const parsed = try version_selector.parse(parts[2]);
        if (parsed.kind != .version) return error.InvalidManagedObjectPath;
        return validatePlatform(parts[3]);
    }
    if (count == 5 and std.mem.eql(u8, parts[0], "releases")) {
        try validateReleaseProduct(parts[1]);
        const parsed = try version_selector.parse(parts[2]);
        if (parsed.kind != .version) return error.InvalidManagedObjectPath;
        try validateRevision(parts[3]);
        return validatePlatform(parts[4]);
    }
    return error.InvalidManagedObjectPath;
}

fn projectRegistrationPath(
    allocator: std.mem.Allocator,
    home: []const u8,
    canonical_root: []const u8,
) ![]const u8 {
    return std.fs.path.join(allocator, &.{
        home,
        state_relative_root,
        "projects",
        try projectRegistrationName(allocator, canonical_root),
    });
}

fn projectRegistrationName(allocator: std.mem.Allocator, canonical_root: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical_root, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "{s}.json", .{hex});
}

fn projectRegistrationLockPath(
    allocator: std.mem.Allocator,
    home: []const u8,
    canonical_root: []const u8,
) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical_root, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const name = try std.fmt.allocPrint(allocator, "{s}.lock", .{hex});
    return std.fs.path.join(allocator, &.{ home, state_relative_root, "locks", "projects", name });
}

fn unreachableSincePath(
    allocator: std.mem.Allocator,
    home: []const u8,
    relative_root: []const u8,
) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(relative_root, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const name = try std.fmt.allocPrint(allocator, "{s}.timestamp", .{hex});
    return std.fs.path.join(allocator, &.{ home, state_relative_root, "unreachable-since", name });
}

fn writeUnreachableSince(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    relative_root: []const u8,
    now: i64,
) !void {
    const path = try unreachableSincePath(allocator, home, relative_root);
    try ensureDirectoryWithin(
        io,
        allocator,
        home,
        std.fs.path.dirname(path) orelse return error.InvalidStoreStatePath,
        error.InvalidStoreStatePath,
    );
    const value = try std.fmt.allocPrint(allocator, "{d}\n", .{now});
    try atomicWrite(io, allocator, path, value);
}

fn readUnreachableSince(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    relative_root: []const u8,
) !?i64 {
    const path = try unreachableSincePath(allocator, home, relative_root);
    const parent = std.fs.path.dirname(path) orelse return error.InvalidStoreStatePath;
    var directory = std.Io.Dir.cwd().openDir(io, parent, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer directory.close(io);
    if (!try pathResolvesWithin(io, allocator, home, parent)) return error.InvalidStoreStatePath;
    const value = readTrimmedFile(io, allocator, path, 64) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const timestamp = std.fmt.parseInt(i64, value, 10) catch return error.InvalidUnreachableSinceMarker;
    if (timestamp < 0) return error.InvalidUnreachableSinceMarker;
    return timestamp;
}

fn deleteUnreachableSince(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    relative_root: []const u8,
) !void {
    const path = try unreachableSincePath(allocator, home, relative_root);
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn atomicWrite(io: std.Io, allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidStoreStatePath;
    try std.Io.Dir.cwd().createDirPath(io, parent);
    var random: [12]u8 = undefined;
    io.random(&random);
    const suffix = std.fmt.bytesToHex(random, .lower);
    const temporary = try std.fmt.allocPrint(allocator, "{s}.tmp-{s}", .{ path, suffix });
    errdefer std.Io.Dir.cwd().deleteFile(io, temporary) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temporary, .data = bytes });
    try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), path, io);
}

fn readSha256Marker(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    name: []const u8,
) ![]const u8 {
    const path = try std.fs.path.join(allocator, &.{ root, name });
    const value = try readTrimmedFile(io, allocator, path, 128);
    try validateSha256(value);
    return value;
}

fn readTrimmedFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) ![]const u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes));
    return std.mem.trim(u8, bytes, " \t\r\n");
}

fn validateStoreOwnership(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
) !void {
    const canonical_home = try std.Io.Dir.cwd().realPathFileAlloc(io, home, allocator);
    const parent = std.fs.path.dirname(canonical_home) orelse return error.UnsafeManagedStoreRoot;
    if (pathEqual(parent, canonical_home)) return error.UnsafeManagedStoreRoot;
    const marker_path = try std.fs.path.join(allocator, &.{
        home,
        state_relative_root,
        release_store.store_marker_file_name,
    });
    const marker_stat = try std.Io.Dir.cwd().statFile(io, marker_path, .{
        .follow_symlinks = false,
    });
    if (marker_stat.kind != .file or
        !try pathResolvesWithin(io, allocator, home, marker_path))
    {
        return error.InvalidStoreMarker;
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, marker_path, allocator, .limited(64 * 1024));
    const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidStoreMarker;
    if (value != .object or value.object.count() != 3) return error.InvalidStoreMarker;
    const schema = requiredInteger(value.object, "schemaVersion") catch return error.InvalidStoreMarker;
    if (schema != 1) return error.UnsupportedStoreSchema;
    const kind = requiredString(value.object, "kind") catch return error.InvalidStoreMarker;
    if (!std.mem.eql(u8, kind, "hutch-store")) return error.InvalidStoreMarker;
    const stored_root = requiredString(value.object, "canonicalRoot") catch return error.InvalidStoreMarker;
    if (!std.fs.path.isAbsolute(stored_root) or !pathEqual(stored_root, canonical_home)) {
        return error.StoreRootMismatch;
    }
}

fn validateDestructiveHome(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    home: []const u8,
) !void {
    const canonical_home = try std.Io.Dir.cwd().realPathFileAlloc(init.io, home, allocator);
    const parent = std.fs.path.dirname(canonical_home) orelse return error.UnsafeManagedStoreRoot;
    if (pathEqual(parent, canonical_home)) return error.UnsafeManagedStoreRoot;
    for ([_][]const u8{ "HOME", "USERPROFILE" }) |name| {
        const configured = init.environ_map.get(name) orelse continue;
        const canonical_user = std.Io.Dir.cwd().realPathFileAlloc(init.io, configured, allocator) catch continue;
        if (pathEqual(canonical_home, canonical_user)) return error.UnsafeManagedStoreRoot;
    }
}

fn validateManagedObject(allocator: std.mem.Allocator, object: ManagedObject) !void {
    try validateSegment(object.version);
    try validatePlatform(object.platform);
    switch (object.kind) {
        .electrobun => {
            try validateSha256(object.core_sha256 orelse return error.InvalidManagedObject);
            try validateSha256(object.source_manifest_sha256 orelse return error.InvalidManagedObject);
            const expected = try std.fmt.allocPrint(allocator, "releases/electrobun/{s}/{s}", .{ object.version, object.platform });
            if (!std.mem.eql(u8, expected, object.relative_root)) return error.InvalidManagedObject;
        },
        .electrobun_cef => {
            try validateSha256(object.cef_sha256 orelse return error.InvalidManagedObject);
            const expected = try std.fmt.allocPrint(allocator, "releases/electrobun/{s}/{s}/cef", .{ object.version, object.platform });
            if (!std.mem.eql(u8, expected, object.relative_root)) return error.InvalidManagedObject;
        },
        .release => {
            const product = object.release_product orelse return error.InvalidManagedObject;
            try validateReleaseProduct(product);
            const revision = object.revision orelse return error.InvalidManagedObject;
            try validateRevision(revision);
            try validateSha256(object.archive_sha256 orelse return error.InvalidManagedObject);
            const expected = try std.fmt.allocPrint(
                allocator,
                "releases/{s}/{s}/{s}/{s}",
                .{ product, object.version, revision, object.platform },
            );
            if (!std.mem.eql(u8, expected, object.relative_root)) return error.InvalidManagedObject;
        },
        .toolchain => {
            const kind = object.toolchain_kind orelse return error.InvalidManagedObject;
            try validateToolchainKind(kind);
            const expected = try std.fmt.allocPrint(allocator, "toolchains/{s}/{s}/{s}", .{ kind, object.version, object.platform });
            if (!std.mem.eql(u8, expected, object.relative_root)) return error.InvalidManagedObject;
        },
    }
}

fn validateSegment(value: []const u8) !void {
    if (value.len == 0 or std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) {
        return error.InvalidManagedObjectPath;
    }
    for (value) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-' or byte == '+')) {
            return error.InvalidManagedObjectPath;
        }
    }
}

fn validateToolchainKind(value: []const u8) !void {
    inline for (@typeInfo(toolchain_store.Kind).@"enum".fields) |field| {
        if (std.mem.eql(u8, value, field.name)) return;
    }
    return error.InvalidManagedObjectPath;
}

fn validateReleaseProduct(value: []const u8) !void {
    if (std.mem.eql(u8, value, "hutch") or std.mem.eql(u8, value, "cottontail")) return;
    return error.InvalidManagedObjectPath;
}

fn validateRevision(value: []const u8) !void {
    if (value.len != 40 and value.len != 64) return error.InvalidRevision;
    for (value) |byte| {
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return error.InvalidRevision;
    }
}

fn validatePlatform(value: []const u8) !void {
    inline for (.{
        "macos-arm64",
        "macos-x64",
        "linux-arm64",
        "linux-x64",
        "windows-x64",
    }) |platform| {
        if (std.mem.eql(u8, value, platform)) return;
    }
    return error.InvalidManagedObjectPath;
}

fn validateTrashName(value: []const u8) !void {
    if (value.len != 24) return error.InvalidStoreTrashPath;
    for (value) |byte| {
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return error.InvalidStoreTrashPath;
    }
}

fn validateSha256(value: []const u8) !void {
    if (value.len != 64) return error.InvalidSha256;
    for (value) |byte| if (!std.ascii.isHex(byte)) return error.InvalidSha256;
}

fn requiredObject(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.InvalidProjectRegistration;
    return value.object;
}

fn requiredString(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = object.get(name) orelse return error.InvalidProjectRegistration;
    if (value != .string) return error.InvalidProjectRegistration;
    return value.string;
}

fn requiredInteger(object: std.json.ObjectMap, name: []const u8) !i64 {
    const value = object.get(name) orelse return error.InvalidProjectRegistration;
    if (value != .integer) return error.InvalidProjectRegistration;
    return value.integer;
}

fn unixSeconds(io: std.Io) i64 {
    return @intCast(@divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn pathResolvesWithin(
    io: std.Io,
    allocator: std.mem.Allocator,
    parent: []const u8,
    child: []const u8,
) !bool {
    const canonical_parent = try std.Io.Dir.cwd().realPathFileAlloc(io, parent, allocator);
    const canonical_child = try std.Io.Dir.cwd().realPathFileAlloc(io, child, allocator);
    const canonical_cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    const lexical_parent = try std.fs.path.resolve(allocator, &.{ canonical_cwd, parent });
    const lexical_child = try std.fs.path.resolve(allocator, &.{ canonical_cwd, child });
    const relative = try std.fs.path.relative(allocator, canonical_cwd, null, lexical_parent, lexical_child);
    if (relative.len == 0 or std.fs.path.isAbsolute(relative)) return false;
    const expected_child = try std.fs.path.resolve(allocator, &.{ canonical_parent, relative });
    if (!pathHasParent(expected_child, canonical_parent)) return false;
    return pathEqual(expected_child, canonical_child);
}

fn pathHasParent(child: []const u8, parent: []const u8) bool {
    if (child.len <= parent.len or !pathEqual(child[0..parent.len], parent)) return false;
    return std.fs.path.isSep(child[parent.len]);
}

fn pathEqual(lhs: []const u8, rhs: []const u8) bool {
    return if (builtin.os.tag == .windows)
        std.ascii.eqlIgnoreCase(lhs, rhs)
    else
        std.mem.eql(u8, lhs, rhs);
}

fn ensureDirectoryWithin(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    path: []const u8,
    comptime invalid_path_error: anyerror,
) !void {
    const existing: ?std.Io.File.Stat = std.Io.Dir.cwd().statFile(io, path, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |stat| {
        if (stat.kind != .directory) return invalid_path_error;
    }
    try std.Io.Dir.cwd().createDirPath(io, path);
    if (!try pathResolvesWithin(io, allocator, home, path)) return invalid_path_error;
}

const test_core_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const test_manifest_sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const test_cef_sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const test_release_sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
const test_release_revision = "0123456789abcdef0123456789abcdef01234567";

fn testAbsoluteRoot(
    io: std.Io,
    allocator: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
) ![]const u8 {
    const relative = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    return std.Io.Dir.cwd().realPathFileAlloc(io, relative, allocator);
}

fn createTestCandidate(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    object: ManagedObject,
) ![]const u8 {
    const root = try relativeRootPath(allocator, home, object.relative_root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    try ensureTestStore(io, allocator, home);
    switch (object.kind) {
        .electrobun => try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = try std.fs.path.join(allocator, &.{ root, ".core-complete" }),
            .data = try std.mem.concat(allocator, u8, &.{ object.core_sha256.?, "\n" }),
        }),
        .electrobun_cef => try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = try std.fs.path.join(allocator, &.{ root, ".cef-complete" }),
            .data = try std.mem.concat(allocator, u8, &.{ object.cef_sha256.?, "\n" }),
        }),
        .release => try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = try std.fs.path.join(allocator, &.{ root, ".dash-installed" }),
            .data = object.archive_sha256.?,
        }),
        .toolchain => try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = try std.fs.path.join(allocator, &.{ root, ".hutch-toolchain" }),
            .data = object.version,
        }),
    }
    if (object.kind == .electrobun) {
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = try std.fs.path.join(allocator, &.{ root, "native-devkit.json" }),
            .data = "{}",
        });
    }
    if (object.kind == .release) {
        const product: release_store.Product = if (std.mem.eql(u8, object.release_product.?, "hutch"))
            .hutch
        else
            .cottontail;
        const bin = try std.fs.path.join(allocator, &.{ root, "bin" });
        try std.Io.Dir.cwd().createDirPath(io, bin);
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = try std.fs.path.join(allocator, &.{ bin, product.executableFileName() }),
            .data = "fixture",
        });
        const metadata = try std.fmt.allocPrint(
            allocator,
            "{{\"schema\":1,\"kind\":\"archive\",\"product\":\"{s}\",\"version\":\"{s}\",\"revision\":\"{s}\",\"platform\":\"{s}\"}}\n",
            .{ product.name(), object.version, object.revision.?, object.platform },
        );
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = try std.fs.path.join(allocator, &.{
                root,
                if (product == .hutch) "hutch-release.json" else "cottontail-release.json",
            }),
            .data = metadata,
        });
    }
    const lock_root = if (object.kind == .electrobun_cef)
        std.fs.path.dirname(root) orelse return error.InvalidManagedObjectPath
    else
        root;
    const lock_path = try std.mem.concat(allocator, u8, &.{ lock_root, ".lock" });
    const lock = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .read = true, .truncate = false });
    lock.close(io);
    return root;
}

fn ensureTestStore(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
) !void {
    const state = try std.fs.path.join(allocator, &.{ home, state_relative_root });
    const existing = std.Io.Dir.cwd().statFile(io, state, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |stat| {
        if (stat.kind != .directory) return;
    } else {
        try std.Io.Dir.cwd().createDirPath(io, state);
    }
    const marker = try std.fs.path.join(allocator, &.{ state, release_store.store_marker_file_name });
    if (pathExists(io, marker)) return;
    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, home, allocator);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = marker,
        .data = try testStoreMarkerJson(allocator, canonical),
    });
}

fn testStoreMarkerJson(allocator: std.mem.Allocator, canonical_root: []const u8) ![]const u8 {
    var marker_value: std.json.ObjectMap = .empty;
    try marker_value.put(allocator, "schemaVersion", .{ .integer = 1 });
    try marker_value.put(allocator, "kind", .{ .string = "hutch-store" });
    try marker_value.put(allocator, "canonicalRoot", .{ .string = canonical_root });
    return stringifyJson(allocator, .{ .object = marker_value });
}

fn testElectrobunObject() ManagedObject {
    return .{
        .kind = .electrobun,
        .relative_root = "releases/electrobun/2.0.0/macos-arm64",
        .version = "2.0.0",
        .platform = "macos-arm64",
        .core_sha256 = test_core_sha256,
        .source_manifest_sha256 = test_manifest_sha256,
    };
}

fn testElectrobunCefObject() ManagedObject {
    return .{
        .kind = .electrobun_cef,
        .relative_root = "releases/electrobun/2.0.0/macos-arm64/cef",
        .version = "2.0.0",
        .platform = "macos-arm64",
        .cef_sha256 = test_cef_sha256,
    };
}

fn testToolchainObject() ManagedObject {
    return .{
        .kind = .toolchain,
        .relative_root = "toolchains/zig/0.16.0/macos-arm64",
        .version = "0.16.0",
        .platform = "macos-arm64",
        .toolchain_kind = "zig",
    };
}

fn testReleaseObject(product: []const u8) ManagedObject {
    return .{
        .kind = .release,
        .relative_root = if (std.mem.eql(u8, product, "hutch"))
            "releases/hutch/0.6.0/0123456789abcdef0123456789abcdef01234567/macos-arm64"
        else
            "releases/cottontail/0.4.0/0123456789abcdef0123456789abcdef01234567/macos-arm64",
        .version = if (std.mem.eql(u8, product, "hutch")) "0.6.0" else "0.4.0",
        .platform = "macos-arm64",
        .release_product = product,
        .revision = test_release_revision,
        .archive_sha256 = test_release_sha256,
    };
}

test "test store markers JSON-encode Windows paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const windows_root = "C:\\Users\\runneradmin\\.hutch";
    const bytes = try testStoreMarkerJson(allocator, windows_root);
    const marker = try std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{});
    try std.testing.expectEqualStrings(
        windows_root,
        marker.object.get("canonicalRoot").?.string,
    );
}

test "project graph schema records exact objects without legacy expansion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const combined = try std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        "{\"type\":\"electrobun\",\"product\":\"electrobun\",\"relativeRoot\":\"releases/electrobun/2.0.0/macos-arm64\",\"version\":\"2.0.0\",\"platform\":\"macos-arm64\",\"coreSha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"sourceManifestSha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"cefSha256\":\"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"}",
        .{},
    );
    var rejected: std.ArrayList(ManagedObject) = .empty;
    try std.testing.expectError(
        error.InvalidProjectRegistration,
        appendParsedManagedObject(allocator, &rejected, combined),
    );

    const release = testReleaseObject("hutch");
    const serialized = try objectJson(allocator, release);
    var parsed: std.ArrayList(ManagedObject) = .empty;
    try appendParsedManagedObject(allocator, &parsed, serialized);
    try std.testing.expectEqual(@as(usize, 1), parsed.items.len);
    try std.testing.expectEqual(ManagedObject.Kind.release, parsed.items[0].kind);
    try std.testing.expectEqualStrings(release.relative_root, parsed.items[0].relative_root);
    try std.testing.expectEqualStrings(test_release_sha256, parsed.items[0].archive_sha256.?);
}

test "project registration records a deterministic exact dependency graph" {
    // These fixtures crash the Windows test runner (file-lock handles vs
    // tmpDir cleanup); they had never executed on Windows before the test
    // roots were fixed. Skip until the Windows investigation lands.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ root, "hutch-home" });
    const project = try std.fs.path.join(allocator, &.{ root, "project" });
    try std.Io.Dir.cwd().createDirPath(io, project);

    const electrobun = testElectrobunObject();
    const toolchain = testToolchainObject();
    try registerProjectAt(io, allocator, home, project, &.{ toolchain, electrobun }, 1_000);

    const project_lock_path = try std.fs.path.join(allocator, &.{ project, ".hutch", "dependencies.lock" });
    const project_lock = try std.Io.Dir.cwd().readFileAlloc(io, project_lock_path, allocator, .limited(max_state_file_bytes));
    const electrobun_index = std.mem.indexOf(u8, project_lock, electrobun.relative_root).?;
    const toolchain_index = std.mem.indexOf(u8, project_lock, toolchain.relative_root).?;
    try std.testing.expect(electrobun_index < toolchain_index);

    const registration_path = try projectRegistrationPath(allocator, home, project);
    const registration = try std.Io.Dir.cwd().readFileAlloc(io, registration_path, allocator, .limited(max_state_file_bytes));
    try std.testing.expect(std.mem.indexOf(u8, registration, "\"lastSeenUnixSeconds\":1000") != null);
    try std.testing.expect(std.mem.indexOf(u8, registration, "\"objects\"") == null);
    try std.testing.expect(pathExists(io, try projectRegistrationLockPath(allocator, home, project)));
    try std.testing.expect(!pathExists(
        io,
        try std.mem.concat(allocator, u8, &.{ registration_path, ".lock" }),
    ));

    const scanned = try scanRegistrations(io, allocator, home);
    try std.testing.expectEqual(@as(usize, 2), scanned.reachable.items.len);
    try std.testing.expectEqual(@as(usize, 0), scanned.expired_paths.items.len);
    try std.testing.expectEqual(@as(?i64, null), try readUnreachableSince(io, allocator, home, electrobun.relative_root));
    try std.testing.expectEqual(@as(?i64, null), try readUnreachableSince(io, allocator, home, toolchain.relative_root));
}

test "project registration never follows a project .hutch symlink" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ root, "hutch-home" });
    const project = try std.fs.path.join(allocator, &.{ root, "project" });
    const outside = try std.fs.path.join(allocator, &.{ root, "outside-state" });
    try std.Io.Dir.cwd().createDirPath(io, project);
    try std.Io.Dir.cwd().createDirPath(io, outside);
    const sentinel = try std.fs.path.join(allocator, &.{ outside, "sentinel" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sentinel, .data = "keep" });
    try std.Io.Dir.cwd().symLink(
        io,
        outside,
        try std.fs.path.join(allocator, &.{ project, ".hutch" }),
        .{ .is_directory = true },
    );

    try std.testing.expectError(
        error.InvalidProjectStatePath,
        registerProjectAt(io, allocator, home, project, &.{testElectrobunObject()}, 1_000),
    );
    try std.testing.expect(pathExists(io, sentinel));
    try std.testing.expect(!pathExists(io, try std.fs.path.join(allocator, &.{ outside, "dependencies.lock" })));
    try std.testing.expect(!pathExists(io, try std.fs.path.join(allocator, &.{ outside, "locks" })));
}

test "resolver outputs become managed objects only inside the hutch home" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ root, "hutch-home" });
    const electrobun_fixture = testElectrobunObject();
    const electrobun_root = try createTestCandidate(io, allocator, home, electrobun_fixture);
    const core_only = try managedElectrobunObjectsAt(
        io,
        allocator,
        home,
        electrobun_root,
        electrobun_fixture.version,
        test_manifest_sha256,
        false,
    );
    const electrobun = core_only[0].?;
    try std.testing.expect(core_only[1] == null);
    try std.testing.expectEqualStrings(electrobun_fixture.relative_root, electrobun.relative_root);
    try std.testing.expectEqualStrings(test_core_sha256, electrobun.core_sha256.?);
    _ = try createTestCandidate(io, allocator, home, testElectrobunCefObject());
    const with_cef = try managedElectrobunObjectsAt(
        io,
        allocator,
        home,
        electrobun_root,
        electrobun_fixture.version,
        test_manifest_sha256,
        true,
    );
    try std.testing.expectEqualStrings(electrobun_fixture.relative_root, with_cef[0].?.relative_root);
    try std.testing.expectEqualStrings(testElectrobunCefObject().relative_root, with_cef[1].?.relative_root);
    try std.testing.expectEqualStrings(test_cef_sha256, with_cef[1].?.cef_sha256.?);

    const external_root = try std.fs.path.join(allocator, &.{ root, "local-devkit" });
    try std.Io.Dir.cwd().createDirPath(io, external_root);
    const external = try managedElectrobunObjectsAt(
        io,
        allocator,
        home,
        external_root,
        electrobun_fixture.version,
        test_manifest_sha256,
        false,
    );
    try std.testing.expect(external[0] == null);
    try std.testing.expect(external[1] == null);

    const toolchain_fixture = testToolchainObject();
    const toolchain_root = try createTestCandidate(io, allocator, home, toolchain_fixture);
    const toolchain = (try managedToolchainObjectAt(io, allocator, home, .zig, .{
        .binary = try std.fs.path.join(allocator, &.{ toolchain_root, "zig" }),
        .root = toolchain_root,
        .version = toolchain_fixture.version,
        .system = false,
    })).?;
    try std.testing.expectEqualStrings(toolchain_fixture.relative_root, toolchain.relative_root);
    try std.testing.expect((try managedToolchainObjectAt(io, allocator, home, .zig, .{
        .binary = "zig",
        .root = null,
        .version = toolchain_fixture.version,
        .system = true,
    })) == null);
}

test "prune removes only stale unreachable managed objects" {
    // These fixtures crash the Windows test runner (file-lock handles vs
    // tmpDir cleanup); they had never executed on Windows before the test
    // roots were fixed. Skip until the Windows investigation lands.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ root, "hutch-home" });
    const project = try std.fs.path.join(allocator, &.{ root, "project" });
    try std.Io.Dir.cwd().createDirPath(io, project);

    const electrobun = testElectrobunObject();
    const toolchain = testToolchainObject();
    const electrobun_root = try createTestCandidate(io, allocator, home, electrobun);
    const toolchain_root = try createTestCandidate(io, allocator, home, toolchain);
    const now = automatic_retention_seconds + 10_000;
    try registerProjectAt(io, allocator, home, project, &.{electrobun}, now);
    try writeUnreachableSince(io, allocator, home, toolchain.relative_root, now - automatic_retention_seconds - 1);

    const third_party_file = try std.fs.path.join(allocator, &.{ home, "third-party", "keep" });
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(third_party_file).?);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = third_party_file, .data = "third-party" });
    const stale_trash = try std.fs.path.join(allocator, &.{ home, "state", "trash", "111111111111111111111111", "leftover" });
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(stale_trash).?);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = stale_trash, .data = "detached" });

    const preview = try pruneAt(io, allocator, home, .{
        .dry_run = true,
        .now_unix_seconds = now,
    });
    try std.testing.expectEqual(@as(usize, 2), preview.scanned);
    try std.testing.expectEqual(@as(usize, 1), preview.reachable);
    try std.testing.expectEqual(@as(usize, 1), preview.eligible);
    try std.testing.expectEqualStrings(toolchain.relative_root, preview.actions[0].relative_root);
    try std.testing.expect(pathExists(io, toolchain_root));

    const pruned = try pruneAt(io, allocator, home, .{
        .now_unix_seconds = now,
    });
    try std.testing.expectEqual(@as(usize, 1), pruned.pruned);
    try std.testing.expect(pathExists(io, electrobun_root));
    try std.testing.expect(!pathExists(io, toolchain_root));
    try std.testing.expect(pathExists(io, third_party_file));
    try std.testing.expect(!pathExists(io, stale_trash));
}

test "removing the last CEF reference prunes only CEF while core remains" {
    // These fixtures crash the Windows test runner (file-lock handles vs
    // tmpDir cleanup); they had never executed on Windows before the test
    // roots were fixed. Skip until the Windows investigation lands.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ root, "hutch-home" });
    const core_project = try std.fs.path.join(allocator, &.{ root, "core-project" });
    const cef_project = try std.fs.path.join(allocator, &.{ root, "cef-project" });
    try std.Io.Dir.cwd().createDirPath(io, core_project);
    try std.Io.Dir.cwd().createDirPath(io, cef_project);

    const core = testElectrobunObject();
    const cef = testElectrobunCefObject();
    const core_root = try createTestCandidate(io, allocator, home, core);
    const cef_root = try createTestCandidate(io, allocator, home, cef);
    try registerProjectAt(io, allocator, home, core_project, &.{core}, 70_000);
    try registerProjectAt(io, allocator, home, cef_project, &.{ core, cef }, 70_000);

    const cef_lock_path = try std.fs.path.join(allocator, &.{ cef_project, ".hutch", "dependencies.lock" });
    const cef_lock = try std.Io.Dir.cwd().readFileAlloc(io, cef_lock_path, allocator, .limited(max_state_file_bytes));
    try std.testing.expect(std.mem.indexOf(u8, cef_lock, "\"type\":\"electrobun-cef\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_lock, test_cef_sha256) != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_lock, test_core_sha256) != null);

    const initially_reachable = try scanRegistrations(io, allocator, home);
    try std.testing.expectEqual(@as(usize, 2), initially_reachable.reachable.items.len);

    // The CEF project disables CEF while another project continues to use the
    // same exact core. Its new dependency graph drops only the CEF subobject.
    try registerProjectAt(io, allocator, home, cef_project, &.{core}, 70_002);
    const preview = try pruneAt(io, allocator, home, .{
        .dry_run = true,
        .now_unix_seconds = 70_003,
    });
    try std.testing.expectEqual(@as(usize, 2), preview.scanned);
    try std.testing.expectEqual(@as(usize, 1), preview.reachable);
    try std.testing.expectEqual(@as(usize, 1), preview.eligible);
    try std.testing.expectEqualStrings(cef.relative_root, preview.actions[0].relative_root);

    const pruned = try pruneAt(io, allocator, home, .{
        .now_unix_seconds = 70_003,
    });
    try std.testing.expectEqual(@as(usize, 1), pruned.pruned);
    try std.testing.expectEqualStrings(cef.relative_root, pruned.actions[0].relative_root);
    try std.testing.expect(pathExists(io, core_root));
    try std.testing.expect(pathExists(io, try std.fs.path.join(allocator, &.{ core_root, ".core-complete" })));
    try std.testing.expect(pathExists(io, try std.fs.path.join(allocator, &.{ core_root, "native-devkit.json" })));
    try std.testing.expect(!pathExists(io, cef_root));
}

test "core pruning cannot bypass independently retained CEF" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ root, "hutch-home" });
    const core = testElectrobunObject();
    const cef = testElectrobunCefObject();
    const core_root = try createTestCandidate(io, allocator, home, core);
    const cef_root = try createTestCandidate(io, allocator, home, cef);
    const now = automatic_retention_seconds + 90_000;
    try writeUnreachableSince(io, allocator, home, core.relative_root, now - automatic_retention_seconds - 1);
    try writeUnreachableSince(io, allocator, home, cef.relative_root, now - 1);

    const retained = (try pruneAutomaticAt(io, allocator, home, now, &.{})).?;
    try std.testing.expectEqual(@as(usize, 0), retained.pruned);
    try std.testing.expectEqual(@as(usize, 2), retained.retention_kept);
    try std.testing.expect(pathExists(io, core_root));
    try std.testing.expect(pathExists(io, cef_root));

    const expired = (try pruneAutomaticAt(
        io,
        allocator,
        home,
        now + automatic_retention_seconds + 1,
        &.{},
    )).?;
    try std.testing.expectEqual(@as(usize, 1), expired.eligible);
    try std.testing.expectEqual(@as(usize, 1), expired.pruned);
    try std.testing.expectEqualStrings(core.relative_root, expired.actions[0].relative_root);
    try std.testing.expect(!pathExists(io, core_root));
    try std.testing.expect(!pathExists(io, cef_root));
}

test "first unreachable observation starts automatic retention" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ root, "hutch-home" });
    const toolchain = testToolchainObject();
    const toolchain_root = try createTestCandidate(io, allocator, home, toolchain);

    const seeded = (try pruneAutomaticAt(io, allocator, home, 20_000, &.{})).?;
    try std.testing.expectEqual(@as(usize, 0), seeded.pruned);
    try std.testing.expectEqual(@as(usize, 1), seeded.retention_kept);
    try std.testing.expectEqual(@as(?i64, 20_000), try readUnreachableSince(io, allocator, home, toolchain.relative_root));
    try std.testing.expect(pathExists(io, toolchain_root));

    const expired = (try pruneAutomaticAt(
        io,
        allocator,
        home,
        20_000 + automatic_retention_seconds,
        &.{},
    )).?;
    try std.testing.expectEqual(@as(usize, 1), expired.pruned);
    try std.testing.expect(!pathExists(io, toolchain_root));
}

test "manual dry-run previews without mutating artifacts or state" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ root, "hutch-home" });
    const electrobun = testElectrobunObject();
    const electrobun_root = try createTestCandidate(io, allocator, home, electrobun);

    const preview = try pruneAt(io, allocator, home, .{
        .dry_run = true,
        .now_unix_seconds = 30_000,
    });
    try std.testing.expectEqual(@as(usize, 1), preview.eligible);
    try std.testing.expectEqual(@as(usize, 0), preview.pruned);
    try std.testing.expect(pathExists(io, electrobun_root));
    try std.testing.expectEqual(@as(?i64, null), try readUnreachableSince(io, allocator, home, electrobun.relative_root));
}

test "missing projects protect nothing immediately" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ root, "hutch-home" });
    const project = try std.fs.path.join(allocator, &.{ root, "project" });
    try std.Io.Dir.cwd().createDirPath(io, project);
    const electrobun = testElectrobunObject();
    try registerProjectAt(io, allocator, home, project, &.{electrobun}, 40_000);
    try std.Io.Dir.cwd().deleteTree(io, project);

    const scanned = try scanRegistrations(io, allocator, home);
    try std.testing.expectEqual(@as(usize, 0), scanned.reachable.items.len);
    try std.testing.expectEqual(@as(usize, 1), scanned.expired_paths.items.len);
}

test "a missing project never extends an unrelated object's retention" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ root, "hutch-home" });
    const project = try std.fs.path.join(allocator, &.{ root, "project" });
    try std.Io.Dir.cwd().createDirPath(io, project);
    try registerProjectAt(io, allocator, home, project, &.{testElectrobunObject()}, 1);
    try std.Io.Dir.cwd().deleteTree(io, project);

    const toolchain = testToolchainObject();
    const toolchain_root = try createTestCandidate(io, allocator, home, toolchain);
    try writeUnreachableSince(io, allocator, home, toolchain.relative_root, 1);
    const retained = (try pruneAutomaticAt(io, allocator, home, 2, &.{})).?;
    try std.testing.expectEqual(@as(usize, 0), retained.pruned);
    try std.testing.expectEqual(@as(usize, 1), retained.retention_kept);
    try std.testing.expect(pathExists(io, toolchain_root));

    const expired = (try pruneAutomaticAt(
        io,
        allocator,
        home,
        automatic_retention_seconds + 1,
        &.{},
    )).?;
    try std.testing.expectEqual(@as(usize, 1), expired.pruned);
    try std.testing.expect(!pathExists(io, toolchain_root));
}

test "a verified project lock is the live reachability source of truth" {
    // These fixtures crash the Windows test runner (file-lock handles vs
    // tmpDir cleanup); they had never executed on Windows before the test
    // roots were fixed. Skip until the Windows investigation lands.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ root, "hutch-home" });
    const project = try std.fs.path.join(allocator, &.{ root, "project" });
    try std.Io.Dir.cwd().createDirPath(io, project);
    const electrobun = testElectrobunObject();
    const toolchain = testToolchainObject();
    try registerProjectAt(io, allocator, home, project, &.{ electrobun, toolchain }, 45_000);

    const registration_path = try projectRegistrationPath(allocator, home, project);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, registration_path, allocator, .limited(max_state_file_bytes));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"objects\"") == null);

    const scanned = try scanRegistrations(io, allocator, home);
    try std.testing.expectEqual(@as(usize, 2), scanned.reachable.items.len);
    try std.testing.expect(containsPath(scanned.reachable.items, electrobun.relative_root));
    try std.testing.expect(containsPath(scanned.reachable.items, toolchain.relative_root));
}

test "corrupt registration protects nothing and is removed independently" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ root, "hutch-home" });
    const electrobun = testElectrobunObject();
    const electrobun_root = try createTestCandidate(io, allocator, home, electrobun);
    const registrations = try std.fs.path.join(allocator, &.{ home, state_relative_root, "projects" });
    try std.Io.Dir.cwd().createDirPath(io, registrations);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ registrations, "bad.json" }),
        .data = "{not-json",
    });

    const result = try pruneAt(io, allocator, home, .{ .now_unix_seconds = 50_000 });
    try std.testing.expectEqual(@as(usize, 1), result.expired_registrations);
    try std.testing.expectEqual(@as(usize, 1), result.pruned);
    try std.testing.expect(!pathExists(io, electrobun_root));
}

test "expired registrations are fully validated before removal" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ root, "hutch-home" });
    const project = try std.fs.path.join(allocator, &.{ root, "project" });
    try std.Io.Dir.cwd().createDirPath(io, project);
    const electrobun = testElectrobunObject();
    const electrobun_root = try createTestCandidate(io, allocator, home, electrobun);
    try registerProjectAt(io, allocator, home, project, &.{electrobun}, 1);
    try std.Io.Dir.cwd().deleteTree(io, project);

    const registration_path = try projectRegistrationPath(allocator, home, project);
    const valid = try std.Io.Dir.cwd().readFileAlloc(io, registration_path, allocator, .limited(max_state_file_bytes));
    const invalid = try std.mem.replaceOwned(u8, allocator, valid, "\"type\":\"electrobun\"", "\"type\":\"unknown\"");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = registration_path, .data = invalid });

    const result = try pruneAt(io, allocator, home, .{ .now_unix_seconds = automatic_retention_seconds + 2 });
    try std.testing.expectEqual(@as(usize, 1), result.expired_registrations);
    try std.testing.expect(!pathExists(io, registration_path));
    try std.testing.expect(!pathExists(io, electrobun_root));
}

test "registration symlinks are ignored without following them" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ root, "hutch-home" });
    const electrobun = testElectrobunObject();
    const electrobun_root = try createTestCandidate(io, allocator, home, electrobun);
    const registrations = try std.fs.path.join(allocator, &.{ home, state_relative_root, "projects" });
    try std.Io.Dir.cwd().createDirPath(io, registrations);
    const outside = try std.fs.path.join(allocator, &.{ root, "outside-registration.json" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = outside, .data = "{}" });
    try std.Io.Dir.cwd().symLink(
        io,
        outside,
        try std.fs.path.join(allocator, &.{ registrations, "alias.json" }),
        .{},
    );

    const result = try pruneAt(io, allocator, home, .{ .now_unix_seconds = 55_000 });
    try std.testing.expectEqual(@as(usize, 1), result.pruned);
    try std.testing.expect(!pathExists(io, electrobun_root));
    try std.testing.expect(pathExists(io, outside));
}

test "managed object discovery never follows directory symlinks" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ root, "hutch-home" });
    try std.Io.Dir.cwd().createDirPath(io, home);
    try ensureTestStore(io, allocator, home);
    const outside = try std.fs.path.join(allocator, &.{ root, "outside-toolchains", "zig", "9.9.9", "macos-arm64" });
    try std.Io.Dir.cwd().createDirPath(io, outside);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ outside, ".hutch-toolchain" }),
        .data = "9.9.9",
    });
    const outside_root = try std.fs.path.join(allocator, &.{ root, "outside-toolchains" });
    const link = try std.fs.path.join(allocator, &.{ home, "toolchains" });
    try std.Io.Dir.cwd().symLink(io, outside_root, link, .{ .is_directory = true });

    try std.testing.expectError(error.InvalidManagedObjectPath, pruneAt(io, allocator, home, .{
        .dry_run = true,
        .now_unix_seconds = 60_000,
    }));
    try std.testing.expect(pathExists(io, outside));
    try std.testing.expect(pathExists(io, link));
}

test "a state namespace escaping the hutch home blocks deletion" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ root, "hutch-home" });
    try std.Io.Dir.cwd().createDirPath(io, home);
    const outside_state = try std.fs.path.join(allocator, &.{ root, "outside-state" });
    try std.Io.Dir.cwd().createDirPath(io, outside_state);
    try std.Io.Dir.cwd().symLink(
        io,
        outside_state,
        try std.fs.path.join(allocator, &.{ home, "state" }),
        .{ .is_directory = true },
    );
    const toolchain = testToolchainObject();
    const toolchain_root = try createTestCandidate(io, allocator, home, toolchain);

    try std.testing.expectError(error.FileNotFound, pruneAt(io, allocator, home, .{
        .now_unix_seconds = 65_000,
    }));
    try std.testing.expect(pathExists(io, toolchain_root));
    try std.testing.expect(!pathExists(io, try std.fs.path.join(allocator, &.{ outside_state, "locks" })));
}

test "a dangling projects namespace cannot hide registrations" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ root, "hutch-home" });
    const projects_root = try std.fs.path.join(allocator, &.{ home, state_relative_root, "projects" });
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(projects_root).?);
    try std.Io.Dir.cwd().symLink(
        io,
        try std.fs.path.join(allocator, &.{ root, "missing-projects-target" }),
        projects_root,
        .{ .is_directory = true },
    );
    const toolchain = testToolchainObject();
    const toolchain_root = try createTestCandidate(io, allocator, home, toolchain);

    try std.testing.expectError(error.InvalidStoreStatePath, pruneAt(io, allocator, home, .{
        .now_unix_seconds = 66_000,
    }));
    try std.testing.expect(pathExists(io, toolchain_root));
}

test "an in-home trash alias cannot delete third-party data" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ root, "hutch-home" });
    const third_party_root = try std.fs.path.join(allocator, &.{ home, "third-party", "npm" });
    const third_party_file = try std.fs.path.join(allocator, &.{ third_party_root, "111111111111111111111111", "keep" });
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(third_party_file).?);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = third_party_file, .data = "third-party" });
    const state_root = try std.fs.path.join(allocator, &.{ home, state_relative_root });
    try std.Io.Dir.cwd().createDirPath(io, state_root);
    try ensureTestStore(io, allocator, home);
    try std.Io.Dir.cwd().symLink(
        io,
        third_party_root,
        try std.fs.path.join(allocator, &.{ state_root, "trash" }),
        .{ .is_directory = true },
    );

    try std.testing.expectError(error.InvalidStoreTrashPath, pruneAt(io, allocator, home, .{
        .now_unix_seconds = 67_000,
    }));
    try std.testing.expect(pathExists(io, third_party_file));
}

test "a trash namespace escaping the hutch home blocks deletion" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ root, "hutch-home" });
    try std.Io.Dir.cwd().createDirPath(io, home);
    const outside_trash = try std.fs.path.join(allocator, &.{ root, "outside-trash" });
    try std.Io.Dir.cwd().createDirPath(io, outside_trash);
    const sentinel = try std.fs.path.join(allocator, &.{ outside_trash, "keep" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sentinel, .data = "third-party" });
    const state_root = try std.fs.path.join(allocator, &.{ home, state_relative_root });
    try std.Io.Dir.cwd().createDirPath(io, state_root);
    try std.Io.Dir.cwd().symLink(
        io,
        try std.fs.path.join(allocator, &.{ root, "outside-trash" }),
        try std.fs.path.join(allocator, &.{ state_root, "trash" }),
        .{ .is_directory = true },
    );
    const toolchain = testToolchainObject();
    const toolchain_root = try createTestCandidate(io, allocator, home, toolchain);
    try writeUnreachableSince(io, allocator, home, toolchain.relative_root, 1);

    try std.testing.expectError(error.InvalidStoreTrashPath, pruneAt(io, allocator, home, .{
        .now_unix_seconds = 70_000,
    }));
    try std.testing.expect(pathExists(io, toolchain_root));
    try std.testing.expect(pathExists(io, sentinel));
}

test "a read-only inventory reports reachability, leases, and missing projects" {
    // These fixtures crash the Windows test runner (file-lock handles vs
    // tmpDir cleanup); they had never executed on Windows before the test
    // roots were fixed. Skip until the Windows investigation lands.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testAbsoluteRoot(io, allocator, &tmp);
    const home = try std.fs.path.join(allocator, &.{ root, "hutch-home" });
    const live_project = try std.fs.path.join(allocator, &.{ root, "live-project" });
    const gone_project = try std.fs.path.join(allocator, &.{ root, "gone-project" });
    try std.Io.Dir.cwd().createDirPath(io, live_project);
    try std.Io.Dir.cwd().createDirPath(io, gone_project);

    const electrobun = testElectrobunObject();
    const toolchain = testToolchainObject();
    const electrobun_root = try createTestCandidate(io, allocator, home, electrobun);
    _ = try createTestCandidate(io, allocator, home, toolchain);
    try registerProjectAt(io, allocator, home, live_project, &.{electrobun}, 1_000);
    try registerProjectAt(io, allocator, home, gone_project, &.{toolchain}, 1_000);
    // The project directory disappears, but its registration remains.
    try std.Io.Dir.cwd().deleteTree(io, gone_project);

    const lease = try store_locks.acquireObjectLease(io, allocator, home, electrobun_root);
    const held = try inventoryAt(io, allocator, home);
    lease.close(io);

    try std.testing.expectEqual(@as(usize, 0), held.issues.len);
    try std.testing.expectEqual(@as(usize, 2), held.objects.len);
    try std.testing.expectEqualStrings(electrobun.relative_root, held.objects[0].relative_root);
    try std.testing.expect(held.objects[0].reachable);
    try std.testing.expect(held.objects[0].in_use);
    try std.testing.expectEqual(@as(?i64, null), held.objects[0].unreachable_since_unix_seconds);
    try std.testing.expectEqualStrings(toolchain.relative_root, held.objects[1].relative_root);
    try std.testing.expect(!held.objects[1].reachable);
    try std.testing.expect(!held.objects[1].in_use);

    try std.testing.expectEqual(@as(usize, 2), held.projects.len);
    try std.testing.expectEqualStrings(gone_project, held.projects[0].canonical_root);
    try std.testing.expect(!held.projects[0].project_exists);
    try std.testing.expect(!held.projects[0].lock_verified);
    try std.testing.expectEqual(@as(usize, 0), held.projects[0].objects.len);
    try std.testing.expectEqualStrings(live_project, held.projects[1].canonical_root);
    try std.testing.expect(held.projects[1].project_exists);
    try std.testing.expect(held.projects[1].lock_verified);

    // Releasing the lease makes the object detachable again, and inventory
    // never mutates reachability state.
    const released = try inventoryAt(io, allocator, home);
    try std.testing.expect(!released.objects[0].in_use);

    const preview = try pruneAt(io, allocator, home, .{ .dry_run = true, .now_unix_seconds = 1_001 });
    try std.testing.expectEqual(@as(usize, 2), preview.scanned);
    try std.testing.expectEqual(@as(usize, 1), preview.reachable);
    try std.testing.expectEqual(@as(usize, 1), preview.eligible);
}
