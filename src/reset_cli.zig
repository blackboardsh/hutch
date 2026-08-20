const std = @import("std");
const builtin = @import("builtin");
const file_locks = @import("file_locks.zig");
const no_follow_file = @import("no_follow_file.zig");
const store_locks = @import("store_locks.zig");
const release_store = @import("release_store.zig");
const version_selector = @import("version_selector.zig");

const version = @import("version.zig").version;

const usage = "Usage: hutch reset\n";
const max_release_metadata_bytes = 1024 * 1024;
const max_launcher_bytes = 64 * 1024 * 1024;
const max_lock_walk_depth = 64;
const launcher_storage_schema = "1";

const CurrentInstall = struct {
    home: []const u8,
    channel: []const u8,
    selection: release_store.Selection,
    release_root: []const u8,
    release_lock: []const u8,
    release_launcher: []const u8,
    global_launcher: []const u8,
    configured_launcher_is_global: bool,
};

/// Resets Hutch's managed home around the release that is executing this
/// command. This operation is deliberately non-interactive: any argument is
/// an error and, importantly, is rejected before the store is inspected or
/// mutated.
pub fn run(
    init: std.process.Init,
    args: []const [:0]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    if (args.len != 0) {
        try stderr.writeAll("hutch reset: reset does not accept arguments\n");
        try stderr.writeAll(usage);
        return 1;
    }

    const allocator = init.arena.allocator();
    const current = reset(init, allocator) catch |err| {
        try writeResetError(stderr, err);
        return 1;
    };
    try stdout.print(
        "Reset Hutch; retained {s} ({s})\n",
        .{ current.selection.version, current.channel },
    );
    return 0;
}

fn reset(init: std.process.Init, allocator: std.mem.Allocator) !CurrentInstall {
    const configured_home = try release_store.hutchHome(init, allocator);

    // Ownership is a precondition for taking even Hutch's persistent graph
    // lock: acquiring that lock is allowed to create state/locks. A bad or
    // unmarked target must therefore fail this read-only check first.
    const canonical_home = try validateOwnedStoreRoot(
        init.io,
        allocator,
        configured_home,
    );
    try validateResetBoundary(init.io, allocator, canonical_home, init.environ_map);
    const identity = release_store.loadStoreIdentity(init, allocator) catch |err| switch (err) {
        error.FileNotFound => return error.HutchStoreMarkerMissing,
        error.HutchStoreRootMismatch => return error.HutchStoreCanonicalRootMismatch,
        else => return err,
    };
    if (!pathEqual(canonical_home, identity.canonical_root)) {
        return error.HutchStoreCanonicalRootMismatch;
    }

    var current: CurrentInstall = undefined;
    var transaction_root: ?[]const u8 = null;
    {
        const graph = (try store_locks.tryAcquireGraphExclusive(
            init.io,
            allocator,
            canonical_home,
        )) orelse return error.HutchStoreInUse;
        defer graph.close(init.io);

        // Repeat all destructive preconditions after serialization. This
        // closes the validation-to-mutation race without ever claiming an
        // unowned path.
        const locked_home = try validateOwnedStoreRoot(
            init.io,
            allocator,
            configured_home,
        );
        if (!pathEqual(canonical_home, locked_home)) return error.HutchStoreChangedDuringReset;
        const locked_identity = release_store.loadStoreIdentity(init, allocator) catch |err| switch (err) {
            error.FileNotFound => return error.HutchStoreMarkerMissing,
            error.HutchStoreRootMismatch => return error.HutchStoreCanonicalRootMismatch,
            else => return err,
        };
        if (!pathEqual(canonical_home, locked_identity.canonical_root)) {
            return error.HutchStoreChangedDuringReset;
        }

        current = try validateCurrentInstall(init, allocator, canonical_home);

        // Probe every pre-existing object lease while the graph is exclusive.
        // Reset fails before mutation if another release/toolchain is live.
        // Once all exclusive locks have been observed, the graph lock prevents
        // a new lease from appearing and the handles can be closed before
        // Windows removes their lock files.
        try drainObjectLeases(init.io, allocator, current);

        // Publish the two pieces required to boot before removing anything
        // else. If reset is interrupted after this point, the selected release
        // and global launcher remain usable and a rerun finishes cleanup.
        try ensureGlobalLauncher(init.io, allocator, current);
        try writeFreshSelection(init.io, allocator, current);

        transaction_root = try sweepHome(init.io, allocator, current);
    }

    // Everything unwanted was detached atomically enough to leave the live
    // store usable. Slow recursive deletion happens without holding the graph
    // lock; an interrupted cleanup is discovered by the next reset/prune.
    if (transaction_root) |trash| {
        std.Io.Dir.cwd().deleteTree(init.io, trash) catch
            return error.ResetTrashCleanupFailed;
    }
    return current;
}

