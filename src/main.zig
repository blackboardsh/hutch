const std = @import("std");
const builtin = @import("builtin");
const bootstrap_pragma = @import("bootstrap_pragma.zig");
const electrobun = @import("electrobun.zig");
const package_manager_adapter = @import("package_manager_adapter.zig");
const process_replace = @import("process_replace.zig");
const release_store = @import("release_store.zig");
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
    \\  hutch install [package-manager-options...]
    \\  hutch pm [package-manager-arguments...]
    \\  hutch run [--if-configured] [script-name] [args...]
    \\  hutch test [files/options...]
    \\  hutch build [args...]
    \\  hutch self <path|version|update> [selector]
    \\  hutch cottontail <path|version|update> [selector]
    \\  hutch --help
    \\  hutch --version
    \\
    \\Config:
    \\  Scripts are resolved only from hutch.config.ts.
    \\  Script values may be shell strings or non-empty argv string arrays.
    \\  packageManager selects npm (default), bun, pnpm, yarn, or an explicit executable.
    \\  Hutch delegates package-manager argv and never resolves package.json dependencies.
    \\  Test files and options are forwarded to the selected Cottontail runtime.
    \\
;

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
        "import { writeFileSync as __hutchWriteConfig } from \"node:fs\";\nimport * as configModule from ",
    );
    try appendJsStringLiteral(allocator, &source, config_path);
    try source.appendSlice(allocator,
        \\;
        \\const loadedConfig = configModule.default ?? {};
        \\__hutchWriteConfig(
    );
    try appendJsStringLiteral(allocator, &source, result_path);
    try source.appendSlice(allocator, ", JSON.stringify(loadedConfig));\n");

    return try source.toOwnedSlice(allocator);
}

fn findHutchConfig(init: std.process.Init, allocator: std.mem.Allocator) ![]const u8 {
    return (try bootstrap_pragma.findNearestConfig(init.io, allocator)) orelse
        error.HutchConfigNotFound;
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

fn loadHutchConfig(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    cottontail_path: []const u8,
) !Config {
    const config_path = try findHutchConfig(init, allocator);
    const tmp_dir = try createPrivateTempDirectory(init, allocator, "hutch-config-loader-");
    defer std.Io.Dir.cwd().deleteTree(init.io, tmp_dir) catch {};
    const loader_path = try pathJoin(allocator, &.{ tmp_dir, "load.mjs" });
    const result_path = try pathJoin(allocator, &.{ tmp_dir, "config.json" });
    const loader_source = try makeConfigLoaderSource(allocator, config_path, result_path);
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = loader_path,
        .data = loader_source,
    });

    const execution = try std.process.run(allocator, init.io, .{
        .argv = &[_][]const u8{ cottontail_path, loader_path },
        .create_no_window = true,
    });
    defer allocator.free(execution.stdout);
    defer allocator.free(execution.stderr);

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

    const result = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        result_path,
        allocator,
        .limited(1024 * 1024),
    );
    const trimmed = std.mem.trim(u8, result, " \r\n\t");
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, trimmed, .{});

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

fn createPrivateTempDirectory(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    prefix: []const u8,
) ![]const u8 {
    const permissions: std.Io.Dir.Permissions = if (builtin.os.tag == .windows)
        .default_dir
    else
        @enumFromInt(0o700);
    const tmp_root = try tempDir(init, allocator);

    var attempt: usize = 0;
    while (attempt < 16) : (attempt += 1) {
        var random_bytes: [12]u8 = undefined;
        init.io.random(&random_bytes);
        var random_name: [std.base64.url_safe.Encoder.calcSize(random_bytes.len)]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&random_name, &random_bytes);

        const path = try std.fs.path.join(allocator, &.{
            tmp_root,
            try std.mem.concat(allocator, u8, &.{ prefix, &random_name }),
        });
        std.Io.Dir.cwd().createDir(init.io, path, permissions) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return path;
    }

    return error.TemporaryDirectoryCollision;
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

fn createShellLauncherShim(
    init: std.process.Init,
    allocator: std.mem.Allocator,
) !?[]const u8 {
    const launcher = init.environ_map.get("HUTCH_LAUNCHER_PATH") orelse return null;
    const stat = std.Io.Dir.cwd().statFile(init.io, launcher, .{}) catch
        return error.ConfiguredLauncherNotFound;
    if (stat.kind != .file) return error.ConfiguredLauncherIsNotAFile;

    const shim_dir = try createPrivateTempDirectory(init, allocator, "hutch-shell-launcher-");
    errdefer std.Io.Dir.cwd().deleteTree(init.io, shim_dir) catch {};

    const shim_path = try std.fs.path.join(allocator, &.{
        shim_dir,
        if (builtin.os.tag == .windows) "hutch.exe" else "hutch",
    });
    try std.Io.Dir.copyFile(
        std.Io.Dir.cwd(),
        launcher,
        std.Io.Dir.cwd(),
        shim_path,
        init.io,
        .{ .permissions = .executable_file },
    );
    return shim_dir;
}

