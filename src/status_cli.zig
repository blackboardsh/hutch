const std = @import("std");
const builtin = @import("builtin");
const bootstrap_pragma = @import("bootstrap_pragma.zig");
const managed_store = @import("managed_store.zig");
const release_store = @import("release_store.zig");
const version_selector = @import("version_selector.zig");

const help_text =
    "Usage:\n" ++
    "  hutch status [--json]\n" ++
    "\n" ++
    "Reports the resolved Hutch home, installed releases and their selections,\n" ++
    "installed toolchains, managed-store reachability, and registered projects.\n" ++
    "\n" ++
    "Sizes are recursive file totals. Symlinks are counted but never followed,\n" ++
    "so a bin launcher can never pull an out-of-store tree into a total.\n" ++
    "Like ordinary commands, `status` may run the lazy 10-day prune first;\n" ++
    "the report itself is a read-only snapshot of the store.\n";

/// The `--json` document version. Any incompatible field change bumps this.
pub const json_schema_version = 4;

const max_walk_depth = 64;

const platform_keys = [_][]const u8{
    "macos-arm64",
    "macos-x64",
    "linux-x64",
    "linux-arm64",
    "windows-x64",
};

pub fn run(
    init: std.process.Init,
    args: []const [:0]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var emit_json = false;
    for (args) |arg| {
        if (isHelp(arg)) {
            try stdout.writeAll(help_text);
            return 0;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            emit_json = true;
            continue;
        }
        try stderr.print("hutch status: unknown option: {s}\n", .{arg});
        try stderr.writeAll(help_text);
        return 1;
    }

    const allocator = init.arena.allocator();
    const report = collect(init, allocator) catch |err| {
        try stderr.print("hutch status: {s}\n", .{@errorName(err)});
        return 1;
    };

    if (emit_json) {
        try writeJson(allocator, report, stdout);
    } else {
        try writeText(allocator, report, stdout);
    }
    return 0;
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

// -- Disk usage ------------------------------------------------------------

pub const Usage = struct {
    bytes: u64 = 0,
    files: u64 = 0,
    directories: u64 = 0,
    /// Counted, never traversed: a launcher symlink may leave the store.
    symlinks: u64 = 0,
    /// Entries that could not be read. Each one is also reported as an issue.
    unreadable: u64 = 0,

    pub fn add(self: *Usage, other: Usage) void {
        self.bytes += other.bytes;
        self.files += other.files;
        self.directories += other.directories;
        self.symlinks += other.symlinks;
        self.unreadable += other.unreadable;
    }
};

const Issues = std.ArrayList([]const u8);

fn appendIssue(
    allocator: std.mem.Allocator,
    issues: *Issues,
    subject: []const u8,
    err: anyerror,
) !void {
    try issues.append(allocator, try std.fmt.allocPrint(
        allocator,
        "{s}: {s}",
        .{ subject, @errorName(err) },
    ));
}

/// Recursive file-size total for `path`.
///
/// Directories are opened through their parent handle without following
/// symlinks, so the walk can never leave the subtree it was pointed at.
/// Unreadable entries are recorded and skipped instead of aborting the walk.
pub fn measure(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    issues: *Issues,
) !Usage {
    var usage: Usage = .{};
    var directory = std.Io.Dir.cwd().openDir(io, path, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| {
        try appendIssue(allocator, issues, path, err);
        usage.unreadable += 1;
        return usage;
    };
    defer directory.close(io);
    usage.directories += 1;
    try measureOpenDirectory(io, allocator, directory, path, 0, &usage, issues);
    return usage;
}

fn measureOpenDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    directory: std.Io.Dir,
    display_path: []const u8,
    depth: usize,
    usage: *Usage,
    issues: *Issues,
) !void {
    if (depth >= max_walk_depth) {
        try appendIssue(allocator, issues, display_path, error.WalkDepthExceeded);
        usage.unreadable += 1;
        return;
    }
    var iterator = directory.iterate();
    while (true) {
        const entry = (iterator.next(io) catch |err| {
            try appendIssue(allocator, issues, display_path, err);
            usage.unreadable += 1;
            return;
        }) orelse break;

        var kind = entry.kind;
        if (kind == .unknown) {
            const stat = directory.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err| {
                try appendChildIssue(allocator, issues, display_path, entry.name, err);
                usage.unreadable += 1;
                continue;
            };
            kind = stat.kind;
        }

        switch (kind) {
            .sym_link => usage.symlinks += 1,
            .directory => {
                const child_path = try std.fs.path.join(allocator, &.{ display_path, entry.name });
                var child = directory.openDir(io, entry.name, .{
                    .iterate = true,
                    .follow_symlinks = false,
                }) catch |err| {
                    try appendIssue(allocator, issues, child_path, err);
                    usage.unreadable += 1;
                    continue;
                };
                defer child.close(io);
                usage.directories += 1;
                try measureOpenDirectory(io, allocator, child, child_path, depth + 1, usage, issues);
            },
            else => {
                const stat = directory.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err| {
                    try appendChildIssue(allocator, issues, display_path, entry.name, err);
                    usage.unreadable += 1;
                    continue;
                };
                if (stat.kind == .sym_link) {
                    usage.symlinks += 1;
                    continue;
                }
                usage.files += 1;
                usage.bytes += stat.size;
            },
        }
    }
}

fn appendChildIssue(
    allocator: std.mem.Allocator,
    issues: *Issues,
    parent: []const u8,
    name: []const u8,
    err: anyerror,
) !void {
    const path = try std.fs.path.join(allocator, &.{ parent, name });
    try appendIssue(allocator, issues, path, err);
}

/// Human-readable binary size. Values below 1 KiB stay exact.
pub fn formatBytes(buffer: *[32]u8, bytes: u64) []const u8 {
    if (bytes < 1024) return std.fmt.bufPrint(buffer, "{d} B", .{bytes}) catch unreachable;
    const units = [_][]const u8{ "KiB", "MiB", "GiB", "TiB", "PiB", "EiB" };
    var value: f64 = @as(f64, @floatFromInt(bytes)) / 1024.0;
    var index: usize = 0;
    // 1023.95 rounds up to "1024.0" at one decimal, which reads as the next
    // unit. Promote instead of printing a value that looks out of range.
    while (value >= 1023.95 and index + 1 < units.len) : (index += 1) {
        value /= 1024.0;
    }
    return std.fmt.bufPrint(buffer, "{d:.1} {s}", .{ value, units[index] }) catch unreachable;
}

// -- Report model ----------------------------------------------------------

pub const ReleaseInstall = struct {
    version: []const u8,
    /// Absent for releases stored without a revision level (Electrobun).
    revision: ?[]const u8 = null,
    platform: []const u8,
    path: []const u8,
    relative_root: []const u8,
    usage: Usage = .{},
    selections: std.ArrayList([]const u8) = .empty,
};

pub const ReleaseProduct = struct {
    name: []const u8,
    installs: std.ArrayList(ReleaseInstall) = .empty,
    bytes: u64 = 0,
};

pub const Toolchain = struct {
    language: []const u8,
    version: []const u8,
    platform: []const u8,
    path: []const u8,
    relative_root: []const u8,
    usage: Usage = .{},
};

pub const ReleaseSelection = struct {
    product: []const u8,
    name: []const u8,
    version: []const u8,
    revision: []const u8,
    platform: []const u8,
    /// The exact product, version, revision, and platform are installed.
    installed: bool,
};

pub const PinEntry = struct {
    product: []const u8,
    field: []const u8,
    /// The pragma's selector text, or null when the directory uses the
    /// active-channel default.
    selector: ?[]const u8,
    /// The version this directory actually runs. Null when unknowable
    /// (a build-revision pin, or no selection recorded yet).
    resolved: ?[]const u8,
    /// The active channel's current selection.
    channel_version: ?[]const u8,
    behind: bool,
};

pub const PinReport = struct {
    config_path: ?[]const u8 = null,
    channel: []const u8 = "production",
    parse_error: ?[]const u8 = null,
    entries: std.ArrayList(PinEntry) = .empty,
};

pub const ManagedStoreObject = struct {
    kind: managed_store.ManagedObject.Kind,
    relative_root: []const u8,
    version: []const u8,
    platform: []const u8,
    toolchain_kind: ?[]const u8 = null,
    /// First observed unreachable by an automatic prune. Null while reachable
    /// or before an automatic sweep has established the retention window.
    unreachable_since_unix_seconds: ?i64 = null,
    reachable: bool = false,
    in_use: bool = false,
    /// Contained in another managed object, so its bytes are already counted
    /// in that parent's total.
    nested: bool = false,
    bytes: u64 = 0,
};

pub const Report = struct {
    home: []const u8,
    home_source: release_store.HomeSource,
    pins: PinReport = .{},
    releases: std.ArrayList(ReleaseProduct) = .empty,
    selections: std.ArrayList(ReleaseSelection) = .empty,
    toolchains: std.ArrayList(Toolchain) = .empty,
    managed_objects: std.ArrayList(ManagedStoreObject) = .empty,
    projects: []const managed_store.InventoryProject = &.{},
    issues: Issues = .empty,
    releases_usage: Usage = .{},
    toolchains_usage: Usage = .{},
    managed_bytes: u64 = 0,

    pub fn totalBytes(self: Report) u64 {
        return self.releases_usage.bytes + self.toolchains_usage.bytes;
    }
};

pub fn collect(init: std.process.Init, allocator: std.mem.Allocator) !Report {
    const home = try release_store.resolveHutchHome(init, allocator);
    var report: Report = .{ .home = home.path, .home_source = home.source };

    try collectReleases(init.io, allocator, home.path, &report);
    try collectSelections(init, allocator, &report);
    try collectPins(init, allocator, &report);
    try collectToolchains(init.io, allocator, home.path, &report);
    try collectManagedStore(init, allocator, &report);
    return report;
}

fn collectPins(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    report: *Report,
) !void {
    const channel_name = init.environ_map.get("HUTCH_ACTIVE_CHANNEL") orelse "production";
    report.pins.channel = version_selector.normalizeChannel(channel_name) catch "production";

    var pragma: bootstrap_pragma.Pragma = .{};
    if (bootstrap_pragma.findNearestConfig(init.io, allocator) catch null) |config_path| {
        report.pins.config_path = config_path;
        if (bootstrap_pragma.parseFile(init.io, allocator, config_path)) |parsed| {
            if (parsed) |value| pragma = value;
        } else |err| {
            report.pins.parse_error = @errorName(err);
        }
    }

    for ([_]release_store.Product{ .hutch, .cottontail }) |product| {
        const field = if (product == .hutch) pragma.cli else pragma.cottontail;
        const channel_version = selectionVersion(report, product, report.pins.channel);
        const selector: ?[]const u8 = if (field) |value| switch (value.kind) {
            .version, .production, .canary => value.value,
            .build => try std.fmt.allocPrint(allocator, "build:{s}", .{value.value}),
        } else null;
        const resolved: ?[]const u8 = if (field) |value| switch (value.kind) {
            .version => value.value,
            .build => null,
            .production, .canary => selectionVersion(report, product, value.value),
        } else channel_version;
        try report.pins.entries.append(allocator, .{
            .product = product.name(),
            .field = if (product == .hutch) "cli" else "cottontail",
            .selector = selector,
            .resolved = resolved,
            .channel_version = channel_version,
            .behind = resolved != null and channel_version != null and
                !std.mem.eql(u8, resolved.?, channel_version.?),
        });
    }
}

fn selectionVersion(
    report: *const Report,
    product: release_store.Product,
    channel: []const u8,
) ?[]const u8 {
    for (report.selections.items) |selection| {
        if (std.mem.eql(u8, selection.product, product.name()) and
            std.mem.eql(u8, selection.name, channel))
        {
            return selection.version;
        }
    }
    return null;
}

fn collectReleases(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    report: *Report,
) !void {
    const root = try std.fs.path.join(allocator, &.{ home, "releases" });
    var names: std.ArrayList([]const u8) = .empty;
    try directoryNames(io, allocator, root, &names, &report.issues);
    std.mem.sort([]const u8, names.items, {}, stringLessThan);

    for (names.items) |name| {
        var product: ReleaseProduct = .{ .name = name };
        const product_root = try std.fs.path.join(allocator, &.{ root, name });

        var versions: std.ArrayList([]const u8) = .empty;
        try directoryNames(io, allocator, product_root, &versions, &report.issues);
        std.mem.sort([]const u8, versions.items, {}, stringLessThan);

        for (versions.items) |version| {
            const version_root = try std.fs.path.join(allocator, &.{ product_root, version });
            var children: std.ArrayList([]const u8) = .empty;
            try directoryNames(io, allocator, version_root, &children, &report.issues);
            std.mem.sort([]const u8, children.items, {}, stringLessThan);

            for (children.items) |child| {
                if (isPlatformKey(child)) {
                    try appendReleaseInstall(io, allocator, &product, .{
                        .version = version,
                        .revision = null,
                        .platform = child,
                        .path = try std.fs.path.join(allocator, &.{ version_root, child }),
                        .relative_root = try std.fmt.allocPrint(
                            allocator,
                            "releases/{s}/{s}/{s}",
                            .{ name, version, child },
                        ),
                    }, &report.issues);
                    continue;
                }
                if (!isRevision(child)) {
                    try appendIssue(
                        allocator,
                        &report.issues,
                        try std.fs.path.join(allocator, &.{ version_root, child }),
                        error.UnrecognizedProductLayout,
                    );
                    continue;
                }
                const revision_root = try std.fs.path.join(allocator, &.{ version_root, child });
                var platforms: std.ArrayList([]const u8) = .empty;
                try directoryNames(io, allocator, revision_root, &platforms, &report.issues);
                std.mem.sort([]const u8, platforms.items, {}, stringLessThan);
                for (platforms.items) |platform| {
                    if (!isPlatformKey(platform)) continue;
                    try appendReleaseInstall(io, allocator, &product, .{
                        .version = version,
                        .revision = child,
                        .platform = platform,
                        .path = try std.fs.path.join(allocator, &.{ revision_root, platform }),
                        .relative_root = try std.fmt.allocPrint(
                            allocator,
                            "releases/{s}/{s}/{s}/{s}",
                            .{ name, version, child, platform },
                        ),
                    }, &report.issues);
                }
            }
        }

        if (product.installs.items.len == 0) continue;
        for (product.installs.items) |install| {
            product.bytes += install.usage.bytes;
            report.releases_usage.add(install.usage);
        }
        try report.releases.append(allocator, product);
    }
}

fn appendReleaseInstall(
    io: std.Io,
    allocator: std.mem.Allocator,
    product: *ReleaseProduct,
    install: ReleaseInstall,
    issues: *Issues,
) !void {
    var measured = install;
    measured.usage = try measure(io, allocator, install.path, issues);
    try product.installs.append(allocator, measured);
}

fn collectToolchains(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    report: *Report,
) !void {
    const root = try std.fs.path.join(allocator, &.{ home, "toolchains" });
    var languages: std.ArrayList([]const u8) = .empty;
    try directoryNames(io, allocator, root, &languages, &report.issues);
    std.mem.sort([]const u8, languages.items, {}, stringLessThan);

    for (languages.items) |language| {
        const language_root = try std.fs.path.join(allocator, &.{ root, language });
        var versions: std.ArrayList([]const u8) = .empty;
        try directoryNames(io, allocator, language_root, &versions, &report.issues);
        std.mem.sort([]const u8, versions.items, {}, stringLessThan);

        for (versions.items) |version| {
            const version_root = try std.fs.path.join(allocator, &.{ language_root, version });
            var platforms: std.ArrayList([]const u8) = .empty;
            try directoryNames(io, allocator, version_root, &platforms, &report.issues);
            std.mem.sort([]const u8, platforms.items, {}, stringLessThan);

            for (platforms.items) |platform| {
                if (!isPlatformKey(platform)) continue;
                const path = try std.fs.path.join(allocator, &.{ version_root, platform });
                const usage = try measure(io, allocator, path, &report.issues);
                report.toolchains_usage.add(usage);
                try report.toolchains.append(allocator, .{
                    .language = language,
                    .version = version,
                    .platform = platform,
                    .path = path,
                    .relative_root = try std.fmt.allocPrint(
                        allocator,
                        "toolchains/{s}/{s}/{s}",
                        .{ language, version, platform },
                    ),
                    .usage = usage,
                });
            }
        }
    }
}

fn collectSelections(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    report: *Report,
) !void {
    const selections = release_store.loadSelections(init, allocator) catch |err| {
        const path = try std.fs.path.join(allocator, &.{
            report.home,
            release_store.state_directory_name,
            release_store.selections_file_name,
        });
        try appendIssue(allocator, &report.issues, path, err);
        return;
    };
    try appendSelections(allocator, report, selections);
}

fn appendSelections(
    allocator: std.mem.Allocator,
    report: *Report,
    selections: release_store.Selections,
) !void {
    if (selections.hutch_production) |selection| {
        try appendSelection(allocator, report, .hutch, "production", selection);
    }
    if (selections.hutch_canary) |selection| {
        try appendSelection(allocator, report, .hutch, "canary", selection);
    }
    if (selections.cottontail_production) |selection| {
        try appendSelection(allocator, report, .cottontail, "production", selection);
    }
    if (selections.cottontail_canary) |selection| {
        try appendSelection(allocator, report, .cottontail, "canary", selection);
    }
}

fn appendSelection(
    allocator: std.mem.Allocator,
    report: *Report,
    product: release_store.Product,
    name: []const u8,
    selection: release_store.Selection,
) !void {
    const installed = try attachSelection(allocator, report, product.name(), name, selection);
    try report.selections.append(allocator, .{
        .product = product.name(),
        .name = name,
        .version = selection.version,
        .revision = selection.revision,
        .platform = selection.platform,
        .installed = installed,
    });
}

fn attachSelection(
    allocator: std.mem.Allocator,
    report: *Report,
    product_name: []const u8,
    name: []const u8,
    selection: release_store.Selection,
) !bool {
    for (report.releases.items) |*product| {
        if (!std.mem.eql(u8, product.name, product_name)) continue;
        for (product.installs.items) |*install| {
            if (!std.mem.eql(u8, install.version, selection.version)) continue;
            if (!std.mem.eql(u8, install.platform, selection.platform)) continue;
            const revision = install.revision orelse continue;
            if (!std.mem.eql(u8, revision, selection.revision)) continue;
            try install.selections.append(allocator, name);
            return true;
        }
    }
    return false;
}

fn collectManagedStore(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    report: *Report,
) !void {
    const found = managed_store.inventory(init, allocator) catch |err| {
        try appendIssue(allocator, &report.issues, "managed state", err);
        return;
    };
    for (found.issues) |issue| try report.issues.append(allocator, issue);
    report.projects = found.projects;

    for (found.objects) |object| {
        var entry: ManagedStoreObject = .{
            .kind = object.kind,
            .relative_root = object.relative_root,
            .version = object.version,
            .platform = object.platform,
            .toolchain_kind = object.toolchain_kind,
            .unreachable_since_unix_seconds = object.unreachable_since_unix_seconds,
            .reachable = object.reachable,
            .in_use = object.in_use,
            .nested = hasManagedAncestor(found.objects, object.relative_root),
        };
        entry.bytes = knownBytes(report.*, object.relative_root) orelse
            (try measure(init.io, allocator, object.absolute_root, &report.issues)).bytes;
        if (!entry.nested) report.managed_bytes += entry.bytes;
        try report.managed_objects.append(allocator, entry);
    }
}

fn hasManagedAncestor(
    objects: []const managed_store.InventoryObject,
    relative_root: []const u8,
) bool {
    for (objects) |other| {
        if (relative_root.len > other.relative_root.len and
            std.mem.startsWith(u8, relative_root, other.relative_root) and
            relative_root[other.relative_root.len] == '/')
        {
            return true;
        }
    }
    return false;
}

/// Managed objects live under `releases/` and `toolchains/`, so their sizes are
/// almost always already measured. Only a nested payload needs its own walk.
fn knownBytes(report: Report, relative_root: []const u8) ?u64 {
    for (report.releases.items) |product| {
        for (product.installs.items) |install| {
            if (std.mem.eql(u8, install.relative_root, relative_root)) return install.usage.bytes;
        }
    }
    for (report.toolchains.items) |toolchain| {
        if (std.mem.eql(u8, toolchain.relative_root, relative_root)) return toolchain.usage.bytes;
    }
    return null;
}

fn directoryNames(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    output: *std.ArrayList([]const u8),
    issues: *Issues,
) !void {
    var directory = std.Io.Dir.cwd().openDir(io, path, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            try appendIssue(allocator, issues, path, err);
            return;
        },
    };
    defer directory.close(io);

    var iterator = directory.iterate();
    while (true) {
        const entry = (iterator.next(io) catch |err| {
            try appendIssue(allocator, issues, path, err);
            return;
        }) orelse break;
        if (entry.kind != .directory) continue;
        if (std.mem.startsWith(u8, entry.name, ".")) continue;
        try output.append(allocator, try allocator.dupe(u8, entry.name));
    }
}

fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn isPlatformKey(name: []const u8) bool {
    for (platform_keys) |key| if (std.mem.eql(u8, key, name)) return true;
    return false;
}

fn isRevision(name: []const u8) bool {
    if (name.len != 40 and name.len != 64) return false;
    for (name) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn objectTypeName(kind: managed_store.ManagedObject.Kind) []const u8 {
    return switch (kind) {
        .electrobun => "electrobun",
        .electrobun_cef => "electrobun-cef",
        .release => "release",
        .toolchain => "toolchain",
    };
}

// -- Plain-text rendering --------------------------------------------------

const Align = enum { left, right };

const Table = struct {
    headers: []const []const u8,
    aligns: []const Align,
    rows: std.ArrayList([]const []const u8) = .empty,

    fn addRow(
        self: *Table,
        allocator: std.mem.Allocator,
        cells: []const []const u8,
    ) !void {
        std.debug.assert(cells.len == self.headers.len);
        try self.rows.append(allocator, try allocator.dupe([]const u8, cells));
    }

    fn write(
        self: Table,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        indent: usize,
    ) !void {
        const widths = try allocator.alloc(usize, self.headers.len);
        defer allocator.free(widths);
        for (self.headers, 0..) |header, index| widths[index] = header.len;
        for (self.rows.items) |row| {
            for (row, 0..) |cell, index| widths[index] = @max(widths[index], cell.len);
        }
        try writeRow(writer, indent, self.headers, self.aligns, widths);
        for (self.rows.items) |row| try writeRow(writer, indent, row, self.aligns, widths);
    }
};

fn writeRow(
    writer: *std.Io.Writer,
    indent: usize,
    cells: []const []const u8,
    aligns: []const Align,
    widths: []const usize,
) !void {
    try writer.splatByteAll(' ', indent);
    for (cells, 0..) |cell, index| {
        if (index > 0) try writer.writeAll("  ");
        const padding = widths[index] - cell.len;
        // Trailing whitespace on the final column is never useful.
        if (aligns[index] == .right) try writer.splatByteAll(' ', padding);
        try writer.writeAll(cell);
        if (aligns[index] == .left and index + 1 < cells.len) try writer.splatByteAll(' ', padding);
    }
    try writer.writeAll("\n");
}

fn sizeText(allocator: std.mem.Allocator, bytes: u64) ![]const u8 {
    var buffer: [32]u8 = undefined;
    return allocator.dupe(u8, formatBytes(&buffer, bytes));
}

pub fn writeText(
    allocator: std.mem.Allocator,
    report: Report,
    writer: *std.Io.Writer,
) !void {
    try writer.writeAll("Home\n");
    try writer.print("  path    {s}\n", .{report.home});
    if (report.home_source.deprecated()) {
        try writer.print(
            "  source  {s} (deprecated; prefer HUTCH_HOME)\n",
            .{report.home_source.label()},
        );
    } else if (report.home_source == .default_home) {
        try writer.writeAll("  source  default (~/.hutch)\n");
    } else {
        try writer.print("  source  {s}\n", .{report.home_source.label()});
    }

    try writer.writeAll("\nPins (current directory)\n");
    if (report.pins.config_path) |config_path| {
        try writer.print("  config  {s}\n", .{config_path});
    } else {
        try writer.writeAll("  config  (no hutch.config.ts found; the channel default applies)\n");
    }
    if (report.pins.parse_error) |parse_error| {
        try writer.print("  (pragma unreadable: {s})\n", .{parse_error});
    } else {
        var table: Table = .{
            .headers = &.{ "product", "pragma", "runs", "channel", "action" },
            .aligns = &.{ .left, .left, .left, .left, .left },
        };
        for (report.pins.entries.items) |entry| {
            try table.addRow(allocator, &.{
                entry.product,
                if (entry.selector) |selector|
                    try std.fmt.allocPrint(allocator, "{s}={s}", .{ entry.field, selector })
                else
                    "(default)",
                entry.resolved orelse "?",
                try std.fmt.allocPrint(allocator, "{s} {s}", .{
                    report.pins.channel,
                    entry.channel_version orelse "-",
                }),
                if (entry.behind)
                    try std.fmt.allocPrint(allocator, "hutch {s} pin", .{
                        if (std.mem.eql(u8, entry.product, "hutch")) "self" else entry.product,
                    })
                else
                    "-",
            });
        }
        try table.write(allocator, writer, 2);
    }

    try writer.writeAll("\nReleases\n");
    if (report.releases.items.len == 0) {
        try writer.writeAll("  (none)\n");
    } else {
        for (report.releases.items) |product| {
            try writer.print("  {s}\n", .{product.name});
            var table: Table = .{
                .headers = &.{ "version", "revision", "platform", "size", "files", "selections" },
                .aligns = &.{ .left, .left, .left, .right, .right, .left },
            };
            for (product.installs.items) |install| {
                try table.addRow(allocator, &.{
                    install.version,
                    install.revision orelse "-",
                    install.platform,
                    try sizeText(allocator, install.usage.bytes),
                    try std.fmt.allocPrint(allocator, "{d}", .{install.usage.files}),
                    if (install.selections.items.len == 0)
                        "-"
                    else
                        try joinStrings(allocator, install.selections.items, ", "),
                });
            }
            try table.write(allocator, writer, 4);
            try writer.print("    subtotal {s}\n", .{try sizeText(allocator, product.bytes)});
        }
    }
    try writer.print("  releases total {s}\n", .{try sizeText(allocator, report.releases_usage.bytes)});

    try writer.writeAll("\nSelections\n");
    if (report.selections.items.len == 0) {
        try writer.writeAll("  (none)\n");
    } else {
        var table: Table = .{
            .headers = &.{ "product", "selection", "version", "revision", "platform", "state" },
            .aligns = &.{ .left, .left, .left, .left, .left, .left },
        };
        for (report.selections.items) |selection| {
            try table.addRow(allocator, &.{
                selection.product,
                selection.name,
                selection.version,
                selection.revision,
                selection.platform,
                if (selection.installed) "installed" else "missing",
            });
        }
        try table.write(allocator, writer, 2);
    }

    try writer.writeAll("\nToolchains\n");
    if (report.toolchains.items.len == 0) {
        try writer.writeAll("  (none)\n");
    } else {
        var table: Table = .{
            .headers = &.{ "language", "version", "platform", "size", "files" },
            .aligns = &.{ .left, .left, .left, .right, .right },
        };
        for (report.toolchains.items) |toolchain| {
            try table.addRow(allocator, &.{
                toolchain.language,
                toolchain.version,
                toolchain.platform,
                try sizeText(allocator, toolchain.usage.bytes),
                try std.fmt.allocPrint(allocator, "{d}", .{toolchain.usage.files}),
            });
        }
        try table.write(allocator, writer, 2);
    }
    try writer.print("  toolchains total {s}\n", .{try sizeText(allocator, report.toolchains_usage.bytes)});

    try writer.writeAll("\nManaged store\n");
    try writer.print(
        "  automatic retention {d} days from first becoming unreachable\n",
        .{@divExact(managed_store.automatic_retention_seconds, 24 * 60 * 60)},
    );
    if (report.managed_objects.items.len == 0) {
        try writer.writeAll("  (no managed objects)\n");
    } else {
        var table: Table = .{
            .headers = &.{ "object", "type", "size", "state", "unreachable since" },
            .aligns = &.{ .left, .left, .right, .left, .left },
        };
        for (report.managed_objects.items) |object| {
            try table.addRow(allocator, &.{
                object.relative_root,
                objectTypeName(object.kind),
                try sizeText(allocator, object.bytes),
                try managedStoreStateText(allocator, object),
                if (object.unreachable_since_unix_seconds) |seconds|
                    try std.fmt.allocPrint(allocator, "{d}", .{seconds})
                else
                    "-",
            });
        }
        try table.write(allocator, writer, 2);
    }
    try writer.print(
        "  managed objects {d}, total {s} (already counted in releases and toolchains)\n",
        .{ report.managed_objects.items.len, try sizeText(allocator, report.managed_bytes) },
    );

    try writer.print("\nProjects ({d})\n", .{report.projects.len});
    if (report.projects.len == 0) {
        try writer.writeAll("  (none registered)\n");
    } else {
        for (report.projects) |project| {
            try writer.print("  {s}{s}\n", .{
                project.canonical_root,
                if (project.project_exists) "" else "  [path missing]",
            });
            try writer.print("    state       {s}, last seen {d}\n", .{
                if (project.lock_verified) "lock verified" else "registration only",
                project.last_seen_unix_seconds,
            });
            if (project.objects.len == 0) {
                try writer.writeAll("    references  (none)\n");
            } else {
                for (project.objects, 0..) |object, index| {
                    try writer.print("    {s}  {s} ({s})\n", .{
                        if (index == 0) "references" else "          ",
                        object.relative_root,
                        objectTypeName(object.kind),
                    });
                }
            }
        }
    }

    if (report.issues.items.len != 0) {
        try writer.print("\nIssues ({d})\n", .{report.issues.items.len});
        for (report.issues.items) |issue| try writer.print("  {s}\n", .{issue});
    }

    try writer.writeAll("\nTotal\n");
    try writer.print("  releases    {s}\n", .{try sizeText(allocator, report.releases_usage.bytes)});
    try writer.print("  toolchains  {s}\n", .{try sizeText(allocator, report.toolchains_usage.bytes)});
    try writer.print("  on disk     {s}\n", .{try sizeText(allocator, report.totalBytes())});
}

fn managedStoreStateText(allocator: std.mem.Allocator, object: ManagedStoreObject) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    try parts.append(allocator, if (object.reachable) "reachable" else "unreachable");
    if (object.in_use) try parts.append(allocator, "in use");
    if (object.nested) try parts.append(allocator, "nested");
    return joinStrings(allocator, parts.items, ", ");
}