fn writeResetError(stderr: *std.Io.Writer, err: anyerror) !void {
    const message = switch (err) {
        error.HutchStoreMarkerMissing => "Hutch home is not owned by Hutch (state/store.json store marker is missing)",
        error.HutchStoreRootIsSymbolicLink => "Hutch home is a symbolic link or junction; reset refuses symlinked stores",
        error.HutchStoreCanonicalRootMismatch => "Hutch store marker canonical root does not match the configured Hutch home",
        error.UnsafeHutchResetTarget => "refusing to reset a filesystem root or the user home directory",
        error.InvalidHutchStoreMarker, error.UnsupportedHutchStoreSchema => "Hutch store ownership marker is invalid",
        error.InvalidCurrentHutchChannel => "the active Hutch release channel is missing or invalid",
        error.InvalidCurrentHutchRelease => "the currently executing Hutch release is incomplete or invalid",
        error.InvalidCurrentHutchLauncher => "the current Hutch launcher is missing, aliased, or does not match this release",
        error.HutchGlobalLauncherMismatch => "the running Windows launcher does not match the retained Hutch release",
        error.HutchGlobalLauncherInUse => "the global Hutch launcher is in use and could not be replaced safely",
        error.HutchStoreInUse => "a Hutch release or toolchain is currently in use; try reset again after it exits",
        else => null,
    };
    if (message) |text| {
        try stderr.print("hutch reset: {s}\n", .{text});
    } else {
        try stderr.print("hutch reset: {s}\n", .{@errorName(err)});
    }
}

/// Confirms that the configured root itself is a real directory (not a
/// symlink/junction), and that state/store.json is a direct, regular child.
/// The marker contents are parsed by release_store.loadStoreIdentity.
fn validateOwnedStoreRoot(
    io: std.Io,
    allocator: std.mem.Allocator,
    configured_home: []const u8,
) ![]const u8 {
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    const absolute_home = try std.fs.path.resolve(allocator, &.{ cwd, configured_home });
    const home_stat = std.Io.Dir.cwd().statFile(io, absolute_home, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.HutchStoreMarkerMissing,
        else => return err,
    };
    if (home_stat.kind == .sym_link) return error.HutchStoreRootIsSymbolicLink;
    if (home_stat.kind != .directory) return error.InvalidHutchStoreRoot;

    // lstat identifies POSIX symlinks. The canonical-parent comparison also
    // catches Windows junctions, where some filesystems report directory.
    const parent = std.fs.path.dirname(absolute_home) orelse return error.InvalidHutchStoreRoot;
    const name = std.fs.path.basename(absolute_home);
    const canonical_parent = try std.Io.Dir.cwd().realPathFileAlloc(io, parent, allocator);
    const unaliased_home = try std.fs.path.join(allocator, &.{ canonical_parent, name });
    const canonical_home = try std.Io.Dir.cwd().realPathFileAlloc(io, absolute_home, allocator);
    if (!pathEqual(unaliased_home, canonical_home)) return error.HutchStoreRootIsSymbolicLink;

    const state = try std.fs.path.join(allocator, &.{ canonical_home, release_store.state_directory_name });
    try requireUnaliasedDirectory(io, allocator, canonical_home, state, error.HutchStoreMarkerMissing);
    const marker = try std.fs.path.join(allocator, &.{ state, release_store.store_marker_file_name });
    requireRegularFile(io, marker) catch |err| switch (err) {
        error.FileNotFound => return error.HutchStoreMarkerMissing,
        error.PathIsSymbolicLink => return error.InvalidHutchStoreMarker,
        else => return err,
    };
    return canonical_home;
}

fn validateResetBoundary(
    io: std.Io,
    allocator: std.mem.Allocator,
    canonical_home: []const u8,
    environment: *const std.process.Environ.Map,
) !void {
    const parent = try std.fs.path.resolve(allocator, &.{ canonical_home, ".." });
    if (pathEqual(parent, canonical_home)) return error.UnsafeHutchResetTarget;

    for ([_][]const u8{ "HOME", "USERPROFILE" }) |name| {
        const configured = environment.get(name) orelse continue;
        if (configured.len == 0) continue;
        const canonical_user_home = std.Io.Dir.cwd().realPathFileAlloc(
            io,
            configured,
            allocator,
        ) catch continue;
        if (pathEqual(canonical_home, canonical_user_home)) {
            return error.UnsafeHutchResetTarget;
        }
    }
}

