const std = @import("std");
const builtin = @import("builtin");
const cache_locks = @import("cache_locks.zig");
const project_state = @import("project_state.zig");
const release_store = @import("release_store.zig");
const toolchain_store = @import("toolchain_store.zig");

const schema_version = 2;
const minimum_readable_schema_version = 1;
const project_lock_kind = "hutch-project-dependencies";
const registration_kind = "hutch-project-registration";
const state_relative_root = cache_locks.state_relative_root;
const max_state_file_bytes = 1024 * 1024;

pub const default_grace_seconds: i64 = 30 * 24 * 60 * 60;

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

pub const GraphLock = cache_locks.GraphLock;
pub const ObjectLease = cache_locks.ObjectLease;

pub const PruneOptions = struct {
    dry_run: bool = false,
    grace_seconds: i64 = default_grace_seconds,
    now_unix_seconds: ?i64 = null,
};

pub const PruneAction = struct {
    relative_root: []const u8,
};

pub const PruneResult = struct {
    actions: []const PruneAction,
    scanned: usize,
    reachable: usize,
    grace_kept: usize,
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
    grace_kept,
    eligible,
};

const RegistrationScan = struct {
    reachable: std.ArrayList([]const u8) = .empty,
    expired_paths: std.ArrayList([]const u8) = .empty,
    defer_unreachable_pruning: bool = false,
};

pub fn acquireUsageLock(
    init: std.process.Init,
    allocator: std.mem.Allocator,
) !GraphLock {
    const home = try release_store.hutchHome(init, allocator);
    return cache_locks.acquireGraph(init.io, allocator, home, .shared);
}

fn acquireGraphLockAt(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    mode: std.Io.File.Lock,
) !GraphLock {
    return cache_locks.acquireGraph(io, allocator, home, mode);
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
        std.fs.path.dirname(registration_path) orelse return error.InvalidCacheStatePath,
        error.InvalidCacheStatePath,
    );
    const registration_lock_path = try projectRegistrationLockPath(allocator, home, canonical_project_root);
    try ensureDirectoryWithin(
        io,
        allocator,
        home,
        std.fs.path.dirname(registration_lock_path) orelse return error.InvalidCacheStatePath,
        error.InvalidCacheStatePath,
    );
    try cache_locks.initializePersistentFile(io, registration_lock_path);
    if (!try pathResolvesWithin(io, allocator, home, registration_lock_path)) return error.InvalidCacheStatePath;
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
    try registration.put(allocator, "objects", .{ .array = try objectsJson(allocator, objects) });
    const registration_bytes = try stringifyJson(allocator, .{ .object = registration });

    try atomicWrite(io, allocator, registration_path, registration_bytes);
    for (objects) |object| try touchLastUsed(io, allocator, home, object.relative_root, now);
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
    last_used_unix_seconds: ?i64 = null,
    /// Referenced by at least one project registration or verified project lock.
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

    var candidates: std.ArrayList(Candidate) = .empty;
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
            .last_used_unix_seconds = readLastUsed(io, allocator, home, candidate.relative_root) catch blk: {
                try appendIssue(allocator, &issues, candidate.relative_root, error.InvalidLastUsedMarker);
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
        const project = inventoryRegistration(io, allocator, path) catch |err| {
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
    path: []const u8,
) !InventoryProject {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_state_file_bytes));
    const registration = std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidCacheRegistration;
    const object = try requiredObject(registration);
    const registration_schema = try readableSchemaVersion(object);
    if (!std.mem.eql(u8, try requiredString(object, "kind"), registration_kind)) {
        return error.InvalidCacheRegistration;
    }
    const canonical_root = try requiredString(object, "canonicalRoot");
    if (!std.fs.path.isAbsolute(canonical_root)) return error.InvalidCacheRegistration;
    const lock_sha256 = try requiredString(object, "projectLockSha256");
    try validateSha256(lock_sha256);
    const last_seen = try requiredInteger(object, "lastSeenUnixSeconds");
    const values = object.get("objects") orelse return error.InvalidCacheRegistration;
    if (values != .array) return error.InvalidCacheRegistration;

    var registered: std.ArrayList(ManagedObject) = .empty;
    for (values.array.items) |value| {
        try appendParsedManagedObjects(allocator, &registered, value, registration_schema);
    }

    const locked = projectLockObjectsIfMatches(io, allocator, canonical_root, lock_sha256) catch null;
    return .{
        .canonical_root = canonical_root,
        .registration_path = path,
        .project_exists = pathExists(io, canonical_root),
        .lock_verified = locked != null,
        .last_seen_unix_seconds = last_seen,
        .objects = locked orelse try registered.toOwnedSlice(allocator),
    };
}

