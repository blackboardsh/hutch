const std = @import("std");
const builtin = @import("builtin");
const bootstrap_pragma = @import("bootstrap_pragma.zig");
const store_locks = @import("store_locks.zig");
const release_store = @import("release_store.zig");
const version_selector = @import("version_selector.zig");
const toolchain_store = @import("toolchain_store.zig");

pub const Kind = enum { bun, cottontail };

pub const Selected = struct {
    kind: Kind,
    executable: []const u8,
    root: ?[]const u8,
    version: ?[]const u8 = null,
    revision: ?[]const u8 = null,
    local: bool,
    lease: ?store_locks.ObjectLease = null,

    pub fn close(self: Selected, io: std.Io) void {
        if (self.lease) |lease| lease.close(io);
    }
};

/// Config evaluation, build helpers, and scripts share one runtime selection.
/// A Cottontail version pin only chooses its version after explicit opt-in.
pub fn resolveSelected(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    command_args: []const [:0]const u8,
) !Selected {
    if (try useCottontailScripts(init.environ_map)) {
        const runtime = try resolveCottontail(init, allocator, command_args);
        return .{
            .kind = .cottontail,
            .executable = runtime.executable,
            .root = runtime.root,
            .version = runtime.version,
            .revision = runtime.revision,
            .local = runtime.local,
            .lease = runtime.lease,
        };
    }

    const runtime = try toolchain_store.resolveVersion(init, allocator, .bun, toolchain_store.default_bun_version);
    errdefer runtime.close(init.io);
    if (runtime.lease) |lease| try lease.makeInheritable(init.io);
    return .{
        .kind = .bun,
        .executable = if (runtime.resolution.system)
            try absoluteSystemBun(init.io, allocator, init.environ_map, runtime.resolution.version)
        else
            runtime.resolution.binary,
        .root = runtime.resolution.root,
        .version = runtime.resolution.version,
        .local = runtime.resolution.system,
        .lease = runtime.lease,
    };
}

fn absoluteSystemBun(
    io: std.Io,
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    version: []const u8,
) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    // Windows checks cwd before PATH, including the native PATHEXT rules.
    if (builtin.os.tag == .windows) {
        if (try systemBunInDirectory(io, allocator, cwd, "", version)) |binary| return binary;
    }
    const search_path = environment.get("PATH") orelse
        if (builtin.os.tag == .windows) "" else std.Io.Threaded.default_PATH;
    // Match Zig's process lookup, which skips empty PATH components.
    var directories = std.mem.tokenizeScalar(u8, search_path, if (builtin.os.tag == .windows) ';' else ':');
    while (directories.next()) |directory| {
        if (try systemBunInDirectory(io, allocator, cwd, directory, version)) |binary| return binary;
    }
    return error.FileNotFound;
}

fn systemBunInDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    cwd: []const u8,
    directory: []const u8,
    version: []const u8,
) !?[]const u8 {
    // Keep symlink spellings intact: shims can locate their runtime via argv[0].
    const expanded_directory: ?[]u8 = if (builtin.os.tag == .windows) expanded: {
        const kind = std.fs.path.parsePathWindows(u8, directory).kind;
        if (kind != .rooted and kind != .drive_relative) break :expanded null;
        // These Win32 forms depend on the original current drive (or its
        // per-drive cwd), even though rooted paths report isAbsolute == true.
        const wide = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, directory);
        defer allocator.free(wide);
        var full: [std.os.windows.PATH_MAX_WIDE]u16 = undefined;
        const bytes = std.os.windows.ntdll.RtlGetFullPathName_U(wide.ptr, @sizeOf(@TypeOf(full)), &full, null);
        if (bytes == 0) return error.BadPathName;
        if (bytes >= @sizeOf(@TypeOf(full))) return error.NameTooLong;
        break :expanded try std.unicode.wtf16LeToWtf8Alloc(allocator, full[0 .. bytes / 2]);
    } else null;
    defer if (expanded_directory) |expanded| allocator.free(expanded);
    const fixed_directory = expanded_directory orelse directory;
    const binary = if (std.fs.path.isAbsolute(fixed_directory))
        try std.fs.path.join(allocator, &.{ fixed_directory, "bun" })
    else
        try std.fs.path.join(allocator, &.{ cwd, fixed_directory, "bun" });
    var keep_binary = false;
    defer if (!keep_binary) allocator.free(binary);
    // The toolchain store already accepted the first runnable PATH Bun's
    // version. Repeat only that startup-free probe with absolute candidates:
    // native spawning handles execute permissions, missing script interpreters,
    // and Windows exact-name/PATHEXT ordering without evaluating user code.
    const result = std.process.run(allocator, io, .{
        .argv = &.{ binary, "--version" },
        .exe = .{ .path = .cwd() },
        .create_no_window = true,
    }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.IsDir, error.AccessDenied => return null,
        error.InvalidExe => if (builtin.os.tag == .windows) return null else return err,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    // Never search past a runnable but different Bun to find the desired pin.
    // That would change the system-versus-managed policy after resolution.
    if (result.term != .exited or result.term.exited != 0 or
        !std.mem.eql(u8, std.mem.trim(u8, result.stdout, " \t\r\n"), version))
        return error.SystemBunChanged;
    keep_binary = true;
    return binary;
}