fn validateCurrentInstall(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    home: []const u8,
) !CurrentInstall {
    const channel_value = init.environ_map.get("HUTCH_ACTIVE_CHANNEL") orelse
        return error.InvalidCurrentHutchChannel;
    const channel = version_selector.normalizeChannel(channel_value) catch
        return error.InvalidCurrentHutchChannel;
    const executing = try std.process.executablePathAlloc(init.io, allocator);
    requireRegularFile(init.io, executing) catch return error.InvalidCurrentHutchRelease;
    const canonical_executing = try std.Io.Dir.cwd().realPathFileAlloc(init.io, executing, allocator);
    if (!std.mem.eql(u8, std.fs.path.basename(canonical_executing), release_store.Product.hutch.executableFileName())) {
        return error.InvalidCurrentHutchRelease;
    }
    const bin = std.fs.path.dirname(canonical_executing) orelse return error.InvalidCurrentHutchRelease;
    if (!std.mem.eql(u8, std.fs.path.basename(bin), "bin")) return error.InvalidCurrentHutchRelease;
    const release_root = std.fs.path.dirname(bin) orelse return error.InvalidCurrentHutchRelease;

    const selection = try validateReleaseMetadata(init.io, allocator, release_root);
    const expected_root = try std.fs.path.join(allocator, &.{
        home,
        release_store.releases_directory_name,
        release_store.Product.hutch.name(),
        selection.version,
        selection.revision,
        selection.platform,
    });
    if (!pathEqual(release_root, expected_root)) return error.InvalidCurrentHutchRelease;
    try requireReleaseHierarchy(init.io, allocator, home, selection);
    const expected_engine = try std.fs.path.join(allocator, &.{
        expected_root,
        "bin",
        release_store.Product.hutch.executableFileName(),
    });
    if (!pathEqual(canonical_executing, expected_engine)) return error.InvalidCurrentHutchRelease;

    const release_launcher = try std.fs.path.join(allocator, &.{
        release_root,
        "bin",
        launcherFileName(false),
    });
    requireRegularFile(init.io, release_launcher) catch return error.InvalidCurrentHutchLauncher;

    const configured_launcher = init.environ_map.get("HUTCH_LAUNCHER_PATH") orelse
        return error.InvalidCurrentHutchLauncher;
    if (!std.fs.path.isAbsolute(configured_launcher)) return error.InvalidCurrentHutchLauncher;
    requireRegularFile(init.io, configured_launcher) catch return error.InvalidCurrentHutchLauncher;
    const canonical_configured = try std.Io.Dir.cwd().realPathFileAlloc(
        init.io,
        configured_launcher,
        allocator,
    );
    const canonical_release_launcher = try std.Io.Dir.cwd().realPathFileAlloc(
        init.io,
        release_launcher,
        allocator,
    );
    const global_launcher = try std.fs.path.join(allocator, &.{
        home,
        "bin",
        launcherFileName(std.mem.eql(u8, channel, "canary")),
    });
    const configured_is_release = pathEqual(canonical_configured, canonical_release_launcher);
    const configured_is_global = pathEqual(canonical_configured, global_launcher);
    if (!configured_is_release and !configured_is_global) {
        return error.InvalidCurrentHutchLauncher;
    }
    if (configured_is_global) {
        // A canonical string comparison alone is insufficient when bin/hutch
        // is an alias. Requiring the concrete file rejects that escape.
        requireUnaliasedFile(init.io, allocator, home, global_launcher) catch
            return error.InvalidCurrentHutchLauncher;
    }
    const storage_schema = init.environ_map.get("HUTCH_LAUNCHER_STORAGE_SCHEMA") orelse
        return error.InvalidCurrentHutchLauncher;
    if (!std.mem.eql(u8, storage_schema, launcher_storage_schema)) {
        return error.InvalidCurrentHutchLauncher;
    }

    return .{
        .home = home,
        .channel = try allocator.dupe(u8, channel),
        .selection = .{
            .version = try allocator.dupe(u8, selection.version),
            .revision = try allocator.dupe(u8, selection.revision),
            .platform = try allocator.dupe(u8, selection.platform),
        },
        .release_root = release_root,
        .release_lock = try std.mem.concat(allocator, u8, &.{ release_root, ".lock" }),
        .release_launcher = release_launcher,
        .global_launcher = global_launcher,
        .configured_launcher_is_global = configured_is_global,
    };
}

fn requireReleaseHierarchy(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    selection: release_store.Selection,
) !void {
    var path = home;
    for ([_][]const u8{
        release_store.releases_directory_name,
        release_store.Product.hutch.name(),
        selection.version,
        selection.revision,
        selection.platform,
        "bin",
    }) |component| {
        path = try std.fs.path.join(allocator, &.{ path, component });
        requireUnaliasedDirectory(io, allocator, home, path, error.InvalidCurrentHutchRelease) catch
            return error.InvalidCurrentHutchRelease;
    }
}

