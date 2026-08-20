const std = @import("std");
const builtin = @import("builtin");
const bootstrap_pragma = @import("bootstrap_pragma.zig");
const pragma_pin = @import("pragma_pin.zig");
const managed_store = @import("managed_store.zig");
const package_manager = @import("package_manager/root.zig");
const prune_cli = @import("prune_cli.zig");
const electrobun = @import("electrobun.zig");
const electrobun_artifacts = @import("electrobun_artifacts.zig");
const electrobun_devkit = @import("electrobun_devkit.zig");
const electrobun_templates = @import("electrobun_templates.zig");
const package_manager_adapter = @import("package_manager_adapter.zig");
const process_replace = @import("process_replace.zig");
const release_store = @import("release_store.zig");
const reset_cli = @import("reset_cli.zig");
const runtime_autoinstall = @import("runtime_autoinstall.zig");
const runtime_resolver = @import("runtime_resolver.zig");
const status_cli = @import("status_cli.zig");
const store_locks = @import("store_locks.zig");
const toolchain_store = @import("toolchain_store.zig");
const version_selector = @import("version_selector.zig");

const version = @import("version.zig").version;
const hutch_version = @import("version.zig");

const help_text_template =
    \\hutch {s}
    \\Hutch workspace orchestrator.
    \\
    \\Usage:
    \\  hutch <entrypoint.js|entrypoint.ts> [args...]
    \\  hutch <script-name> [args...]
    \\  hutch electrobun <init|config|sync|prepare|build|run|dev> [args...]
    \\  hutch install [package-manager-options...]
    \\  hutch pm [package-manager-arguments...]
    \\  hutch run [--if-configured] [script-name] [args...]
    \\  hutch test [files/options...]
    \\  hutch build [args...]
    \\  hutch prune [--dry-run]
    \\  hutch reset
    \\  hutch status [--json]
    \\  hutch upgrade [selector]
    \\  hutch self <path|version|update|pin> [selector] [--recursive]
    \\  hutch cottontail <path|version|pin> [selector] [--recursive]
    \\  hutch --help
    \\  hutch --version
    \\
    \\Config:
    \\  Scripts are resolved only from hutch.config.ts.
    \\  String scripts run through the selected Cottontail Bun.$ shell.
    \\  Array scripts run as exact non-empty argv string arrays.
    \\  packageManager selects npm, bun, pnpm, yarn, or an explicit executable;
    \\  without a selection, Hutch's built-in npm-compatible resolver installs
    \\  package.json registry, file, and git dependencies into hutch.lock,
    \\  ignoring any foreign lockfile, and never runs lifecycle scripts.
    \\  Its `pm exec` runs only project-local node_modules/.bin commands.
    \\  Scripts invoke dependency managers and other external tools explicitly.
    \\  Test files and options are forwarded to the selected Cottontail runtime.
    \\
;

const package_manager_help_text =
    \\Hutch built-in package manager.
    \\
    \\Usage:
    \\  hutch install [package-manager-options...]
    \\  hutch pm exec [--] <command> [args...]
    \\  hutch pm --version
    \\  hutch pm --help
    \\
    \\`pm exec` runs an executable from the nearest package project's
    \\node_modules/.bin. It never downloads a package or falls back to PATH.
    \\
;

const upgrade_help_text =
    \\Upgrade Hutch and its paired Cottontail release.
    \\
    \\Usage:
    \\  hutch upgrade [production|stable|canary|latest|<semver>|build:<revision>]
    \\  hutch self update [production|stable|canary|latest|<semver>|build:<revision>]
    \\
;

const BuiltinPackageManagerCommand = union(enum) {
    help,
    version,
    exec: []const [:0]const u8,
};

const Config = struct {
    root: std.json.Value,
};

fn printHelp(writer: anytype) !void {
    try writer.print(help_text_template, .{version});
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

fn isVersionFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v");
}

fn parseBuiltinPackageManagerCommand(
    args: []const [:0]const u8,
) !BuiltinPackageManagerCommand {
    if (args.len == 0) return .help;
    if (isHelpFlag(args[0]) or std.mem.eql(u8, args[0], "help")) {
        if (args.len != 1) return error.UnexpectedBuiltinPackageManagerArguments;
        return .help;
    }
    if (isVersionFlag(args[0])) {
        if (args.len != 1) return error.UnexpectedBuiltinPackageManagerArguments;
        return .version;
    }
    if (!std.mem.eql(u8, args[0], "exec")) {
        return error.UnsupportedBuiltinPackageManagerCommand;
    }

    var command_index: usize = 1;
    if (command_index < args.len and std.mem.eql(u8, args[command_index], "--")) {
        command_index += 1;
    }
    if (command_index >= args.len) return error.MissingBuiltinExecCommand;
    return .{ .exec = args[command_index..] };
}

fn isSafeLocalBinName(name: []const u8) bool {
    return name.len > 0 and
        !std.mem.eql(u8, name, ".") and
        !std.mem.eql(u8, name, "..") and
        std.mem.indexOfScalar(u8, name, 0) == null and
        std.mem.indexOfAny(u8, name, "/\\") == null and
        !std.fs.path.isAbsolute(name);
}

fn appendUpgradeReleaseArguments(
    allocator: std.mem.Allocator,
    destination: *std.ArrayList([:0]const u8),
    args: []const [:0]const u8,
) !void {
    try destination.append(allocator, "update");
    try destination.appendSlice(allocator, args);
}

fn isHutchUpdateHelpRequest(args: []const [:0]const u8) bool {
    return args.len == 2 and
        std.mem.eql(u8, args[0], "update") and
        isHelpFlag(args[1]);
}

fn isInstallerBootstrapInvocation(args: []const [:0]const u8) bool {
    return args.len >= 3 and
        std.mem.eql(u8, args[1], "self") and
        std.mem.eql(u8, args[2], "bootstrap-install");
}

// When an explicit Cottontail resolution is configured, Hutch acts as the
// Bun-CLI facade for that runtime (test harnesses, pinned-toolchain setups):
// invocations must behave like the runtime's own CLI instead of Hutch's
// workspace orchestrator.
fn isBunCliFacade(environment: *const std.process.Environ.Map) bool {
    return environment.get("DASH_COTTONTAIL") != null or
        environment.get("COTTONTAIL_BINARY") != null;
}

fn isCottontailTestCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "test");
}

// These are runtime builtins, never package scripts; forward them like
// "test". In particular, `repl` and `completions` must reach Cottontail when
// Hutch is used as the Bun-compatible facade.
fn isReservedRuntimeCommand(command: []const u8) bool {
    return isCottontailTestCommand(command) or
        std.mem.eql(u8, command, "exec") or
        std.mem.eql(u8, command, "repl") or
        std.mem.eql(u8, command, "completions");
}

fn isFakeNodeInvocation(args: []const [:0]const u8) bool {
    var index: usize = 1;
    while (index < args.len and
        (std.mem.eql(u8, args[index], "--bun") or std.mem.eql(u8, args[index], "-b")))
    {
        index += 1;
    }
    return index < args.len and std.mem.eql(u8, args[index], "node");
}

fn runtimeCommandArguments(args: []const [:0]const u8) []const [:0]const u8 {
    return if (args.len > 1) args[1..] else args[0..0];
}

fn termExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| @intCast(@min(code, 255)),
        .signal => |signal| signal: {
            if (builtin.os.tag != .windows) std.posix.raise(signal) catch {};
            break :signal @intCast(@min(128 + @intFromEnum(signal), 255));
        },
        .stopped => 1,
        .unknown => 1,
    };
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn pathJoin(allocator: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    return std.fs.path.join(allocator, parts);
}

fn resolveCottontail(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    command_args: []const [:0]const u8,
) !runtime_resolver.Resolution {
    const resolution = try runtime_resolver.resolveCottontail(init, allocator, command_args);
    // Registration is advisory reachability state. Read-only projects still
    // run under live object leases; an unwritable `.hutch` must not break the
    // user's command.
    registerRuntimeProjectReleases(init, allocator, resolution) catch {};
    // Electrobun registers its complete H+C+devkit+toolchain graph after all
    // of those dependencies have resolved. Running automatic GC here would
    // be too early on the first invocation of a project.
    if (command_args.len == 0 or !std.mem.eql(u8, command_args[0], "electrobun")) {
        managed_store.pruneAutomatic(init, allocator);
    }
    return resolution;
}

fn registerRuntimeProjectReleases(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    cottontail: runtime_resolver.Resolution,
) !void {
    const config_path = (try bootstrap_pragma.findNearestConfig(init.io, allocator)) orelse return;
    const project_root = std.fs.path.dirname(config_path) orelse return error.InvalidProjectRoot;

    var releases: std.ArrayList(managed_store.ManagedObject) = .empty;
    const current_engine = try std.process.executablePathAlloc(init.io, allocator);
    if (try managed_store.managedReleaseObject(
        init,
        allocator,
        .hutch,
        current_engine,
    )) |managed| try releases.append(allocator, managed);
    if (try managed_store.managedReleaseObject(
        init,
        allocator,
        .cottontail,
        cottontail.root,
    )) |managed| try releases.append(allocator, managed);

    try managed_store.registerProjectReleases(
        init,
        allocator,
        project_root,
        releases.items,
    );
}

fn runProcess(
    init: std.process.Init,
    argv: []const []const u8,
) !u8 {
    var child = try std.process.spawn(init.io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    defer child.kill(init.io);

    return termExitCode(try child.wait(init.io));
}

fn runCottontailCommand(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    cottontail_path: []const u8,
    command_args: []const []const u8,
) !u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, cottontail_path);
    for (command_args) |arg| {
        try argv.append(allocator, arg);
    }

    var env = try init.environ_map.clone(allocator);
    defer env.deinit();
    const hutch_path = if (init.environ_map.get("HUTCH_LAUNCHER_PATH")) |configured|
        try allocator.dupe(u8, configured)
    else
        try std.process.executablePathAlloc(init.io, allocator);
    try env.put("COTTONTAIL_SPAWN_EXEC_PATH", hutch_path);
    // A custom argv[0] from the invoker (e.g. Bun.spawn's argv0 option)
    // belongs to the runtime child, not to Hutch.
    try env.put("COTTONTAIL_SPAWN_ARGV0", customInvocationArgv0(init, allocator) orelse hutch_path);

    if (comptime builtin.os.tag != .windows) {
        try process_replace.replace(allocator, cottontail_path, argv.items, &env);
        unreachable;
    }

    var child = try std.process.spawn(init.io, .{
        .argv = argv.items,
        .environ_map = &env,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    defer child.kill(init.io);

    return termExitCode(try child.wait(init.io));
}

fn customInvocationArgv0(
    init: std.process.Init,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    const argv = init.minimal.args.toSlice(allocator) catch return null;
    if (argv.len == 0) return null;
    const argv0: []const u8 = argv[0];
    if (std.process.executablePathAlloc(init.io, allocator)) |self_exe| {
        if (std.mem.eql(u8, argv0, self_exe)) return null;
    } else |_| {}
    // Normal invocations use the binary's own name or path; anything else is
    // a deliberate argv[0] override from the caller.
    if (std.mem.startsWith(u8, std.fs.path.basename(argv0), "hutch")) return null;
    return argv0;
}

fn appendJsStringLiteral(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    try out.append(allocator, '"');
    for (value) |char| {
        switch (char) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, char),
        }
    }
    try out.append(allocator, '"');
}

fn makeConfigLoaderSource(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    result_path: []const u8,
) ![]const u8 {
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(allocator);

    try source.appendSlice(
        allocator,
        "import { chmodSync as __hutchChmodConfig, writeFileSync as __hutchWriteConfig } from \"node:fs\";\n" ++
            "const __hutchClearPrivateArgv = () => {\n" ++
            "  process.argv.splice(1);\n" ++
            "  if (Array.isArray(Bun.argv) && Bun.argv !== process.argv) Bun.argv.splice(1);\n" ++
            "  if (Array.isArray(cottontail.argv)) cottontail.argv.splice(1);\n" ++
            "  if (Array.isArray(cottontail.args)) cottontail.args.splice(0);\n" ++
            "  if (Array.isArray(process.execArgv)) process.execArgv.splice(0);\n" ++
            "  if (Array.isArray(cottontail.execArgv)) cottontail.execArgv.splice(0);\n" ++
            "};\n" ++
            "__hutchClearPrivateArgv();\n" ++
            "const configModule = await import(",
    );
    try appendJsStringLiteral(allocator, &source, config_path);
    try source.appendSlice(allocator,
        \\);
        \\const loadedConfig = configModule.default ?? {};
        \\__hutchWriteConfig(
    );
    try appendJsStringLiteral(allocator, &source, result_path);
    try source.appendSlice(allocator, ", JSON.stringify(loadedConfig), { mode: 0o600 });\n");
    try source.appendSlice(allocator, "__hutchChmodConfig(");
    try appendJsStringLiteral(allocator, &source, result_path);
    try source.appendSlice(allocator, ", 0o600);\n");

    return try source.toOwnedSlice(allocator);
}

fn findHutchConfig(init: std.process.Init, allocator: std.mem.Allocator) ![]const u8 {
    return (try bootstrap_pragma.findNearestConfig(init.io, allocator)) orelse
        error.HutchConfigNotFound;
}