pub const Resolution = struct {
    root: []const u8,
    executable: []const u8,
    version: ?[]const u8 = null,
    revision: ?[]const u8 = null,
    local: bool,
    lease: ?store_locks.ObjectLease = null,

    pub fn close(self: Resolution, io: std.Io) void {
        if (self.lease) |lease| lease.close(io);
    }
};

pub fn resolveCottontail(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    command_args: []const [:0]const u8,
) !Resolution {
    const resolution = if (init.environ_map.get("DASH_COTTONTAIL") orelse
        init.environ_map.get("COTTONTAIL_BINARY")) |configured|
        try localResolution(init.io, allocator, configured)
    else if (environmentFlagEnabled(init.environ_map, "DASH_USE_LOCAL_COTTONTAIL"))
        try resolveLocalCheckout(init, allocator)
    else managed: {
        const selector = if (init.environ_map.get("DASH_COTTONTAIL_SELECTOR")) |configured|
            try version_selector.parse(configured)
        else selector: {
            const pragma = try bootstrap_pragma.discover(init, allocator, command_args);
            if (pragma.cottontail) |selected| break :selector selected;
            // Unpinned projects run the Cottontail this Hutch release was
            // built and tested with; `hutch self update` advances both
            // together. This is the build-time runtime only — the Cottontail
            // bundled into an app is pinned by the Electrobun release's
            // devkit manifest instead.
            break :selector try version_selector.parse(
                @import("version.zig").paired_cottontail_version,
            );
        };

        const release = try release_store.resolveLeased(
            init,
            allocator,
            .cottontail,
            selector,
            .{
                .refresh = environmentFlagEnabled(init.environ_map, "DASH_RELEASE_REFRESH"),
                .offline = environmentFlagEnabled(init.environ_map, "DASH_RELEASE_OFFLINE"),
            },
        );
        break :managed Resolution{
            .root = release.resolution.root,
            .executable = release.resolution.executable,
            .version = release.resolution.version,
            .revision = release.resolution.revision,
            .local = false,
            .lease = release.lease,
        };
    };
    if (resolution.lease) |lease| try lease.makeInheritable(init.io);
    return resolution;
}

fn resolveLocalCheckout(
    init: std.process.Init,
    allocator: std.mem.Allocator,
) !Resolution {
    if (init.environ_map.get("DASH_LOCAL_COTTONTAIL_ROOT") orelse
        init.environ_map.get("COTTONTAIL_ROOT")) |root|
    {
        const executable = try std.fs.path.join(allocator, &.{
            root,
            "zig-out",
            "bin",
            cottontailBinaryName(),
        });
        if (!pathExists(init.io, executable)) return error.LocalCottontailNotFound;
        return .{
            .root = try allocator.dupe(u8, root),
            .executable = executable,
            .local = true,
        };
    }

    const executable_dir = try std.process.executableDirPathAlloc(init.io, allocator);
    const root = try std.fs.path.join(allocator, &.{
        executable_dir,
        "..",
        "..",
        "..",
        "..",
        "cottontail",
    });
    const executable = try std.fs.path.join(allocator, &.{
        root,
        "zig-out",
        "bin",
        cottontailBinaryName(),
    });
    if (!pathExists(init.io, executable)) return error.LocalCottontailNotFound;
    return .{
        .root = root,
        .executable = executable,
        .local = true,
    };
}

fn localResolution(
    io: std.Io,
    allocator: std.mem.Allocator,
    configured: []const u8,
) !Resolution {
    const executable = if (std.fs.path.isAbsolute(configured))
        try allocator.dupe(u8, configured)
    else
        try std.Io.Dir.cwd().realPathFileAlloc(io, configured, allocator);
    if (!pathExists(io, executable)) return error.ConfiguredCottontailNotFound;

    const bin_dir = std.fs.path.dirname(executable) orelse return error.InvalidCottontailPath;
    const root = std.fs.path.dirname(bin_dir) orelse bin_dir;
    return .{
        .root = try allocator.dupe(u8, root),
        .executable = executable,
        .local = true,
    };
}