fn validateReleaseMetadata(
    io: std.Io,
    allocator: std.mem.Allocator,
    release_root: []const u8,
) !release_store.Selection {
    const installed_marker = try std.fs.path.join(allocator, &.{ release_root, ".dash-installed" });
    requireRegularFile(io, installed_marker) catch return error.InvalidCurrentHutchRelease;
    const marker_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        installed_marker,
        allocator,
        .limited(128),
    );
    const archive_sha256 = std.mem.trim(u8, marker_bytes, " \t\r\n");
    if (!isLowerHex(archive_sha256, 64)) return error.InvalidCurrentHutchRelease;

    const metadata_path = try std.fs.path.join(allocator, &.{ release_root, "hutch-release.json" });
    requireRegularFile(io, metadata_path) catch return error.InvalidCurrentHutchRelease;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        metadata_path,
        allocator,
        .limited(max_release_metadata_bytes),
    );
    const root = std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidCurrentHutchRelease;
    if (root != .object) return error.InvalidCurrentHutchRelease;
    if (jsonInteger(root, "schema") != 1 or
        !jsonStringEquals(root, "kind", "archive") or
        !jsonStringEquals(root, "product", "hutch"))
    {
        return error.InvalidCurrentHutchRelease;
    }
    const metadata = root.object;
    const selected_version = jsonString(metadata, "version") orelse return error.InvalidCurrentHutchRelease;
    const revision = jsonString(metadata, "revision") orelse return error.InvalidCurrentHutchRelease;
    const platform = jsonString(metadata, "platform") orelse return error.InvalidCurrentHutchRelease;
    const parsed_version = version_selector.parse(selected_version) catch return error.InvalidCurrentHutchRelease;
    if (parsed_version.kind != .version or
        (!isLowerHex(revision, 40) and !isLowerHex(revision, 64)) or
        !std.mem.eql(u8, selected_version, version) or
        !std.mem.eql(u8, platform, release_store.platformKey() catch return error.InvalidCurrentHutchRelease))
    {
        return error.InvalidCurrentHutchRelease;
    }
    const expected_executable = if (builtin.os.tag == .windows)
        "bin/hutch-engine.exe"
    else
        "bin/hutch-engine";
    if (!jsonStringEquals(root, "executable", expected_executable)) {
        return error.InvalidCurrentHutchRelease;
    }
    return .{
        .version = try allocator.dupe(u8, selected_version),
        .revision = try allocator.dupe(u8, revision),
        .platform = try allocator.dupe(u8, platform),
    };
}

fn drainObjectLeases(
    io: std.Io,
    allocator: std.mem.Allocator,
    current: CurrentInstall,
) !void {
    var files: std.ArrayList(std.Io.File) = .empty;
    defer files.deinit(allocator);
    defer for (files.items) |file| file.close(io);

    for ([_][]const u8{ release_store.releases_directory_name, "toolchains" }) |name| {
        const root = try std.fs.path.join(allocator, &.{ current.home, name });
        try acquireLocksBelow(
            io,
            allocator,
            root,
            current.release_lock,
            0,
            &files,
        );
    }

    // Close before deleting on Windows. The exclusive graph lock remains held,
    // so conforming users cannot publish or acquire a new object lease.
    for (files.items) |file| file.close(io);
    files.clearRetainingCapacity();
}

fn acquireLocksBelow(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    retained_lock: []const u8,
    depth: usize,
    files: *std.ArrayList(std.Io.File),
) !void {
    if (depth >= max_lock_walk_depth) return error.ResetStoreDepthExceeded;
    var directory = std.Io.Dir.cwd().openDir(io, path, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer directory.close(io);

    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        const child = try std.fs.path.join(allocator, &.{ path, entry.name });
        const kind = if (entry.kind == .unknown)
            (try directory.statFile(io, entry.name, .{ .follow_symlinks = false })).kind
        else
            entry.kind;
        switch (kind) {
            .directory => try acquireLocksBelow(
                io,
                allocator,
                child,
                retained_lock,
                depth + 1,
                files,
            ),
            .file => if (std.mem.endsWith(u8, entry.name, ".lock") and
                !pathEqual(child, retained_lock))
            {
                const file = file_locks.openNonblocking(
                    io,
                    std.Io.Dir.cwd(),
                    child,
                    .read_write,
                    .exclusive,
                ) catch |err| switch (err) {
                    error.WouldBlock, error.AccessDenied, error.PermissionDenied => return error.HutchStoreInUse,
                    else => return err,
                };
                try files.append(allocator, file);
            },
            else => {},
        }
    }
}

fn ensureGlobalLauncher(
    io: std.Io,
    allocator: std.mem.Allocator,
    current: CurrentInstall,
) !void {
    if (builtin.os.tag == .windows and current.configured_launcher_is_global) {
        if (!try filesEqual(
            io,
            allocator,
            current.release_launcher,
            current.global_launcher,
        )) return error.HutchGlobalLauncherMismatch;
        return;
    }

    const bin = std.fs.path.dirname(current.global_launcher) orelse
        return error.InvalidCurrentHutchLauncher;
    try replaceAliasWithDirectory(io, allocator, current.home, bin);
    copyFileAtomic(io, current.release_launcher, current.global_launcher) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied, error.FileBusy => return error.HutchGlobalLauncherInUse,
        else => return err,
    };
    if (!try filesEqual(io, allocator, current.release_launcher, current.global_launcher)) {
        return error.HutchGlobalLauncherMismatch;
    }
}

fn writeFreshSelection(
    io: std.Io,
    allocator: std.mem.Allocator,
    current: CurrentInstall,
) !void {
    const bytes = try freshSelectionsJson(
        allocator,
        current.channel,
        current.selection,
    );
    const path = try std.fs.path.join(allocator, &.{
        current.home,
        release_store.state_directory_name,
        release_store.selections_file_name,
    });
    // The exclusive graph lock serializes all selection writers for reset.
    try release_store.writeAtomicFileLocked(io, path, bytes);
}