const TrustedTempParent = struct {
    dir: std.Io.Dir,
    path: []const u8,

    fn close(self: *TrustedTempParent, io: std.Io) void {
        self.dir.close(io);
    }
};

const PrivateTempLeaf = struct {
    dir: std.Io.Dir,
    inode: std.Io.File.INode,
};

const PrivateTempDirectory = struct {
    parent: std.Io.Dir,
    dir: std.Io.Dir,
    name: []const u8,
    path: []const u8,
    inode: std.Io.File.INode,

    fn deinit(self: *PrivateTempDirectory, io: std.Io) void {
        // Empty the directory through the retained handle. After it is closed,
        // remove only the original leaf entry, non-recursively: if another
        // same-user process replaced that entry, cleanup must never follow the
        // replacement into an unrelated tree.
        cleanupPrivateTempLeaf(io, self.parent, self.dir, self.name, self.inode);
        self.parent.close(io);
    }
};

fn deletePrivateDirectoryContents(io: std.Io, dir: std.Io.Dir) void {
    var cleanup_pass: usize = 0;
    while (cleanup_pass < 4) : (cleanup_pass += 1) {
        var iterator = dir.iterate();
        var found_entry = false;
        while (iterator.next(io) catch null) |entry| {
            found_entry = true;
            dir.deleteTree(io, entry.name) catch {};
        }
        if (!found_entry) break;
    }
}

fn cleanupPrivateTempLeaf(
    io: std.Io,
    parent: std.Io.Dir,
    child: std.Io.Dir,
    name: []const u8,
    inode: std.Io.File.INode,
) void {
    deletePrivateDirectoryContents(io, child);
    child.close(io);
    deletePrivateTempLeafIfIdentity(io, parent, name, inode);
}

fn cleanupPrivateTempBeforeSignal(
    io: std.Io,
    term: std.process.Child.Term,
    private: *PrivateTempDirectory,
    private_live: *bool,
) void {
    switch (term) {
        .signal => {
            if (private_live.*) {
                private.deinit(io);
                private_live.* = false;
            }
        },
        else => {},
    }
}

fn deletePrivateTempLeafIfIdentity(
    io: std.Io,
    parent: std.Io.Dir,
    name: []const u8,
    inode: std.Io.File.INode,
) void {
    const current = parent.statFile(io, name, .{
        .follow_symlinks = false,
    }) catch null;
    if (current) |stat| {
        if (stat.kind == .directory and stat.inode == inode) {
            parent.deleteDir(io, name) catch {};
        }
    }
}

const PosixDirectoryIdentity = struct {
    owner: u64,
    mode: u32,
};

fn posixDirectoryIdentity(dir: std.Io.Dir) !PosixDirectoryIdentity {
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var statx = std.mem.zeroes(linux.Statx);
        const result = linux.statx(
            dir.handle,
            "",
            linux.AT.EMPTY_PATH,
            .{ .TYPE = true, .MODE = true, .UID = true },
            &statx,
        );
        if (linux.errno(result) != .SUCCESS or
            !statx.mask.TYPE or !statx.mask.MODE or !statx.mask.UID)
        {
            return error.TemporaryDirectoryMetadataUnavailable;
        }
        return .{ .owner = statx.uid, .mode = statx.mode };
    } else if (comptime builtin.os.tag != .windows) {
        var stat = std.mem.zeroes(std.c.Stat);
        if (std.posix.errno(std.c.fstat(dir.handle, &stat)) != .SUCCESS) {
            return error.TemporaryDirectoryMetadataUnavailable;
        }
        return .{ .owner = stat.uid, .mode = stat.mode };
    } else {
        unreachable;
    }
}

fn posixDirectoryIsTrusted(dir: std.Io.Dir) !bool {
    const identity = try posixDirectoryIdentity(dir);
    const effective_user: u64 = std.c.geteuid();
    const owned_by_process = identity.owner == effective_user;
    const owned_by_root = identity.owner == 0;
    const writable_by_others = identity.mode & 0o022 != 0;
    const sticky = identity.mode & 0o1000 != 0;

    return ((owned_by_process or owned_by_root) and !writable_by_others) or
        ((owned_by_process or owned_by_root) and sticky);
}

fn pathIsProjectDescendant(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    candidate: []const u8,
) !bool {
    const relative = try std.fs.path.relative(
        allocator,
        project_root,
        null,
        project_root,
        candidate,
    );
    defer allocator.free(relative);
    if (relative.len == 0) return true;
    if (std.fs.path.isAbsolute(relative)) return false;
    var components = std.fs.path.componentIterator(relative);
    const first = components.next() orelse return true;
    return !std.mem.eql(u8, first.name, "..");
}

fn canonicalDirPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
) ![]const u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try dir.realPath(io, &buffer);
    return try allocator.dupe(u8, buffer[0..length]);
}

fn validateCanonicalTempAncestors(
    io: std.Io,
    canonical_path: []const u8,
) !bool {
    if (comptime builtin.os.tag == .windows) return true;

    var current = canonical_path;
    while (true) {
        var ancestor = std.Io.Dir.openDirAbsolute(io, current, .{
            .follow_symlinks = false,
            .iterate = true,
        }) catch return false;
        const trusted = posixDirectoryIsTrusted(ancestor) catch false;
        ancestor.close(io);
        if (!trusted) return false;

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        current = parent;
    }
    return true;
}

fn tryOpenTrustedTempParent(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    project_root: []const u8,
    candidate: []const u8,
) !?TrustedTempParent {
    if (candidate.len == 0) return null;
    var dir = std.Io.Dir.cwd().openDir(init.io, candidate, .{
        .follow_symlinks = false,
        .iterate = true,
    }) catch return null;
    errdefer dir.close(init.io);

    const stat = dir.stat(init.io) catch {
        dir.close(init.io);
        return null;
    };
    if (stat.kind != .directory) {
        dir.close(init.io);
        return null;
    }
    const canonical_path = canonicalDirPath(init.io, allocator, dir) catch {
        dir.close(init.io);
        return null;
    };
    if (try pathIsProjectDescendant(allocator, project_root, canonical_path)) {
        dir.close(init.io);
        return null;
    }
    if (!try validateCanonicalTempAncestors(init.io, canonical_path)) {
        dir.close(init.io);
        return null;
    }

    return .{ .dir = dir, .path = canonical_path };
}

const windows_temp_api = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;
    const csidl_local_app_data = 0x001c;
    const shgfp_type_current = 0;

    extern "shell32" fn SHGetFolderPathW(
        owner: ?*anyopaque,
        folder: c_int,
        token: ?*anyopaque,
        flags: windows.DWORD,
        path: [*]u16,
    ) callconv(.winapi) i32;
} else struct {};

fn windowsTrustedTempPath(allocator: std.mem.Allocator) ![]const u8 {
    if (comptime builtin.os.tag != .windows) unreachable;

    var local_app_data_w: [std.os.windows.PATH_MAX_WIDE]u16 = undefined;
    const result = windows_temp_api.SHGetFolderPathW(
        null,
        windows_temp_api.csidl_local_app_data,
        null,
        windows_temp_api.shgfp_type_current,
        &local_app_data_w,
    );
    if (result < 0) return error.TrustedTemporaryDirectoryUnavailable;
    const wide_length = std.mem.indexOfScalar(u16, &local_app_data_w, 0) orelse
        return error.TrustedTemporaryDirectoryUnavailable;
    var local_app_data: [std.os.windows.PATH_MAX_WIDE * 3]u8 = undefined;
    const local_length = std.unicode.wtf16LeToWtf8(
        &local_app_data,
        local_app_data_w[0..wide_length],
    );
    return try std.fs.path.join(allocator, &.{ local_app_data[0..local_length], "Temp" });
}

fn createPrivateTempLeaf(
    io: std.Io,
    parent: std.Io.Dir,
    name: []const u8,
) !PrivateTempLeaf {
    const permissions: std.Io.Dir.Permissions = if (builtin.os.tag == .windows)
        .default_dir
    else
        @enumFromInt(0o700);
    try parent.createDir(io, name, permissions);

    const created_stat = parent.statFile(io, name, .{
        .follow_symlinks = false,
    }) catch return error.TemporaryDirectoryMetadataUnavailable;
    if (created_stat.kind != .directory) return error.UnsafeTemporaryDirectory;
    if (comptime builtin.os.tag != .windows) {
        // mkdir honors the caller's umask. Force the protocol's exact private
        // mode before opening the directory, then verify that the name still
        // identifies the directory we created.
        parent.setFilePermissions(io, name, @enumFromInt(0o700), .{
            .follow_symlinks = false,
        }) catch |err| {
            deletePrivateTempLeafIfIdentity(io, parent, name, created_stat.inode);
            return err;
        };
        const permission_stat = parent.statFile(io, name, .{
            .follow_symlinks = false,
        }) catch |err| {
            deletePrivateTempLeafIfIdentity(io, parent, name, created_stat.inode);
            return err;
        };
        if (permission_stat.kind != .directory or permission_stat.inode != created_stat.inode) {
            return error.UnsafeTemporaryDirectory;
        }
    }

    var child = parent.openDir(io, name, .{
        .follow_symlinks = false,
        .iterate = true,
    }) catch |err| {
        // The newly created name may have been replaced before it could be
        // opened. Only remove the exact empty directory identity we created.
        deletePrivateTempLeafIfIdentity(io, parent, name, created_stat.inode);
        return err;
    };
    const stat = child.stat(io) catch |err| {
        child.close(io);
        deletePrivateTempLeafIfIdentity(io, parent, name, created_stat.inode);
        return err;
    };
    if (stat.inode != created_stat.inode) {
        child.close(io);
        return error.UnsafeTemporaryDirectory;
    }
    errdefer cleanupPrivateTempLeaf(io, parent, child, name, stat.inode);
    if (stat.kind != .directory) return error.UnsafeTemporaryDirectory;
    if (comptime builtin.os.tag != .windows) {
        try child.setPermissions(io, @enumFromInt(0o700));
        const identity = try posixDirectoryIdentity(child);
        if (identity.owner != @as(u64, std.c.geteuid()) or identity.mode & 0o777 != 0o700) {
            return error.UnsafeTemporaryDirectory;
        }
    }
    return .{ .dir = child, .inode = stat.inode };
}

fn createPrivateTempDirectoryInParent(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    parent: TrustedTempParent,
    prefix: []const u8,
) !PrivateTempDirectory {
    var attempt: usize = 0;
    while (attempt < 16) : (attempt += 1) {
        var random_bytes: [16]u8 = undefined;
        init.io.random(&random_bytes);
        var random_name: [std.base64.url_safe.Encoder.calcSize(random_bytes.len)]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&random_name, &random_bytes);
        const name = try std.mem.concat(allocator, u8, &.{ prefix, &random_name });
        const path = try std.fs.path.join(allocator, &.{ parent.path, name });

        const child = createPrivateTempLeaf(init.io, parent.dir, name) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        errdefer cleanupPrivateTempLeaf(init.io, parent.dir, child.dir, name, child.inode);
        return .{
            .parent = parent.dir,
            .dir = child.dir,
            .name = name,
            .path = path,
            .inode = child.inode,
        };
    }
    return error.TemporaryDirectoryCollision;
}

fn createPrivateTempDirectory(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    prefix: []const u8,
) !PrivateTempDirectory {
    const project_root = try std.Io.Dir.cwd().realPathFileAlloc(init.io, ".", allocator);

    if (comptime builtin.os.tag == .windows) {
        const candidate = try windowsTrustedTempPath(allocator);
        var parent = (try tryOpenTrustedTempParent(
            init,
            allocator,
            project_root,
            candidate,
        )) orelse return error.TrustedTemporaryDirectoryUnavailable;
        errdefer parent.close(init.io);
        return try createPrivateTempDirectoryInParent(init, allocator, parent, prefix);
    } else {
        const candidates = [_]?[]const u8{
            init.environ_map.get("TMPDIR"),
            init.environ_map.get("TEMP"),
            if (builtin.os.tag.isDarwin()) "/private/tmp" else "/tmp",
        };
        for (candidates) |optional_candidate| {
            const candidate = optional_candidate orelse continue;
            var parent = (try tryOpenTrustedTempParent(
                init,
                allocator,
                project_root,
                candidate,
            )) orelse continue;
            const private = createPrivateTempDirectoryInParent(
                init,
                allocator,
                parent,
                prefix,
            ) catch |err| {
                parent.close(init.io);
                switch (err) {
                    error.AccessDenied,
                    error.PermissionDenied,
                    error.ReadOnlyFileSystem,
                    => continue,
                    else => return err,
                }
            };
            return private;
        }
        return error.TrustedTemporaryDirectoryUnavailable;
    }
}

const ElectrobunVersionSource = enum {
    explicit_config,
    npm_default,
    projection,
    channel,
};

const ElectrobunVersionSelection = struct {
    version: []const u8,
    source: ElectrobunVersionSource,
};