fn runShellScript(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    script: []const u8,
    script_args: []const [:0]const u8,
) !u8 {
    const command = try shellCommandWithArgs(allocator, script, script_args);
    const argv = if (builtin.os.tag == .windows)
        &[_][]const u8{ "cmd.exe", "/C", command }
    else
        &[_][]const u8{ "/bin/sh", "-c", command };

    const launcher_shim = try createShellLauncherShim(init, allocator);
    defer if (launcher_shim) |directory| {
        std.Io.Dir.cwd().deleteTree(init.io, directory) catch {};
    };

    var env = try configuredScriptEnvironment(init, allocator, launcher_shim);
    defer env.deinit();

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
        .string => |command| if (scriptLooksLikeEntrypoint(command))
            try runCottontailScript(init, allocator, cottontail_path, command, script_args)
        else
            try runShellScript(init, allocator, command, script_args),
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
    if (args.len == 0 or isHelpFlag(args[0])) {
        const namespace = if (product == .hutch) "self" else "cottontail";
        try stderr.print(
            "Usage: hutch {s} <path|version|update> [production|stable|canary|<semver>|build:<revision>]\n",
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
    return version_selector.normalizeChannel(channel);
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

fn forwardToCottontail(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    command_args: []const [:0]const u8,
    stderr: *std.Io.Writer,
) !u8 {
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

fn resolvePackageManager(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    stderr: *std.Io.Writer,
) !?package_manager_adapter.Selection {
    if (findHutchConfig(init, allocator)) |_| {
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
        return package_manager_adapter.fromConfig(config.root) catch |err| {
            switch (err) {
                error.UnsupportedPackageManager => try stderr.writeAll(
                    "hutch: unsupported packageManager in hutch.config.ts; expected npm, bun, pnpm, or yarn\n",
                ),
                error.InvalidPackageManagerConfig => try stderr.writeAll(
                    "hutch: packageManager must be npm, bun, pnpm, yarn, or { name, executable? }\n",
                ),
            }
            return null;
        };
    } else |err| switch (err) {
        error.HutchConfigNotFound => return package_manager_adapter.defaultSelection(),
        else => return err,
    }
}

fn runPackageManager(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    subcommand: ?[]const u8,
    forwarded_args: []const [:0]const u8,
    stderr: *std.Io.Writer,
) !u8 {
    const selection = (try resolvePackageManager(init, allocator, stderr)) orelse return 1;
    const term = package_manager_adapter.run(
        init,
        allocator,
        selection,
        subcommand,
        forwarded_args,
    ) catch |err| {
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
        try stdout.print("{s}\n", .{version});
        try stdout.flush();
        return;
    }

    const is_release_command = std.mem.eql(u8, command, "self") or
        std.mem.eql(u8, command, "cottontail");
    if (!is_release_command) {
        try maybePromptForUpdates(init, allocator, stderr);
    }

    if (is_release_command) {
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

    if (std.mem.startsWith(u8, command, "-") or
        isReservedRuntimeCommand(command) or
        (isBunCliFacade(init.environ_map) and
            (std.mem.eql(u8, command, "getcompletes") or isFakeNodeInvocation(args))))
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

    if (std.mem.eql(u8, command, "install") or std.mem.eql(u8, command, "pm")) {
        const exit_code = try runPackageManager(
            init,
            allocator,
            if (std.mem.eql(u8, command, "install")) "install" else null,
            args[2..],
            stderr,
        );
        try stderr.flush();
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    }

    if (std.mem.eql(u8, command, "run")) {
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

    if (pathExists(init.io, command) or runtimeDiagnosticEligible(command)) {
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
            command,
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

    if (std.mem.eql(u8, command, "build")) {
        const exit_code = try forwardToCottontail(
            init,
            allocator,
            args[1..],
            stderr,
        );
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    }

    try stderr.print("error: Script not found \"{s}\"\n", .{command});
    try stderr.flush();
    std.process.exit(1);
}
test "help text describes hutch config scripts" {
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "hutch run") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "--if-configured") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "hutch test [files/options...]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "hutch install") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "hutch pm") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "packageManager") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "<script-name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "hutch.config.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "dash.config.ts") == null);
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "package.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text_template, "argv string arrays") != null);
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