fn freshSelectionsJson(
    allocator: std.mem.Allocator,
    channel: []const u8,
    selection: release_store.Selection,
) ![]const u8 {
    var selected: std.json.ObjectMap = .empty;
    try selected.put(allocator, "version", .{ .string = selection.version });
    try selected.put(allocator, "revision", .{ .string = selection.revision });
    try selected.put(allocator, "platform", .{ .string = selection.platform });

    var channels: std.json.ObjectMap = .empty;
    try channels.put(allocator, channel, .{ .object = selected });
    var products: std.json.ObjectMap = .empty;
    try products.put(allocator, "hutch", .{ .object = channels });

    var root: std.json.ObjectMap = .empty;
    try root.put(allocator, "schemaVersion", .{ .integer = 1 });
    try root.put(allocator, "kind", .{ .string = "hutch-selections" });
    try root.put(allocator, "products", .{ .object = products });
    const compact = try std.json.Stringify.valueAlloc(
        allocator,
        std.json.Value{ .object = root },
        .{},
    );
    return std.mem.concat(allocator, u8, &.{ compact, "\n" });
}

fn sweepHome(
    io: std.Io,
    allocator: std.mem.Allocator,
    current: CurrentInstall,
) !?[]const u8 {
    var candidates: std.ArrayList([]const u8) = .empty;
    var home = try std.Io.Dir.cwd().openDir(io, current.home, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer home.close(io);

    const names = try directoryEntryNames(io, allocator, home);
    for (names) |name| {
        if (std.mem.eql(u8, name, "bin")) {
            try collectBinCandidates(io, allocator, current, &candidates);
        } else if (std.mem.eql(u8, name, release_store.releases_directory_name)) {
            try collectReleaseCandidates(io, allocator, current, &candidates);
        } else if (std.mem.eql(u8, name, release_store.state_directory_name)) {
            try collectStateCandidates(io, allocator, current.home, &candidates);
        } else if (std.mem.eql(u8, name, "toolchains")) {
            try candidates.append(allocator, try std.fs.path.join(allocator, &.{ current.home, name }));
        } else {
            try candidates.append(allocator, try std.fs.path.join(allocator, &.{ current.home, name }));
        }
    }

    if (candidates.items.len == 0) {
        try ensureEmptyToolchainsRoot(io, allocator, current.home);
        return null;
    }

    const transaction = try createResetTransactionRoot(io, allocator, current.home);
    var moved: std.ArrayList(ResetMove) = .empty;
    errdefer moved.deinit(allocator);
    stageResetCandidates(io, allocator, transaction, candidates.items, &moved) catch |err| {
        rollbackResetMoves(io, moved.items) catch return error.ResetRollbackFailed;
        std.Io.Dir.cwd().deleteTree(io, transaction) catch {};
        return err;
    };
    ensureEmptyToolchainsRoot(io, allocator, current.home) catch |err| {
        rollbackResetMoves(io, moved.items) catch return error.ResetRollbackFailed;
        std.Io.Dir.cwd().deleteTree(io, transaction) catch {};
        return err;
    };
    moved.deinit(allocator);
    return transaction;
}

fn collectBinCandidates(
    io: std.Io,
    allocator: std.mem.Allocator,
    current: CurrentInstall,
    candidates: *std.ArrayList([]const u8),
) !void {
    const bin_path = try std.fs.path.join(allocator, &.{ current.home, "bin" });
    var bin = try std.Io.Dir.cwd().openDir(io, bin_path, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer bin.close(io);
    const keep = std.fs.path.basename(current.global_launcher);
    const names = try directoryEntryNames(io, allocator, bin);
    for (names) |name| {
        if (std.mem.eql(u8, name, keep)) continue;
        try candidates.append(allocator, try std.fs.path.join(allocator, &.{ bin_path, name }));
    }
}

fn collectReleaseCandidates(
    io: std.Io,
    allocator: std.mem.Allocator,
    current: CurrentInstall,
    candidates: *std.ArrayList([]const u8),
) !void {
    const releases = try std.fs.path.join(allocator, &.{
        current.home,
        release_store.releases_directory_name,
    });
    try collectSingleBranchCandidates(io, allocator, releases, &.{
        release_store.Product.hutch.name(),
        current.selection.version,
        current.selection.revision,
        current.selection.platform,
    }, 0, candidates);
}

/// Collects every entry except the one directory chain named by `components`.
/// At the leaf, the immutable current release and its sibling object-lock file
/// are retained wholesale (the engine/launcher may be mapped on Windows).
fn collectSingleBranchCandidates(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    components: []const []const u8,
    index: usize,
    candidates: *std.ArrayList([]const u8),
) !void {
    var directory = try std.Io.Dir.cwd().openDir(io, path, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer directory.close(io);
    const keep = components[index];
    const keep_lock = if (index + 1 == components.len)
        try std.mem.concat(allocator, u8, &.{ keep, ".lock" })
    else
        null;

    const names = try directoryEntryNames(io, allocator, directory);
    for (names) |name| {
        if (std.mem.eql(u8, name, keep)) {
            if (index + 1 < components.len) {
                const child = try std.fs.path.join(allocator, &.{ path, name });
                try collectSingleBranchCandidates(
                    io,
                    allocator,
                    child,
                    components,
                    index + 1,
                    candidates,
                );
            }
            continue;
        }
        if (keep_lock) |keep_lock_name| {
            if (std.mem.eql(u8, name, keep_lock_name)) continue;
        }
        try candidates.append(allocator, try std.fs.path.join(allocator, &.{ path, name }));
    }
}

fn collectStateCandidates(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    candidates: *std.ArrayList([]const u8),
) !void {
    const state_path = try std.fs.path.join(allocator, &.{ home, release_store.state_directory_name });
    var state = try std.Io.Dir.cwd().openDir(io, state_path, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer state.close(io);

    const names = try directoryEntryNames(io, allocator, state);
    for (names) |name| {
        if (std.mem.eql(u8, name, release_store.store_marker_file_name) or
            std.mem.eql(u8, name, release_store.selections_file_name))
        {
            continue;
        }
        if (std.mem.eql(u8, name, "locks")) {
            try collectStateLockCandidates(io, allocator, state_path, candidates);
            continue;
        }
        try candidates.append(allocator, try std.fs.path.join(allocator, &.{ state_path, name }));
    }
}

fn collectStateLockCandidates(
    io: std.Io,
    allocator: std.mem.Allocator,
    state_path: []const u8,
    candidates: *std.ArrayList([]const u8),
) !void {
    const locks_path = try std.fs.path.join(allocator, &.{ state_path, "locks" });
    var locks = try std.Io.Dir.cwd().openDir(io, locks_path, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer locks.close(io);
    const names = try directoryEntryNames(io, allocator, locks);
    for (names) |name| {
        if (std.mem.eql(u8, name, "graph.lock")) continue;
        try candidates.append(allocator, try std.fs.path.join(allocator, &.{ locks_path, name }));
    }
}

const ResetMove = struct {
    source: []const u8,
    destination: []const u8,
};

fn createResetTransactionRoot(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
) ![]const u8 {
    var random: [12]u8 = undefined;
    io.random(&random);
    const suffix = std.fmt.bytesToHex(random, .lower);
    const root = try std.fs.path.join(allocator, &.{
        home,
        release_store.state_directory_name,
        try std.fmt.allocPrint(allocator, "reset-{s}", .{&suffix}),
    });
    try std.Io.Dir.cwd().createDir(io, root, .default_dir);
    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, root, allocator);
    if (!pathEqual(canonical, root) or !pathHasParent(canonical, home)) {
        return error.InvalidResetPath;
    }
    return root;
}

fn stageResetCandidates(
    io: std.Io,
    allocator: std.mem.Allocator,
    transaction: []const u8,
    candidates: []const []const u8,
    moved: *std.ArrayList(ResetMove),
) !void {
    try moved.ensureUnusedCapacity(allocator, candidates.len);
    for (candidates, 0..) |source, index| {
        const destination = try std.fs.path.join(allocator, &.{
            transaction,
            try std.fmt.allocPrint(allocator, "entry-{d}", .{index}),
        });
        try std.Io.Dir.cwd().rename(source, std.Io.Dir.cwd(), destination, io);
        moved.appendAssumeCapacity(.{ .source = source, .destination = destination });
    }
}

fn rollbackResetMoves(io: std.Io, moved: []const ResetMove) !void {
    var index = moved.len;
    while (index > 0) {
        index -= 1;
        const item = moved[index];
        try std.Io.Dir.cwd().rename(item.destination, std.Io.Dir.cwd(), item.source, io);
    }
}

fn ensureEmptyToolchainsRoot(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
) !void {
    const toolchains = try std.fs.path.join(allocator, &.{ home, "toolchains" });
    std.Io.Dir.cwd().createDir(io, toolchains, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, toolchains, allocator);
    if (!pathEqual(canonical, toolchains) or !pathHasParent(canonical, home)) {
        return error.InvalidResetPath;
    }
}

fn directoryEntryNames(
    io: std.Io,
    allocator: std.mem.Allocator,
    directory: std.Io.Dir,
) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    return names.toOwnedSlice(allocator);
}

fn replaceAliasWithDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    path: []const u8,
) !void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (stat) |value| {
        if (value.kind == .directory) {
            const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
            if (pathEqual(canonical, path) and pathHasParent(canonical, home)) return;
        }
        try std.Io.Dir.cwd().deleteTree(io, path);
    }
    try std.Io.Dir.cwd().createDirPath(io, path);
    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
    if (!pathEqual(canonical, path) or !pathHasParent(canonical, home)) {
        return error.InvalidResetPath;
    }
}

fn copyFileAtomic(io: std.Io, source: []const u8, destination: []const u8) !void {
    const source_file = try no_follow_file.openForRead(std.Io.Dir.cwd(), io, source, .{
        .mode = .read_only,
    });
    defer source_file.close(io);
    const source_stat = try source_file.stat(io);
    if (source_stat.kind != .file) return error.InvalidCurrentHutchLauncher;

    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, destination, .{
        .make_path = true,
        .replace = true,
        .permissions = .executable_file,
    });
    defer atomic.deinit(io);
    var read_buffer: [64 * 1024]u8 = undefined;
    var write_buffer: [64 * 1024]u8 = undefined;
    var reader = source_file.reader(io, &read_buffer);
    var writer = atomic.file.writer(io, &write_buffer);
    _ = writer.interface.sendFileAll(&reader, .unlimited) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.WriteFailed => return writer.err.?,
    };
    try writer.interface.flush();
    try atomic.file.sync(io);
    try atomic.replace(io);
}