/// Probes the object lease without waiting. A held lease means some process is
/// using the object right now.
fn objectInUse(io: std.Io, allocator: std.mem.Allocator, lock_root: []const u8) !bool {
    const lock_path = try std.mem.concat(allocator, u8, &.{ lock_root, ".lock" });
    if (!pathExists(io, lock_path)) return false;
    const exclusive = (try cache_locks.tryAcquireObjectExclusive(io, allocator, lock_root)) orelse return true;
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
    return pruneAt(init.io, allocator, home, options);
}

fn pruneAt(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    options: PruneOptions,
) !PruneResult {
    if (options.grace_seconds < 0) return error.InvalidCacheGracePeriod;
    const now = options.now_unix_seconds orelse unixSeconds(io);
    var trash_root: ?[]const u8 = null;
    var stale_trash: std.ArrayList([]const u8) = .empty;
    var final_result: PruneResult = undefined;
    {
        const graph_lock = try acquireGraphLockAt(io, allocator, home, .exclusive);
        defer graph_lock.close(io);

        if (!options.dry_run) try collectTrashRoots(io, allocator, home, &stale_trash);

        const registrations = try scanRegistrations(io, allocator, home, now);
        var candidates: std.ArrayList(Candidate) = .empty;
        try collectElectrobunCandidates(io, allocator, home, &candidates);
        try collectToolchainCandidates(io, allocator, home, &candidates);
        std.mem.sort(Candidate, candidates.items, {}, candidateLessThan);

        const dispositions = try allocator.alloc(CandidateDisposition, candidates.items.len);
        for (candidates.items, 0..) |candidate, index| {
            if (candidateIsReachable(registrations.reachable.items, candidate)) {
                dispositions[index] = .reachable;
                continue;
            }
            if (registrations.defer_unreachable_pruning) {
                dispositions[index] = .grace_kept;
                continue;
            }
            const last_used = try readLastUsed(io, allocator, home, candidate.relative_root);
            if (options.grace_seconds > 0 and (last_used == null or now < last_used.? or now - last_used.? < options.grace_seconds)) {
                dispositions[index] = .grace_kept;
                if (!options.dry_run and last_used == null) {
                    try touchLastUsed(io, allocator, home, candidate.relative_root, now);
                }
                continue;
            }
            dispositions[index] = .eligible;
        }

        // A nested CEF payload can be detached without core, but detaching
        // core necessarily removes CEF too. Preserve the parent whenever any
        // independently managed descendant is still within its own grace.
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
        var grace_kept: usize = 0;
        for (candidates.items, dispositions, 0..) |candidate, disposition, index| {
            switch (disposition) {
                .reachable => reachable_count += 1,
                .grace_kept => grace_kept += 1,
                .eligible => if (!candidateHasEligibleAncestor(candidates.items, dispositions, index)) {
                    try eligible_actions.append(allocator, .{
                        .relative_root = try allocator.dupe(u8, candidate.relative_root),
                    });
                },
            }
        }

        const eligible_count = eligible_actions.items.len;
        if (options.dry_run) {
            final_result = .{
                .actions = try eligible_actions.toOwnedSlice(allocator),
                .scanned = candidates.items.len,
                .reachable = reachable_count,
                .grace_kept = grace_kept,
                .eligible = eligible_count,
                .expired_registrations = registrations.expired_paths.items.len,
                .pruned = 0,
            };
        } else {
            for (registrations.expired_paths.items) |path| {
                std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                };
            }

            var pruned_actions: std.ArrayList(PruneAction) = .empty;
            for (eligible_actions.items) |action| {
                const candidate = findCandidate(candidates.items, action.relative_root) orelse continue;
                if (!try candidateStillValid(io, allocator, candidate)) continue;
                {
                    const object_lock = try tryAcquireCandidateLock(io, allocator, candidate.lock_root) orelse continue;
                    defer object_lock.close(io);
                    const batch = trash_root orelse blk: {
                        const created = try createTrashRoot(io, allocator, home);
                        trash_root = created;
                        break :blk created;
                    };
                    const destination = try relativeRootPath(allocator, batch, candidate.relative_root);
                    const destination_parent = std.fs.path.dirname(destination) orelse return error.InvalidCacheTrashPath;
                    try std.Io.Dir.cwd().createDirPath(io, destination_parent);
                    std.Io.Dir.cwd().rename(candidate.absolute_root, std.Io.Dir.cwd(), destination, io) catch |err| switch (err) {
                        error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.FileBusy => continue,
                        else => return err,
                    };
                }
                const last_used_path = try lastUsedPath(allocator, home, candidate.relative_root);
                std.Io.Dir.cwd().deleteFile(io, last_used_path) catch {};
                try pruned_actions.append(allocator, action);
            }
            const pruned_count = pruned_actions.items.len;
            final_result = .{
                .actions = try pruned_actions.toOwnedSlice(allocator),
                .scanned = candidates.items.len,
                .reachable = reachable_count,
                .grace_kept = grace_kept,
                .eligible = eligible_count,
                .expired_registrations = registrations.expired_paths.items.len,
                .pruned = pruned_count,
            };
        }
    }

    // Candidates were detached atomically under the graph lock. Slow recursive
    // deletion happens afterward; crash trash is safe to remove on a later run.
    for (stale_trash.items) |path| std.Io.Dir.cwd().deleteTree(io, path) catch {};
    if (trash_root) |path| std.Io.Dir.cwd().deleteTree(io, path) catch {};
    return final_result;
}

