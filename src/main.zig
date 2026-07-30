const std = @import("std");
const builtin = @import("builtin");
const bootstrap_pragma = @import("bootstrap_pragma.zig");
const electrobun = @import("electrobun.zig");
const package_manager = @import("package_manager/root.zig");
const process_replace = @import("process_replace.zig");
const release_store = @import("release_store.zig");
const runtime_autoinstall = @import("runtime_autoinstall.zig");
const runtime_resolver = @import("runtime_resolver.zig");
const version_selector = @import("version_selector.zig");

const version = @import("version.zig").version;

const help_text_template =
    \\hutch {s}
    \\Hutch workspace orchestrator.
    \\
    \\Usage:
    \\  hutch <entrypoint.js|entrypoint.ts> [args...]
    \\  hutch <script-name> [args...]
    \\  hutch electrobun <init|build|run|dev> [args...]
    \\  hutch run [script-name] [args...]
    \\  hutch install [args...]
    \\  hutch <add|remove|update> [args...]
    \\  hutch <init|create|x> [args...]
    \\  hutch build [args...]
    \\  hutch self <path|version|update> [selector]
    \\  hutch cottontail <path|version|update> [selector]
    \\  hutch --help
    \\  hutch --version
    \\
    \\Config:
    \\  Scripts are resolved from dash.config.ts first, then package.json.
    \\  Package-manager commands are implemented by Hutch.
    \\
;