fn preferredElectrobunVersion(
    explicit_config: ?[]const u8,
    npm_default: ?[]const u8,
    projection: ?[]const u8,
    channel: ?[]const u8,
) ?ElectrobunVersionSelection {
    if (explicit_config) |selected| return .{ .version = selected, .source = .explicit_config };
    if (npm_default) |selected| return .{ .version = selected, .source = .npm_default };
    if (projection) |selected| return .{ .version = selected, .source = .projection };
    if (channel) |selected| return .{ .version = selected, .source = .channel };
    return null;
}

fn configuredElectrobunVersion(root: std.json.Value) !?[]const u8 {
    return electrobun_devkit.configuredVersion(root) catch |err| switch (err) {
        error.ElectrobunVersionMissing => null,
        else => return err,
    };
}

fn configuredOrNpmDefaultElectrobunVersion(
    config_root: std.json.Value,
    npm_default: ?[]const u8,
) !?ElectrobunVersionSelection {
    if (try configuredElectrobunVersion(config_root)) |explicit| {
        return .{ .version = explicit, .source = .explicit_config };
    }
    const configured = npm_default orelse return null;
    electrobun_devkit.validateExactVersion(configured) catch
        return error.InvalidDefaultElectrobunVersion;
    return .{ .version = configured, .source = .npm_default };
}

// One selector feeds both Electrobun app commands and packageManager: "bun".
// `sync` is the only caller that declines an existing projection, because it
// intentionally advances a floating project to the current channel head.
fn selectElectrobunProjectVersion(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    config_root: std.json.Value,
    project_root: []const u8,
    preserve_projection: bool,
) !ElectrobunVersionSelection {
    if (try configuredOrNpmDefaultElectrobunVersion(
        config_root,
        init.environ_map.get("HUTCH_DEFAULT_ELECTROBUN"),
    )) |selected| {
        return selected;
    }
    if (preserve_projection) {
        if (projectedElectrobunVersionAtRoot(init, allocator, project_root)) |projection| {
            return .{ .version = projection, .source = .projection };
        }
    }

    const channel = try electrobun_templates.activeChannel(init.environ_map);
    const catalog = try electrobun_templates.load(init, allocator, channel);
    electrobun_devkit.validateExactVersion(catalog.version) catch
        return error.InvalidElectrobunChannelVersion;
    return preferredElectrobunVersion(null, null, null, catalog.version).?;
}

// The Electrobun release an app command targets, resolved as: explicit config
// pin > shim-supplied npm default > existing projection > channel head.
fn resolveElectrobunProjectVersion(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    cottontail_path: []const u8,
    subcommand: []const u8,
    stderr: anytype,
) ![]const u8 {
    const config_root = if (loadHutchConfig(init, allocator, cottontail_path)) |hutch_config|
        hutch_config.root
    else |err| switch (err) {
        error.HutchConfigNotFound => std.json.Value{ .object = .empty },
        else => {
            try stderr.print(
                "hutch electrobun: failed to load hutch.config.ts: {s}\n",
                .{@errorName(err)},
            );
            try stderr.flush();
            std.process.exit(1);
        },
    };

    const selected = selectElectrobunProjectVersion(
        init,
        allocator,
        config_root,
        ".",
        !std.mem.eql(u8, subcommand, "sync"),
    ) catch |err| switch (err) {
        error.InvalidElectrobunVersion => {
            try stderr.writeAll(
                "hutch electrobun: electrobun.version in hutch.config.ts must be an exact semantic version; channels, ranges, and latest are not allowed\n",
            );
            try stderr.flush();
            std.process.exit(1);
        },
        error.InvalidHutchConfig,
        error.InvalidElectrobunVersionType,
        => {
            try stderr.writeAll(
                "hutch electrobun: electrobun in hutch.config.ts must be an object containing an exact string version\n",
            );
            try stderr.flush();
            std.process.exit(1);
        },
        error.InvalidDefaultElectrobunVersion => {
            try stderr.print(
                "hutch electrobun: HUTCH_DEFAULT_ELECTROBUN must be an exact semantic version, got \"{s}\"\n",
                .{init.environ_map.get("HUTCH_DEFAULT_ELECTROBUN").?},
            );
            try stderr.flush();
            std.process.exit(1);
        },
        error.InvalidTemplateChannel => {
            try stderr.writeAll("hutch electrobun: invalid HUTCH_ACTIVE_CHANNEL\n");
            try stderr.flush();
            std.process.exit(1);
        },
        else => {
            const channel = electrobun_templates.activeChannel(init.environ_map) catch unreachable;
            try stderr.print(
                "hutch electrobun: no electrobun.version is pinned and the {s} release channel " ++
                    "could not be resolved ({s}). Pin electrobun: {{ version: \"<exact-semver>\" }} " ++
                    "in hutch.config.ts, or retry with network access.\n",
                .{ channel.name(), @errorName(err) },
            );
            try stderr.flush();
            std.process.exit(1);
        },
    };

    if (selected.source == .channel) {
        const channel = electrobun_templates.activeChannel(init.environ_map) catch unreachable;
        try stderr.print(
            "hutch electrobun: floating on the {s} channel: Electrobun {s} " ++
                "(pin electrobun.version in hutch.config.ts to stop)\n",
            .{ channel.name(), selected.version },
        );
        try stderr.flush();
    }
    return selected.version;
}

// A floating project's devkit projection records the release it was last
// synced to; reusing it keeps builds stable between explicit syncs.
fn projectedElectrobunVersionAtRoot(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    project_root: []const u8,
) ?[]const u8 {
    const path = std.fs.path.join(
        allocator,
        &.{ project_root, ".hutch", "devkit", "projection.json" },
    ) catch return null;
    const source = std.Io.Dir.cwd().readFileAlloc(
        init.io,
        path,
        allocator,
        .limited(1024 * 1024),
    ) catch return null;
    return projectedElectrobunVersionFromMetadata(allocator, source);
}

fn projectedElectrobunVersionFromMetadata(
    allocator: std.mem.Allocator,
    source: []const u8,
) ?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        source,
        .{ .duplicate_field_behavior = .@"error" },
    ) catch return null;
    if (parsed != .object) return null;
    const schema_version = parsed.object.get("schemaVersion") orelse return null;
    if (schema_version != .integer or schema_version.integer != 1) return null;
    const kind = parsed.object.get("kind") orelse return null;
    if (kind != .string or
        !std.mem.eql(u8, kind.string, "electrobun-devkit-projection")) return null;
    const product = parsed.object.get("product") orelse return null;
    if (product != .object) return null;
    const product_name = product.object.get("name") orelse return null;
    if (product_name != .string or
        !std.mem.eql(u8, product_name.string, "electrobun")) return null;
    const project_version = product.object.get("version") orelse return null;
    if (project_version != .string or project_version.string.len == 0) return null;
    electrobun_devkit.validateExactVersion(project_version.string) catch return null;
    return project_version.string;
}

fn loadHutchConfig(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    cottontail_path: []const u8,
) !Config {
    const config_path = try findHutchConfig(init, allocator);
    var tmp_dir = try createPrivateTempDirectory(init, allocator, "hutch-config-loader-");
    var tmp_dir_live = true;
    defer if (tmp_dir_live) tmp_dir.deinit(init.io);
    const loader_path = try pathJoin(allocator, &.{ tmp_dir.path, "load.mjs" });
    const result_path = try pathJoin(allocator, &.{ tmp_dir.path, "config.json" });
    const loader_source = try makeConfigLoaderSource(allocator, config_path, result_path);
    try writePrivateFileAtomic(init.io, tmp_dir.dir, "load.mjs", loader_source);
    try writePrivateFileAtomic(init.io, tmp_dir.dir, hutch_private_bunfig_name, "");

    const execution = try std.process.run(allocator, init.io, .{
        .argv = &[_][]const u8{
            cottontail_path,
            "--hutch-config-file",
            loader_path,
            "--hutch-private-root",
            tmp_dir.path,
        },
        .create_no_window = true,
    });
    defer allocator.free(execution.stdout);
    defer allocator.free(execution.stderr);

    cleanupPrivateTempBeforeSignal(init.io, execution.term, &tmp_dir, &tmp_dir_live);
    if (execution.stdout.len > 0) {
        var stdout_buffer: [2048]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
        try stdout_writer.interface.writeAll(execution.stdout);
        try stdout_writer.interface.flush();
    }
    if (termExitCode(execution.term) != 0) {
        if (execution.stderr.len > 0) {
            var stderr_buffer: [2048]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
            try stderr_writer.interface.writeAll(execution.stderr);
            try stderr_writer.interface.flush();
        }
        return error.HutchConfigLoadFailed;
    }

    const result = try tmp_dir.dir.readFileAlloc(
        init.io,
        "config.json",
        allocator,
        .limited(1024 * 1024),
    );
    const trimmed = std.mem.trim(u8, result, " \r\n\t");
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, trimmed, .{});
    if (parsed != .object) return error.InvalidHutchConfig;

    return .{
        .root = parsed,
    };
}

fn getObjectField(value: std.json.Value, name: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |object| object.get(name),
        else => null,
    };
}

fn configuredScriptEnvironment(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    launcher_path_directory: ?[]const u8,
) !std.process.Environ.Map {
    var env = try init.environ_map.clone(allocator);
    errdefer env.deinit();

    // Keep the version-matched Hutch launcher available to recursive config
    // tasks. Release installs place it next to the engine; split/custom layouts
    // communicate its authoritative location explicitly.
    const executable_dir = launcher_path_directory orelse if (init.environ_map.get("HUTCH_LAUNCHER_PATH")) |launcher|
        std.fs.path.dirname(launcher) orelse return error.InvalidConfiguredLauncherPath
    else
        try std.process.executableDirPathAlloc(init.io, allocator);
    const path_key = if (builtin.os.tag == .windows) "Path" else "PATH";
    const existing_path = env.get(path_key) orelse env.get("PATH") orelse "";
    const run_path = if (existing_path.len > 0)
        try std.fmt.allocPrint(
            allocator,
            "{s}{c}{s}",
            .{ executable_dir, std.fs.path.delimiter, existing_path },
        )
    else
        executable_dir;
    try env.put(path_key, run_path);
    return env;
}

const hutch_shell_wrapper_name = "hutch-shell-wrapper.mjs";
const hutch_private_bunfig_name = "bunfig.toml";

const hutch_shell_wrapper_source =
    \\const [command, ...args] = process.argv.slice(2);
    \\const clearPrivateArgv = () => {
    \\  process.argv.splice(1);
    \\  if (Array.isArray(Bun.argv) && Bun.argv !== process.argv) Bun.argv.splice(1);
    \\  if (Array.isArray(cottontail.argv)) cottontail.argv.splice(1);
    \\  if (Array.isArray(cottontail.args)) cottontail.args.splice(0);
    \\  if (Array.isArray(process.execArgv)) process.execArgv.splice(0);
    \\  if (Array.isArray(cottontail.execArgv)) cottontail.execArgv.splice(0);
    \\};
    \\clearPrivateArgv();
    \\globalThis.__cottontailLoadDotenv?.();
    \\const hadStandaloneFlags = Object.prototype.hasOwnProperty.call(globalThis, "__cottontailStandaloneFlags");
    \\const previousStandaloneFlags = globalThis.__cottontailStandaloneFlags;
    \\if (previousStandaloneFlags == null) globalThis.__cottontailStandaloneFlags = {};
    \\try {
    \\  await globalThis.__cottontailLoadStandaloneBunfig?.();
    \\} finally {
    \\  if (hadStandaloneFlags) globalThis.__cottontailStandaloneFlags = previousStandaloneFlags;
    \\  else delete globalThis.__cottontailStandaloneFlags;
    \\}
    \\clearPrivateArgv();
    \\const strings = [command];
    \\for (let index = 0; index < args.length; index++) {
    \\  strings[strings.length - 1] += " ";
    \\  strings.push("");
    \\}
    \\strings.raw = strings;
    \\const task = Bun.$(strings, ...args).nothrow();
    \\task.options[Symbol.for("cottontail.internal.hutchShellTask")] = {
    \\  input: () => Bun.stdin.stream(),
    \\  passthrough: true,
    \\};
    \\const result = await task;
    \\process.exitCode = result.exitCode;
;

fn writePrivateFileAtomic(
    io: std.Io,
    dir: std.Io.Dir,
    name: []const u8,
    contents: []const u8,
) !void {
    const permissions: std.Io.Dir.Permissions = if (builtin.os.tag == .windows)
        .default_file
    else
        @enumFromInt(0o600);
    var atomic_file = try dir.createFileAtomic(io, name, .{
        .permissions = permissions,
        .replace = false,
    });
    defer atomic_file.deinit(io);
    if (comptime builtin.os.tag != .windows) {
        // File creation also honors umask; bind the exact mode to the already
        // open descriptor before atomically publishing its name.
        try atomic_file.file.setPermissions(io, @enumFromInt(0o600));
    }

    var write_buffer: [4096]u8 = undefined;
    var writer = atomic_file.file.writer(io, &write_buffer);
    try writer.interface.writeAll(contents);
    try writer.interface.flush();
    try atomic_file.file.sync(io);
    try atomic_file.link(io);
}