fn collectTrashRoots(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    output: *std.ArrayList([]const u8),
) !void {
    const root = try std.fs.path.join(allocator, &.{ home, state_relative_root, "trash" });
    try ensureDirectoryWithin(io, allocator, home, root, error.InvalidCacheTrashPath);
    var directory = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer directory.close(io);
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
    now: i64,
) !RegistrationScan {
    var result: RegistrationScan = .{};
    const projects_root = try std.fs.path.join(allocator, &.{ home, state_relative_root, "projects" });
    try ensureDirectoryWithin(io, allocator, home, projects_root, error.InvalidCacheStatePath);
    var directory = try std.Io.Dir.cwd().openDir(io, projects_root, .{ .iterate = true });
    defer directory.close(io);
    if (!try pathResolvesWithin(io, allocator, home, projects_root)) return error.InvalidCacheStatePath;
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (entry.kind != .file) return error.InvalidCacheRegistration;
        const path = try std.fs.path.join(allocator, &.{ projects_root, entry.name });
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_state_file_bytes));
        const registration = std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{
            .duplicate_field_behavior = .@"error",
        }) catch return error.InvalidCacheRegistration;
        const object = try requiredObject(registration);
        const registration_schema = try readableSchemaVersion(object);
        if (!std.mem.eql(u8, try requiredString(object, "kind"), registration_kind)) {
            return error.InvalidCacheRegistration;
        }
        const canonical_root = try requiredString(object, "canonicalRoot");
        if (!std.fs.path.isAbsolute(canonical_root)) return error.InvalidCacheRegistration;
        const expected_name = try projectRegistrationName(allocator, canonical_root);
        if (!std.mem.eql(u8, expected_name, entry.name)) return error.InvalidCacheRegistration;
        const lock_sha256 = try requiredString(object, "projectLockSha256");
        try validateSha256(lock_sha256);
        const last_seen = try requiredInteger(object, "lastSeenUnixSeconds");
        if (last_seen < 0) return error.InvalidCacheRegistration;
        const values = object.get("objects") orelse return error.InvalidCacheRegistration;
        if (values != .array) return error.InvalidCacheRegistration;

        var parsed_objects: std.ArrayList(ManagedObject) = .empty;
        for (values.array.items) |value| {
            try appendParsedManagedObjects(allocator, &parsed_objects, value, registration_schema);
        }

        const project_objects = try projectLockObjectsIfMatches(io, allocator, canonical_root, lock_sha256);
        const within_missing_grace = now < last_seen or now - last_seen < default_grace_seconds;
        if (project_objects == null and !within_missing_grace) {
            try result.expired_paths.append(allocator, path);
            continue;
        }
        if (project_objects == null) result.defer_unreachable_pruning = true;
        for ((project_objects orelse parsed_objects.items)) |parsed| {
            if (!containsPath(result.reachable.items, parsed.relative_root)) {
                try result.reachable.append(allocator, parsed.relative_root);
            }
        }
    }
    return result;
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
    const project_schema = readableSchemaVersion(object) catch return error.InvalidProjectDependencyLock;
    if (!std.mem.eql(u8, requiredString(object, "kind") catch return error.InvalidProjectDependencyLock, project_lock_kind)) {
        return error.InvalidProjectDependencyLock;
    }
    const values = object.get("objects") orelse return error.InvalidProjectDependencyLock;
    if (values != .array) return error.InvalidProjectDependencyLock;
    var objects: std.ArrayList(ManagedObject) = .empty;
    for (values.array.items) |value| {
        appendParsedManagedObjects(allocator, &objects, value, project_schema) catch return error.InvalidProjectDependencyLock;
    }
    const owned = try objects.toOwnedSlice(allocator);
    return @as(?[]const ManagedObject, owned);
}