fn joinStrings(
    allocator: std.mem.Allocator,
    values: []const []const u8,
    separator: []const u8,
) ![]const u8 {
    return std.mem.join(allocator, separator, values);
}

// -- JSON rendering --------------------------------------------------------

pub fn writeJson(
    allocator: std.mem.Allocator,
    report: Report,
    writer: *std.Io.Writer,
) !void {
    const document = try jsonDocument(allocator, report);
    const bytes = try std.json.Stringify.valueAlloc(allocator, document, .{
        .whitespace = .indent_2,
    });
    try writer.writeAll(bytes);
    try writer.writeAll("\n");
}

fn jsonDocument(allocator: std.mem.Allocator, report: Report) !std.json.Value {
    var home: std.json.ObjectMap = .empty;
    try home.put(allocator, "path", .{ .string = report.home });
    try home.put(allocator, "source", .{ .string = report.home_source.label() });
    try home.put(allocator, "environmentVariable", if (report.home_source.environmentVariable()) |name|
        .{ .string = name }
    else
        .null);
    try home.put(allocator, "deprecated", .{ .bool = report.home_source.deprecated() });

    var pin_entries = std.json.Array.init(allocator);
    for (report.pins.entries.items) |entry| {
        var value: std.json.ObjectMap = .empty;
        try value.put(allocator, "product", .{ .string = entry.product });
        try value.put(allocator, "field", .{ .string = entry.field });
        try value.put(allocator, "selector", if (entry.selector) |selector|
            .{ .string = selector }
        else
            .null);
        try value.put(allocator, "resolved", if (entry.resolved) |resolved|
            .{ .string = resolved }
        else
            .null);
        try value.put(allocator, "channelVersion", if (entry.channel_version) |channel_version|
            .{ .string = channel_version }
        else
            .null);
        try value.put(allocator, "behind", .{ .bool = entry.behind });
        try pin_entries.append(.{ .object = value });
    }
    var pins: std.json.ObjectMap = .empty;
    try pins.put(allocator, "configPath", if (report.pins.config_path) |config_path|
        .{ .string = config_path }
    else
        .null);
    try pins.put(allocator, "channel", .{ .string = report.pins.channel });
    try pins.put(allocator, "parseError", if (report.pins.parse_error) |parse_error|
        .{ .string = parse_error }
    else
        .null);
    try pins.put(allocator, "entries", .{ .array = pin_entries });

    var releases = std.json.Array.init(allocator);
    for (report.releases.items) |product| {
        var installs = std.json.Array.init(allocator);
        for (product.installs.items) |install| {
            var selections = std.json.Array.init(allocator);
            for (install.selections.items) |selection| try selections.append(.{ .string = selection });
            var value: std.json.ObjectMap = .empty;
            try value.put(allocator, "version", .{ .string = install.version });
            try value.put(allocator, "revision", if (install.revision) |revision|
                .{ .string = revision }
            else
                .null);
            try value.put(allocator, "platform", .{ .string = install.platform });
            try value.put(allocator, "path", .{ .string = install.path });
            try value.put(allocator, "relativeRoot", .{ .string = install.relative_root });
            try value.put(allocator, "selections", .{ .array = selections });
            try putUsage(allocator, &value, install.usage);
            try installs.append(.{ .object = value });
        }
        var value: std.json.ObjectMap = .empty;
        try value.put(allocator, "name", .{ .string = product.name });
        try value.put(allocator, "bytes", .{ .integer = @intCast(product.bytes) });
        try value.put(allocator, "installs", .{ .array = installs });
        try releases.append(.{ .object = value });
    }

    var selections = std.json.Array.init(allocator);
    for (report.selections.items) |selection| {
        var value: std.json.ObjectMap = .empty;
        try value.put(allocator, "product", .{ .string = selection.product });
        try value.put(allocator, "name", .{ .string = selection.name });
        try value.put(allocator, "version", .{ .string = selection.version });
        try value.put(allocator, "revision", .{ .string = selection.revision });
        try value.put(allocator, "platform", .{ .string = selection.platform });
        try value.put(allocator, "installed", .{ .bool = selection.installed });
        try selections.append(.{ .object = value });
    }

    var toolchains = std.json.Array.init(allocator);
    for (report.toolchains.items) |toolchain| {
        var value: std.json.ObjectMap = .empty;
        try value.put(allocator, "language", .{ .string = toolchain.language });
        try value.put(allocator, "version", .{ .string = toolchain.version });
        try value.put(allocator, "platform", .{ .string = toolchain.platform });
        try value.put(allocator, "path", .{ .string = toolchain.path });
        try value.put(allocator, "relativeRoot", .{ .string = toolchain.relative_root });
        try putUsage(allocator, &value, toolchain.usage);
        try toolchains.append(.{ .object = value });
    }

    var objects = std.json.Array.init(allocator);
    for (report.managed_objects.items) |object| {
        var value: std.json.ObjectMap = .empty;
        try value.put(allocator, "type", .{ .string = objectTypeName(object.kind) });
        try value.put(allocator, "relativeRoot", .{ .string = object.relative_root });
        try value.put(allocator, "version", .{ .string = object.version });
        try value.put(allocator, "platform", .{ .string = object.platform });
        try value.put(allocator, "toolchain", if (object.toolchain_kind) |kind|
            .{ .string = kind }
        else
            .null);
        try value.put(allocator, "bytes", .{ .integer = @intCast(object.bytes) });
        try value.put(allocator, "reachable", .{ .bool = object.reachable });
        try value.put(allocator, "inUse", .{ .bool = object.in_use });
        try value.put(allocator, "nested", .{ .bool = object.nested });
        try value.put(allocator, "unreachableSinceUnixSeconds", if (object.unreachable_since_unix_seconds) |seconds|
            .{ .integer = seconds }
        else
            .null);
        try objects.append(.{ .object = value });
    }
    var managed_store_document: std.json.ObjectMap = .empty;
    try managed_store_document.put(
        allocator,
        "automaticRetentionSeconds",
        .{ .integer = managed_store.automatic_retention_seconds },
    );
    try managed_store_document.put(allocator, "objectCount", .{ .integer = @intCast(report.managed_objects.items.len) });
    try managed_store_document.put(allocator, "bytes", .{ .integer = @intCast(report.managed_bytes) });
    try managed_store_document.put(allocator, "objects", .{ .array = objects });

    var projects = std.json.Array.init(allocator);
    for (report.projects) |project| {
        var references = std.json.Array.init(allocator);
        for (project.objects) |object| {
            var value: std.json.ObjectMap = .empty;
            try value.put(allocator, "type", .{ .string = objectTypeName(object.kind) });
            try value.put(allocator, "relativeRoot", .{ .string = object.relative_root });
            try value.put(allocator, "version", .{ .string = object.version });
            try value.put(allocator, "platform", .{ .string = object.platform });
            try value.put(allocator, "toolchain", if (object.toolchain_kind) |kind|
                .{ .string = kind }
            else
                .null);
            try references.append(.{ .object = value });
        }
        var value: std.json.ObjectMap = .empty;
        try value.put(allocator, "path", .{ .string = project.canonical_root });
        try value.put(allocator, "exists", .{ .bool = project.project_exists });
        try value.put(allocator, "registrationPath", .{ .string = project.registration_path });
        try value.put(allocator, "lockVerified", .{ .bool = project.lock_verified });
        try value.put(allocator, "lastSeenUnixSeconds", .{ .integer = project.last_seen_unix_seconds });
        try value.put(allocator, "references", .{ .array = references });
        try projects.append(.{ .object = value });
    }

    var issues = std.json.Array.init(allocator);
    for (report.issues.items) |issue| try issues.append(.{ .string = issue });

    var totals: std.json.ObjectMap = .empty;
    try totals.put(allocator, "releasesBytes", .{ .integer = @intCast(report.releases_usage.bytes) });
    try totals.put(allocator, "toolchainsBytes", .{ .integer = @intCast(report.toolchains_usage.bytes) });
    try totals.put(allocator, "managedBytes", .{ .integer = @intCast(report.managed_bytes) });
    try totals.put(allocator, "bytes", .{ .integer = @intCast(report.totalBytes()) });

    var root: std.json.ObjectMap = .empty;
    try root.put(allocator, "schemaVersion", .{ .integer = json_schema_version });
    try root.put(allocator, "kind", .{ .string = "hutch-status" });
    try root.put(allocator, "home", .{ .object = home });
    try root.put(allocator, "pins", .{ .object = pins });
    try root.put(allocator, "releases", .{ .array = releases });
    try root.put(allocator, "selections", .{ .array = selections });
    try root.put(allocator, "toolchains", .{ .array = toolchains });
    try root.put(allocator, "managedStore", .{ .object = managed_store_document });
    try root.put(allocator, "projects", .{ .array = projects });
    try root.put(allocator, "issues", .{ .array = issues });
    try root.put(allocator, "totals", .{ .object = totals });
    return .{ .object = root };
}