fn createShellTaskDirectory(
    init: std.process.Init,
    allocator: std.mem.Allocator,
) !PrivateTempDirectory {
    var task_dir = try createPrivateTempDirectory(init, allocator, "hutch-shell-launcher-");
    errdefer task_dir.deinit(init.io);

    try writePrivateFileAtomic(
        init.io,
        task_dir.dir,
        hutch_shell_wrapper_name,
        hutch_shell_wrapper_source,
    );
    try writePrivateFileAtomic(init.io, task_dir.dir, hutch_private_bunfig_name, "");

    const launcher = init.environ_map.get("HUTCH_LAUNCHER_PATH") orelse return task_dir;
    const stat = std.Io.Dir.cwd().statFile(init.io, launcher, .{}) catch
        return error.ConfiguredLauncherNotFound;
    if (stat.kind != .file) return error.ConfiguredLauncherIsNotAFile;

    // String tasks resolve the literal command name `hutch`. A private PATH
    // entry containing the exact selected launcher preserves canary/custom
    // identity without rewriting shell text or relying on Windows batch shims.
    try std.Io.Dir.copyFile(
        std.Io.Dir.cwd(),
        launcher,
        task_dir.dir,
        if (builtin.os.tag == .windows) "hutch.exe" else "hutch",
        init.io,
        .{ .permissions = .executable_file },
    );
    if (comptime builtin.os.tag != .windows) {
        try task_dir.dir.setFilePermissions(init.io, "hutch", @enumFromInt(0o700), .{
            .follow_symlinks = false,
        });
    }
    return task_dir;
}

fn runCottontailShellScript(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    cottontail_path: []const u8,
    script: []const u8,
    script_args: []const [:0]const u8,
) !u8 {
    var task_dir = try createShellTaskDirectory(init, allocator);
    var task_dir_live = true;
    defer if (task_dir_live) task_dir.deinit(init.io);
    const wrapper_path = try pathJoin(allocator, &.{ task_dir.path, hutch_shell_wrapper_name });

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        cottontail_path,
        "--hutch-shell-file",
        wrapper_path,
        "--hutch-private-root",
        task_dir.path,
        script,
    });
    for (script_args) |arg| try argv.append(allocator, arg);

    var env = try configuredScriptEnvironment(
        init,
        allocator,
        if (init.environ_map.get("HUTCH_LAUNCHER_PATH") != null) task_dir.path else null,
    );
    defer env.deinit();

    var child = try std.process.spawn(init.io, .{
        .argv = argv.items,
        .environ_map = &env,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    defer child.kill(init.io);

    const term = try child.wait(init.io);
    task_dir.deinit(init.io);
    task_dir_live = false;
    return termExitCode(term);
}

fn runArgvScript(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    script_argv: std.json.Array,
    script_args: []const [:0]const u8,
    stderr: anytype,
) !u8 {
    if (script_argv.items.len == 0) {
        try stderr.writeAll("hutch: script argv must not be empty\n");
        return 1;
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    for (script_argv.items, 0..) |arg, index| {
        if (arg != .string) {
            try stderr.writeAll("hutch: script argv entries must be strings\n");
            return 1;
        }
        if (index == 0 and std.mem.eql(u8, arg.string, "hutch")) {
            if (init.environ_map.get("HUTCH_LAUNCHER_PATH")) |configured| {
                const stat = std.Io.Dir.cwd().statFile(init.io, configured, .{}) catch {
                    try stderr.print("hutch: configured launcher not found: {s}\n", .{configured});
                    return 1;
                };
                if (stat.kind != .file) {
                    try stderr.print("hutch: configured launcher is not a file: {s}\n", .{configured});
                    return 1;
                }
                try argv.append(allocator, configured);
            } else {
                // Development builds may execute the engine directly. In that
                // case only, fall back to a sibling launcher before PATH.
                const exe_dir = try std.process.executableDirPathAlloc(init.io, allocator);
                const launcher_name = if (builtin.os.tag == .windows) "hutch.exe" else "hutch";
                const launcher = try pathJoin(allocator, &.{ exe_dir, launcher_name });
                try argv.append(allocator, if (pathExists(init.io, launcher)) launcher else arg.string);
            }
        } else {
            try argv.append(allocator, arg.string);
        }
    }
    for (script_args) |arg| try argv.append(allocator, arg);

    var env = try configuredScriptEnvironment(init, allocator, null);
    defer env.deinit();
    var child = std.process.spawn(init.io, .{
        .argv = argv.items,
        .environ_map = &env,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        try stderr.print("hutch: could not run configured command {s}: {s}\n", .{
            argv.items[0],
            @errorName(err),
        });
        return 1;
    };
    defer child.kill(init.io);
    return termExitCode(try child.wait(init.io));
}

fn isConfiguredScriptValue(value: std.json.Value) bool {
    return switch (value) {
        .string => true,
        .array => |argv| valid: {
            if (argv.items.len == 0) break :valid false;
            for (argv.items) |arg| if (arg != .string) break :valid false;
            break :valid true;
        },
        else => false,
    };
}

fn printScripts(writer: anytype, config: Config) !bool {
    const scripts = getObjectField(config.root, "scripts") orelse return false;

    return switch (scripts) {
        .object => |object| {
            var found = false;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (isConfiguredScriptValue(entry.value_ptr.*)) {
                    try writer.print("{s}\n", .{entry.key_ptr.*});
                    found = true;
                }
            }
            return found;
        },
        else => false,
    };
}

fn runConfiguredScriptIfExists(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    cottontail_path: []const u8,
    script_name: []const u8,
    script_args: []const [:0]const u8,
    stderr: anytype,
) !?u8 {
    const config = loadHutchConfig(init, allocator, cottontail_path) catch |err| switch (err) {
        error.HutchConfigNotFound => return null,
        else => return err,
    };
    const scripts = getObjectField(config.root, "scripts") orelse return null;
    const script = getObjectField(scripts, script_name) orelse return null;

    return switch (script) {
        .string => |command| try runCottontailShellScript(
            init,
            allocator,
            cottontail_path,
            command,
            script_args,
        ),
        .array => |argv| try runArgvScript(init, allocator, argv, script_args, stderr),
        else => {
            try stderr.print(
                "hutch: script must be a string or non-empty argv string array: {s}\n",
                .{script_name},
            );
            return 1;
        },
    };
}

fn isExplicitRuntimePath(name: []const u8) bool {
    return std.fs.path.isAbsolute(name) or
        std.mem.startsWith(u8, name, "./") or
        std.mem.startsWith(u8, name, ".\\") or
        std.mem.startsWith(u8, name, "../") or
        std.mem.startsWith(u8, name, "..\\") or
        std.mem.indexOfAny(u8, name, "/\\") != null;
}

fn runtimeDiagnosticEligible(name: []const u8) bool {
    return isExplicitRuntimePath(name) or std.fs.path.extension(name).len > 0;
}

fn runReleaseCommand(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    product: release_store.Product,
    args: []const [:0]const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    if (product == .hutch and args.len == 3 and
        std.mem.eql(u8, args[0], "bootstrap-install"))
    {
        release_store.bootstrapInstalledHutch(init, allocator, args[1], args[2]) catch |err| {
            if (err == error.InstalledHutchReleaseBusy) {
                try stderr.writeAll(
                    "hutch: could not install Hutch because this exact release is currently in use; close running Hutch processes and retry\n",
                );
            } else if (err == error.UnsafeUnmarkedHutchHome) {
                try stderr.writeAll(
                    "hutch: refusing to claim an unmarked Hutch home that is a user/root directory or contains unrelated files\n",
                );
            } else {
                try stderr.print("hutch: could not bootstrap installed Hutch: {s}\n", .{@errorName(err)});
            }
            return 1;
        };
        return 0;
    }
    const namespace = if (product == .hutch) "self" else "cottontail";
    if (args.len == 0 or isHelpFlag(args[0])) {
        const verbs = if (product == .hutch) "path|version|update|pin" else "path|version|pin";
        try stderr.print(
            "Usage: hutch {s} <{s}> " ++
                "[production|stable|canary|latest|<semver>|build:<revision>] [--recursive]\n",
            .{ namespace, verbs },
        );
        return if (args.len == 0) 1 else 0;
    }
    if (product == .hutch and isHutchUpdateHelpRequest(args)) {
        try stdout.writeAll(upgrade_help_text);
        return 0;
    }

    const operation = args[0];
    if (std.mem.eql(u8, operation, "pin")) {
        return runPinCommand(init, allocator, product, args[1..], stdout, stderr);
    }
    if (product == .cottontail and std.mem.eql(u8, operation, "update")) {
        try stderr.print(
            "hutch cottontail: Cottontail is paired with the Hutch release " ++
                "({s} for this launcher); 'hutch upgrade' advances both together. " ++
                "Pin a different version with the // @hutch pragma or 'hutch cottontail pin'.\n",
            .{hutch_version.paired_cottontail_version},
        );
        return 1;
    }
    if (args.len > 2) {
        try stderr.print("hutch {s}: too many arguments\n", .{namespace});
        return 1;
    }
    const channel = activeReleaseChannel(init.environ_map) catch |err| {
        try stderr.print("hutch: invalid active channel: {s}\n", .{@errorName(err)});
        return 1;
    };
    const selector = if (args.len == 2)
        version_selector.parse(args[1]) catch |err| {
            try stderr.print("hutch: invalid release selector: {s}\n", .{@errorName(err)});
            return 1;
        }
    else
        version_selector.parse(defaultProductVersion(init.environ_map, product, channel)) catch unreachable;
    const refresh = std.mem.eql(u8, operation, "update");
    if (!refresh and
        !std.mem.eql(u8, operation, "path") and
        !std.mem.eql(u8, operation, "version"))
    {
        try stderr.print("hutch {s}: unknown command: {s}\n", .{ namespace, operation });
        return 1;
    }

    const resolution = release_store.resolve(
        init,
        allocator,
        product,
        selector,
        .{
            .refresh = refresh,
            .offline = environmentFlag(init.environ_map, "DASH_RELEASE_OFFLINE"),
        },
    ) catch |err| {
        try stderr.print(
            "hutch: could not resolve {s}: {s}\n",
            .{ product.name(), @errorName(err) },
        );
        return 1;
    };

    const updated_channel: ?[]const u8 = if (refresh)
        activateResolvedUpdate(
            init,
            allocator,
            product,
            selector,
            channel,
            resolution,
        ) catch |err| {
            try stderr.print(
                "hutch: could not activate {s}: {s}\n",
                .{ product.name(), @errorName(err) },
            );
            return 1;
        }
    else
        null;

    if (std.mem.eql(u8, operation, "path")) {
        try stdout.print("{s}\n", .{resolution.executable});
    } else if (std.mem.eql(u8, operation, "version")) {
        try stdout.print("{s}\n", .{resolution.version});
    } else {
        const channel_name = updated_channel.?;
        try writeReleaseUpdateSuccess(stdout, product, resolution, channel_name);
        notePragmaPin(init, allocator, product, channel_name, resolution.version, stderr) catch {};
    }
    return 0;
}

// Channel selectors are activated by release_store.resolve itself. Exact and
// build selectors have no inherent channel, so an update binds the selected
// release to the channel of the launcher that performed the update.
fn activateResolvedUpdate(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    product: release_store.Product,
    selector: version_selector.Selector,
    active_channel: []const u8,
    resolution: release_store.Resolution,
) ![]const u8 {
    if (selector.channel()) |selected_channel| return selected_channel;
    try release_store.activateChannel(
        init,
        allocator,
        product,
        active_channel,
        resolution,
    );
    return active_channel;
}

fn writeReleaseUpdateSuccess(
    writer: anytype,
    product: release_store.Product,
    resolution: release_store.Resolution,
    channel: []const u8,
) !void {
    try writer.print(
        "{s} {s}@{s} is active for {s}\n",
        .{ product.name(), resolution.version, resolution.revision, channel },
    );
}

// An updated channel selection changes nothing for a project whose pragma
// pins a version: say so, or the update looks silently ignored.
fn notePragmaPin(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    product: release_store.Product,
    channel_name: []const u8,
    updated_version: []const u8,
    stderr: anytype,
) !void {
    const config_path = (try bootstrap_pragma.findNearestConfig(init.io, allocator)) orelse return;
    const pragma = ((bootstrap_pragma.parseFile(init.io, allocator, config_path) catch return) orelse return);
    const field = (if (product == .hutch) pragma.cli else pragma.cottontail) orelse return;
    const namespace = if (product == .hutch) "self" else "cottontail";
    const key = if (product == .hutch) "cli" else "cottontail";
    switch (field.kind) {
        .version => if (!std.mem.eql(u8, field.value, updated_version)) {
            try stderr.print(
                "note: this project pins {s}={s} via {s}; run 'hutch {s} pin' to move it to {s}\n",
                .{ key, field.value, config_path, namespace, updated_version },
            );
        },
        .build => try stderr.print(
            "note: this project pins {s}=build:{s} via {s}; run 'hutch {s} pin' to move it to {s}\n",
            .{ key, field.value, config_path, namespace, updated_version },
        ),
        .production, .canary => if (!std.mem.eql(u8, field.value, channel_name)) {
            try stderr.print(
                "note: this project tracks the {s} channel via {s}, not {s}\n",
                .{ field.value, config_path, channel_name },
            );
        },
    }
}

fn runPinCommand(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    product: release_store.Product,
    args: []const [:0]const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const namespace = if (product == .hutch) "self" else "cottontail";
    const key = if (product == .hutch) "cli" else "cottontail";

    var recursive = false;
    var requested: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--recursive") or std.mem.eql(u8, arg, "-r")) {
            recursive = true;
        } else if (requested == null and arg.len > 0 and arg[0] != '-') {
            requested = arg;
        } else {
            try stderr.print("hutch {s} pin: unexpected argument: {s}\n", .{ namespace, arg });
            return 1;
        }
    }
    if (requested) |text| {
        _ = version_selector.parse(text) catch |err| {
            try stderr.print("hutch: invalid release selector: {s}\n", .{@errorName(err)});
            return 1;
        };
    }

    // Without a selector, pin what would run unpinned today: the active
    // channel's Hutch, or Cottontail's paired default. `latest`/`stable`/
    // `canary` write the floating alias instead.
    const value = requested orelse concrete: {
        const channel = activeReleaseChannel(init.environ_map) catch |err| {
            try stderr.print("hutch: invalid active channel: {s}\n", .{@errorName(err)});
            return 1;
        };
        const selector = version_selector.parse(
            defaultProductVersion(init.environ_map, product, channel),
        ) catch unreachable;
        const resolution = release_store.resolve(init, allocator, product, selector, .{
            .offline = environmentFlag(init.environ_map, "DASH_RELEASE_OFFLINE"),
        }) catch |err| {
            try stderr.print(
                "hutch: could not resolve {s}: {s}\n",
                .{ product.name(), @errorName(err) },
            );
            return 1;
        };
        break :concrete resolution.version;
    };

    if (recursive) {
        const root = try std.Io.Dir.cwd().realPathFileAlloc(init.io, ".", allocator);
        const configs = try pragma_pin.findConfigsRecursive(init.io, allocator, root);
        var pinned: usize = 0;
        for (configs) |config_path| {
            // Recursive pinning only moves existing pins; projects that
            // track a channel or the global default keep doing so.
            const pragma = (bootstrap_pragma.parseFile(init.io, allocator, config_path) catch |err| {
                try stderr.print(
                    "hutch {s} pin: skipped {s}: {s}\n",
                    .{ namespace, config_path, @errorName(err) },
                );
                continue;
            }) orelse continue;
            const field = (if (product == .hutch) pragma.cli else pragma.cottontail) orelse continue;
            if (field.kind != .version and field.kind != .build) continue;
            const rewrite = pragma_pin.pinConfigFile(init.io, allocator, config_path, key, value) catch |err| {
                try stderr.print(
                    "hutch {s} pin: could not rewrite {s}: {s}\n",
                    .{ namespace, config_path, @errorName(err) },
                );
                return 1;
            };
            const before = rewrite.previous.?;
            if (std.mem.eql(u8, before, value)) continue;
            try stdout.print("{s}: {s}={s} (was {s})\n", .{ config_path, key, value, before });
            pinned += 1;
        }
        try stdout.print(
            "pinned {s}={s} in {d} of {d} configs under {s}\n",
            .{ key, value, pinned, configs.len, root },
        );
        return 0;
    }

    const config_path = (try bootstrap_pragma.findNearestConfig(init.io, allocator)) orelse {
        try stderr.print(
            "hutch {s} pin: no hutch.config.ts found from the current directory\n",
            .{namespace},
        );
        return 1;
    };
    const rewrite = pragma_pin.pinConfigFile(init.io, allocator, config_path, key, value) catch |err| {
        try stderr.print(
            "hutch {s} pin: could not rewrite {s}: {s}\n",
            .{ namespace, config_path, @errorName(err) },
        );
        return 1;
    };
    try stdout.print(
        "{s}: {s}={s} (was {s})\n",
        .{ config_path, key, value, rewrite.previous orelse "unset" },
    );
    return 0;
}