fn readableSchemaVersion(object: std.json.ObjectMap) !usize {
    const value = try requiredInteger(object, "schemaVersion");
    if (value < minimum_readable_schema_version or value > schema_version) {
        return error.UnsupportedCacheSchema;
    }
    return @intCast(value);
}

fn appendParsedManagedObjects(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(ManagedObject),
    value: std.json.Value,
    source_schema: usize,
) !void {
    const object = try requiredObject(value);
    const kind_name = try requiredString(object, "type");
    const relative_root = try requiredString(object, "relativeRoot");
    const version = try requiredString(object, "version");
    const platform = try requiredString(object, "platform");
    try validateSegment(version);
    try validatePlatform(platform);
    if (std.mem.eql(u8, kind_name, "electrobun")) {
        if (!std.mem.eql(u8, try requiredString(object, "product"), "electrobun")) return error.InvalidCacheRegistration;
        const expected = try std.fmt.allocPrint(allocator, "releases/electrobun/{s}/{s}", .{ version, platform });
        if (!std.mem.eql(u8, expected, relative_root)) return error.InvalidCacheRegistration;
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
        // The original schema stored optional CEF provenance on the core
        // object. Expand it into the independently reachable v2 child so a
        // live v1 project can never lose its CEF payload during migration.
        if (source_schema == 1) {
            if (object.get("cefSha256")) |cef| {
                if (cef != .string) return error.InvalidCacheRegistration;
                try validateSha256(cef.string);
                try output.append(allocator, .{
                    .kind = .electrobun_cef,
                    .relative_root = try std.fmt.allocPrint(
                        allocator,
                        "releases/electrobun/{s}/{s}/cef",
                        .{ version, platform },
                    ),
                    .version = version,
                    .platform = platform,
                    .cef_sha256 = cef.string,
                });
            }
        } else if (object.get("cefSha256") != null) {
            return error.InvalidCacheRegistration;
        }
        return;
    }
    if (std.mem.eql(u8, kind_name, "electrobun-cef")) {
        if (!std.mem.eql(u8, try requiredString(object, "product"), "electrobun")) return error.InvalidCacheRegistration;
        const expected = try std.fmt.allocPrint(allocator, "releases/electrobun/{s}/{s}/cef", .{ version, platform });
        if (!std.mem.eql(u8, expected, relative_root)) return error.InvalidCacheRegistration;
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
        if (source_schema < 2) return error.InvalidCacheRegistration;
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
        if (!std.mem.eql(u8, expected, relative_root)) return error.InvalidCacheRegistration;
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
        if (!std.mem.eql(u8, expected, relative_root)) return error.InvalidCacheRegistration;
        try output.append(allocator, .{
            .kind = .toolchain,
            .relative_root = relative_root,
            .version = version,
            .platform = platform,
            .toolchain_kind = toolchain_kind,
        });
        return;
    }
    return error.InvalidCacheRegistration;
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
            if (try pathResolvesWithin(io, allocator, home, absolute) and
                try candidateStillValid(io, allocator, candidate))
            {
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
            if (try candidateStillValid(io, allocator, cef_candidate) and
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
                if (try pathResolvesWithin(io, allocator, home, absolute) and
                    try candidateStillValid(io, allocator, candidate))
                {
                    try output.append(allocator, candidate);
                }
            }
        }
    }
}

fn candidateLessThan(_: void, lhs: Candidate, rhs: Candidate) bool {
    return std.mem.order(u8, lhs.relative_root, rhs.relative_root) == .lt;
}