const Config = struct {
    raw_json: []const u8,
    root: std.json.Value,
    dir: []const u8 = ".",
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
    return runtime_resolver.resolveCottontail(init, allocator, command_args);
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

fn runCottontailScript(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    cottontail_path: []const u8,
    script_path: []const u8,
    script_args: []const [:0]const u8,
) !u8 {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    try args.append(allocator, script_path);
    for (script_args) |arg| {
        try args.append(allocator, arg);
    }

    return try runCottontailCommand(init, allocator, cottontail_path, args.items);
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
    const hutch_path = try package_manager.host.cliExecutableForInit(init, allocator);
    try env.put("COTTONTAIL_SPAWN_EXEC_PATH", hutch_path);
    try env.put("COTTONTAIL_SPAWN_ARGV0", hutch_path);

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

fn prepareRuntimeAutoInstall(
    init: std.process.Init,
    entrypoint: []const u8,
    mode: runtime_autoinstall.Mode,
    stderr: *std.Io.Writer,
) !bool {
    runtime_autoinstall.prepare(init, entrypoint, mode, stderr) catch |err| {
        if (err != error.AutoInstallFailed) {
            try stderr.print("hutch: dependency preflight failed: {s}\n", .{@errorName(err)});
        }
        try stderr.flush();
        return false;
    };
    return true;
}

fn printBinaryLockfile(
    init: std.process.Init,
    path: []const u8,
    stdout: *std.Io.Writer,
) !bool {
    if (!std.mem.endsWith(u8, path, ".lockb")) return false;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        init.io,
        path,
        init.arena.allocator(),
        .limited(256 * 1024 * 1024),
    ) catch return false;
    if (!package_manager.bun_lockfile.isBinaryLockfile(bytes)) return false;

    try package_manager.bun_lockfile.writeYarnFromBinary(
        init,
        init.arena.allocator(),
        bytes,
        stdout,
    );
    try stdout.flush();
    return true;
}

fn normalizeLeadingPackageManagerConfig(
    allocator: std.mem.Allocator,
    args: []const [:0]const u8,
) ![]const [:0]const u8 {
    if (args.len < 3) return args;
    const first = args[1];
    const command_index: usize = if (std.mem.eql(u8, first, "--save"))
        2
    else if (std.mem.startsWith(u8, first, "-c=") or
        std.mem.startsWith(u8, first, "--config="))
        2
    else if ((std.mem.eql(u8, first, "-c") or
        std.mem.eql(u8, first, "--config")) and args.len > 3)
        3
    else
        return args;
    if (command_index >= args.len or
        !package_manager.cli.recognizes(args[command_index]))
    {
        return args;
    }

    const normalized = try allocator.alloc([:0]const u8, args.len);
    normalized[0] = args[0];
    normalized[1] = args[command_index];
    @memcpy(normalized[2 .. command_index + 1], args[1..command_index]);
    @memcpy(
        normalized[command_index + 1 ..],
        args[command_index + 1 ..],
    );
    return normalized;
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

fn makeConfigLoaderSource(allocator: std.mem.Allocator, config_path: []const u8) ![]const u8 {
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(allocator);

    try source.appendSlice(allocator, "import * as configModule from ");
    try appendJsStringLiteral(allocator, &source, config_path);
    try source.appendSlice(allocator,
        \\;
        \\const loadedConfig = configModule.default ?? {};
        \\console.log(JSON.stringify(loadedConfig));
        \\
    );

    return try source.toOwnedSlice(allocator);
}

fn findDashConfig(init: std.process.Init, allocator: std.mem.Allocator) ![]const u8 {
    return (try bootstrap_pragma.findNearestConfig(init.io, allocator)) orelse
        error.DashConfigNotFound;
}

fn tempDir(init: std.process.Init, allocator: std.mem.Allocator) ![]const u8 {
    if (init.environ_map.get("TMPDIR")) |value| {
        return try allocator.dupe(u8, value);
    }

    if (init.environ_map.get("TEMP")) |value| {
        return try allocator.dupe(u8, value);
    }

    return try allocator.dupe(u8, "/tmp");
}

fn currentProcessId() u64 {
    return switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        else => @intCast(std.posix.system.getpid()),
    };
}

fn loadDashConfig(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    cottontail_path: []const u8,
) !Config {
    const config_path = try findDashConfig(init, allocator);
    const loader_source = try makeConfigLoaderSource(allocator, config_path);

    const tmp_root = try tempDir(init, allocator);
    const tmp_dir = try pathJoin(allocator, &.{ tmp_root, "dash" });
    try std.Io.Dir.cwd().createDirPath(init.io, tmp_dir);

    const loader_name = try std.fmt.allocPrint(
        allocator,
        "dash-config-loader-{d}.mjs",
        .{currentProcessId()},
    );
    const loader_path = try pathJoin(allocator, &.{ tmp_dir, loader_name });
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = loader_path,
        .data = loader_source,
    });
    defer std.Io.Dir.cwd().deleteFile(init.io, loader_path) catch {};

    const result = try std.process.run(allocator, init.io, .{
        .argv = &[_][]const u8{ cottontail_path, loader_path },
        .create_no_window = true,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (termExitCode(result.term) != 0) {
        if (result.stderr.len > 0) {
            var stderr_buffer: [2048]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
            const stderr = &stderr_writer.interface;
            try stderr.writeAll(result.stderr);
            try stderr.flush();
        }
        return error.DashConfigLoadFailed;
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \r\n\t");
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, trimmed, .{});

    return .{
        .raw_json = try allocator.dupe(u8, trimmed),
        .root = parsed,
    };
}

fn loadPackageJson(init: std.process.Init, allocator: std.mem.Allocator) !?Config {
    var current: []const u8 = try std.Io.Dir.cwd().realPathFileAlloc(
        init.io,
        ".",
        allocator,
    );
    while (true) {
        const package_path = try pathJoin(allocator, &.{ current, "package.json" });
        if (pathExists(init.io, package_path)) {
            const source = try std.Io.Dir.cwd().readFileAlloc(
                init.io,
                package_path,
                allocator,
                .limited(16 * 1024 * 1024),
            );
            const normalized = package_manager.lockfile.normalizeJsonc(
                allocator,
                source,
            ) catch return error.PackageJsonLoadFailed;
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, normalized, .{
                .duplicate_field_behavior = .use_last,
            }) catch return error.PackageJsonLoadFailed;

            return .{
                .raw_json = source,
                .root = parsed,
                .dir = current,
            };
        }
        const parent = std.fs.path.dirname(current) orelse return null;
        if (std.mem.eql(u8, parent, current)) return null;
        current = parent;
    }
}