fn activeReleaseChannel(environment: *const std.process.Environ.Map) ![]const u8 {
    const channel = environment.get("HUTCH_ACTIVE_CHANNEL") orelse "production";
    return version_selector.normalizeChannel(channel);
}

// The no-selector default: Hutch floats on the channel, Cottontail runs
// this release's tested pair.
fn defaultProductVersion(
    environment: *const std.process.Environ.Map,
    product: release_store.Product,
    channel: []const u8,
) []const u8 {
    _ = environment;
    if (product != .cottontail) return channel;
    return hutch_version.paired_cottontail_version;
}

fn environmentFlag(environment: *const std.process.Environ.Map, name: []const u8) bool {
    const value = environment.get(name) orelse return false;
    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes");
}

fn maybePromptForUpdates(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    stderr: anytype,
) !void {
    if (environmentFlag(init.environ_map, "HUTCH_NO_UPDATE_CHECK") or
        init.environ_map.get("CI") != null or
        !(std.Io.File.stdin().isTty(init.io) catch false) or
        !(std.Io.File.stderr().isTty(init.io) catch false))
    {
        return;
    }

    const channel = activeReleaseChannel(init.environ_map) catch return;
    var reader_buffer: [1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(init.io, &reader_buffer);

    // Cottontail is paired with the Hutch release, so only Hutch itself has
    // a floating channel worth prompting about; updating it moves the pair.
    for ([_]release_store.Product{.hutch}) |product| {
        const available = release_store.checkForUpdate(
            init,
            allocator,
            product,
            channel,
        ) catch continue;
        const update = available orelse continue;

        try stderr.print(
            "hutch: {s} {s} is available (current {s}). " ++
                "[u]pdate, [s]kip this version, or [l]ater? ",
            .{ product.name(), update.version, update.current_version },
        );
        try stderr.flush();
        const line = (stdin_reader.interface.takeDelimiter('\n') catch null) orelse {
            try stderr.writeAll("\n");
            return;
        };
        const response = std.mem.trim(u8, line, " \t\r");
        if (std.ascii.eqlIgnoreCase(response, "u") or
            std.ascii.eqlIgnoreCase(response, "update"))
        {
            const selector = version_selector.parse(channel) catch unreachable;
            const resolution = release_store.resolve(
                init,
                allocator,
                product,
                selector,
                .{ .refresh = true },
            ) catch |err| {
                try stderr.print(
                    "hutch: could not update {s}: {s}\n",
                    .{ product.name(), @errorName(err) },
                );
                continue;
            };
            try stderr.print(
                "hutch: updated {s} to {s}; it will be used by the next command.\n",
                .{ product.name(), resolution.version },
            );
        } else if (std.ascii.eqlIgnoreCase(response, "s") or
            std.ascii.eqlIgnoreCase(response, "skip"))
        {
            release_store.skipUpdate(
                init,
                allocator,
                product,
                channel,
                update.revision,
            ) catch {};
            try stderr.print("hutch: skipped {s} {s}.\n", .{ product.name(), update.version });
        }
    }
}

fn cottontailRuntimeOptionTakesValue(arg: []const u8) bool {
    if (std.mem.indexOfScalar(u8, arg, '=') != null) return false;
    const value_options = [_][]const u8{
        "-r",
        "--allow-fs-read",
        "--allow-fs-write",
        "--conditions",
        "--console-depth",
        "--cpu-prof-dir",
        "--cpu-prof-interval",
        "--cpu-prof-name",
        "--cwd",
        "--define",
        "--diagnostic-dir",
        "--elide-lines",
        "--env-file",
        "--env-file-if-exists",
        "--experimental-default-type",
        "--experimental-loader",
        "--feature",
        "--fetch-preconnect",
        "--filter",
        "--heap-prof-dir",
        "--heap-prof-name",
        "--icu-data-dir",
        "--import",
        "--input-type",
        "--inspect-publish-uid",
        "--loader",
        "--port",
        "--preload",
        "--redirect-warnings",
        "--require",
        "--shell",
        "--snapshot-blob",
        "--test-name-pattern",
        "--test-reporter",
        "--test-reporter-destination",
        "--test-shard",
        "--tsconfig-override",
        "--user-agent",
    };
    for (value_options) |option| {
        if (std.mem.eql(u8, arg, option)) return true;
    }
    return false;
}

const RuntimeAutoInstallInput = union(enum) {
    entrypoint: []const u8,
    source: []const u8,
};

fn isDirectRuntimeFacade(environment: *const std.process.Environ.Map) bool {
    return isBunCliFacade(environment) and
        environment.get("HUTCH_LAUNCHER_PATH") == null;
}

// Runtime arguments here exclude the leading "hutch"; scanning starts at 0.
fn runtimeAutoInstallInput(args: []const [:0]const u8) ?RuntimeAutoInstallInput {
    var index: usize = 0;
    var saw_run = false;
    while (index < args.len) {
        const arg: []const u8 = args[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            return if (index < args.len) .{ .entrypoint = args[index] } else null;
        }
        if (!saw_run and std.mem.eql(u8, arg, "run")) {
            saw_run = true;
            index += 1;
            continue;
        }
        if (!saw_run and
            (std.mem.eql(u8, arg, "-e") or
                std.mem.eql(u8, arg, "--eval") or
                std.mem.eql(u8, arg, "-p") or
                std.mem.eql(u8, arg, "--print")))
        {
            return if (index + 1 < args.len) .{ .source = args[index + 1] } else null;
        }
        if (!saw_run and std.mem.startsWith(u8, arg, "--eval=")) {
            return .{ .source = arg["--eval=".len..] };
        }
        if (!saw_run and std.mem.startsWith(u8, arg, "--print=")) {
            return .{ .source = arg["--print=".len..] };
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            index += if (cottontailRuntimeOptionTakesValue(arg) and index + 1 < args.len) 2 else 1;
            continue;
        }
        return .{ .entrypoint = arg };
    }
    return null;
}

fn prepareRuntimeAutoInstall(
    init: std.process.Init,
    entrypoint: []const u8,
    mode: runtime_autoinstall.Mode,
    stderr: *std.Io.Writer,
) !bool {
    // Direct facade mode (engine spawned as the runtime's CLI, no launcher):
    // the runtime owns dependency installation; scanning here would reject
    // entrypoints the runtime itself handles (non-package imports, syntax the
    // scanner cannot parse) and mask its real errors.
    if (isDirectRuntimeFacade(init.environ_map)) return true;
    runtime_autoinstall.prepare(init, entrypoint, mode, stderr) catch |err| {
        if (err != error.AutoInstallFailed) {
            try stderr.print("hutch: dependency preflight failed: {s}\n", .{@errorName(err)});
        }
        try stderr.flush();
        return false;
    };
    return true;
}

fn prepareForwardedRuntimeAutoInstall(
    init: std.process.Init,
    command_args: []const [:0]const u8,
    stderr: *std.Io.Writer,
) !bool {
    if (isDirectRuntimeFacade(init.environ_map)) return true;
    const input = runtimeAutoInstallInput(command_args) orelse return true;
    switch (input) {
        .entrypoint => |entrypoint| {
            return try prepareRuntimeAutoInstall(init, entrypoint, .auto, stderr);
        },
        .source => |source| {
            runtime_autoinstall.prepareSource(init, source, .auto, stderr) catch |err| {
                if (err != error.AutoInstallFailed) {
                    try stderr.print("hutch: dependency preflight failed: {s}\n", .{@errorName(err)});
                }
                try stderr.flush();
                return false;
            };
            return true;
        },
    }
}

fn forwardToCottontail(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    command_args: []const [:0]const u8,
    stderr: *std.Io.Writer,
) !u8 {
    if (!try prepareForwardedRuntimeAutoInstall(init, command_args, stderr)) return 1;
    const cottontail = resolveCottontail(init, allocator, command_args) catch |err| {
        try stderr.print("hutch: could not resolve Cottontail: {s}\n", .{@errorName(err)});
        try stderr.flush();
        return 1;
    };
    return runCottontailCommand(
        init,
        allocator,
        cottontail.executable,
        command_args,
    );
}

fn runNamedConfigScript(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    name: []const u8,
    script_args: []const [:0]const u8,
    stderr: *std.Io.Writer,
) !?u8 {
    const no_args: [0][:0]const u8 = .{};
    const cottontail = resolveCottontail(init, allocator, &no_args) catch |err| {
        try stderr.print("hutch: could not resolve Cottontail: {s}\n", .{@errorName(err)});
        return 1;
    };
    return runConfiguredScriptIfExists(
        init,
        allocator,
        cottontail.executable,
        name,
        script_args,
        stderr,
    );
}

const PackageManagerResolution = struct {
    selection: package_manager_adapter.Selection,
    toolchain: ?toolchain_store.LeasedResolution = null,
    electrobun_core_lease: ?store_locks.ObjectLease = null,

    fn close(self: PackageManagerResolution, io: std.Io) void {
        if (self.toolchain) |leased| leased.close(io);
        if (self.electrobun_core_lease) |lease| lease.close(io);
    }
};

fn resolvePackageManager(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    stderr: *std.Io.Writer,
) !?PackageManagerResolution {
    if (findHutchConfig(init, allocator)) |config_path| {
        const no_args: [0][:0]const u8 = .{};
        const cottontail = resolveCottontail(init, allocator, &no_args) catch |err| {
            try stderr.print(
                "hutch: could not resolve Cottontail to load hutch.config.ts: {s}\n",
                .{@errorName(err)},
            );
            return null;
        };
        const config = loadHutchConfig(init, allocator, cottontail.executable) catch |err| {
            try stderr.print("hutch: failed to load hutch.config.ts: {s}\n", .{@errorName(err)});
            return null;
        };
        const selection = package_manager_adapter.fromConfig(config.root) catch |err| {
            switch (err) {
                error.UnsupportedPackageManager => try stderr.writeAll(
                    "hutch: unsupported packageManager in hutch.config.ts; expected bun, npm, pnpm, or yarn\n",
                ),
                error.InvalidPackageManagerConfig => try stderr.writeAll(
                    "hutch: packageManager must be bun, npm, pnpm, yarn, or { name, executable? }\n",
                ),
            }
            return null;
        };
        if (package_manager_adapter.eligibleForVendoredBun(selection)) {
            return resolveVendoredBun(
                init,
                allocator,
                config.root,
                std.fs.path.dirname(config_path) orelse ".",
                selection,
                stderr,
            );
        }
        return .{ .selection = selection };
    } else |err| switch (err) {
        error.HutchConfigNotFound => {
            managed_store.pruneAutomatic(init, allocator);
            return .{ .selection = package_manager_adapter.defaultSelection() };
        },
        else => return err,
    }
}

const LeasedElectrobunDevkit = struct {
    resolution: electrobun_devkit.Resolution,
    lease: ?store_locks.ObjectLease = null,
};

fn retainElectrobunCoreLeaseForBun(
    io: std.Io,
    lease: ?store_locks.ObjectLease,
    embedded_bun: ?[]const u8,
) ?store_locks.ObjectLease {
    if (embedded_bun != null) return lease;
    if (lease) |held| held.close(io);
    return null;
}

fn electrobunConfigExists(
    io: std.Io,
    allocator: std.mem.Allocator,
    project_root: []const u8,
) bool {
    for ([_][]const u8{
        "electrobun.config.ts",
        "electrobun.config.mts",
        "electrobun.config.js",
        "electrobun.config.mjs",
    }) |name| {
        const path = std.fs.path.join(allocator, &.{ project_root, name }) catch return false;
        if (pathExists(io, path)) return true;
    }
    return false;
}

fn isElectrobunPackageManagerProject(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    config_root: std.json.Value,
    project_root: []const u8,
) bool {
    if (config_root == .object and config_root.object.get("electrobun") != null) return true;
    if (init.environ_map.get("HUTCH_DEFAULT_ELECTROBUN") != null) return true;
    if (projectedElectrobunVersionAtRoot(init, allocator, project_root) != null) return true;
    return electrobunConfigExists(init.io, allocator, project_root);
}

fn loadElectrobunDevkitForPackageManager(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    electrobun_version: []const u8,
) !LeasedElectrobunDevkit {
    if (init.environ_map.get("HUTCH_ELECTROBUN_DEVKIT_ROOT")) |configured| {
        if (configured.len == 0) return error.InvalidElectrobunDevkitRoot;
        const core_root = try std.Io.Dir.cwd().realPathFileAlloc(init.io, configured, allocator);
        return .{
            .resolution = try electrobun_devkit.load(
                init.io,
                allocator,
                core_root,
                electrobun_version,
            ),
        };
    }

    // Keep graph discovery, devkit validation, and lease acquisition atomic
    // with respect to pruning. The caller retains this lease only when Bun is
    // embedded in the core; a modern devkit releases it after reading the pin.
    const graph = try managed_store.acquireUsageLock(init, allocator);
    defer graph.close(init.io);
    const core_root = try electrobun_artifacts.ensureCore(init, allocator, electrobun_version);
    const resolution = try electrobun_devkit.load(
        init.io,
        allocator,
        core_root,
        electrobun_version,
    );
    const home = try release_store.hutchHome(init, allocator);
    return .{
        .resolution = resolution,
        .lease = try store_locks.acquireObjectLease(init.io, allocator, home, core_root),
    };
}

// Explicit packageManager: "bun" is pinned by the selected Electrobun
// devkit when this is an Electrobun project. Generic projects use Hutch's Bun
// default. A current managed Bun holds its own toolchain lease; only a
// historical embedded Bun retains the Electrobun core lease while it runs.
fn resolveVendoredBun(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    config_root: std.json.Value,
    project_root: []const u8,
    selection: package_manager_adapter.Selection,
    stderr: *std.Io.Writer,
) !?PackageManagerResolution {
    var electrobun_core_lease: ?store_locks.ObjectLease = null;
    var bun_version: []const u8 = toolchain_store.default_bun_version;
    const electrobun_project = isElectrobunPackageManagerProject(
        init,
        allocator,
        config_root,
        project_root,
    );

    if (electrobun_project) {
        const selected = selectElectrobunProjectVersion(
            init,
            allocator,
            config_root,
            project_root,
            true,
        ) catch |err| {
            try stderr.print(
                "hutch: could not select the Electrobun release for packageManager: bun: {s}\n",
                .{@errorName(err)},
            );
            return null;
        };
        const devkit = loadElectrobunDevkitForPackageManager(
            init,
            allocator,
            selected.version,
        ) catch |err| {
            try stderr.print(
                "hutch: could not resolve the Electrobun {s} devkit for packageManager: bun: {s}\n",
                .{ selected.version, @errorName(err) },
            );
            return null;
        };
        const embedded_bun = devkit.resolution.runtime.bun;
        const pinned_bun_version = devkit.resolution.toolchains.bun;
        electrobun_core_lease = retainElectrobunCoreLeaseForBun(
            init.io,
            devkit.lease,
            embedded_bun,
        );
        if (embedded_bun) |path| {
            var resolved = selection;
            resolved.executable = path;
            return .{
                .selection = resolved,
                .electrobun_core_lease = electrobun_core_lease,
            };
        }
        bun_version = pinned_bun_version;
    }

    const leased = (if (electrobun_project)
        toolchain_store.resolveManagedOnlyVersion(init, allocator, .bun, bun_version)
    else
        // Generic Bun projects retain Hutch's normal default-version behavior,
        // including accepting an exact version match from PATH.
        toolchain_store.resolveVersion(init, allocator, .bun, bun_version)) catch |err| {
        if (electrobun_core_lease) |lease| lease.close(init.io);
        switch (err) {
            error.ToolchainNotInstalledOffline => try stderr.print(
                "hutch: bun {s} is not installed; offline mode cannot download it\n",
                .{bun_version},
            ),
            error.ToolchainDamagedOffline => try stderr.print(
                "hutch: the installed bun {s} toolchain is damaged; disable offline mode to replace it\n",
                .{bun_version},
            ),
            else => try stderr.print(
                "hutch: could not resolve the bun {s} toolchain: {s}\n",
                .{ bun_version, @errorName(err) },
            ),
        }
        return null;
    };
    var resolved = selection;
    resolved.executable = leased.resolution.binary;
    return .{
        .selection = resolved,
        .toolchain = leased,
        .electrobun_core_lease = electrobun_core_lease,
    };
}

fn findNearestPackageRoot(
    io: std.Io,
    allocator: std.mem.Allocator,
) !?[]const u8 {
    var current: []const u8 = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    while (true) {
        const manifest = try std.fs.path.join(allocator, &.{ current, "package.json" });
        if (pathExists(io, manifest)) return current;

        const parent = std.fs.path.dirname(current) orelse return null;
        if (std.mem.eql(u8, parent, current)) return null;
        current = try allocator.dupe(u8, parent);
    }
}

fn localBinCandidateIsFile(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

fn resolveLocalBinExecutable(
    io: std.Io,
    allocator: std.mem.Allocator,
    bin_directory: []const u8,
    command: []const u8,
) !?[]const u8 {
    if (comptime builtin.os.tag == .windows) {
        // npm-compatible installs conventionally publish .cmd shims, but
        // native executables and .bat shims are valid local bins too. Resolve
        // every candidate by exact path so PATH and global installs can never
        // satisfy the request.
        for ([_][]const u8{ "", ".exe", ".cmd", ".bat" }) |suffix| {
            const filename = try std.fmt.allocPrint(allocator, "{s}{s}", .{ command, suffix });
            const candidate = try std.fs.path.join(allocator, &.{ bin_directory, filename });
            if (localBinCandidateIsFile(io, candidate)) return candidate;
        }
        return null;
    }

    const candidate = try std.fs.path.join(allocator, &.{ bin_directory, command });
    return if (localBinCandidateIsFile(io, candidate)) candidate else null;
}

fn runLocalPackageBin(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    exec_args: []const [:0]const u8,
    stderr: *std.Io.Writer,
) !u8 {
    const command = exec_args[0];
    if (!isSafeLocalBinName(command)) {
        try stderr.print(
            "hutch pm exec: command must be a bare name in node_modules/.bin: {s}\n",
            .{command},
        );
        return 1;
    }

    const project_root = (try findNearestPackageRoot(init.io, allocator)) orelse {
        try stderr.writeAll(
            "hutch pm exec: no package.json found in this directory or its ancestors\n",
        );
        return 1;
    };
    const bin_directory = try std.fs.path.join(
        allocator,
        &.{ project_root, "node_modules", ".bin" },
    );
    const executable = (try resolveLocalBinExecutable(
        init.io,
        allocator,
        bin_directory,
        command,
    )) orelse {
        try stderr.print(
            "hutch pm exec: {s} was not found in {s}\n",
            .{ command, bin_directory },
        );
        return 1;
    };

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, executable);
    for (exec_args[1..]) |arg| try argv.append(allocator, arg);

    // Match package-manager exec environments for subprocesses while keeping
    // resolution of argv[0] pinned to the exact local path above.
    var environment = try init.environ_map.clone(allocator);
    defer environment.deinit();
    const path_key = if (builtin.os.tag == .windows) "Path" else "PATH";
    const inherited_path = environment.get(path_key) orelse environment.get("PATH") orelse "";
    const child_path = if (inherited_path.len == 0)
        try allocator.dupe(u8, bin_directory)
    else
        try std.fmt.allocPrint(
            allocator,
            "{s}{c}{s}",
            .{ bin_directory, std.fs.path.delimiter, inherited_path },
        );
    try environment.put(path_key, child_path);

    var child = std.process.spawn(init.io, .{
        .argv = argv.items,
        .environ_map = &environment,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        if (err == error.InvalidBatchScriptArg) {
            try stderr.writeAll(
                "hutch pm exec: Windows .cmd/.bat shims reject arguments containing NUL, CR, or LF\n",
            );
        } else {
            try stderr.print(
                "hutch pm exec: could not run {s}: {s}\n",
                .{ executable, @errorName(err) },
            );
        }
        return 1;
    };
    defer child.kill(init.io);
    return termExitCode(try child.wait(init.io));
}

fn runBuiltinPackageManager(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    args: []const [:0]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const command = parseBuiltinPackageManagerCommand(args) catch |err| {
        switch (err) {
            error.MissingBuiltinExecCommand => try stderr.writeAll(
                "hutch pm exec: expected [--] <command> [args...]\n",
            ),
            error.UnsupportedBuiltinPackageManagerCommand => try stderr.print(
                "hutch pm: unsupported built-in command: {s}\n" ++
                    "Use `hutch install`, `hutch pm exec`, or `hutch pm --help`.\n",
                .{args[0]},
            ),
            error.UnexpectedBuiltinPackageManagerArguments => try stderr.writeAll(
                "hutch pm: --help and --version do not accept arguments\n",
            ),
        }
        return 1;
    };

    return switch (command) {
        .help => help: {
            try stdout.writeAll(package_manager_help_text);
            break :help 0;
        },
        .version => version_output: {
            try stdout.print("{s}\n", .{version});
            break :version_output 0;
        },
        .exec => |exec_args| runLocalPackageBin(init, allocator, exec_args, stderr),
    };
}

fn runPackageManager(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    subcommand: ?[]const u8,
    forwarded_args: []const [:0]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const resolution = (try resolvePackageManager(init, allocator, stderr)) orelse return 1;
    defer resolution.close(init.io);
    const selection = resolution.selection;
    if (selection.name == .hutch) {
        if (subcommand == null) {
            return runBuiltinPackageManager(
                init,
                allocator,
                forwarded_args,
                stdout,
                stderr,
            );
        }
        var builtin_args: std.ArrayList([:0]const u8) = .empty;
        defer builtin_args.deinit(allocator);
        try builtin_args.append(allocator, "hutch");
        try builtin_args.append(allocator, "install");
        try builtin_args.appendSlice(allocator, forwarded_args);
        return package_manager.cli.run(init, builtin_args.items, stdout, stderr);
    }
    const term = package_manager_adapter.run(
        init,
        allocator,
        selection,
        subcommand,
        forwarded_args,
    ) catch |err| {
        if (err == error.InvalidBatchScriptArg) {
            try stderr.writeAll(
                "hutch: Windows .cmd/.bat package-manager shims reject arguments containing NUL, CR, or LF\n",
            );
            return 1;
        }
        try stderr.print("hutch: could not run package manager {s} ({s}): {s}\n", .{
            @tagName(selection.name),
            selection.executable,
            @errorName(err),
        });
        return 1;
    };
    return termExitCode(term);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    // A directly invoked engine does not have a launcher parent to retain its
    // managed release. Keep this lease for the complete engine lifetime; the
    // helper returns null for development binaries outside the owned store.
    const current_hutch_lease = try managed_store.acquireCurrentHutchLease(init, allocator);
    defer if (current_hutch_lease) |lease| lease.close(init.io);

    const command: ?[]const u8 = if (args.len > 1) args[1] else null;
    if (args.len <= 1) {
        if (isBunCliFacade(init.environ_map)) {
            const exit_code = try forwardToCottontail(
                init,
                allocator,
                args[1..],
                stderr,
            );
            if (exit_code != 0) std.process.exit(exit_code);
            return;
        }
        managed_store.pruneAutomatic(init, allocator);
        try printHelp(stdout);
        try stdout.flush();
        return;
    }

    const selected_command = command.?;

    if (isHelpFlag(selected_command)) {
        managed_store.pruneAutomatic(init, allocator);
        try printHelp(stdout);
        try stdout.flush();
        return;
    }

    if (isVersionFlag(selected_command)) {
        if (isBunCliFacade(init.environ_map)) {
            const exit_code = try forwardToCottontail(
                init,
                allocator,
                args[1..],
                stderr,
            );
            if (exit_code != 0) std.process.exit(exit_code);
            return;
        }
        managed_store.pruneAutomatic(init, allocator);
        try stdout.print("{s}\n", .{version});
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, selected_command, "prune")) {
        const exit_code = try prune_cli.run(init, args[2..], stdout, stderr);
        try stdout.flush();
        try stderr.flush();
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    }

    if (std.mem.eql(u8, selected_command, "reset")) {
        const exit_code = try reset_cli.run(init, args[2..], stdout, stderr);
        try stdout.flush();
        try stderr.flush();
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    }

    if (std.mem.eql(u8, selected_command, "cache") or
        std.mem.eql(u8, selected_command, "clean"))
    {
        try stderr.print(
            "hutch: `{s}` is not a command; use `hutch prune` or `hutch reset`\n",
            .{selected_command},
        );
        try stderr.flush();
        std.process.exit(1);
    }

    if (std.mem.eql(u8, selected_command, "status")) {
        managed_store.pruneAutomatic(init, allocator);
        const exit_code = try status_cli.run(init, args[2..], stdout, stderr);
        try stdout.flush();
        try stderr.flush();
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    }

    // `hutch upgrade` is the preferred spelling of `hutch self update`: it
    // advances the global Hutch release and its paired Cottontail together.
    // Bare `update` stays unclaimed so it can someday mean "update my
    // dependencies", matching npm/bun muscle memory.
    if (std.mem.eql(u8, selected_command, "upgrade")) {
        var upgrade_args: std.ArrayList([:0]const u8) = .empty;
        defer upgrade_args.deinit(allocator);
        try appendUpgradeReleaseArguments(allocator, &upgrade_args, args[2..]);
        const exit_code = try runReleaseCommand(
            init,
            allocator,
            .hutch,
            upgrade_args.items,
            stdout,
            stderr,
        );
        managed_store.pruneAutomatic(init, allocator);
        try stdout.flush();
        try stderr.flush();
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    }

    const is_release_command = std.mem.eql(u8, selected_command, "self") or
        std.mem.eql(u8, selected_command, "cottontail");
    if (!is_release_command) {
        try maybePromptForUpdates(init, allocator, stderr);
    }

    if (is_release_command) {
        const product: release_store.Product = if (std.mem.eql(u8, selected_command, "self"))
            .hutch
        else
            .cottontail;
        const exit_code = try runReleaseCommand(
            init,
            allocator,
            product,
            args[2..],
            stdout,
            stderr,
        );
        if (!isInstallerBootstrapInvocation(args)) {
            managed_store.pruneAutomatic(init, allocator);
        }
        try stdout.flush();
        try stderr.flush();
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    }

    if (std.mem.startsWith(u8, selected_command, "-") or
        isReservedRuntimeCommand(selected_command) or
        (isBunCliFacade(init.environ_map) and
            (std.mem.eql(u8, selected_command, "getcompletes") or isFakeNodeInvocation(args))))
    {
        const exit_code = try forwardToCottontail(
            init,
            allocator,
            runtimeCommandArguments(args),
            stderr,
        );
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    }

    if (std.mem.eql(u8, selected_command, "install") or std.mem.eql(u8, selected_command, "pm")) {
        const exit_code = try runPackageManager(
            init,
            allocator,
            if (std.mem.eql(u8, selected_command, "install")) "install" else null,
            args[2..],
            stdout,
            stderr,
        );
        try stdout.flush();
        try stderr.flush();
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    }

    if (std.mem.eql(u8, selected_command, "run")) {
        const cottontail = resolveCottontail(init, allocator, args[1..]) catch |err| {
            try stderr.print("hutch: could not resolve Cottontail: {s}\n", .{@errorName(err)});
            try stderr.flush();
            std.process.exit(1);
        };

        if (args.len <= 2) {
            const config = loadHutchConfig(init, allocator, cottontail.executable) catch |err| switch (err) {
                error.HutchConfigNotFound => null,
                else => {
                    try stderr.writeAll("hutch: failed to load hutch.config.ts\n");
                    try stderr.flush();
                    std.process.exit(1);
                },
            };
            if (config) |loaded| {
                _ = try printScripts(stdout, loaded);
                try stdout.flush();
            }
            return;
        }

        const if_configured = std.mem.eql(u8, args[2], "--if-configured");
        const requested_index: usize = if (if_configured) 3 else 2;
        if (args.len <= requested_index) {
            try stderr.writeAll("hutch run --if-configured requires a script name\n");
            try stderr.flush();
            std.process.exit(1);
        }

        const requested = args[requested_index];
        if (!if_configured and std.mem.startsWith(u8, requested, "-")) {
            const exit_code = try runCottontailCommand(
                init,
                allocator,
                cottontail.executable,
                args[1..],
            );
            if (exit_code != 0) std.process.exit(exit_code);
            return;
        }
        if (try runConfiguredScriptIfExists(
            init,
            allocator,
            cottontail.executable,
            requested,
            args[requested_index + 1 ..],
            stderr,
        )) |exit_code| {
            try stderr.flush();
            if (exit_code != 0) std.process.exit(exit_code);
            return;
        }

        if (if_configured) return;

        if (!pathExists(init.io, requested) and !runtimeDiagnosticEligible(requested)) {
            try stderr.print("error: Script not found \"{s}\"\n", .{requested});
            try stderr.flush();
            std.process.exit(1);
        }

        const exit_code = try runCottontailCommand(
            init,
            allocator,
            cottontail.executable,
            args[1..],
        );
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    }

    if (std.mem.eql(u8, selected_command, "electrobun")) {
        const cottontail = resolveCottontail(init, allocator, args[1..]) catch |err| {
            try stderr.print("hutch: could not resolve Cottontail: {s}\n", .{@errorName(err)});
            try stderr.flush();
            std.process.exit(1);
        };
        const requires_project_version = args.len > 2 and
            (std.mem.eql(u8, args[2], "config") or
                std.mem.eql(u8, args[2], "sync") or
                std.mem.eql(u8, args[2], "prepare") or
                std.mem.eql(u8, args[2], "build") or
                std.mem.eql(u8, args[2], "run") or
                std.mem.eql(u8, args[2], "dev"));
        const electrobun_version: ?[]const u8 = if (requires_project_version)
            try resolveElectrobunProjectVersion(init, allocator, cottontail.executable, args[2], stderr)
        else
            null;
        const exit_code = electrobun.run(
            init,
            args[2..],
            cottontail.executable,
            cottontail.root,
            electrobun_version,
        ) catch |err| switch (err) {
            error.InvalidMainProcess,
            error.UnsupportedMainProcess,
            error.LegacyBunVersionConfig,
            error.ElectrobunProductConfigMovedToHutch,
            => 1,
            error.InvalidBuildEnvironment => blk: {
                try stderr.writeAll("hutch electrobun: --env must be dev, canary, or stable\n");
                try stderr.flush();
                break :blk 1;
            },
            else => return err,
        };
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    }

    if (pathExists(init.io, selected_command) or runtimeDiagnosticEligible(selected_command)) {
        const exit_code = try forwardToCottontail(
            init,
            allocator,
            args[1..],
            stderr,
        );
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    }

    if (findHutchConfig(init, allocator)) |_| {
        if (try runNamedConfigScript(
            init,
            allocator,
            selected_command,
            args[2..],
            stderr,
        )) |exit_code| {
            try stderr.flush();
            if (exit_code != 0) std.process.exit(exit_code);
            return;
        }
    } else |err| switch (err) {
        error.HutchConfigNotFound => {},
        else => return err,
    }

    if (std.mem.eql(u8, selected_command, "build")) {
        const exit_code = try forwardToCottontail(
            init,
            allocator,
            args[1..],
            stderr,
        );
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    }

    try stderr.print("error: Script not found \"{s}\"\n", .{selected_command});
    try stderr.flush();
    std.process.exit(1);
}
test "help text describes hutch config scripts" {
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "hutch run") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "--if-configured") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "hutch test [files/options...]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "hutch install") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "hutch pm") != null);
    try std.testing.expect(std.mem.indexOf(u8, package_manager_help_text, "pm exec [--]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "packageManager") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "hutch prune [--dry-run]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "hutch reset") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "hutch cache") == null);
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "hutch status [--json]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "<script-name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "hutch.config.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "dash.config.ts") == null);
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "package.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "argv string arrays") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "Cottontail Bun.$ shell") != null);
}