fn candidateStillValid(io: std.Io, allocator: std.mem.Allocator, candidate: Candidate) !bool {
    switch (candidate.kind) {
        .electrobun => {
            _ = readSha256Marker(io, allocator, candidate.absolute_root, ".core-complete") catch return false;
            return pathExists(
                io,
                try std.fs.path.join(allocator, &.{ candidate.absolute_root, "native-devkit.json" }),
            );
        },
        .electrobun_cef => {
            _ = readSha256Marker(io, allocator, candidate.absolute_root, ".cef-complete") catch return false;
            return true;
        },
        // Release discovery is deliberately enabled only after channel roots,
        // bootstrap publication, and process leases are wired together.
        .release => return false,
        .toolchain => {
            const marker = try std.fs.path.join(allocator, &.{ candidate.absolute_root, ".hutch-toolchain" });
            const value = readTrimmedFile(io, allocator, marker, 256) catch return false;
            return std.mem.eql(u8, value, candidate.version);
        },
    }
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
    candidate_root: []const u8,
) !?std.Io.File {
    return cache_locks.tryAcquireObjectExclusive(io, allocator, candidate_root);
}

fn createTrashRoot(io: std.Io, allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
    var random: [12]u8 = undefined;
    io.random(&random);
    const suffix = std.fmt.bytesToHex(random, .lower);
    const trash_parent = try std.fs.path.join(allocator, &.{ home, state_relative_root, "trash" });
    try ensureDirectoryWithin(io, allocator, home, trash_parent, error.InvalidCacheTrashPath);
    const root = try std.fs.path.join(allocator, &.{ trash_parent, &suffix });
    try std.Io.Dir.cwd().createDirPath(io, root);
    if (!try pathResolvesWithin(io, allocator, home, root)) return error.InvalidCacheTrashPath;
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

fn lastUsedPath(
    allocator: std.mem.Allocator,
    home: []const u8,
    relative_root: []const u8,
) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(relative_root, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const name = try std.fmt.allocPrint(allocator, "{s}.timestamp", .{hex});
    return std.fs.path.join(allocator, &.{ home, state_relative_root, "last-used", name });
}

fn touchLastUsed(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    relative_root: []const u8,
    now: i64,
) !void {
    const path = try lastUsedPath(allocator, home, relative_root);
    try ensureDirectoryWithin(
        io,
        allocator,
        home,
        std.fs.path.dirname(path) orelse return error.InvalidCacheStatePath,
        error.InvalidCacheStatePath,
    );
    const value = try std.fmt.allocPrint(allocator, "{d}\n", .{now});
    try atomicWrite(io, allocator, path, value);
}

fn readLastUsed(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    relative_root: []const u8,
) !?i64 {
    const path = try lastUsedPath(allocator, home, relative_root);
    const parent = std.fs.path.dirname(path) orelse return error.InvalidCacheStatePath;
    var directory = std.Io.Dir.cwd().openDir(io, parent, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer directory.close(io);
    if (!try pathResolvesWithin(io, allocator, home, parent)) return error.InvalidCacheStatePath;
    const value = readTrimmedFile(io, allocator, path, 64) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const timestamp = std.fmt.parseInt(i64, value, 10) catch return error.InvalidLastUsedMarker;
    if (timestamp < 0) return error.InvalidLastUsedMarker;
    return timestamp;
}

fn atomicWrite(io: std.Io, allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidCacheStatePath;
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
    inline for (.{ "zig", "rust", "go", "odin" }) |kind| {
        if (std.mem.eql(u8, value, kind)) return;
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
    if (value.len != 24) return error.InvalidCacheTrashPath;
    for (value) |byte| {
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return error.InvalidCacheTrashPath;
    }
}

fn validateSha256(value: []const u8) !void {
    if (value.len != 64) return error.InvalidSha256;
    for (value) |byte| if (!std.ascii.isHex(byte)) return error.InvalidSha256;
}

fn requiredObject(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.InvalidCacheRegistration;
    return value.object;
}

fn requiredString(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = object.get(name) orelse return error.InvalidCacheRegistration;
    if (value != .string) return error.InvalidCacheRegistration;
    return value.string;
}

fn requiredInteger(object: std.json.ObjectMap, name: []const u8) !i64 {
    const value = object.get(name) orelse return error.InvalidCacheRegistration;
    if (value != .integer) return error.InvalidCacheRegistration;
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
    const lock_root = if (object.kind == .electrobun_cef)
        std.fs.path.dirname(root) orelse return error.InvalidManagedObjectPath
    else
        root;
    const lock_path = try std.mem.concat(allocator, u8, &.{ lock_root, ".lock" });
    const lock = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .read = true, .truncate = false });
    lock.close(io);
    return root;
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

test "schema v2 records exact release identity and expands combined v1 CEF reachability" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const v1 = try std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        "{\"type\":\"electrobun\",\"product\":\"electrobun\",\"relativeRoot\":\"releases/electrobun/2.0.0/macos-arm64\",\"version\":\"2.0.0\",\"platform\":\"macos-arm64\",\"coreSha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"sourceManifestSha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"cefSha256\":\"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"}",
        .{},
    );
    var expanded: std.ArrayList(ManagedObject) = .empty;
    try appendParsedManagedObjects(allocator, &expanded, v1, 1);
    try std.testing.expectEqual(@as(usize, 2), expanded.items.len);
    try std.testing.expectEqual(ManagedObject.Kind.electrobun, expanded.items[0].kind);
    try std.testing.expectEqual(ManagedObject.Kind.electrobun_cef, expanded.items[1].kind);
    try std.testing.expectEqualStrings(
        "releases/electrobun/2.0.0/macos-arm64/cef",
        expanded.items[1].relative_root,
    );
    try std.testing.expectEqualStrings(test_cef_sha256, expanded.items[1].cef_sha256.?);

    const release = testReleaseObject("hutch");
    const serialized = try objectJson(allocator, release);
    var parsed: std.ArrayList(ManagedObject) = .empty;
    try appendParsedManagedObjects(allocator, &parsed, serialized, schema_version);
    try std.testing.expectEqual(@as(usize, 1), parsed.items.len);
    try std.testing.expectEqual(ManagedObject.Kind.release, parsed.items[0].kind);
    try std.testing.expectEqualStrings(release.relative_root, parsed.items[0].relative_root);
    try std.testing.expectEqualStrings(test_release_sha256, parsed.items[0].archive_sha256.?);

    var rejected: std.ArrayList(ManagedObject) = .empty;
    try std.testing.expectError(
        error.InvalidCacheRegistration,
        appendParsedManagedObjects(allocator, &rejected, serialized, 1),
    );
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
    try std.testing.expect(std.mem.indexOf(u8, registration, test_core_sha256) != null);
    try std.testing.expect(std.mem.indexOf(u8, registration, test_manifest_sha256) != null);
    try std.testing.expect(pathExists(io, try projectRegistrationLockPath(allocator, home, project)));
    try std.testing.expect(!pathExists(
        io,
        try std.mem.concat(allocator, u8, &.{ registration_path, ".lock" }),
    ));

    const scanned = try scanRegistrations(io, allocator, home, 1_001);
    try std.testing.expectEqual(@as(usize, 2), scanned.reachable.items.len);
    try std.testing.expectEqual(@as(usize, 0), scanned.expired_paths.items.len);
    try std.testing.expectEqual(@as(?i64, 1_000), try readLastUsed(io, allocator, home, electrobun.relative_root));
    try std.testing.expectEqual(@as(?i64, 1_000), try readLastUsed(io, allocator, home, toolchain.relative_root));
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
    const now = default_grace_seconds + 10_000;
    try registerProjectAt(io, allocator, home, project, &.{electrobun}, now);
    try touchLastUsed(io, allocator, home, toolchain.relative_root, now - default_grace_seconds - 1);

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

    const initially_reachable = try scanRegistrations(io, allocator, home, 70_001);
    try std.testing.expectEqual(@as(usize, 2), initially_reachable.reachable.items.len);

    // The CEF project disables CEF while another project continues to use the
    // same exact core. Its new dependency graph drops only the CEF subobject.
    try registerProjectAt(io, allocator, home, cef_project, &.{core}, 70_002);
    const preview = try pruneAt(io, allocator, home, .{
        .dry_run = true,
        .grace_seconds = 0,
        .now_unix_seconds = 70_003,
    });
    try std.testing.expectEqual(@as(usize, 2), preview.scanned);
    try std.testing.expectEqual(@as(usize, 1), preview.reachable);
    try std.testing.expectEqual(@as(usize, 1), preview.eligible);
    try std.testing.expectEqualStrings(cef.relative_root, preview.actions[0].relative_root);

    const pruned = try pruneAt(io, allocator, home, .{
        .grace_seconds = 0,
        .now_unix_seconds = 70_003,
    });
    try std.testing.expectEqual(@as(usize, 1), pruned.pruned);
    try std.testing.expectEqualStrings(cef.relative_root, pruned.actions[0].relative_root);
    try std.testing.expect(pathExists(io, core_root));
    try std.testing.expect(pathExists(io, try std.fs.path.join(allocator, &.{ core_root, ".core-complete" })));
    try std.testing.expect(pathExists(io, try std.fs.path.join(allocator, &.{ core_root, "native-devkit.json" })));
    try std.testing.expect(!pathExists(io, cef_root));
}