fn putUsage(
    allocator: std.mem.Allocator,
    value: *std.json.ObjectMap,
    usage: Usage,
) !void {
    try value.put(allocator, "bytes", .{ .integer = @intCast(usage.bytes) });
    try value.put(allocator, "files", .{ .integer = @intCast(usage.files) });
    try value.put(allocator, "directories", .{ .integer = @intCast(usage.directories) });
    try value.put(allocator, "symlinks", .{ .integer = @intCast(usage.symlinks) });
    try value.put(allocator, "unreadable", .{ .integer = @intCast(usage.unreadable) });
}

// -- Tests -----------------------------------------------------------------

fn testReport(allocator: std.mem.Allocator) !Report {
    var report: Report = .{
        .home = "/legacy/dash",
        .home_source = .dash_home,
    };
    var product: ReleaseProduct = .{ .name = "hutch" };
    var install: ReleaseInstall = .{
        .version = "0.6.4",
        .revision = "e7be5b833cef1d3cc5bdc01770d3fb936daf9733",
        .platform = "macos-arm64",
        .path = "/legacy/dash/releases/hutch/0.6.4/e7be5b833cef1d3cc5bdc01770d3fb936daf9733/macos-arm64",
        .relative_root = "releases/hutch/0.6.4/e7be5b833cef1d3cc5bdc01770d3fb936daf9733/macos-arm64",
        .usage = .{ .bytes = 4 * 1024 * 1024, .files = 3, .directories = 2 },
    };
    try install.selections.append(allocator, "production");
    try product.installs.append(allocator, install);
    product.bytes = install.usage.bytes;
    try report.releases.append(allocator, product);
    report.releases_usage = install.usage;

    try report.selections.append(allocator, .{
        .product = "hutch",
        .name = "production",
        .version = install.version,
        .revision = install.revision.?,
        .platform = install.platform,
        .installed = true,
    });

    const toolchain_usage: Usage = .{ .bytes = 2048, .files = 1, .directories = 1 };
    try report.toolchains.append(allocator, .{
        .language = "zig",
        .version = "0.16.0",
        .platform = "macos-arm64",
        .path = "/legacy/dash/toolchains/zig/0.16.0/macos-arm64",
        .relative_root = "toolchains/zig/0.16.0/macos-arm64",
        .usage = toolchain_usage,
    });
    report.toolchains_usage = toolchain_usage;

    try report.managed_objects.append(allocator, .{
        .kind = .toolchain,
        .relative_root = "toolchains/zig/0.16.0/macos-arm64",
        .version = "0.16.0",
        .platform = "macos-arm64",
        .toolchain_kind = "zig",
        .unreachable_since_unix_seconds = 1_700_000_000,
        .reachable = false,
        .in_use = false,
        .nested = false,
        .bytes = toolchain_usage.bytes,
    });
    report.managed_bytes = toolchain_usage.bytes;

    report.projects = try allocator.dupe(managed_store.InventoryProject, &.{.{
        .canonical_root = "/workspace/app",
        .registration_path = "/legacy/dash/state/projects/abc.json",
        .project_exists = false,
        .lock_verified = false,
        .last_seen_unix_seconds = 1_700_000_001,
        .objects = &.{},
    }});
    return report;
}