fn getObjectField(value: std.json.Value, name: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |object| object.get(name),
        else => null,
    };
}

fn scriptLooksLikeEntrypoint(script: []const u8) bool {
    if (std.mem.indexOfAny(u8, script, " \t\r\n") != null) return false;
    return std.mem.endsWith(u8, script, ".js") or
        std.mem.endsWith(u8, script, ".mjs") or
        std.mem.endsWith(u8, script, ".ts") or
        std.mem.endsWith(u8, script, ".mts");
}

fn appendShellQuoted(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    if (builtin.os.tag == .windows) {
        try out.append(allocator, '"');
        for (value) |char| {
            if (char == '"') try out.append(allocator, '\\');
            try out.append(allocator, char);
        }
        try out.append(allocator, '"');
        return;
    }

    try out.append(allocator, '\'');
    for (value) |char| {
        if (char == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, char);
        }
    }
    try out.append(allocator, '\'');
}

fn shellCommandWithArgs(
    allocator: std.mem.Allocator,
    script: []const u8,
    script_args: []const [:0]const u8,
) ![]const u8 {
    var command: std.ArrayList(u8) = .empty;
    errdefer command.deinit(allocator);

    try command.appendSlice(allocator, script);
    for (script_args) |arg| {
        try command.append(allocator, ' ');
        try appendShellQuoted(allocator, &command, arg);
    }

    return try command.toOwnedSlice(allocator);
}