fn cottontailBinaryName() []const u8 {
    return if (builtin.os.tag == .windows) "cottontail.exe" else "cottontail";
}

fn environmentFlagEnabled(environment: *const std.process.Environ.Map, name: []const u8) bool {
    const value = environment.get(name) orelse return false;
    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes");
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

test "runtime resolver binary names match the host" {
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("cottontail.exe", cottontailBinaryName());
    } else {
        try std.testing.expectEqualStrings("cottontail", cottontailBinaryName());
    }
}

// Runtime selection applies to configuration, build helpers, and scripts. A
// Cottontail version pragma alone never opts into the experimental runtime.
pub fn useCottontailScripts(environment: *const std.process.Environ.Map) !bool {
    if (environment.get("HUTCH_RUNTIME")) |runtime| {
        if (std.mem.eql(u8, runtime, "bun")) return false;
        if (std.mem.eql(u8, runtime, "cottontail")) return true;
        return error.InvalidHutchRuntime;
    }
    return environment.get("DASH_COTTONTAIL") != null or
        environment.get("COTTONTAIL_BINARY") != null or
        environmentFlagEnabled(environment, "DASH_USE_LOCAL_COTTONTAIL");
}

test "Bun is selected unless Cottontail is explicitly requested" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try std.testing.expect(!try useCottontailScripts(&environment));
    try environment.put("DASH_COTTONTAIL_SELECTOR", "0.7.3");
    try std.testing.expect(!try useCottontailScripts(&environment));
    try environment.put("HUTCH_RUNTIME", "cottontail");
    try std.testing.expect(try useCottontailScripts(&environment));
    try environment.put("COTTONTAIL_BINARY", "/explicit/cottontail");
    try environment.put("HUTCH_RUNTIME", "bun");
    try std.testing.expect(!try useCottontailScripts(&environment));
    _ = environment.swapRemove("HUTCH_RUNTIME");
    try std.testing.expect(try useCottontailScripts(&environment));
    try environment.put("HUTCH_RUNTIME", "invalid");
    try std.testing.expectError(error.InvalidHutchRuntime, useCottontailScripts(&environment));
}

test "system Bun keeps PATH order and executable checks when making relative entries absolute" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    for ([_][]const u8{ "denied", "broken", "relative tools", "later" }) |directory|
        try temporary.dir.createDir(io, directory, .default_dir);
    const matching = "#!/bin/sh\n[ \"$1\" = --version ] || exit 7\nprintf '1.4.4\\n'\n";
    try temporary.dir.writeFile(io, .{ .sub_path = "denied/bun", .data = matching });
    try temporary.dir.writeFile(io, .{ .sub_path = "broken/bun", .data = "#!/hutch-test-missing-interpreter\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "relative tools/bun", .data = matching });
    try temporary.dir.writeFile(io, .{ .sub_path = "later/bun", .data = "#!/bin/sh\nprintf '0.0.0\\n'\n" });
    for ([_][]const u8{ "broken/bun", "relative tools/bun", "later/bun" }) |path| {
        const file = try temporary.dir.openFile(io, path, .{});
        defer file.close(io);
        try file.setPermissions(io, .executable_file);
    }
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const relative = try std.fs.path.relativeAlloc(allocator, cwd, null, cwd, root);
    defer allocator.free(relative);
    const search_path = try std.fmt.allocPrint(allocator, "{s}/denied::{s}/broken:{s}/relative tools:{s}/later", .{ root, root, relative, root });
    defer allocator.free(search_path);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("PATH", search_path);
    const binary = try absoluteSystemBun(io, allocator, &environment, "1.4.4");
    defer allocator.free(binary);
    try std.testing.expect(std.fs.path.isAbsolute(binary));
    const resolved = try std.Io.Dir.cwd().realPathFileAlloc(io, binary, allocator);
    defer allocator.free(resolved);
    const expected = try std.fs.path.join(allocator, &.{ root, "relative tools", "bun" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, resolved);

    const changed_path = try std.fmt.allocPrint(allocator, "{s}/later:{s}/relative tools", .{ root, root });
    defer allocator.free(changed_path);
    try environment.put("PATH", changed_path);
    try std.testing.expectError(error.SystemBunChanged, absoluteSystemBun(io, allocator, &environment, "1.4.4"));
}