test "core pruning cannot bypass an independently recent CEF grace period" {
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
    const now = default_grace_seconds + 90_000;
    try touchLastUsed(io, allocator, home, core.relative_root, now - default_grace_seconds - 1);
    try touchLastUsed(io, allocator, home, cef.relative_root, now - 1);

    const retained = try pruneAt(io, allocator, home, .{ .now_unix_seconds = now });
    try std.testing.expectEqual(@as(usize, 0), retained.pruned);
    try std.testing.expectEqual(@as(usize, 2), retained.grace_kept);
    try std.testing.expect(pathExists(io, core_root));
    try std.testing.expect(pathExists(io, cef_root));

    const expired = try pruneAt(io, allocator, home, .{
        .now_unix_seconds = now + default_grace_seconds + 1,
    });
    try std.testing.expectEqual(@as(usize, 1), expired.eligible);
    try std.testing.expectEqual(@as(usize, 1), expired.pruned);
    try std.testing.expectEqualStrings(core.relative_root, expired.actions[0].relative_root);
    try std.testing.expect(!pathExists(io, core_root));
    try std.testing.expect(!pathExists(io, cef_root));
}

test "missing last-used state receives grace before an object can be pruned" {
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

    const seeded = try pruneAt(io, allocator, home, .{ .now_unix_seconds = 20_000 });
    try std.testing.expectEqual(@as(usize, 0), seeded.pruned);
    try std.testing.expectEqual(@as(usize, 1), seeded.grace_kept);
    try std.testing.expectEqual(@as(?i64, 20_000), try readLastUsed(io, allocator, home, toolchain.relative_root));
    try std.testing.expect(pathExists(io, toolchain_root));

    const expired = try pruneAt(io, allocator, home, .{
        .now_unix_seconds = 20_000 + default_grace_seconds + 1,
    });
    try std.testing.expectEqual(@as(usize, 1), expired.pruned);
    try std.testing.expect(!pathExists(io, toolchain_root));
}