test "human readable sizes stay in range and never round into the next unit" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0 B", formatBytes(&buffer, 0));
    try std.testing.expectEqualStrings("1023 B", formatBytes(&buffer, 1023));
    try std.testing.expectEqualStrings("1.0 KiB", formatBytes(&buffer, 1024));
    try std.testing.expectEqualStrings("1.5 KiB", formatBytes(&buffer, 1536));
    try std.testing.expectEqualStrings("1.0 MiB", formatBytes(&buffer, 1024 * 1024));
    try std.testing.expectEqualStrings("2.5 GiB", formatBytes(&buffer, 2560 * 1024 * 1024));
    try std.testing.expectEqualStrings("1.0 TiB", formatBytes(&buffer, 1024 * 1024 * 1024 * 1024));
    // 1024 KiB must promote to MiB instead of printing "1024.0 KiB".
    try std.testing.expectEqualStrings("1.0 MiB", formatBytes(&buffer, 1024 * 1024 - 1));
}

test "the resolved home and its source are reported in both formats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const report = try testReport(allocator);

    var text: std.Io.Writer.Allocating = .init(allocator);
    try writeText(allocator, report, &text.writer);
    const rendered = text.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "  path    /legacy/dash\n") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered,
        "  source  DASH_HOME (deprecated; prefer HUTCH_HOME)\n",
    ) != null);
    // Every section is present even when a store has no entries of that type.
    for ([_][]const u8{ "Releases", "Selections", "Toolchains", "Managed store", "Projects", "Total" }) |section| {
        try std.testing.expect(std.mem.indexOf(u8, rendered, section) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\nChannels\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\nCache\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[path missing]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "4.0 MiB") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "automatic retention 10 days") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "unreachable") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "last used") == null);

    var default_home = report;
    default_home.home_source = .default_home;
    var default_text: std.Io.Writer.Allocating = .init(allocator);
    try writeText(allocator, default_home, &default_text.writer);
    try std.testing.expect(std.mem.indexOf(
        u8,
        default_text.written(),
        "  source  default (~/.hutch)\n",
    ) != null);
}