test "Electrobun package manager version precedence is explicit default projection channel" {
    const explicit = preferredElectrobunVersion(
        "1.2.3",
        "2.3.4",
        "3.4.5",
        "4.5.6",
    ).?;
    try std.testing.expectEqual(ElectrobunVersionSource.explicit_config, explicit.source);
    try std.testing.expectEqualStrings("1.2.3", explicit.version);

    const npm_default = preferredElectrobunVersion(
        null,
        "2.3.4",
        "3.4.5",
        "4.5.6",
    ).?;
    try std.testing.expectEqual(ElectrobunVersionSource.npm_default, npm_default.source);
    try std.testing.expectEqualStrings("2.3.4", npm_default.version);

    const projection = preferredElectrobunVersion(null, null, "3.4.5", "4.5.6").?;
    try std.testing.expectEqual(ElectrobunVersionSource.projection, projection.source);
    try std.testing.expectEqualStrings("3.4.5", projection.version);

    const channel = preferredElectrobunVersion(null, null, null, "4.5.6").?;
    try std.testing.expectEqual(ElectrobunVersionSource.channel, channel.source);
    try std.testing.expectEqualStrings("4.5.6", channel.version);
    try std.testing.expect(preferredElectrobunVersion(null, null, null, null) == null);
}

test "Electrobun version selection accepts only an authentic projection identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const valid = projectedElectrobunVersionFromMetadata(allocator,
        \\{"schemaVersion":1,"kind":"electrobun-devkit-projection","product":{"name":"electrobun","version":"2.0.1-beta.27"}}
    ).?;
    try std.testing.expectEqualStrings("2.0.1-beta.27", valid);

    const invalid = [_][]const u8{
        \\{"kind":"electrobun-devkit-projection","product":{"name":"electrobun","version":"2.0.1"}}
        ,
        \\{"schemaVersion":2,"kind":"electrobun-devkit-projection","product":{"name":"electrobun","version":"2.0.1"}}
        ,
        \\{"schemaVersion":1,"kind":"other-projection","product":{"name":"electrobun","version":"2.0.1"}}
        ,
        \\{"schemaVersion":1,"kind":"electrobun-devkit-projection","product":{"name":"other","version":"2.0.1"}}
        ,
        \\{"schemaVersion":1,"kind":"electrobun-devkit-projection","product":{"version":"2.0.1"}}
        ,
        \\{"schemaVersion":1,"kind":"electrobun-devkit-projection","product":{"name":"electrobun","version":"latest"}}
        ,
        \\{"schemaVersion":1,"kind":"electrobun-devkit-projection","product":{"name":"electrobun","version":"2.0.1","version":"9.9.9"}}
        ,
    };
    for (invalid) |source| {
        try std.testing.expect(projectedElectrobunVersionFromMetadata(allocator, source) == null);
    }
}