fn runShellScript(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    script: []const u8,
    script_args: []const [:0]const u8,
    lifecycle_name: ?[]const u8,
) !u8 {
    const command = try shellCommandWithArgs(allocator, script, script_args);
    const argv = if (builtin.os.tag == .windows)
        &[_][]const u8{ "cmd.exe", "/C", command }
    else
        &[_][]const u8{ "/bin/sh", "-c", command };

    var env = try init.environ_map.clone(allocator);
    defer env.deinit();

    const exe_dir = try std.process.executableDirPathAlloc(init.io, allocator);
    const local_bin = try pathJoin(allocator, &.{ "node_modules", ".bin" });
    const path_key = if (builtin.os.tag == .windows) "Path" else "PATH";
    const existing_path = env.get(path_key) orelse env.get("PATH") orelse "";
    const run_path = if (existing_path.len > 0)
        try std.fmt.allocPrint(
            allocator,
            "{s}{c}{s}{c}{s}",
            .{ exe_dir, std.fs.path.delimiter, local_bin, std.fs.path.delimiter, existing_path },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "{s}{c}{s}",
            .{ exe_dir, std.fs.path.delimiter, local_bin },
        );
    try env.put(path_key, run_path);

    if (lifecycle_name) |name| {
        try env.put("npm_lifecycle_event", name);
        try env.put("npm_lifecycle_script", script);
        try env.put("npm_command", "run-script");
    }

    var child = try std.process.spawn(init.io, .{
        .argv = argv,
        .environ_map = &env,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    defer child.kill(init.io);

    return termExitCode(try child.wait(init.io));
}

fn printScripts(writer: anytype, config: Config) !bool {
    const scripts = getObjectField(config.root, "scripts") orelse return false;

    return switch (scripts) {
        .object => |object| {
            var found = false;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (entry.value_ptr.* == .string) {
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
    const config = loadDashConfig(init, allocator, cottontail_path) catch |err| switch (err) {
        error.DashConfigNotFound => return null,
        else => return err,
    };
    const scripts = getObjectField(config.root, "scripts") orelse return null;
    const script = getObjectField(scripts, script_name) orelse return null;

    if (script != .string) {
        try stderr.print("hutch: script must be a string: {s}\n", .{script_name});
        return 1;
    }
    if (try loadPackageJson(init, allocator)) |package| {
        if (!try ensurePackageDependencies(init, package, stderr)) return 1;
    }

    const command = script.string;
    if (scriptLooksLikeEntrypoint(command)) {
        return try runCottontailScript(init, allocator, cottontail_path, command, script_args);
    }

    return try runShellScript(init, allocator, command, script_args, null);
}

fn packageHasDependencies(config: Config) bool {
    for ([_][]const u8{ "dependencies", "devDependencies", "optionalDependencies" }) |field| {
        const value = getObjectField(config.root, field) orelse continue;
        if (value == .object and value.object.count() > 0) return true;
    }
    return false;
}

fn ensurePackageDependencies(
    init: std.process.Init,
    package: Config,
    stderr: *std.Io.Writer,
) !bool {
    const node_modules = try pathJoin(
        init.arena.allocator(),
        &.{ package.dir, "node_modules" },
    );
    if (!packageHasDependencies(package) or pathExists(init.io, node_modules)) {
        return true;
    }

    try stderr.writeAll("hutch: installing package dependencies...\n");
    try stderr.flush();
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const package_dir = try init.arena.allocator().dupeZ(u8, package.dir);
    const install_args = [_][:0]const u8{
        "hutch",
        "install",
        "--cwd",
        package_dir,
    };
    const exit_code = try package_manager.cli.run(
        init,
        &install_args,
        &stdout_file_writer.interface,
        stderr,
    );
    return exit_code == 0;
}

fn runPackageStage(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    stage_name: []const u8,
    command: []const u8,
    script_args: []const [:0]const u8,
    stderr: anytype,
) !u8 {
    try stderr.print("$ {s}\n", .{command});
    try stderr.flush();
    return runShellScript(
        init,
        allocator,
        command,
        script_args,
        stage_name,
    );
}

fn runPackageScriptIfExists(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    script_name: []const u8,
    script_args: []const [:0]const u8,
    stderr: *std.Io.Writer,
    silent: bool,
    force_runtime: bool,
) !?u8 {
    const package = (try loadPackageJson(init, allocator)) orelse return null;
    const scripts = getObjectField(package.root, "scripts") orelse return null;
    const script = getObjectField(scripts, script_name) orelse return null;

    if (script != .string) {
        try stderr.print("hutch: script must be a string: {s}\n", .{script_name});
        return 1;
    }

    if (!try ensurePackageDependencies(
        init,
        package,
        stderr,
    )) return 1;

    return try package_manager.run.runSingleIfExists(
        init,
        script_name,
        script_args,
        silent,
        force_runtime,
    );
}

const PackageScriptInvocation = struct {
    name: []const u8,
    args: []const [:0]const u8,
    config_path: ?[]const u8,
    explicit_run: bool,
    force_runtime: bool,
    if_present: bool,
    silent: bool,
};

fn parsePackageScriptInvocation(
    init: std.process.Init,
    args: []const [:0]const u8,
) !?PackageScriptInvocation {
    if (args.len < 2) return null;

    var index: usize = 1;
    var explicit_run = false;
    var config_path: ?[]const u8 = null;
    var force_runtime = false;
    var if_present = false;
    var silent = false;
    while (index < args.len) {
        const arg: []const u8 = args[index];
        if (!explicit_run and std.mem.eql(u8, arg, "run")) {
            explicit_run = true;
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--silent")) {
            silent = true;
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--bun") or std.mem.eql(u8, arg, "-b")) {
            force_runtime = true;
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--if-present")) {
            if_present = true;
            index += 1;
            continue;
        }
        if ((std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) and
            index + 1 < args.len)
        {
            config_path = args[index + 1];
            index += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-c=")) {
            config_path = arg["-c=".len..];
            index += 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--config=")) {
            config_path = arg["--config=".len..];
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--cwd")) {
            if (index + 1 >= args.len) return null;
            try std.process.setCurrentPath(init.io, args[index + 1]);
            index += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--cwd=")) {
            try std.process.setCurrentPath(init.io, arg["--cwd=".len..]);
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--shell")) {
            if (index + 1 >= args.len) return null;
            index += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--shell=")) {
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (std.mem.startsWith(u8, arg, "-")) return null;
        return .{
            .name = arg,
            .args = args[index + 1 ..],
            .config_path = config_path,
            .explicit_run = explicit_run,
            .force_runtime = force_runtime,
            .if_present = if_present,
            .silent = silent,
        };
    }
    return null;
}

fn runReleaseCommand(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    product: release_store.Product,
    args: []const [:0]const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    if (args.len == 0 or isHelpFlag(args[0])) {
        const namespace = if (product == .hutch) "self" else "cottontail";
        try stderr.print(
            "Usage: hutch {s} <path|version|update> [production|canary|<semver>|build:<revision>]\n",
            .{namespace},
        );
        return if (args.len == 0) 1 else 0;
    }
    if (args.len > 2) {
        try stderr.print("hutch {s}: too many arguments\n", .{product.name()});
        return 1;
    }

    const operation = args[0];
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
        version_selector.parse(channel) catch unreachable;
    const refresh = std.mem.eql(u8, operation, "update");
    if (!refresh and
        !std.mem.eql(u8, operation, "path") and
        !std.mem.eql(u8, operation, "version"))
    {
        try stderr.print("hutch {s}: unknown command: {s}\n", .{ product.name(), operation });
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

    if (std.mem.eql(u8, operation, "path")) {
        try stdout.print("{s}\n", .{resolution.executable});
    } else if (std.mem.eql(u8, operation, "version")) {
        try stdout.print("{s}\n", .{resolution.version});
    } else {
        try stdout.print(
            "{s} {s}@{s} is active for {s}\n",
            .{ product.name(), resolution.version, resolution.revision, selector.channel() orelse "this project" },
        );
    }
    return 0;
}

fn activeReleaseChannel(environment: *const std.process.Environ.Map) ![]const u8 {
    const channel = environment.get("HUTCH_ACTIVE_CHANNEL") orelse "production";
    if (!std.mem.eql(u8, channel, "production") and !std.mem.eql(u8, channel, "canary")) {
        return error.InvalidReleaseChannel;
    }
    return channel;
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

    for ([_]release_store.Product{ .hutch, .cottontail }) |product| {
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

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var args = try init.minimal.args.toSlice(allocator);
    args = try normalizeLeadingPackageManagerConfig(allocator, args);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    if (args.len <= 1) {
        try printHelp(stdout);
        try stdout.flush();
        return;
    }

    const command = args[1];

    if (isHelpFlag(command)) {
        try printHelp(stdout);
        try stdout.flush();
        return;
    }

    if (isVersionFlag(command)) {
        try stdout.print("{s}\n", .{version});
        try stdout.flush();
        return;
    }

    if (runtime_autoinstall.parseLeadingInvocation(args)) |invocation| {
        const entrypoint = args[invocation.entry_index];
        if (pathExists(init.io, entrypoint)) {
            if (!try prepareRuntimeAutoInstall(init, entrypoint, invocation.mode, stderr)) {
                std.process.exit(1);
            }
            const cottontail = resolveCottontail(init, allocator, args[1..]) catch |err| {
                try stderr.print("hutch: could not resolve Cottontail: {s}\n", .{@errorName(err)});
                try stderr.flush();
                std.process.exit(1);
            };
            const exit_code = try runCottontailCommand(
                init,
                allocator,
                cottontail.executable,
                args[1..],
            );
            if (exit_code != 0) std.process.exit(exit_code);
            return;
        }
    }

    if (package_manager.bunx.detectInvocation(
        args,
        init.environ_map.get("BUN_INTERNAL_BUNX_INSTALL") != null,
        init.environ_map.get("HUTCH_LAUNCHER_PATH"),
    )) |invocation| {
        const exit_code = try package_manager.bunx.run(
            init,
            args,
            invocation,
            stdout,
            stderr,
        );
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    }

    const is_release_command = std.mem.eql(u8, command, "self") or
        std.mem.eql(u8, command, "cottontail");
    if (!is_release_command) {
        try maybePromptForUpdates(init, allocator, stderr);
    }

    if (std.mem.eql(u8, command, "self") or std.mem.eql(u8, command, "cottontail")) {
        const product: release_store.Product = if (std.mem.eql(u8, command, "self"))
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
        try stdout.flush();
        try stderr.flush();
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    }

    if (std.mem.eql(u8, command, "upgrade") and
        std.mem.eql(
            u8,
            init.environ_map.get("COTTONTAIL_UPSTREAM_RUNTIME") orelse "",
            "bun",
        ))
    {
        const exit_code = try package_manager.upgrade.run(init, args, stdout, stderr);
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    }

    if (package_manager.cli.recognizes(command)) {
        const exit_code = try package_manager.cli.run(init, args, stdout, stderr);
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    }

    if (try package_manager.run.tryRun(init, args)) |exit_code| {
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    }

    const may_be_package_script = std.mem.eql(u8, command, "run") or
        std.mem.eql(u8, command, "--silent") or
        std.mem.eql(u8, command, "--bun") or
        std.mem.eql(u8, command, "-b") or
        std.mem.eql(u8, command, "--if-present") or
        std.mem.eql(u8, command, "-c") or
        std.mem.eql(u8, command, "--config") or
        std.mem.startsWith(u8, command, "-c=") or
        std.mem.startsWith(u8, command, "--config=") or
        std.mem.eql(u8, command, "--cwd") or
        std.mem.startsWith(u8, command, "--cwd=") or
        std.mem.eql(u8, command, "--shell") or
        std.mem.startsWith(u8, command, "--shell=");
    if (may_be_package_script) {
        if (try parsePackageScriptInvocation(init, args)) |invocation| {
            const configured = try package_manager.run.configuredRun(
                init,
                invocation.config_path,
                invocation.silent,
                invocation.force_runtime,
            );
            const cottontail = resolveCottontail(init, allocator, args[1..]) catch |err| {
                try stderr.print("hutch: could not resolve Cottontail: {s}\n", .{@errorName(err)});
                try stderr.flush();
                std.process.exit(1);
            };
            if (try runConfiguredScriptIfExists(
                init,
                allocator,
                cottontail.executable,
                invocation.name,
                invocation.args,
                stderr,
            )) |exit_code| {
                try stderr.flush();
                if (exit_code != 0) std.process.exit(exit_code);
                return;
            }
            if (try runPackageScriptIfExists(
                init,
                allocator,
                invocation.name,
                invocation.args,
                stderr,
                configured.silent,
                configured.force_runtime,
            )) |exit_code| {
                try stderr.flush();
                if (exit_code != 0) std.process.exit(exit_code);
                return;
            }
            if (invocation.if_present) return;
            if (pathExists(init.io, invocation.name)) {
                if (!try prepareRuntimeAutoInstall(init, invocation.name, .auto, stderr)) {
                    std.process.exit(1);
                }
                const exit_code = try runCottontailScript(
                    init,
                    allocator,
                    cottontail.executable,
                    invocation.name,
                    invocation.args,
                );
                if (exit_code != 0) std.process.exit(exit_code);
                return;
            }
            if (package_manager.run.commandExists(init, invocation.name)) {
                const exit_code = try package_manager.run.runSingleCommand(
                    init,
                    invocation.name,
                    invocation.args,
                    configured.silent,
                );
                if (exit_code != 0) std.process.exit(exit_code);
                return;
            }
            try stderr.print("error: Script not found \"{s}\"\n", .{invocation.name});
            try stderr.flush();
            std.process.exit(1);
        }
    }

    if (std.mem.eql(u8, command, "run")) {
        const cottontail = resolveCottontail(init, allocator, args[1..]) catch |err| {
            try stderr.print("hutch: could not resolve Cottontail: {s}\n", .{@errorName(err)});
            try stderr.flush();
            std.process.exit(1);
        };
        const cottontail_path = cottontail.executable;
        if (args.len > 2 and pathExists(init.io, args[2])) {
            if (!try prepareRuntimeAutoInstall(init, args[2], .auto, stderr)) {
                std.process.exit(1);
            }
        }

        if (args.len <= 2) {
            const config = loadDashConfig(init, allocator, cottontail_path) catch |err| switch (err) {
                error.DashConfigNotFound => null,
                else => {
                    try stderr.print("hutch: failed to load dash.config.ts\n", .{});
                    try stderr.flush();
                    std.process.exit(1);
                },
            };
            if (config) |loaded| {
                if (try printScripts(stdout, loaded)) {
                    try stdout.flush();
                    return;
                }
            }
            if (try loadPackageJson(init, allocator)) |package| {
                if (try printScripts(stdout, package)) {
                    try stdout.flush();
                    return;
                }
            }
        } else {
            if (try runConfiguredScriptIfExists(init, allocator, cottontail_path, args[2], args[3..], stderr)) |exit_code| {
                try stderr.flush();
                if (exit_code != 0) std.process.exit(exit_code);
                return;
            }
            if (try runPackageScriptIfExists(init, allocator, args[2], args[3..], stderr, false, false)) |exit_code| {
                try stderr.flush();
                if (exit_code != 0) std.process.exit(exit_code);
                return;
            }
            const requested: []const u8 = args[2];
            const path_like = std.mem.indexOfScalar(u8, requested, '/') != null or
                std.mem.indexOfScalar(u8, requested, '\\') != null or
                std.fs.path.extension(requested).len > 0;
            if (!path_like and !pathExists(init.io, requested)) {
                try stderr.print("error: Script not found \"{s}\"\n", .{requested});
                try stderr.flush();
                std.process.exit(1);
            }
        }

        const exit_code = try runCottontailCommand(init, allocator, cottontail_path, args[1..]);
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    }

    if (std.mem.eql(u8, command, "electrobun")) {
        const cottontail = resolveCottontail(init, allocator, args[1..]) catch |err| {
            try stderr.print("hutch: could not resolve Cottontail: {s}\n", .{@errorName(err)});
            try stderr.flush();
            std.process.exit(1);
        };
        const exit_code = try electrobun.run(
            init,
            args[2..],
            cottontail.executable,
            cottontail.root,
        );
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    }

    if (std.mem.eql(u8, command, "init")) {
        const exit_code = try package_manager.init.run(init, args[2..], stdout, stderr);
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    }

    if (std.mem.eql(u8, command, "create") or std.mem.eql(u8, command, "c")) {
        if (try package_manager.create_source.tryRun(init, args, stdout, stderr)) |result| {
            switch (result) {
                .exit_code => |exit_code| {
                    if (exit_code != 0) std.process.exit(exit_code);
                    return;
                },
                .start_dev => {
                    const exit_code = (try runPackageScriptIfExists(
                        init,
                        allocator,
                        "dev",
                        &.{},
                        stderr,
                        false,
                        false,
                    )) orelse {
                        try stderr.writeAll("error: Script not found \"dev\"\n");
                        try stderr.flush();
                        std.process.exit(1);
                    };
                    if (exit_code != 0) std.process.exit(exit_code);
                    return;
                },
            }
        }
        const exit_code = try package_manager.create.run(init, args, stdout, stderr);
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    }

    if (std.mem.eql(u8, command, "build")) {
        const cottontail = resolveCottontail(init, allocator, args[1..]) catch |err| {
            try stderr.print("hutch: could not resolve Cottontail: {s}\n", .{@errorName(err)});
            try stderr.flush();
            std.process.exit(1);
        };
        const exit_code = try runCottontailCommand(init, allocator, cottontail.executable, args[1..]);
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    }

    if ((std.mem.eql(u8, command, "-e") or
        std.mem.eql(u8, command, "--eval") or
        std.mem.eql(u8, command, "-p") or
        std.mem.eql(u8, command, "--print")) and args.len > 2)
    {
        runtime_autoinstall.prepareSource(init, args[2], .auto, stderr) catch |err| {
            if (err != error.AutoInstallFailed) {
                try stderr.print("hutch: dependency preflight failed: {s}\n", .{@errorName(err)});
            }
            try stderr.flush();
            std.process.exit(1);
        };
        const cottontail = resolveCottontail(init, allocator, args[1..]) catch |err| {
            try stderr.print("hutch: could not resolve Cottontail: {s}\n", .{@errorName(err)});
            try stderr.flush();
            std.process.exit(1);
        };
        const exit_code = try runCottontailCommand(
            init,
            allocator,
            cottontail.executable,
            args[1..],
        );
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    }

    if (try printBinaryLockfile(init, command, stdout)) return;

    if (pathExists(init.io, command)) {
        if (!try prepareRuntimeAutoInstall(init, command, .auto, stderr)) {
            std.process.exit(1);
        }
        const cottontail = resolveCottontail(init, allocator, args[1..]) catch |err| {
            try stderr.print("hutch: could not resolve Cottontail: {s}\n", .{@errorName(err)});
            try stderr.flush();
            std.process.exit(1);
        };
        const exit_code = try runCottontailScript(init, allocator, cottontail.executable, command, args[2..]);
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    }

    if (findDashConfig(init, allocator)) |_| {
        const cottontail = resolveCottontail(init, allocator, args[1..]) catch |err| {
            try stderr.print("hutch: could not resolve Cottontail: {s}\n", .{@errorName(err)});
            try stderr.flush();
            std.process.exit(1);
        };
        if (try runConfiguredScriptIfExists(init, allocator, cottontail.executable, command, args[2..], stderr)) |exit_code| {
            try stderr.flush();
            if (exit_code != 0) std.process.exit(exit_code);
            return;
        }
    } else |err| switch (err) {
        error.DashConfigNotFound => {},
        else => return err,
    }

    if (try runPackageScriptIfExists(init, allocator, command, args[2..], stderr, false, false)) |exit_code| {
        try stderr.flush();
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    }
    if (package_manager.run.commandExists(init, command)) {
        const exit_code = try package_manager.run.runSingleCommand(
            init,
            command,
            args[2..],
            true,
        );
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    }
    const path_like = std.mem.indexOfAny(u8, command, "/\\") != null or
        std.fs.path.extension(command).len > 0;
    if (!path_like) {
        try stderr.print("error: Script not found \"{s}\"\n", .{command});
        try stderr.flush();
        std.process.exit(1);
    }
    const cottontail = resolveCottontail(init, allocator, args[1..]) catch |err| {
        try stderr.print("hutch: could not resolve Cottontail: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
    };
    const exit_code = try runCottontailCommand(init, allocator, cottontail.executable, args[1..]);
    if (exit_code != 0) std.process.exit(exit_code);
}

test "help text describes dash config scripts" {
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "hutch run") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "hutch install") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "<script-name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "dash.config.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "package.json") != null);
}

test "package dependency detection drives clean checkout bootstrap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const with_dependencies = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        \\{"dependencies":{"electrobun":"latest"}}
    ,
        .{},
    );
    try std.testing.expect(packageHasDependencies(.{
        .raw_json = "",
        .root = with_dependencies,
    }));

    const without_dependencies = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        \\{"scripts":{"dev":"hutch electrobun dev"}}
    ,
        .{},
    );
    try std.testing.expect(!packageHasDependencies(.{
        .raw_json = "",
        .root = without_dependencies,
    }));
}

test "package manager commands accept leading Bun configuration flags" {
    const args = [_][:0]const u8{ "hutch", "--save", "ci" };
    const normalized = try normalizeLeadingPackageManagerConfig(
        std.testing.allocator,
        &args,
    );
    defer if (normalized.ptr != args[0..].ptr)
        std.testing.allocator.free(normalized);

    try std.testing.expectEqualStrings("ci", normalized[1]);
    try std.testing.expectEqualStrings("--save", normalized[2]);
}