test "the json document exposes every section with stable keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const report = try testReport(allocator);

    var json: std.Io.Writer.Allocating = .init(allocator);
    try writeJson(allocator, report, &json.writer);
    const parsed = try std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        json.written(),
        .{ .duplicate_field_behavior = .@"error" },
    );
    const root = parsed.object;
    try std.testing.expectEqual(@as(i64, json_schema_version), root.get("schemaVersion").?.integer);
    try std.testing.expectEqualStrings("hutch-status", root.get("kind").?.string);

    const home = root.get("home").?.object;
    try std.testing.expectEqualStrings("/legacy/dash", home.get("path").?.string);
    try std.testing.expectEqualStrings("DASH_HOME", home.get("source").?.string);
    try std.testing.expectEqualStrings("DASH_HOME", home.get("environmentVariable").?.string);
    try std.testing.expect(home.get("deprecated").?.bool);

    const releases = root.get("releases").?.array;
    try std.testing.expectEqual(@as(usize, 1), releases.items.len);
    const installs = releases.items[0].object.get("installs").?.array;
    try std.testing.expectEqualStrings("0.6.4", installs.items[0].object.get("version").?.string);
    try std.testing.expectEqualStrings(
        "production",
        installs.items[0].object.get("selections").?.array.items[0].string,
    );
    try std.testing.expectEqual(
        @as(i64, 4 * 1024 * 1024),
        installs.items[0].object.get("bytes").?.integer,
    );

    const selections = root.get("selections").?.array;
    try std.testing.expectEqualStrings("production", selections.items[0].object.get("name").?.string);
    try std.testing.expect(selections.items[0].object.get("installed").?.bool);
    try std.testing.expect(root.get("channels") == null);

    const pins = root.get("pins").?.object;
    try std.testing.expect(pins.get("configPath").? == .null);
    try std.testing.expectEqualStrings("production", pins.get("channel").?.string);
    try std.testing.expect(pins.get("parseError").? == .null);
    try std.testing.expectEqual(@as(usize, 0), pins.get("entries").?.array.items.len);

    const toolchains = root.get("toolchains").?.array;
    try std.testing.expectEqualStrings("zig", toolchains.items[0].object.get("language").?.string);

    const managed_store_document = root.get("managedStore").?.object;
    try std.testing.expectEqual(
        @as(i64, managed_store.automatic_retention_seconds),
        managed_store_document.get("automaticRetentionSeconds").?.integer,
    );
    try std.testing.expectEqual(@as(i64, 1), managed_store_document.get("objectCount").?.integer);
    const object = managed_store_document.get("objects").?.array.items[0].object;
    try std.testing.expectEqualStrings("toolchain", object.get("type").?.string);
    try std.testing.expect(!object.get("reachable").?.bool);
    try std.testing.expect(!object.get("inUse").?.bool);
    try std.testing.expectEqual(@as(i64, 1_700_000_000), object.get("unreachableSinceUnixSeconds").?.integer);
    try std.testing.expect(object.get("lastUsedUnixSeconds") == null);
    try std.testing.expect(root.get("managedState") == null);
    try std.testing.expect(root.get("cache") == null);

    const project = root.get("projects").?.array.items[0].object;
    try std.testing.expectEqualStrings("/workspace/app", project.get("path").?.string);
    try std.testing.expect(!project.get("exists").?.bool);
    try std.testing.expectEqual(@as(usize, 0), project.get("references").?.array.items.len);

    const totals = root.get("totals").?.object;
    try std.testing.expectEqual(@as(i64, 4 * 1024 * 1024), totals.get("releasesBytes").?.integer);
    try std.testing.expectEqual(@as(i64, 2048), totals.get("toolchainsBytes").?.integer);
    try std.testing.expectEqual(@as(i64, 2048), totals.get("managedBytes").?.integer);
    try std.testing.expectEqual(@as(i64, 4 * 1024 * 1024 + 2048), totals.get("bytes").?.integer);
}