test "Electrobun explicit version bypasses a malformed lower-priority npm default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const explicit_root = try std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        "{\"electrobun\":{\"version\":\"1.2.3\"}}",
        .{},
    );
    const explicit = (try configuredOrNpmDefaultElectrobunVersion(
        explicit_root,
        "latest",
    )).?;
    try std.testing.expectEqual(ElectrobunVersionSource.explicit_config, explicit.source);
    try std.testing.expectEqualStrings("1.2.3", explicit.version);

    const floating_root = try std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        "{}",
        .{},
    );
    try std.testing.expectError(
        error.InvalidDefaultElectrobunVersion,
        configuredOrNpmDefaultElectrobunVersion(floating_root, "latest"),
    );
}

test "only an embedded Electrobun Bun retains the core object lease" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const relative = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const fixture = try std.Io.Dir.cwd().realPathFileAlloc(io, relative, allocator);
    const home = try std.fs.path.join(allocator, &.{ fixture, "hutch-home" });
    const core_root = try std.fs.path.join(allocator, &.{
        home,
        "releases",
        "electrobun-core",
        "2.0.0",
        "0123456789abcdef0123456789abcdef01234567",
        "macos-arm64",
    });
    try std.Io.Dir.cwd().createDirPath(io, core_root);

    const modern_graph = try store_locks.acquireGraph(io, allocator, home, .shared);
    const modern_lease = try store_locks.acquireObjectLease(
        io,
        allocator,
        home,
        core_root,
    );
    modern_graph.close(io);
    try std.testing.expect(retainElectrobunCoreLeaseForBun(io, modern_lease, null) == null);
    const modern_exclusive = (try store_locks.tryAcquireObjectExclusive(
        io,
        allocator,
        core_root,
    )).?;
    modern_exclusive.close(io);

    const legacy_graph = try store_locks.acquireGraph(io, allocator, home, .shared);
    const legacy_lease = try store_locks.acquireObjectLease(
        io,
        allocator,
        home,
        core_root,
    );
    legacy_graph.close(io);
    const retained_legacy = retainElectrobunCoreLeaseForBun(
        io,
        legacy_lease,
        "runtime/bun",
    ).?;
    try std.testing.expect((try store_locks.tryAcquireObjectExclusive(
        io,
        allocator,
        core_root,
    )) == null);
    retained_legacy.close(io);
    const legacy_exclusive = (try store_locks.tryAcquireObjectExclusive(
        io,
        allocator,
        core_root,
    )).?;
    legacy_exclusive.close(io);
}