fn filesEqual(
    io: std.Io,
    allocator: std.mem.Allocator,
    lhs: []const u8,
    rhs: []const u8,
) !bool {
    const lhs_bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        lhs,
        allocator,
        .limited(max_launcher_bytes),
    ) catch return false;
    const rhs_bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        rhs,
        allocator,
        .limited(max_launcher_bytes),
    ) catch return false;
    return std.mem.eql(u8, lhs_bytes, rhs_bytes);
}

fn requireRegularFile(io: std.Io, path: []const u8) !void {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind == .sym_link) return error.PathIsSymbolicLink;
    if (stat.kind != .file) return error.PathIsNotRegularFile;
}

fn requireUnaliasedFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    path: []const u8,
) !void {
    try requireRegularFile(io, path);
    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
    if (!pathEqual(canonical, path) or !pathHasParent(canonical, home)) {
        return error.PathEscapesHutchStore;
    }
}

fn requireUnaliasedDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    path: []const u8,
    comptime missing_error: anyerror,
) !void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return missing_error,
        else => return err,
    };
    if (stat.kind == .sym_link) return error.PathIsSymbolicLink;
    if (stat.kind != .directory) return error.PathIsNotDirectory;
    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
    if (!pathEqual(canonical, path) or !pathHasParent(canonical, home)) {
        return error.PathEscapesHutchStore;
    }
}