test "the disk walk sums nested files without following symlinks out of the store" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const relative = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const fixture = try std.Io.Dir.cwd().realPathFileAlloc(io, relative, allocator);
    const store = try std.fs.path.join(allocator, &.{ fixture, "store" });
    const outside = try std.fs.path.join(allocator, &.{ fixture, "outside" });
    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(allocator, &.{ store, "bin" }));
    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(allocator, &.{ store, "lib", "deep" }));
    try std.Io.Dir.cwd().createDirPath(io, outside);

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ store, "marker" }),
        .data = "0123456789",
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ store, "lib", "deep", "payload" }),
        .data = "abcdefghijklmnop",
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ outside, "huge" }),
        .data = "x" ** 4096,
    });
    // A bin launcher symlink must be counted, never traversed.
    try std.Io.Dir.cwd().symLink(
        io,
        outside,
        try std.fs.path.join(allocator, &.{ store, "bin", "escape" }),
        .{ .is_directory = true },
    );
    try std.Io.Dir.cwd().symLink(
        io,
        try std.fs.path.join(allocator, &.{ outside, "huge" }),
        try std.fs.path.join(allocator, &.{ store, "bin", "hutch" }),
        .{},
    );

    var issues: Issues = .empty;
    const usage = try measure(io, allocator, store, &issues);
    try std.testing.expectEqual(@as(u64, 26), usage.bytes);
    try std.testing.expectEqual(@as(u64, 2), usage.files);
    try std.testing.expectEqual(@as(u64, 4), usage.directories);
    try std.testing.expectEqual(@as(u64, 2), usage.symlinks);
    try std.testing.expectEqual(@as(u64, 0), usage.unreadable);
    try std.testing.expectEqual(@as(usize, 0), issues.items.len);

    // A missing path is reported, not fatal.
    var missing_issues: Issues = .empty;
    const missing = try measure(
        io,
        allocator,
        try std.fs.path.join(allocator, &.{ fixture, "absent" }),
        &missing_issues,
    );
    try std.testing.expectEqual(@as(u64, 0), missing.bytes);
    try std.testing.expectEqual(@as(u64, 1), missing.unreadable);
    try std.testing.expectEqual(@as(usize, 1), missing_issues.items.len);
    try std.testing.expect(std.mem.endsWith(u8, missing_issues.items[0], ": FileNotFound"));
}