test "built-in package manager parser handles help version and exec" {
    const no_args = [_][:0]const u8{};
    try std.testing.expectEqual(
        BuiltinPackageManagerCommand.help,
        std.meta.activeTag(try parseBuiltinPackageManagerCommand(&no_args)),
    );

    const help_args = [_][:0]const u8{"--help"};
    try std.testing.expectEqual(
        BuiltinPackageManagerCommand.help,
        std.meta.activeTag(try parseBuiltinPackageManagerCommand(&help_args)),
    );

    const version_args = [_][:0]const u8{"-v"};
    try std.testing.expectEqual(
        BuiltinPackageManagerCommand.version,
        std.meta.activeTag(try parseBuiltinPackageManagerCommand(&version_args)),
    );

    const exec_args = [_][:0]const u8{
        "exec",
        "--",
        "local-tool",
        "two words",
        "--",
        "$literal",
        "",
    };
    const parsed = try parseBuiltinPackageManagerCommand(&exec_args);
    switch (parsed) {
        .exec => |forwarded| {
            try std.testing.expectEqual(@as(usize, 5), forwarded.len);
            for (exec_args[2..], forwarded) |expected, actual| {
                try std.testing.expectEqualStrings(expected, actual);
            }
        },
        else => return error.UnexpectedBuiltinPackageManagerParse,
    }
}

test "built-in package manager parser rejects incomplete commands" {
    const missing_exec = [_][:0]const u8{"exec"};
    try std.testing.expectError(
        error.MissingBuiltinExecCommand,
        parseBuiltinPackageManagerCommand(&missing_exec),
    );

    const separator_only = [_][:0]const u8{ "exec", "--" };
    try std.testing.expectError(
        error.MissingBuiltinExecCommand,
        parseBuiltinPackageManagerCommand(&separator_only),
    );

    const unsupported = [_][:0]const u8{"add"};
    try std.testing.expectError(
        error.UnsupportedBuiltinPackageManagerCommand,
        parseBuiltinPackageManagerCommand(&unsupported),
    );

    const version_with_argument = [_][:0]const u8{ "--version", "extra" };
    try std.testing.expectError(
        error.UnexpectedBuiltinPackageManagerArguments,
        parseBuiltinPackageManagerCommand(&version_with_argument),
    );
}

test "built-in package manager exec accepts only bare local bin names" {
    try std.testing.expect(isSafeLocalBinName("vite"));
    try std.testing.expect(isSafeLocalBinName("tool.exe"));
    try std.testing.expect(!isSafeLocalBinName(""));
    try std.testing.expect(!isSafeLocalBinName("."));
    try std.testing.expect(!isSafeLocalBinName(".."));
    try std.testing.expect(!isSafeLocalBinName("../vite"));
    try std.testing.expect(!isSafeLocalBinName("nested/vite"));
    try std.testing.expect(!isSafeLocalBinName("nested\\vite"));
}

test "upgrade maps its optional selector to self update arguments" {
    var mapped: std.ArrayList([:0]const u8) = .empty;
    defer mapped.deinit(std.testing.allocator);
    const selector = [_][:0]const u8{"canary"};
    try appendUpgradeReleaseArguments(std.testing.allocator, &mapped, &selector);

    try std.testing.expectEqual(@as(usize, 2), mapped.items.len);
    try std.testing.expectEqualStrings("update", mapped.items[0]);
    try std.testing.expectEqualStrings("canary", mapped.items[1]);

    mapped.clearRetainingCapacity();
    const help = [_][:0]const u8{"--help"};
    try appendUpgradeReleaseArguments(std.testing.allocator, &mapped, &help);
    try std.testing.expect(isHutchUpdateHelpRequest(mapped.items));

    const help_with_extra = [_][:0]const u8{ "update", "--help", "extra" };
    try std.testing.expect(!isHutchUpdateHelpRequest(&help_with_extra));
}

test "exact and build updates activate the launcher's current channel and report it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const relative = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const fixture = try std.Io.Dir.cwd().realPathFileAlloc(io, relative, allocator);
    const home = try std.fs.path.join(allocator, &.{ fixture, "hutch-home" });
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("HUTCH_HOME", home);
    try environment.put("HUTCH_ACTIVE_CHANNEL", "canary");
    const init: std.process.Init = .{
        .minimal = .{
            .environ = .empty,
            .args = .{ .vector = &.{} },
        },
        .arena = &arena,
        .gpa = std.testing.allocator,
        .io = io,
        .environ_map = &environment,
        .preopens = .empty,
    };

    const exact_revision = "0123456789abcdef0123456789abcdef01234567";
    const build_revision = "abcdef0123456789abcdef0123456789abcdef01";
    const cases = [_]struct {
        selector: []const u8,
        version: []const u8,
        revision: []const u8,
    }{
        .{
            .selector = "9.8.7",
            .version = "9.8.7",
            .revision = exact_revision,
        },
        .{
            .selector = "build:" ++ build_revision,
            .version = "9.8.8-canary.1",
            .revision = build_revision,
        },
    };

    for (cases) |case| {
        const resolution: release_store.Resolution = .{
            .root = "/managed/hutch",
            .executable = "/managed/hutch/bin/hutch-engine",
            .version = case.version,
            .revision = case.revision,
            .archive_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            .installed = true,
        };
        const activated_channel = try activateResolvedUpdate(
            init,
            allocator,
            .hutch,
            try version_selector.parse(case.selector),
            "canary",
            resolution,
        );
        try std.testing.expectEqualStrings("canary", activated_channel);

        const selections = try release_store.loadSelections(init, allocator);
        const active = selections.hutch_canary.?;
        try std.testing.expectEqualStrings(case.version, active.version);
        try std.testing.expectEqualStrings(case.revision, active.revision);
        try std.testing.expectEqualStrings(try release_store.platformKey(), active.platform);

        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        try writeReleaseUpdateSuccess(&output.writer, .hutch, resolution, activated_channel);
        const expected = try std.fmt.allocPrint(
            allocator,
            "hutch {s}@{s} is active for canary\n",
            .{ case.version, case.revision },
        );
        try std.testing.expectEqualStrings(expected, output.written());
    }
}

test "test is a reserved Cottontail command and preserves every argument" {
    try std.testing.expect(isCottontailTestCommand("test"));
    try std.testing.expect(!isCottontailTestCommand("test:unit"));
    try std.testing.expect(isReservedRuntimeCommand("exec"));
    try std.testing.expect(isReservedRuntimeCommand("repl"));
    try std.testing.expect(isReservedRuntimeCommand("completions"));
    try std.testing.expect(!isReservedRuntimeCommand("execute"));

    const args = [_][:0]const u8{
        "hutch",
        "test",
        "tests/one.test.ts",
        "tests/two test.ts",
        "--test-name-pattern",
        "exact value",
        "--bail=3",
    };
    const forwarded = runtimeCommandArguments(&args);
    try std.testing.expectEqual(@as(usize, args.len - 1), forwarded.len);
    for (args[1..], forwarded) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "project descendant detection is component aware" {
    const allocator = std.testing.allocator;
    const root = if (builtin.os.tag == .windows) "C:\\workspace\\app" else "/workspace/app";
    const child = if (builtin.os.tag == .windows) "C:\\workspace\\app\\tmp" else "/workspace/app/tmp";
    const sibling = if (builtin.os.tag == .windows) "C:\\workspace\\application" else "/workspace/application";

    try std.testing.expect(try pathIsProjectDescendant(allocator, root, root));
    try std.testing.expect(try pathIsProjectDescendant(allocator, root, child));
    try std.testing.expect(!try pathIsProjectDescendant(allocator, root, sibling));
}

test "private temp creation refuses a symlink preclaim" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "preclaim-target", @enumFromInt(0o700));
    try tmp.dir.symLink(
        std.testing.io,
        "preclaim-target",
        "hutch-config-loader-preclaimed",
        .{ .is_directory = true },
    );

    try std.testing.expectError(
        error.PathAlreadyExists,
        createPrivateTempLeaf(
            std.testing.io,
            tmp.dir,
            "hutch-config-loader-preclaimed",
        ),
    );
}

test "private temp cleanup never follows a replaced leaf" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "anchor", @enumFromInt(0o700));
    var parent = try tmp.dir.openDir(std.testing.io, "anchor", .{
        .follow_symlinks = false,
        .iterate = true,
    });
    try parent.createDir(std.testing.io, "target", @enumFromInt(0o700));
    try parent.writeFile(std.testing.io, .{
        .sub_path = "target/keep.txt",
        .data = "must survive",
    });

    const child = try createPrivateTempLeaf(std.testing.io, parent, "hutch-private-fixed");
    try child.dir.writeFile(std.testing.io, .{
        .sub_path = "scratch.txt",
        .data = "temporary",
    });
    var private = PrivateTempDirectory{
        .parent = parent,
        .dir = child.dir,
        .name = "hutch-private-fixed",
        .path = "unused-in-test",
        .inode = child.inode,
    };

    try std.Io.Dir.rename(
        private.parent,
        private.name,
        private.parent,
        "moved-private",
        std.testing.io,
    );
    try private.parent.symLink(
        std.testing.io,
        "target",
        private.name,
        .{ .is_directory = true },
    );
    private.deinit(std.testing.io);

    try tmp.dir.access(std.testing.io, "anchor/target/keep.txt", .{});
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(std.testing.io, "anchor/moved-private/scratch.txt", .{}),
    );
}

test "private temp error cleanup preserves an empty replacement leaf" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "created", @enumFromInt(0o700));
    const created = try tmp.dir.statFile(std.testing.io, "created", .{
        .follow_symlinks = false,
    });
    try tmp.dir.rename("created", tmp.dir, "moved-created", std.testing.io);
    try tmp.dir.createDir(std.testing.io, "created", @enumFromInt(0o700));

    deletePrivateTempLeafIfIdentity(std.testing.io, tmp.dir, "created", created.inode);

    const replacement = try tmp.dir.statFile(std.testing.io, "created", .{
        .follow_symlinks = false,
    });
    try std.testing.expectEqual(std.Io.File.Kind.directory, replacement.kind);
}

test "private temp modes are exact under a restrictive umask" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const previous_umask = std.c.umask(0o777);
    defer _ = std.c.umask(previous_umask);

    const child = try createPrivateTempLeaf(std.testing.io, tmp.dir, "private");
    defer cleanupPrivateTempLeaf(
        std.testing.io,
        tmp.dir,
        child.dir,
        "private",
        child.inode,
    );
    const identity = try posixDirectoryIdentity(child.dir);
    try std.testing.expectEqual(@as(u32, 0o700), identity.mode & 0o777);

    try writePrivateFileAtomic(std.testing.io, child.dir, "private.mjs", "");
    const private_file = try child.dir.statFile(std.testing.io, "private.mjs", .{
        .follow_symlinks = false,
    });
    try std.testing.expectEqual(@as(u32, 0o600), private_file.permissions.toMode() & 0o777);
}

test "private temp is cleaned before child signal propagation" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "anchor", @enumFromInt(0o700));
    const parent = try tmp.dir.openDir(std.testing.io, "anchor", .{
        .follow_symlinks = false,
        .iterate = true,
    });
    const child = try createPrivateTempLeaf(std.testing.io, parent, "private");
    var private = PrivateTempDirectory{
        .parent = parent,
        .dir = child.dir,
        .name = "private",
        .path = "unused-in-test",
        .inode = child.inode,
    };
    var private_live = true;

    cleanupPrivateTempBeforeSignal(
        std.testing.io,
        .{ .signal = std.posix.SIG.TERM },
        &private,
        &private_live,
    );

    try std.testing.expect(!private_live);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(std.testing.io, "anchor/private", .{}),
    );
}