fn jsonInteger(root: std.json.Value, name: []const u8) ?i64 {
    const value = root.object.get(name) orelse return null;
    return switch (value) {
        .integer => |integer| integer,
        else => null,
    };
}

fn jsonStringEquals(root: std.json.Value, name: []const u8, expected: []const u8) bool {
    const value = root.object.get(name) orelse return false;
    return switch (value) {
        .string => |string| std.mem.eql(u8, string, expected),
        else => false,
    };
}

fn jsonString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn isLowerHex(value: []const u8, expected_length: usize) bool {
    if (value.len != expected_length) return false;
    for (value) |char| {
        if (!std.ascii.isDigit(char) and !(char >= 'a' and char <= 'f')) return false;
    }
    return true;
}

fn launcherFileName(canary: bool) []const u8 {
    if (canary) return if (builtin.os.tag == .windows) "hutch-canary.exe" else "hutch-canary";
    return if (builtin.os.tag == .windows) "hutch.exe" else "hutch";
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

test "fresh reset selection contains only the executing Hutch channel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const bytes = try freshSelectionsJson(allocator, "canary", .{
        .version = "1.2.3-canary.4",
        .revision = "0123456789abcdef0123456789abcdef01234567",
        .platform = "macos-arm64",
    });
    const root = try std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{});
    const products = root.object.get("products").?.object;
    try std.testing.expectEqual(@as(usize, 1), products.count());
    try std.testing.expect(products.get("cottontail") == null);
    const hutch = products.get("hutch").?.object;
    try std.testing.expect(hutch.get("production") == null);
    try std.testing.expectEqualStrings(
        "1.2.3-canary.4",
        hutch.get("canary").?.object.get("version").?.string,
    );
}

test "reset release marker validation is strict lowercase sha256" {
    try std.testing.expect(isLowerHex("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", 64));
    try std.testing.expect(!isLowerHex("0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef", 64));
    try std.testing.expect(!isLowerHex("abcdef", 64));
    try std.testing.expect(isLowerHex("0123456789abcdef0123456789abcdef01234567", 40));
}

test "reset engine entry point typechecks as a concrete command" {
    const entry_point: *const fn (
        std.process.Init,
        []const [:0]const u8,
        *std.Io.Writer,
        *std.Io.Writer,
    ) anyerror!u8 = &run;
    try std.testing.expect(@intFromPtr(entry_point) != 0);
}