test "zero-grace dry-run previews without mutating artifacts or state" {
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
        .grace_seconds = 0,
        .now_unix_seconds = 30_000,
    });
    try std.testing.expectEqual(@as(usize, 1), preview.eligible);
    try std.testing.expectEqual(@as(usize, 0), preview.pruned);
    try std.testing.expect(pathExists(io, electrobun_root));
    try std.testing.expectEqual(@as(?i64, null), try readLastUsed(io, allocator, home, electrobun.relative_root));
}

test "missing projects retain shadow roots for grace then expire" {
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

    const retained = try scanRegistrations(io, allocator, home, 40_001);
    try std.testing.expectEqual(@as(usize, 1), retained.reachable.items.len);
    try std.testing.expectEqual(@as(usize, 0), retained.expired_paths.items.len);

    const expired = try scanRegistrations(io, allocator, home, 40_000 + default_grace_seconds + 1);
    try std.testing.expectEqual(@as(usize, 0), expired.reachable.items.len);
    try std.testing.expectEqual(@as(usize, 1), expired.expired_paths.items.len);
}

test "a live shadow registration defers all pruning for its grace window" {
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
    try touchLastUsed(io, allocator, home, toolchain.relative_root, 1);
    const retained = try pruneAt(io, allocator, home, .{
        .grace_seconds = 0,
        .now_unix_seconds = 2,
    });
    try std.testing.expectEqual(@as(usize, 0), retained.pruned);
    try std.testing.expectEqual(@as(usize, 1), retained.grace_kept);
    try std.testing.expect(pathExists(io, toolchain_root));

    const expired = try pruneAt(io, allocator, home, .{
        .grace_seconds = 0,
        .now_unix_seconds = default_grace_seconds + 2,
    });
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
    var registration = try std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{});
    const registration_objects = registration.object.getPtr("objects").?;
    registration_objects.array.items = registration_objects.array.items[0..1];
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = registration_path,
        .data = try stringifyJson(allocator, registration),
    });

    const scanned = try scanRegistrations(io, allocator, home, 45_001);
    try std.testing.expectEqual(@as(usize, 2), scanned.reachable.items.len);
    try std.testing.expect(containsPath(scanned.reachable.items, electrobun.relative_root));
    try std.testing.expect(containsPath(scanned.reachable.items, toolchain.relative_root));
}

