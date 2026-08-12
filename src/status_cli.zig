const std = @import("std");
const builtin = @import("builtin");
const cache_store = @import("cache_store.zig");
const release_store = @import("release_store.zig");

const help_text =
    "Usage:\n" ++
    "  hutch status [--json]\n" ++
    "\n" ++
    "Reports the resolved Hutch home, installed product releases with their\n" ++
    "active channel pointers, installed toolchains, managed cache objects, and\n" ++
    "the projects registered against them.\n" ++
    "\n" ++
    "Sizes are recursive file totals. Symlinks are counted but never followed,\n" ++
    "so a bin launcher can never pull an out-of-store tree into a total.\n" ++
    "`status` only reads the store; it never creates, moves, or deletes state.\n";

/// The `--json` document version. Any incompatible field change bumps this.
pub const json_schema_version = 1;

const max_walk_depth = 64;
const max_pointer_bytes = std.fs.max_path_bytes + 2;

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

pub const ProductInstall = struct {
    version: []const u8,
    /// Absent for products stored without a revision level (Electrobun).
    revision: ?[]const u8 = null,
    platform: []const u8,
    path: []const u8,
    relative_root: []const u8,
    usage: Usage = .{},
    channels: std.ArrayList([]const u8) = .empty,
};

pub const Product = struct {
    name: []const u8,
    installs: std.ArrayList(ProductInstall) = .empty,
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

pub const ChannelPointer = struct {
    product: []const u8,
    channel: []const u8,
    pointer_path: []const u8,
    target: []const u8,
    /// The target matched a discovered install of the same product.
    resolved: bool,
};

pub const CacheObject = struct {
    kind: cache_store.ManagedObject.Kind,
    relative_root: []const u8,
    version: []const u8,
    platform: []const u8,
    toolchain_kind: ?[]const u8 = null,
    last_used_unix_seconds: ?i64 = null,
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
    products: std.ArrayList(Product) = .empty,
    channels: std.ArrayList(ChannelPointer) = .empty,
    toolchains: std.ArrayList(Toolchain) = .empty,
    cache_objects: std.ArrayList(CacheObject) = .empty,
    projects: []const cache_store.InventoryProject = &.{},
    issues: Issues = .empty,
    products_usage: Usage = .{},
    toolchains_usage: Usage = .{},
    cache_bytes: u64 = 0,

    pub fn totalBytes(self: Report) u64 {
        return self.products_usage.bytes + self.toolchains_usage.bytes;
    }
};

pub fn collect(init: std.process.Init, allocator: std.mem.Allocator) !Report {
    const home = try release_store.resolveHutchHome(init, allocator);
    var report: Report = .{ .home = home.path, .home_source = home.source };

    try collectProducts(init.io, allocator, home.path, &report);
    try collectToolchains(init.io, allocator, home.path, &report);
    try collectChannels(init.io, allocator, home.path, &report);
    try collectCache(init, allocator, &report);
    return report;
}

fn collectProducts(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    report: *Report,
) !void {
    const root = try std.fs.path.join(allocator, &.{ home, "products" });
    var names: std.ArrayList([]const u8) = .empty;
    try directoryNames(io, allocator, root, &names, &report.issues);
    std.mem.sort([]const u8, names.items, {}, stringLessThan);

    for (names.items) |name| {
        var product: Product = .{ .name = name };
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
                    try appendProductInstall(io, allocator, &product, .{
                        .version = version,
                        .revision = null,
                        .platform = child,
                        .path = try std.fs.path.join(allocator, &.{ version_root, child }),
                        .relative_root = try std.fmt.allocPrint(
                            allocator,
                            "products/{s}/{s}/{s}",
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
                    try appendProductInstall(io, allocator, &product, .{
                        .version = version,
                        .revision = child,
                        .platform = platform,
                        .path = try std.fs.path.join(allocator, &.{ revision_root, platform }),
                        .relative_root = try std.fmt.allocPrint(
                            allocator,
                            "products/{s}/{s}/{s}/{s}",
                            .{ name, version, child, platform },
                        ),
                    }, &report.issues);
                }
            }
        }

        if (product.installs.items.len == 0) continue;
        for (product.installs.items) |install| {
            product.bytes += install.usage.bytes;
            report.products_usage.add(install.usage);
        }
        try report.products.append(allocator, product);
    }
}

fn appendProductInstall(
    io: std.Io,
    allocator: std.mem.Allocator,
    product: *Product,
    install: ProductInstall,
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

fn collectChannels(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    report: *Report,
) !void {
    const root = try std.fs.path.join(allocator, &.{ home, "channels" });
    var products: std.ArrayList([]const u8) = .empty;
    try directoryNames(io, allocator, root, &products, &report.issues);
    std.mem.sort([]const u8, products.items, {}, stringLessThan);

    for (products.items) |product| {
        const product_root = try std.fs.path.join(allocator, &.{ root, product });
        var directory = std.Io.Dir.cwd().openDir(io, product_root, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| {
            try appendIssue(allocator, &report.issues, product_root, err);
            continue;
        };
        defer directory.close(io);

        var names: std.ArrayList([]const u8) = .empty;
        var iterator = directory.iterate();
        while (true) {
            const entry = (iterator.next(io) catch |err| {
                try appendIssue(allocator, &report.issues, product_root, err);
                break;
            }) orelse break;
            if (entry.kind == .directory) continue;
            if (std.mem.startsWith(u8, entry.name, ".")) continue;
            if (std.mem.endsWith(u8, entry.name, ".lock")) continue;
            try names.append(allocator, try allocator.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, stringLessThan);

        for (names.items) |channel| {
            const pointer_path = try std.fs.path.join(allocator, &.{ product_root, channel });
            const bytes = std.Io.Dir.cwd().readFileAlloc(
                io,
                pointer_path,
                allocator,
                .limited(max_pointer_bytes),
            ) catch |err| {
                try appendIssue(allocator, &report.issues, pointer_path, err);
                continue;
            };
            const target = std.mem.trim(u8, bytes, " \t\r\n");
            const resolved = try attachChannel(allocator, report, product, channel, target);
            try report.channels.append(allocator, .{
                .product = product,
                .channel = channel,
                .pointer_path = pointer_path,
                .target = target,
                .resolved = resolved,
            });
        }
    }
}

fn attachChannel(
    allocator: std.mem.Allocator,
    report: *Report,
    product_name: []const u8,
    channel: []const u8,
    target: []const u8,
) !bool {
    for (report.products.items) |*product| {
        if (!std.mem.eql(u8, product.name, product_name)) continue;
        for (product.installs.items) |*install| {
            if (!std.mem.eql(u8, install.path, target)) continue;
            try install.channels.append(allocator, channel);
            return true;
        }
    }
    return false;
}

fn collectCache(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    report: *Report,
) !void {
    const found = cache_store.inventory(init, allocator) catch |err| {
        try appendIssue(allocator, &report.issues, "cache", err);
        return;
    };
    for (found.issues) |issue| try report.issues.append(allocator, issue);
    report.projects = found.projects;

    for (found.objects) |object| {
        var entry: CacheObject = .{
            .kind = object.kind,
            .relative_root = object.relative_root,
            .version = object.version,
            .platform = object.platform,
            .toolchain_kind = object.toolchain_kind,
            .last_used_unix_seconds = object.last_used_unix_seconds,
            .reachable = object.reachable,
            .in_use = object.in_use,
            .nested = hasManagedAncestor(found.objects, object.relative_root),
        };
        entry.bytes = knownBytes(report.*, object.relative_root) orelse
            (try measure(init.io, allocator, object.absolute_root, &report.issues)).bytes;
        if (!entry.nested) report.cache_bytes += entry.bytes;
        try report.cache_objects.append(allocator, entry);
    }
}

fn hasManagedAncestor(
    objects: []const cache_store.InventoryObject,
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

/// Managed objects live under `products/` and `toolchains/`, so their sizes are
/// almost always already measured. Only a nested payload needs its own walk.
fn knownBytes(report: Report, relative_root: []const u8) ?u64 {
    for (report.products.items) |product| {
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
    if (name.len != 40) return false;
    for (name) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn objectTypeName(kind: cache_store.ManagedObject.Kind) []const u8 {
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

    try writer.writeAll("\nProducts\n");
    if (report.products.items.len == 0) {
        try writer.writeAll("  (none)\n");
    } else {
        for (report.products.items) |product| {
            try writer.print("  {s}\n", .{product.name});
            var table: Table = .{
                .headers = &.{ "version", "revision", "platform", "size", "files", "channels" },
                .aligns = &.{ .left, .left, .left, .right, .right, .left },
            };
            for (product.installs.items) |install| {
                try table.addRow(allocator, &.{
                    install.version,
                    install.revision orelse "-",
                    install.platform,
                    try sizeText(allocator, install.usage.bytes),
                    try std.fmt.allocPrint(allocator, "{d}", .{install.usage.files}),
                    if (install.channels.items.len == 0)
                        "-"
                    else
                        try joinStrings(allocator, install.channels.items, ", "),
                });
            }
            try table.write(allocator, writer, 4);
            try writer.print("    subtotal {s}\n", .{try sizeText(allocator, product.bytes)});
        }
    }
    try writer.print("  products total {s}\n", .{try sizeText(allocator, report.products_usage.bytes)});

    try writer.writeAll("\nChannels\n");
    if (report.channels.items.len == 0) {
        try writer.writeAll("  (none)\n");
    } else {
        var table: Table = .{
            .headers = &.{ "product", "channel", "state", "target" },
            .aligns = &.{ .left, .left, .left, .left },
        };
        for (report.channels.items) |pointer| {
            try table.addRow(allocator, &.{
                pointer.product,
                pointer.channel,
                if (pointer.resolved) "active" else "dangling",
                pointer.target,
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

    try writer.writeAll("\nCache\n");
    if (report.cache_objects.items.len == 0) {
        try writer.writeAll("  (no managed objects)\n");
    } else {
        var table: Table = .{
            .headers = &.{ "object", "type", "size", "state", "last used" },
            .aligns = &.{ .left, .left, .right, .left, .left },
        };
        for (report.cache_objects.items) |object| {
            try table.addRow(allocator, &.{
                object.relative_root,
                objectTypeName(object.kind),
                try sizeText(allocator, object.bytes),
                try cacheStateText(allocator, object),
                if (object.last_used_unix_seconds) |seconds|
                    try std.fmt.allocPrint(allocator, "{d}", .{seconds})
                else
                    "never",
            });
        }
        try table.write(allocator, writer, 2);
    }
    try writer.print(
        "  cache objects {d}, total {s} (already counted in products and toolchains)\n",
        .{ report.cache_objects.items.len, try sizeText(allocator, report.cache_bytes) },
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
    try writer.print("  products    {s}\n", .{try sizeText(allocator, report.products_usage.bytes)});
    try writer.print("  toolchains  {s}\n", .{try sizeText(allocator, report.toolchains_usage.bytes)});
    try writer.print("  on disk     {s}\n", .{try sizeText(allocator, report.totalBytes())});
}

fn cacheStateText(allocator: std.mem.Allocator, object: CacheObject) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    try parts.append(allocator, if (object.reachable) "reachable" else "unreferenced");
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

    var products = std.json.Array.init(allocator);
    for (report.products.items) |product| {
        var installs = std.json.Array.init(allocator);
        for (product.installs.items) |install| {
            var channels = std.json.Array.init(allocator);
            for (install.channels.items) |channel| try channels.append(.{ .string = channel });
            var value: std.json.ObjectMap = .empty;
            try value.put(allocator, "version", .{ .string = install.version });
            try value.put(allocator, "revision", if (install.revision) |revision|
                .{ .string = revision }
            else
                .null);
            try value.put(allocator, "platform", .{ .string = install.platform });
            try value.put(allocator, "path", .{ .string = install.path });
            try value.put(allocator, "relativeRoot", .{ .string = install.relative_root });
            try value.put(allocator, "channels", .{ .array = channels });
            try putUsage(allocator, &value, install.usage);
            try installs.append(.{ .object = value });
        }
        var value: std.json.ObjectMap = .empty;
        try value.put(allocator, "name", .{ .string = product.name });
        try value.put(allocator, "bytes", .{ .integer = @intCast(product.bytes) });
        try value.put(allocator, "installs", .{ .array = installs });
        try products.append(.{ .object = value });
    }

    var channels = std.json.Array.init(allocator);
    for (report.channels.items) |pointer| {
        var value: std.json.ObjectMap = .empty;
        try value.put(allocator, "product", .{ .string = pointer.product });
        try value.put(allocator, "channel", .{ .string = pointer.channel });
        try value.put(allocator, "pointerPath", .{ .string = pointer.pointer_path });
        try value.put(allocator, "target", .{ .string = pointer.target });
        try value.put(allocator, "resolved", .{ .bool = pointer.resolved });
        try channels.append(.{ .object = value });
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
    for (report.cache_objects.items) |object| {
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
        try value.put(allocator, "lastUsedUnixSeconds", if (object.last_used_unix_seconds) |seconds|
            .{ .integer = seconds }
        else
            .null);
        try objects.append(.{ .object = value });
    }
    var cache: std.json.ObjectMap = .empty;
    try cache.put(allocator, "objectCount", .{ .integer = @intCast(report.cache_objects.items.len) });
    try cache.put(allocator, "bytes", .{ .integer = @intCast(report.cache_bytes) });
    try cache.put(allocator, "objects", .{ .array = objects });

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
    try totals.put(allocator, "productsBytes", .{ .integer = @intCast(report.products_usage.bytes) });
    try totals.put(allocator, "toolchainsBytes", .{ .integer = @intCast(report.toolchains_usage.bytes) });
    try totals.put(allocator, "cacheBytes", .{ .integer = @intCast(report.cache_bytes) });
    try totals.put(allocator, "bytes", .{ .integer = @intCast(report.totalBytes()) });

    var root: std.json.ObjectMap = .empty;
    try root.put(allocator, "schemaVersion", .{ .integer = json_schema_version });
    try root.put(allocator, "kind", .{ .string = "hutch-status" });
    try root.put(allocator, "home", .{ .object = home });
    try root.put(allocator, "products", .{ .array = products });
    try root.put(allocator, "channels", .{ .array = channels });
    try root.put(allocator, "toolchains", .{ .array = toolchains });
    try root.put(allocator, "cache", .{ .object = cache });
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
    var product: Product = .{ .name = "hutch" };
    var install: ProductInstall = .{
        .version = "0.6.4",
        .revision = "e7be5b833cef1d3cc5bdc01770d3fb936daf9733",
        .platform = "macos-arm64",
        .path = "/legacy/dash/products/hutch/0.6.4/e7be5b833cef1d3cc5bdc01770d3fb936daf9733/macos-arm64",
        .relative_root = "products/hutch/0.6.4/e7be5b833cef1d3cc5bdc01770d3fb936daf9733/macos-arm64",
        .usage = .{ .bytes = 4 * 1024 * 1024, .files = 3, .directories = 2 },
    };
    try install.channels.append(allocator, "production");
    try product.installs.append(allocator, install);
    product.bytes = install.usage.bytes;
    try report.products.append(allocator, product);
    report.products_usage = install.usage;

    try report.channels.append(allocator, .{
        .product = "hutch",
        .channel = "production",
        .pointer_path = "/legacy/dash/channels/hutch/production",
        .target = install.path,
        .resolved = true,
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

    try report.cache_objects.append(allocator, .{
        .kind = .toolchain,
        .relative_root = "toolchains/zig/0.16.0/macos-arm64",
        .version = "0.16.0",
        .platform = "macos-arm64",
        .toolchain_kind = "zig",
        .last_used_unix_seconds = 1_700_000_000,
        .reachable = true,
        .in_use = false,
        .nested = false,
        .bytes = toolchain_usage.bytes,
    });
    report.cache_bytes = toolchain_usage.bytes;

    const references = try allocator.dupe(cache_store.ManagedObject, &.{.{
        .kind = .toolchain,
        .relative_root = "toolchains/zig/0.16.0/macos-arm64",
        .version = "0.16.0",
        .platform = "macos-arm64",
        .toolchain_kind = "zig",
    }});
    report.projects = try allocator.dupe(cache_store.InventoryProject, &.{.{
        .canonical_root = "/workspace/app",
        .registration_path = "/legacy/dash/state/cache-v2/projects/abc.json",
        .project_exists = false,
        .lock_verified = false,
        .last_seen_unix_seconds = 1_700_000_001,
        .objects = references,
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
    for ([_][]const u8{ "Products", "Channels", "Toolchains", "Cache", "Projects", "Total" }) |section| {
        try std.testing.expect(std.mem.indexOf(u8, rendered, section) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[path missing]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "4.0 MiB") != null);

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

    const products = root.get("products").?.array;
    try std.testing.expectEqual(@as(usize, 1), products.items.len);
    const installs = products.items[0].object.get("installs").?.array;
    try std.testing.expectEqualStrings("0.6.4", installs.items[0].object.get("version").?.string);
    try std.testing.expectEqualStrings(
        "production",
        installs.items[0].object.get("channels").?.array.items[0].string,
    );
    try std.testing.expectEqual(
        @as(i64, 4 * 1024 * 1024),
        installs.items[0].object.get("bytes").?.integer,
    );

    try std.testing.expect(root.get("channels").?.array.items[0].object.get("resolved").?.bool);

    const toolchains = root.get("toolchains").?.array;
    try std.testing.expectEqualStrings("zig", toolchains.items[0].object.get("language").?.string);

    const cache = root.get("cache").?.object;
    try std.testing.expectEqual(@as(i64, 1), cache.get("objectCount").?.integer);
    const object = cache.get("objects").?.array.items[0].object;
    try std.testing.expectEqualStrings("toolchain", object.get("type").?.string);
    try std.testing.expect(object.get("reachable").?.bool);
    try std.testing.expect(!object.get("inUse").?.bool);
    try std.testing.expectEqual(@as(i64, 1_700_000_000), object.get("lastUsedUnixSeconds").?.integer);

    const project = root.get("projects").?.array.items[0].object;
    try std.testing.expectEqualStrings("/workspace/app", project.get("path").?.string);
    try std.testing.expect(!project.get("exists").?.bool);
    try std.testing.expectEqualStrings(
        "toolchains/zig/0.16.0/macos-arm64",
        project.get("references").?.array.items[0].object.get("relativeRoot").?.string,
    );

    const totals = root.get("totals").?.object;
    try std.testing.expectEqual(@as(i64, 4 * 1024 * 1024), totals.get("productsBytes").?.integer);
    try std.testing.expectEqual(@as(i64, 2048), totals.get("toolchainsBytes").?.integer);
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

test "a fixture store is discovered across both product layouts" {
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
        home, "products", "hutch", "0.6.4", revision, "macos-arm64",
    });
    const electrobun_root = try std.fs.path.join(allocator, &.{
        home, "products", "electrobun", "2.0.0", "macos-arm64",
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
    const channel_path = try std.fs.path.join(allocator, &.{ home, "channels", "hutch", "production" });
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(channel_path).?);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = channel_path,
        .data = try std.mem.concat(allocator, u8, &.{ hutch_root, "\n" }),
    });
    const dangling_path = try std.fs.path.join(allocator, &.{ home, "channels", "hutch", "canary" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dangling_path, .data = "/nowhere\n" });

    var report: Report = .{ .home = home, .home_source = .hutch_home };
    try collectProducts(io, allocator, home, &report);
    try collectToolchains(io, allocator, home, &report);
    try collectChannels(io, allocator, home, &report);

    try std.testing.expectEqual(@as(usize, 2), report.products.items.len);
    try std.testing.expectEqualStrings("electrobun", report.products.items[0].name);
    const electrobun_install = report.products.items[0].installs.items[0];
    try std.testing.expect(electrobun_install.revision == null);
    try std.testing.expectEqualStrings("macos-arm64", electrobun_install.platform);
    try std.testing.expectEqualStrings(
        "products/electrobun/2.0.0/macos-arm64",
        electrobun_install.relative_root,
    );

    const hutch_install = report.products.items[1].installs.items[0];
    try std.testing.expectEqualStrings(revision, hutch_install.revision.?);
    try std.testing.expectEqual(@as(usize, 1), hutch_install.channels.items.len);
    try std.testing.expectEqualStrings("production", hutch_install.channels.items[0]);
    try std.testing.expectEqual(@as(u64, 10), hutch_install.usage.bytes);

    try std.testing.expectEqual(@as(u64, 20), report.products_usage.bytes);
    try std.testing.expectEqual(@as(usize, 1), report.toolchains.items.len);
    try std.testing.expectEqual(@as(u64, 10), report.toolchains_usage.bytes);
    try std.testing.expectEqual(@as(u64, 30), report.totalBytes());

    try std.testing.expectEqual(@as(usize, 2), report.channels.items.len);
    try std.testing.expectEqualStrings("canary", report.channels.items[0].channel);
    try std.testing.expect(!report.channels.items[0].resolved);
    try std.testing.expect(report.channels.items[1].resolved);
}

test "status only accepts --json and help flags" {
    try std.testing.expect(isHelp("--help"));
    try std.testing.expect(isHelp("-h"));
    try std.testing.expect(!isHelp("--json"));
    try std.testing.expect(std.mem.indexOf(u8, help_text, "hutch status [--json]") != null);
    try std.testing.expect(isRevision("0123456789abcdef0123456789abcdef01234567"));
    try std.testing.expect(!isRevision("0.6.4"));
    try std.testing.expect(!isRevision("0123456789ABCDEF0123456789abcdef01234567"));
    try std.testing.expect(isPlatformKey("macos-arm64"));
    try std.testing.expect(!isPlatformKey("cef"));
}