test "reset sweep detaches everything outside the minimal current store" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const relative = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const fixture = try std.Io.Dir.cwd().realPathFileAlloc(io, relative, allocator);
    const home = try std.fs.path.join(allocator, &.{ fixture, "home" });
    const revision = "0123456789abcdef0123456789abcdef01234567";
    const platform = "test-platform";
    const current_root = try std.fs.path.join(allocator, &.{
        home, "releases", "hutch", "1.2.3", revision, platform,
    });
    const release_launcher = try std.fs.path.join(allocator, &.{ current_root, "bin", launcherFileName(false) });
    const global_launcher = try std.fs.path.join(allocator, &.{ home, "bin", launcherFileName(false) });
    const marker = try std.fs.path.join(allocator, &.{ home, "state", "store.json" });
    const selections = try std.fs.path.join(allocator, &.{ home, "state", "selections.json" });
    const graph_lock = try std.fs.path.join(allocator, &.{ home, "state", "locks", "graph.lock" });
    const stale_project = try std.fs.path.join(allocator, &.{ home, "state", "projects", "old.json" });
    const old_release = try std.fs.path.join(allocator, &.{ home, "releases", "cottontail", "old", "payload" });
    const old_toolchain = try std.fs.path.join(allocator, &.{ home, "toolchains", "zig", "old", "payload" });
    const legacy_cache = try std.fs.path.join(allocator, &.{ home, "cache", "metadata" });
    for ([_][]const u8{
        release_launcher,
        global_launcher,
        marker,
        selections,
        graph_lock,
        stale_project,
        old_release,
        old_toolchain,
        legacy_cache,
    }) |file| {
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(file).?);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = "fixture" });
    }
    const release_lock = try std.mem.concat(allocator, u8, &.{ current_root, ".lock" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = release_lock, .data = "" });
    const other_launcher = try std.fs.path.join(allocator, &.{ home, "bin", launcherFileName(true) });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = other_launcher, .data = "old" });

    const current: CurrentInstall = .{
        .home = home,
        .channel = "production",
        .selection = .{ .version = "1.2.3", .revision = revision, .platform = platform },
        .release_root = current_root,
        .release_lock = release_lock,
        .release_launcher = release_launcher,
        .global_launcher = global_launcher,
        .configured_launcher_is_global = true,
    };
    const transaction = (try sweepHome(io, allocator, current)).?;

    try std.testing.expect(pathExists(io, current_root));
    try std.testing.expect(pathExists(io, release_lock));
    try std.testing.expect(pathExists(io, global_launcher));
    try std.testing.expect(pathExists(io, marker));
    try std.testing.expect(pathExists(io, selections));
    try std.testing.expect(pathExists(io, graph_lock));
    try std.testing.expect(!pathExists(io, stale_project));
    try std.testing.expect(!pathExists(io, old_release));
    try std.testing.expect(!pathExists(io, old_toolchain));
    try std.testing.expect(!pathExists(io, legacy_cache));
    try std.testing.expect(!pathExists(io, other_launcher));

    const toolchains = try std.fs.path.join(allocator, &.{ home, "toolchains" });
    var toolchains_dir = try std.Io.Dir.cwd().openDir(io, toolchains, .{ .iterate = true });
    defer toolchains_dir.close(io);
    var toolchains_iterator = toolchains_dir.iterate();
    try std.testing.expect((try toolchains_iterator.next(io)) == null);

    try std.Io.Dir.cwd().deleteTree(io, transaction);
    try std.testing.expect(!pathExists(io, transaction));
}

test "reset fails before mutation when another managed object lease is live" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const relative = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const fixture = try std.Io.Dir.cwd().realPathFileAlloc(io, relative, allocator);
    const home = try std.fs.path.join(allocator, &.{ fixture, "home" });
    const live_root = try std.fs.path.join(allocator, &.{ home, "toolchains", "zig", "1.0.0", "test-platform" });
    try std.Io.Dir.cwd().createDirPath(io, live_root);
    const live_lock_path = try std.mem.concat(allocator, u8, &.{ live_root, ".lock" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = live_lock_path, .data = "" });
    const live_lock = try std.Io.Dir.cwd().openFile(io, live_lock_path, .{
        .mode = .read_write,
        .lock = .shared,
        .follow_symlinks = false,
    });
    defer live_lock.close(io);

    const current: CurrentInstall = .{
        .home = home,
        .channel = "production",
        .selection = .{ .version = "1.2.3", .revision = "revision", .platform = "test-platform" },
        .release_root = "unused",
        .release_lock = "not-the-live-lock",
        .release_launcher = "unused",
        .global_launcher = "unused",
        .configured_launcher_is_global = true,
    };
    try std.testing.expectError(
        error.HutchStoreInUse,
        drainObjectLeases(io, allocator, current),
    );
    try std.testing.expect(pathExists(io, live_root));
}

test "reset independently refuses filesystem and user home roots" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const relative = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const fixture = try std.Io.Dir.cwd().realPathFileAlloc(io, relative, allocator);

    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("HOME", fixture);
    try std.testing.expectError(
        error.UnsafeHutchResetTarget,
        validateResetBoundary(io, allocator, fixture, &environment),
    );

    var filesystem_root: []const u8 = fixture;
    while (true) {
        const parent = try std.fs.path.resolve(allocator, &.{ filesystem_root, ".." });
        if (pathEqual(parent, filesystem_root)) break;
        filesystem_root = parent;
    }
    try environment.put("HOME", try std.fs.path.join(allocator, &.{ fixture, "other" }));
    try std.testing.expectError(
        error.UnsafeHutchResetTarget,
        validateResetBoundary(io, allocator, filesystem_root, &environment),
    );
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}