test "corrupt registration fails closed before artifact mutation" {
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

    try std.testing.expectError(error.InvalidCacheRegistration, pruneAt(io, allocator, home, .{
        .grace_seconds = 0,
        .now_unix_seconds = 50_000,
    }));
    try std.testing.expect(pathExists(io, electrobun_root));
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

    try std.testing.expectError(error.InvalidCacheRegistration, pruneAt(io, allocator, home, .{
        .grace_seconds = 0,
        .now_unix_seconds = default_grace_seconds + 2,
    }));
    try std.testing.expect(pathExists(io, registration_path));
    try std.testing.expect(pathExists(io, electrobun_root));
}

test "registration symlinks fail closed before artifact mutation" {
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

    try std.testing.expectError(error.InvalidCacheRegistration, pruneAt(io, allocator, home, .{
        .grace_seconds = 0,
        .now_unix_seconds = 55_000,
    }));
    try std.testing.expect(pathExists(io, electrobun_root));
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
        .grace_seconds = 0,
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

    try std.testing.expectError(error.InvalidCacheStatePath, pruneAt(io, allocator, home, .{
        .grace_seconds = 0,
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

    try std.testing.expectError(error.InvalidCacheStatePath, pruneAt(io, allocator, home, .{
        .grace_seconds = 0,
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
    try std.Io.Dir.cwd().symLink(
        io,
        third_party_root,
        try std.fs.path.join(allocator, &.{ state_root, "trash" }),
        .{ .is_directory = true },
    );

    try std.testing.expectError(error.InvalidCacheTrashPath, pruneAt(io, allocator, home, .{
        .grace_seconds = 0,
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
    try touchLastUsed(io, allocator, home, toolchain.relative_root, 1);

    try std.testing.expectError(error.InvalidCacheTrashPath, pruneAt(io, allocator, home, .{
        .grace_seconds = 0,
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

    const lease = try cache_locks.acquireObjectLease(io, allocator, home, electrobun_root);
    const held = try inventoryAt(io, allocator, home);
    lease.close(io);

    try std.testing.expectEqual(@as(usize, 0), held.issues.len);
    try std.testing.expectEqual(@as(usize, 2), held.objects.len);
    try std.testing.expectEqualStrings(electrobun.relative_root, held.objects[0].relative_root);
    try std.testing.expect(held.objects[0].reachable);
    try std.testing.expect(held.objects[0].in_use);
    try std.testing.expectEqual(@as(?i64, 1_000), held.objects[0].last_used_unix_seconds);
    try std.testing.expectEqualStrings(toolchain.relative_root, held.objects[1].relative_root);
    try std.testing.expect(held.objects[1].reachable);
    try std.testing.expect(!held.objects[1].in_use);

    try std.testing.expectEqual(@as(usize, 2), held.projects.len);
    try std.testing.expectEqualStrings(gone_project, held.projects[0].canonical_root);
    try std.testing.expect(!held.projects[0].project_exists);
    // A missing project falls back to its last registered graph.
    try std.testing.expect(!held.projects[0].lock_verified);
    try std.testing.expectEqualStrings(
        toolchain.relative_root,
        held.projects[0].objects[0].relative_root,
    );
    try std.testing.expectEqualStrings(live_project, held.projects[1].canonical_root);
    try std.testing.expect(held.projects[1].project_exists);
    try std.testing.expect(held.projects[1].lock_verified);

    // Releasing the lease makes the object detachable again, and the inventory
    // never mutated the store: prune still sees both objects as reachable.
    const released = try inventoryAt(io, allocator, home);
    try std.testing.expect(!released.objects[0].in_use);

    const preview = try pruneAt(io, allocator, home, .{ .dry_run = true, .now_unix_seconds = 1_001 });
    try std.testing.expectEqual(@as(usize, 2), preview.scanned);
    try std.testing.expectEqual(@as(usize, 2), preview.reachable);
    try std.testing.expectEqual(@as(usize, 0), preview.eligible);
}