test "a fixture store discovers both release layouts and attaches exact selections" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const relative = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const fixture = try std.Io.Dir.cwd().realPathFileAlloc(io, relative, allocator);
    const home = try std.fs.path.join(allocator, &.{ fixture, "hutch-home" });

    const revision = "0123456789abcdef0123456789abcdef01234567";
    const hutch_root = try std.fs.path.join(allocator, &.{
        home, "releases", "hutch", "0.6.4", revision, "macos-arm64",
    });
    const electrobun_root = try std.fs.path.join(allocator, &.{
        home, "releases", "electrobun", "2.0.0", "macos-arm64",
    });
    const toolchain_root = try std.fs.path.join(allocator, &.{
        home, "toolchains", "zig", "0.16.0", "macos-arm64",
    });
    for ([_][]const u8{ hutch_root, electrobun_root, toolchain_root }) |root| {
        try std.Io.Dir.cwd().createDirPath(io, root);
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = try std.fs.path.join(allocator, &.{ root, "payload" }),
            .data = "0123456789",
        });
    }
    var report: Report = .{ .home = home, .home_source = .hutch_home };
    try collectReleases(io, allocator, home, &report);
    try collectToolchains(io, allocator, home, &report);
    try appendSelections(allocator, &report, .{
        .hutch_production = .{
            .version = "0.6.4",
            .revision = revision,
            .platform = "macos-arm64",
        },
        .hutch_canary = .{
            .version = "0.6.4",
            .revision = "1111111111111111111111111111111111111111",
            .platform = "macos-arm64",
        },
    });

    try std.testing.expectEqual(@as(usize, 2), report.releases.items.len);
    try std.testing.expectEqualStrings("electrobun", report.releases.items[0].name);
    const electrobun_install = report.releases.items[0].installs.items[0];
    try std.testing.expect(electrobun_install.revision == null);
    try std.testing.expectEqualStrings("macos-arm64", electrobun_install.platform);
    try std.testing.expectEqualStrings(
        "releases/electrobun/2.0.0/macos-arm64",
        electrobun_install.relative_root,
    );

    const hutch_install = report.releases.items[1].installs.items[0];
    try std.testing.expectEqualStrings(revision, hutch_install.revision.?);
    try std.testing.expectEqual(@as(usize, 1), hutch_install.selections.items.len);
    try std.testing.expectEqualStrings("production", hutch_install.selections.items[0]);
    try std.testing.expectEqual(@as(u64, 10), hutch_install.usage.bytes);

    try std.testing.expectEqual(@as(u64, 20), report.releases_usage.bytes);
    try std.testing.expectEqual(@as(usize, 1), report.toolchains.items.len);
    try std.testing.expectEqual(@as(u64, 10), report.toolchains_usage.bytes);
    try std.testing.expectEqual(@as(u64, 30), report.totalBytes());

    try std.testing.expectEqual(@as(usize, 2), report.selections.items.len);
    try std.testing.expectEqualStrings("production", report.selections.items[0].name);
    try std.testing.expect(report.selections.items[0].installed);
    try std.testing.expectEqualStrings("canary", report.selections.items[1].name);
    try std.testing.expect(!report.selections.items[1].installed);
}

test "status only accepts --json and help flags" {
    try std.testing.expect(isHelp("--help"));
    try std.testing.expect(isHelp("-h"));
    try std.testing.expect(!isHelp("--json"));
    try std.testing.expect(std.mem.indexOf(u8, help_text, "hutch status [--json]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "may run the lazy 10-day prune first") != null);
    try std.testing.expect(isRevision("0123456789abcdef0123456789abcdef01234567"));
    try std.testing.expect(isRevision("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"));
    try std.testing.expect(!isRevision("0.6.4"));
    try std.testing.expect(!isRevision("0123456789ABCDEF0123456789abcdef01234567"));
    try std.testing.expect(isPlatformKey("macos-arm64"));
    try std.testing.expect(!isPlatformKey("cef"));
}
