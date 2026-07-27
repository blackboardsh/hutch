const std = @import("std");
const builtin = @import("builtin");

const load_config_template = @embedFile("electrobun_cli/load_config_helper.js");
const run_hook_template = @embedFile("electrobun_cli/run_hook_helper.js");
const build_helper_template = @embedFile("electrobun_cli/build_helper.js");

const MainProcess = enum {
    bun,
    cottontail,
    zig,
    rust,
    go,
    odin,
};

const BuildEnvironment = enum {
    dev,
    canary,
    production,
};

const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    self_exe_path: []const u8,
    cottontail_home: []const u8,
    cottontail_binary: []const u8,
    project_root: []const u8,

    fn writeStdout(self: *const Context, comptime fmt: []const u8, args: anytype) void {
        var buffer: [2048]u8 = undefined;
        var writer = std.Io.File.stdout().writer(self.io, &buffer);
        const stdout = &writer.interface;
        stdout.print(fmt, args) catch {};
        stdout.flush() catch {};
    }

    fn writeStderr(self: *const Context, comptime fmt: []const u8, args: anytype) void {
        var buffer: [2048]u8 = undefined;
        var writer = std.Io.File.stderr().writer(self.io, &buffer);
        const stderr = &writer.interface;
        stderr.print(fmt, args) catch {};
        stderr.flush() catch {};
    }
};

const CommandContext = struct {
    raw_json: []const u8,
    root: std.json.Value,
    build_env: BuildEnvironment,
};

const AppBundlePaths = struct {
    build_root: []const u8,
    bundle_root: []const u8,
    exec_dir: []const u8,
    resources_dir: []const u8,
    frameworks_dir: ?[]const u8,
    app_code_dir: []const u8,
};

const PlatformPaths = struct {
    package_root: []const u8,
    shared_dist_dir: []const u8,
    platform_dist_dir: []const u8,
    launcher: []const u8,
    bun_binary: []const u8,
    main_js: []const u8,
    preload_full_js: []const u8,
    preload_sandboxed_js: []const u8,
    core_lib: []const u8,
    native_wrapper: []const u8,
    native_wrapper_cef: []const u8,
    libasar: []const u8,
    process_helper: []const u8,
    cef_dir: []const u8,
    wgpu_lib: []const u8,
    extractor: []const u8,
    bsdiff: []const u8,
    bspatch: []const u8,
    zig_zstd: []const u8,
};

const ReleaseState = struct {
    bundle: AppBundlePaths,
    hash: []const u8,
    compressed_tar_path: []const u8,
    patch_path: ?[]const u8,
};

pub fn forceLink() void {}

pub fn run(
    init: std.process.Init,
    args: []const [:0]const u8,
    cottontail_binary: []const u8,
    cottontail_home: []const u8,
) !u8 {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    if (args.len == 0 or isHelpFlag(args[0])) {
        try printHelp(stdout);
        try stdout.flush();
        return 0;
    }

    const self_exe_path = try std.process.executablePathAlloc(init.io, init.arena.allocator());
    const project_root = try std.Io.Dir.cwd().realPathFileAlloc(init.io, ".", init.arena.allocator());

    const ctx = Context{
        .io = init.io,
        .allocator = init.arena.allocator(),
        .environ_map = init.environ_map,
        .self_exe_path = self_exe_path,
        .cottontail_home = cottontail_home,
        .cottontail_binary = cottontail_binary,
        .project_root = project_root,
    };

    const command = args[0];

    if (std.mem.eql(u8, command, "config")) {
        const config = try loadConfig(&ctx, parseBuildEnvironment(args[1..]));
        ctx.writeStdout("{s}\n", .{config.raw_json});
        return 0;
    }

    if (std.mem.eql(u8, command, "init")) {
        try runInit(&ctx, args[1..]);
        return 0;
    }

    if (std.mem.eql(u8, command, "build")) {
        const config = try loadConfig(&ctx, parseBuildEnvironment(args[1..]));
        try runBuild(&ctx, config);
        return 0;
    }

    if (std.mem.eql(u8, command, "run")) {
        const config = try loadConfig(&ctx, parseBuildEnvironment(args[1..]));
        try runBuiltApp(&ctx, config);
        return 0;
    }

    if (std.mem.eql(u8, command, "dev")) {
        if (hasFlag(args[1..], "--watch")) {
            const config = try loadConfig(&ctx, parseBuildEnvironment(args[1..]));
            try runDevWatch(&ctx, config);
            return 0;
        }

        const config = try loadConfig(&ctx, parseBuildEnvironment(args[1..]));
        try runBuild(&ctx, config);
        try runBuiltApp(&ctx, config);
        return 0;
    }

    try stderr.print("hutch electrobun: unknown command: {s}\n", .{command});
    try printHelp(stderr);
    try stderr.flush();
    return 1;
}

fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\hutch electrobun
        \\Electrobun app build commands orchestrated by Hutch.
        \\
        \\Usage:
        \\  hutch electrobun init [project-name] [--template=name]
        \\  hutch electrobun config [--env=dev|canary|production]
        \\  hutch electrobun build [--env=dev|canary|production]
        \\  hutch electrobun run [--env=dev|canary|production]
        \\  hutch electrobun dev [--env=dev|canary|production] [--watch]
        \\
        \\Notes:
        \\  - esbuild is vendored automatically on first use as a native binary.
        \\  - hook scripts are transpiled and executed by Cottontail through Hutch.
        \\  - init copies templates from the installed electrobun package.
        \\
    );
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

fn hasFlag(args: []const [:0]const u8, flag: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

fn parseBuildEnvironment(args: []const [:0]const u8) BuildEnvironment {
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--env=")) {
            const value = arg["--env=".len..];
            if (std.mem.eql(u8, value, "canary")) return .canary;
            if (std.mem.eql(u8, value, "production")) return .production;
            return .dev;
        }
    }

    return .dev;
}

fn environmentFlagEnabled(environ_map: *const std.process.Environ.Map, name: []const u8) bool {
    const value = environ_map.get(name) orelse return false;
    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes");
}

fn resolvePathForCwd(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        return try allocator.dupe(u8, path);
    }
    return try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
}

fn pathExists(io: std.Io, absolute_path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, absolute_path, .{}) catch return false;
    return true;
}

fn loadConfig(ctx: *const Context, build_env: BuildEnvironment) !CommandContext {
    const tmp_dir = try ensureCliTempDir(ctx);
    const config_source_path = findConfigPath(ctx);
    const empty_config_path = try std.fs.path.join(ctx.allocator, &.{ tmp_dir, "electrobun-config.empty.mjs" });
    const wrapper_path = try std.fs.path.join(ctx.allocator, &.{ tmp_dir, "electrobun-config.loader.mjs" });

    const config_module_path = config_source_path orelse blk: {
        try std.Io.Dir.cwd().writeFile(ctx.io, .{
            .sub_path = empty_config_path,
            .data = "export default {};\n",
        });
        break :blk empty_config_path;
    };

    const config_module_literal = try jsonStringLiteral(ctx, config_module_path);

    const helper_source = try std.mem.replaceOwned(
        u8,
        ctx.allocator,
        load_config_template,
        "__MODULE_NAME__",
        config_module_literal,
    );

    try std.Io.Dir.cwd().writeFile(ctx.io, .{
        .sub_path = wrapper_path,
        .data = helper_source,
    });

    var env_map = std.process.Environ.Map.init(ctx.allocator);
    defer env_map.deinit();
    try inheritCurrentEnvironmentFromContext(ctx, &env_map);
    try env_map.put("ELECTROBUN_BUILD_ENV", buildEnvironmentName(build_env));
    try env_map.put("ELECTROBUN_OS", osName());
    try env_map.put("ELECTROBUN_ARCH", archName());

    const env_arg = try std.fmt.allocPrint(ctx.allocator, "--env={s}", .{buildEnvironmentName(build_env)});
    const result = try std.process.run(ctx.allocator, ctx.io, .{
        .argv = &[_][]const u8{ try resolveCottontailBinary(ctx), wrapper_path, env_arg },
        .cwd = .{ .path = tmp_dir },
        .environ_map = &env_map,
        .create_no_window = true,
    });
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);

    if (termExitCode(result.term) != 0) {
        if (result.stderr.len > 0) ctx.writeStderr("{s}", .{result.stderr});
        return error.ConfigLoadFailed;
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \r\n\t");
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, ctx.allocator, trimmed, .{});

    return .{
        .raw_json = try ctx.allocator.dupe(u8, trimmed),
        .root = parsed,
        .build_env = build_env,
    };
}

fn runBuild(ctx: *const Context, config: CommandContext) !void {
    const build_root = try buildOutputRoot(ctx, config);
    try recreateDir(ctx, build_root);

    try runHook(ctx, config, "preBuild", null);

    const main_process = getMainProcess(config.root);
    switch (main_process) {
        .bun, .cottontail, .zig, .rust, .go, .odin => try buildBundledElectrobunApp(ctx, config),
    }

    if (config.build_env == .dev) {
        try runHook(ctx, config, "postPackage", null);
        ctx.writeStdout("electrobun build complete: {s}\n", .{build_root});
        return;
    }

    const release_state = try prepareRelease(ctx, config);
    var wrapper_env = std.process.Environ.Map.init(ctx.allocator);
    defer wrapper_env.deinit();
    try wrapper_env.put("ELECTROBUN_WRAPPER_BUNDLE_PATH", release_state.bundle.bundle_root);
    try runHook(ctx, config, "postWrap", &wrapper_env);
    try finishRelease(ctx, config, release_state);
    try runHook(ctx, config, "postPackage", null);

    ctx.writeStdout("electrobun build complete: {s}\n", .{build_root});
}

const max_release_download_bytes = 2 * 1024 * 1024 * 1024;

const BundleHashEntry = struct {
    relative_path: []const u8,

    fn lessThan(_: void, lhs: BundleHashEntry, rhs: BundleHashEntry) bool {
        return std.mem.order(u8, lhs.relative_path, rhs.relative_path) == .lt;
    }
};

fn prepareRelease(ctx: *const Context, config: CommandContext) !ReleaseState {
    const platform_paths = try getPlatformPaths(ctx);
    const bundle = try appBundlePaths(ctx, config);
    const hash = try hashBundle(ctx, bundle.bundle_root);
    try writeVersionMetadata(ctx, config, bundle, hash);

    if (shouldCodesign(config)) {
        const entitlements_path = try writeEntitlementsFile(ctx, config);
        try codesignBundle(ctx, config, bundle.bundle_root, entitlements_path);
        if (shouldNotarize(ctx, config)) {
            try notarizeAndStaple(ctx, bundle.bundle_root);
        }
    }

    const app_file_name = try artifactAppFileName(ctx, config);
    const tar_name = if (builtin.os.tag == .macos)
        try std.mem.concat(ctx.allocator, u8, &.{ app_file_name, ".app.tar" })
    else
        try std.mem.concat(ctx.allocator, u8, &.{ app_file_name, ".tar" });
    const tar_path = try std.fs.path.join(ctx.allocator, &.{ bundle.build_root, tar_name });
    try createBundleTar(ctx, bundle.bundle_root, tar_path);

    const patch_path = try generateDeltaPatch(ctx, config, platform_paths, tar_path);
    const compressed_tar_path = try std.mem.concat(ctx.allocator, u8, &.{ tar_path, ".zst" });
    try compressTar(ctx, platform_paths.zig_zstd, tar_path, compressed_tar_path);
    std.Io.Dir.cwd().deleteFile(ctx.io, tar_path) catch {};

    try createOuterWrapper(ctx, config, bundle, platform_paths, hash, compressed_tar_path);

    return .{
        .bundle = bundle,
        .hash = hash,
        .compressed_tar_path = compressed_tar_path,
        .patch_path = patch_path,
    };
}

fn artifactAppFileName(ctx: *const Context, config: CommandContext) ![]const u8 {
    const app_name = try getAppName(ctx, config.root);
    const sanitized = try removeAsciiSpaces(ctx.allocator, app_name);
    return switch (config.build_env) {
        .production => sanitized,
        .canary => std.mem.concat(ctx.allocator, u8, &.{ sanitized, "-canary" }),
        .dev => std.mem.concat(ctx.allocator, u8, &.{ sanitized, "-dev" }),
    };
}

fn removeAsciiSpaces(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    try output.ensureTotalCapacity(allocator, value.len);
    for (value) |byte| {
        if (byte != ' ') output.appendAssumeCapacity(byte);
    }
    return output.toOwnedSlice(allocator);
}

fn releasePlatformPrefix(ctx: *const Context, config: CommandContext) ![]const u8 {
    return std.fmt.allocPrint(ctx.allocator, "{s}-{s}-{s}", .{
        buildEnvironmentName(config.build_env),
        osName(),
        archName(),
    });
}

fn releaseBaseUrl(root: std.json.Value) []const u8 {
    const release = getObjectField(root, "release") orelse return "";
    return getStringFieldFromObject(release, "baseUrl") orelse "";
}

fn releaseGeneratesPatch(root: std.json.Value) bool {
    const release = getObjectField(root, "release") orelse return true;
    const value = release.get("generatePatch") orelse return true;
    return value != .bool or value.bool;
}

fn platformConfigBool(root: std.json.Value, field: []const u8, default: bool) bool {
    const platform = platformBuildObject(root) orelse return default;
    const value = platform.get(field) orelse return default;
    return if (value == .bool) value.bool else default;
}

fn shouldCodesign(config: CommandContext) bool {
    return builtin.os.tag == .macos and
        config.build_env != .dev and
        platformConfigBool(config.root, "codesign", false);
}

fn shouldNotarize(ctx: *const Context, config: CommandContext) bool {
    return shouldCodesign(config) and
        platformConfigBool(config.root, "notarize", false) and
        !environmentFlagEnabled(ctx.environ_map, "ELECTROBUN_SKIP_NOTARIZATION");
}

fn shouldCreateDmg(config: CommandContext) bool {
    return builtin.os.tag == .macos and platformConfigBool(config.root, "createDmg", true);
}

fn hashBundle(ctx: *const Context, bundle_root: []const u8) ![]const u8 {
    var entries: std.ArrayList(BundleHashEntry) = .empty;
    var dir = try std.Io.Dir.openDirAbsolute(ctx.io, bundle_root, .{ .iterate = true });
    defer dir.close(ctx.io);
    var walker = try dir.walk(ctx.allocator);
    defer walker.deinit();

    while (try walker.next(ctx.io)) |entry| {
        if (entry.kind != .file) continue;
        try entries.append(ctx.allocator, .{
            .relative_path = try ctx.allocator.dupe(u8, entry.path),
        });
    }
    std.mem.sort(BundleHashEntry, entries.items, {}, BundleHashEntry.lessThan);

    var hasher = std.hash.Wyhash.init(43770);
    var reader_buffer: [64 * 1024]u8 = undefined;
    var content_buffer: [64 * 1024]u8 = undefined;
    for (entries.items) |entry| {
        hasher.update(entry.relative_path);
        hasher.update(&.{0});
        const absolute_path = try std.fs.path.join(ctx.allocator, &.{ bundle_root, entry.relative_path });
        const file = try std.Io.Dir.openFileAbsolute(ctx.io, absolute_path, .{});
        defer file.close(ctx.io);
        var reader = file.reader(ctx.io, &reader_buffer);
        while (true) {
            const count = try reader.interface.readSliceShort(&content_buffer);
            if (count == 0) break;
            hasher.update(content_buffer[0..count]);
        }
        hasher.update(&.{0xff});
    }

    return formatBase36(ctx.allocator, hasher.final());
}

fn formatBase36(allocator: std.mem.Allocator, input: u64) ![]const u8 {
    const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    var reversed: [13]u8 = undefined;
    var value = input;
    var length: usize = 0;
    while (value > 0) : (value /= 36) {
        reversed[length] = digits[@intCast(value % 36)];
        length += 1;
    }
    if (length == 0) {
        reversed[0] = '0';
        length = 1;
    }

    const output = try allocator.alloc(u8, length);
    for (0..length) |index| {
        output[index] = reversed[length - index - 1];
    }
    return output;
}

fn writeVersionMetadata(
    ctx: *const Context,
    config: CommandContext,
    bundle: AppBundlePaths,
    hash: []const u8,
) !void {
    var object: std.json.ObjectMap = .empty;
    try object.put(ctx.allocator, "version", .{ .string = try getAppVersion(ctx, config.root) });
    try object.put(ctx.allocator, "hash", .{ .string = hash });
    try object.put(ctx.allocator, "channel", .{ .string = buildEnvironmentName(config.build_env) });
    try object.put(ctx.allocator, "baseUrl", .{ .string = releaseBaseUrl(config.root) });
    try object.put(ctx.allocator, "name", .{ .string = try artifactAppFileName(ctx, config) });
    try object.put(ctx.allocator, "identifier", .{ .string = try getAppIdentifier(ctx, config.root) });
    const json = try std.json.Stringify.valueAlloc(
        ctx.allocator,
        std.json.Value{ .object = object },
        .{},
    );
    try std.Io.Dir.cwd().writeFile(ctx.io, .{
        .sub_path = try std.fs.path.join(ctx.allocator, &.{ bundle.resources_dir, "version.json" }),
        .data = json,
    });
}

fn writeExtractorMetadata(
    ctx: *const Context,
    config: CommandContext,
    hash: []const u8,
    output_path: []const u8,
) !void {
    var object: std.json.ObjectMap = .empty;
    try object.put(ctx.allocator, "identifier", .{ .string = try getAppIdentifier(ctx, config.root) });
    try object.put(ctx.allocator, "name", .{ .string = try getAppName(ctx, config.root) });
    try object.put(ctx.allocator, "channel", .{ .string = buildEnvironmentName(config.build_env) });
    try object.put(ctx.allocator, "hash", .{ .string = hash });
    const json = try std.json.Stringify.valueAlloc(
        ctx.allocator,
        std.json.Value{ .object = object },
        .{ .whitespace = .indent_2 },
    );
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = output_path, .data = json });
}

fn createBundleTar(ctx: *const Context, bundle_root: []const u8, tar_path: []const u8) !void {
    const parent = std.fs.path.dirname(bundle_root) orelse return error.InvalidBundlePath;
    const name = std.fs.path.basename(bundle_root);
    var env_map = std.process.Environ.Map.init(ctx.allocator);
    defer env_map.deinit();
    try inheritCurrentEnvironmentFromContext(ctx, &env_map);
    try env_map.put("COPYFILE_DISABLE", "1");
    try runReleaseCommand(
        ctx,
        &.{ "tar", "-cf", tar_path, "-C", parent, name },
        ctx.project_root,
        &env_map,
    );
}

fn compressTar(
    ctx: *const Context,
    zstd_path: []const u8,
    tar_path: []const u8,
    output_path: []const u8,
) !void {
    if (!pathExists(ctx.io, zstd_path)) return error.ZstdNotFound;
    ctx.writeStdout("compressing update bundle...\n", .{});
    try runReleaseCommand(
        ctx,
        &.{ zstd_path, "compress", "-i", tar_path, "-o", output_path, "--threads", "max" },
        ctx.project_root,
        null,
    );
}

fn generateDeltaPatch(
    ctx: *const Context,
    config: CommandContext,
    platform_paths: PlatformPaths,
    current_tar_path: []const u8,
) !?[]const u8 {
    if (!releaseGeneratesPatch(config.root)) {
        ctx.writeStdout("delta patch generation disabled\n", .{});
        return null;
    }
    const base_url = std.mem.trimEnd(u8, releaseBaseUrl(config.root), "/");
    if (base_url.len == 0) {
        ctx.writeStdout("no release.baseUrl configured; skipping delta patch\n", .{});
        return null;
    }
    if (!pathExists(ctx.io, platform_paths.bsdiff) or !pathExists(ctx.io, platform_paths.zig_zstd)) {
        ctx.writeStderr("hutch electrobun: bsdiff or zig-zstd missing; skipping delta patch\n", .{});
        return null;
    }

    const prefix = try releasePlatformPrefix(ctx, config);
    const update_url = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}-update.json", .{ base_url, prefix });
    const update_bytes = fetchOptionalBytes(ctx, update_url, 1024 * 1024) catch |err| {
        ctx.writeStderr("hutch electrobun: could not fetch previous update metadata ({s}); skipping delta patch\n", .{@errorName(err)});
        return null;
    } orelse {
        ctx.writeStdout("no previous release found; skipping delta patch\n", .{});
        return null;
    };
    const previous = std.json.parseFromSliceLeaky(std.json.Value, ctx.allocator, update_bytes, .{}) catch {
        ctx.writeStderr("hutch electrobun: previous update metadata is invalid; skipping delta patch\n", .{});
        return null;
    };
    const previous_hash = getStringField(previous, "hash") orelse {
        ctx.writeStderr("hutch electrobun: previous update metadata has no hash; skipping delta patch\n", .{});
        return null;
    };

    const compressed_name = std.fs.path.basename(try std.mem.concat(ctx.allocator, u8, &.{ current_tar_path, ".zst" }));
    const archive_url = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}-{s}", .{
        base_url,
        prefix,
        compressed_name,
    });
    const previous_archive = fetchOptionalBytes(ctx, archive_url, max_release_download_bytes) catch |err| {
        ctx.writeStderr("hutch electrobun: could not fetch previous update bundle ({s}); skipping delta patch\n", .{@errorName(err)});
        return null;
    } orelse {
        ctx.writeStdout("previous update bundle not found; skipping delta patch\n", .{});
        return null;
    };

    const previous_zstd_path = try std.fs.path.join(ctx.allocator, &.{ std.fs.path.dirname(current_tar_path).?, "prev.tar.zst" });
    const previous_tar_path = try std.fs.path.join(ctx.allocator, &.{ std.fs.path.dirname(current_tar_path).?, "prev.tar" });
    defer std.Io.Dir.cwd().deleteFile(ctx.io, previous_zstd_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(ctx.io, previous_tar_path) catch {};
    try std.Io.Dir.cwd().writeFile(ctx.io, .{
        .sub_path = previous_zstd_path,
        .data = previous_archive,
    });
    if (!try runReleaseCommandSuccess(
        ctx,
        &.{ platform_paths.zig_zstd, "decompress", "-i", previous_zstd_path, "-o", previous_tar_path },
        ctx.project_root,
        null,
    )) {
        ctx.writeStderr("hutch electrobun: failed to decompress previous update bundle; skipping delta patch\n", .{});
        return null;
    }

    const patch_path = try std.fs.path.join(
        ctx.allocator,
        &.{ std.fs.path.dirname(current_tar_path).?, try std.mem.concat(ctx.allocator, u8, &.{ previous_hash, ".patch" }) },
    );
    if (!try runReleaseCommandSuccess(
        ctx,
        &.{ platform_paths.bsdiff, previous_tar_path, current_tar_path, patch_path, "--use-zstd" },
        ctx.project_root,
        null,
    )) {
        std.Io.Dir.cwd().deleteFile(ctx.io, patch_path) catch {};
        ctx.writeStderr("hutch electrobun: delta generation failed; the full update bundle will still be published\n", .{});
        return null;
    }
    return patch_path;
}

fn fetchOptionalBytes(ctx: *const Context, url: []const u8, max_bytes: usize) !?[]const u8 {
    var client: std.http.Client = .{ .allocator = ctx.allocator, .io = ctx.io };
    defer client.deinit();
    client.initDefaultProxies(ctx.allocator, ctx.environ_map) catch {};

    var output: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer output.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &output.writer,
        .keep_alive = builtin.os.tag != .windows,
    });
    const status: u16 = @intFromEnum(result.status);
    if (status == 404) return null;
    if (status < 200 or status >= 300) return error.ReleaseDownloadFailed;
    if (output.written().len > max_bytes) return error.ReleaseDownloadTooLarge;
    return try output.toOwnedSlice();
}

fn getStringField(value: std.json.Value, field: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const item = value.object.get(field) orelse return null;
    return if (item == .string) item.string else null;
}

fn runReleaseCommand(
    ctx: *const Context,
    argv: []const []const u8,
    cwd: []const u8,
    environment: ?*const std.process.Environ.Map,
) !void {
    if (!try runReleaseCommandSuccess(ctx, argv, cwd, environment)) {
        ctx.writeStderr("hutch electrobun: command failed: {s}\n", .{argv[0]});
        return error.ReleaseCommandFailed;
    }
}

fn runReleaseCommandSuccess(
    ctx: *const Context,
    argv: []const []const u8,
    cwd: []const u8,
    environment: ?*const std.process.Environ.Map,
) !bool {
    var child = try std.process.spawn(ctx.io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = environment orelse ctx.environ_map,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
        .create_no_window = true,
    });
    defer child.kill(ctx.io);
    return termExitCode(try child.wait(ctx.io)) == 0;
}

fn createOuterWrapper(
    ctx: *const Context,
    config: CommandContext,
    bundle: AppBundlePaths,
    platform_paths: PlatformPaths,
    hash: []const u8,
    compressed_tar_path: []const u8,
) !void {
    std.Io.Dir.cwd().deleteTree(ctx.io, bundle.bundle_root) catch {};
    try std.Io.Dir.cwd().createDirPath(ctx.io, bundle.exec_dir);
    try std.Io.Dir.cwd().createDirPath(ctx.io, bundle.resources_dir);
    if (builtin.os.tag == .macos) {
        try writeInfoPlist(ctx, config, bundle);
    }

    const wrapped_archive_path = try std.fs.path.join(
        ctx.allocator,
        &.{ bundle.resources_dir, try std.mem.concat(ctx.allocator, u8, &.{ hash, ".tar.zst" }) },
    );
    try copyPath(ctx, compressed_tar_path, wrapped_archive_path);
    try copyPath(
        ctx,
        platform_paths.extractor,
        try std.fs.path.join(ctx.allocator, &.{ bundle.exec_dir, launcherFileName() }),
    );
    try writeExtractorMetadata(
        ctx,
        config,
        hash,
        try std.fs.path.join(ctx.allocator, &.{ bundle.resources_dir, "metadata.json" }),
    );
    try installBundleAssets(ctx, config, bundle);
}

fn installBundleAssets(ctx: *const Context, config: CommandContext, bundle: AppBundlePaths) !void {
    const platform = platformBuildObject(config.root) orelse return;
    switch (builtin.os.tag) {
        .macos => {
            if (getStringFieldFromObject(platform, "icons")) |icons| {
                const source = try absoluteProjectPath(ctx, icons);
                if (!pathExists(ctx.io, source)) {
                    ctx.writeStderr("hutch electrobun: macOS icon source not found: {s}\n", .{source});
                } else {
                    const destination = try std.fs.path.join(ctx.allocator, &.{ bundle.resources_dir, "AppIcon.icns" });
                    if (std.mem.endsWith(u8, icons, ".icon")) {
                        const stem = std.fs.path.stem(std.fs.path.basename(icons));
                        const partial_plist = try std.fs.path.join(ctx.allocator, &.{ bundle.build_root, ".actool-partial-info.plist" });
                        try runReleaseCommand(
                            ctx,
                            &.{
                                "xcrun",
                                "actool",
                                "--compile",
                                bundle.resources_dir,
                                "--app-icon",
                                stem,
                                "--platform",
                                "macosx",
                                "--minimum-deployment-target",
                                "11.0",
                                "--output-partial-info-plist",
                                partial_plist,
                                source,
                            },
                            ctx.project_root,
                            null,
                        );
                        const generated = try std.fs.path.join(ctx.allocator, &.{ bundle.resources_dir, try std.mem.concat(ctx.allocator, u8, &.{ stem, ".icns" }) });
                        if (pathExists(ctx.io, generated) and !std.mem.eql(u8, generated, destination)) {
                            std.Io.Dir.cwd().deleteFile(ctx.io, destination) catch {};
                            try std.Io.Dir.cwd().rename(generated, std.Io.Dir.cwd(), destination, ctx.io);
                        }
                    } else {
                        try runReleaseCommand(
                            ctx,
                            &.{ "iconutil", "-c", "icns", "-o", destination, source },
                            ctx.project_root,
                            null,
                        );
                    }
                }
            }
            try copyDocumentTypeIcons(ctx, config, bundle.resources_dir);
        },
        .linux => {
            const icon = getStringFieldFromObject(platform, "icon") orelse return;
            const source = try absoluteProjectPath(ctx, icon);
            if (!pathExists(ctx.io, source)) {
                ctx.writeStderr("hutch electrobun: Linux icon not found: {s}\n", .{source});
                return;
            }
            try copyPath(ctx, source, try std.fs.path.join(ctx.allocator, &.{ bundle.resources_dir, "appIcon.png" }));
            try copyPath(ctx, source, try std.fs.path.join(ctx.allocator, &.{ bundle.resources_dir, "app", "icon.png" }));

            const app = getObjectField(config.root, "app") orelse return;
            const description = getStringFieldFromObject(app, "description") orelse try getAppName(ctx, config.root);
            const desktop = try std.fmt.allocPrint(
                ctx.allocator,
                "[Desktop Entry]\nVersion=1.0\nType=Application\nName={s}\nComment={s}\nExec=launcher\nIcon=appIcon.png\nTerminal=false\nStartupWMClass={s}\nCategories=Utility;Application;\n",
                .{ try getAppName(ctx, config.root), description, try getAppName(ctx, config.root) },
            );
            const desktop_name = try std.mem.concat(ctx.allocator, u8, &.{ try getAppName(ctx, config.root), ".desktop" });
            try std.Io.Dir.cwd().writeFile(ctx.io, .{
                .sub_path = try std.fs.path.join(ctx.allocator, &.{ bundle.bundle_root, desktop_name }),
                .data = desktop,
            });
        },
        .windows => {
            const icon_path = try prepareWindowsIcon(ctx, config) orelse return;
            try copyPath(
                ctx,
                icon_path,
                try std.fs.path.join(ctx.allocator, &.{ bundle.resources_dir, "app.ico" }),
            );
            const launcher_path = try std.fs.path.join(
                ctx.allocator,
                &.{ bundle.exec_dir, launcherFileName() },
            );
            try embedWindowsIcon(ctx, launcher_path, icon_path);
        },
        else => {},
    }
}

fn copyDocumentTypeIcons(
    ctx: *const Context,
    config: CommandContext,
    resources_dir: []const u8,
) !void {
    const app = getObjectField(config.root, "app") orelse return;
    const associations = app.get("fileAssociations") orelse return;
    if (associations != .array) return;
    for (associations.array.items) |association| {
        if (association != .object) continue;
        const icon = getStringFieldFromObject(association.object, "icon") orelse continue;
        const source = try absoluteProjectPath(ctx, icon);
        if (!pathExists(ctx.io, source)) {
            ctx.writeStderr("hutch electrobun: document icon not found: {s}\n", .{source});
            continue;
        }
        try copyPath(
            ctx,
            source,
            try std.fs.path.join(ctx.allocator, &.{ resources_dir, std.fs.path.basename(source) }),
        );
    }
}

fn writeEntitlementsFile(ctx: *const Context, config: CommandContext) ![]const u8 {
    const build_root = try buildOutputRoot(ctx, config);
    const output_path = try std.fs.path.join(ctx.allocator, &.{ build_root, "entitlements.plist" });
    const platform = platformBuildObject(config.root);
    const entitlements: std.json.ObjectMap = if (platform) |object|
        getObjectFieldFromObject(object, "entitlements") orelse std.json.ObjectMap.empty
    else
        std.json.ObjectMap.empty;
    const contents = try entitlementsPlist(ctx.allocator, entitlements);
    try std.Io.Dir.cwd().writeFile(ctx.io, .{
        .sub_path = output_path,
        .data = contents,
    });
    return output_path;
}

fn entitlementsPlist(
    allocator: std.mem.Allocator,
    entitlements: std.json.ObjectMap,
) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    try output.appendSlice(
        allocator,
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" " ++
            "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" ++
            "<plist version=\"1.0\">\n<dict>\n",
    );

    var iterator = entitlements.iterator();
    while (iterator.next()) |entry| {
        try output.appendSlice(allocator, "    <key>");
        try appendXmlEscaped(&output, allocator, entry.key_ptr.*);
        try output.appendSlice(allocator, "</key>\n");
        try appendEntitlementValue(&output, allocator, entry.value_ptr.*, 4);
        try output.append(allocator, '\n');
    }

    try output.appendSlice(allocator, "</dict>\n</plist>\n");
    return output.toOwnedSlice(allocator);
}

fn appendEntitlementValue(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: std.json.Value,
    indent: usize,
) !void {
    try appendSpaces(output, allocator, indent);
    switch (value) {
        .bool => |enabled| try output.appendSlice(
            allocator,
            if (enabled) "<true/>" else "<false/>",
        ),
        .string => |string| {
            try output.appendSlice(allocator, "<string>");
            try appendXmlEscaped(output, allocator, string);
            try output.appendSlice(allocator, "</string>");
        },
        .array => |array| {
            try output.appendSlice(allocator, "<array>\n");
            for (array.items) |item| {
                if (item != .string) return error.InvalidEntitlementValue;
                try appendSpaces(output, allocator, indent + 4);
                try output.appendSlice(allocator, "<string>");
                try appendXmlEscaped(output, allocator, item.string);
                try output.appendSlice(allocator, "</string>\n");
            }
            try appendSpaces(output, allocator, indent);
            try output.appendSlice(allocator, "</array>");
        },
        else => return error.InvalidEntitlementValue,
    }
}

fn appendSpaces(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    count: usize,
) !void {
    try output.appendNTimes(allocator, ' ', count);
}

fn appendXmlEscaped(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: []const u8,
) !void {
    for (value) |byte| {
        try output.appendSlice(allocator, switch (byte) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&apos;",
            else => &.{byte},
        });
    }
}

const SigningTarget = struct {
    path: []const u8,
    relative_path: []const u8,

    fn deepestFirst(_: void, lhs: SigningTarget, rhs: SigningTarget) bool {
        if (lhs.relative_path.len != rhs.relative_path.len) {
            return lhs.relative_path.len > rhs.relative_path.len;
        }
        return std.mem.order(u8, lhs.relative_path, rhs.relative_path) == .lt;
    }
};

fn codesignBundle(
    ctx: *const Context,
    _: CommandContext,
    bundle_root: []const u8,
    entitlements_path: []const u8,
) !void {
    if (builtin.os.tag != .macos) return;
    const developer_id = ctx.environ_map.get("ELECTROBUN_DEVELOPER_ID") orelse {
        ctx.writeStderr(
            "hutch electrobun: ELECTROBUN_DEVELOPER_ID is required for code signing\n",
            .{},
        );
        return error.MissingDeveloperId;
    };

    var binaries: std.ArrayList(SigningTarget) = .empty;
    defer binaries.deinit(ctx.allocator);
    var bundles: std.ArrayList(SigningTarget) = .empty;
    defer bundles.deinit(ctx.allocator);

    var root = try std.Io.Dir.openDirAbsolute(ctx.io, bundle_root, .{ .iterate = true });
    defer root.close(ctx.io);
    var walker = try root.walk(ctx.allocator);
    defer walker.deinit();

    while (try walker.next(ctx.io)) |entry| {
        const absolute_path = try std.fs.path.join(ctx.allocator, &.{ bundle_root, entry.path });
        switch (entry.kind) {
            .file => {
                if (!try isMachOFile(ctx, absolute_path)) continue;
                try binaries.append(ctx.allocator, .{
                    .path = absolute_path,
                    .relative_path = try ctx.allocator.dupe(u8, entry.path),
                });
            },
            .directory => {
                if (!isNestedCodeBundle(entry.path)) continue;
                try bundles.append(ctx.allocator, .{
                    .path = absolute_path,
                    .relative_path = try ctx.allocator.dupe(u8, entry.path),
                });
            },
            else => {},
        }
    }

    std.mem.sort(SigningTarget, binaries.items, {}, SigningTarget.deepestFirst);
    std.mem.sort(SigningTarget, bundles.items, {}, SigningTarget.deepestFirst);

    ctx.writeStdout("code signing app bundle...\n", .{});
    for (binaries.items) |target| {
        try codesignPath(
            ctx,
            developer_id,
            target.path,
            if (machOUsesEntitlements(target.relative_path)) entitlements_path else null,
            true,
        );
    }
    for (bundles.items) |target| {
        try codesignPath(
            ctx,
            developer_id,
            target.path,
            if (std.mem.endsWith(u8, target.relative_path, ".app")) entitlements_path else null,
            true,
        );
    }
    try codesignPath(ctx, developer_id, bundle_root, entitlements_path, true);
    try runReleaseCommand(
        ctx,
        &.{ "codesign", "--verify", "--deep", "--strict", "--verbose=2", bundle_root },
        ctx.project_root,
        null,
    );
}

fn isNestedCodeBundle(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".app") or
        std.mem.endsWith(u8, path, ".framework") or
        std.mem.endsWith(u8, path, ".bundle") or
        std.mem.endsWith(u8, path, ".xpc") or
        std.mem.endsWith(u8, path, ".appex");
}

fn machOUsesEntitlements(path: []const u8) bool {
    return !std.mem.endsWith(u8, path, ".dylib") and
        !std.mem.endsWith(u8, path, ".node") and
        std.mem.indexOf(u8, path, ".framework/") == null;
}

fn isMachOFile(ctx: *const Context, absolute_path: []const u8) !bool {
    const file = std.Io.Dir.openFileAbsolute(ctx.io, absolute_path, .{}) catch return false;
    defer file.close(ctx.io);
    var reader_buffer: [4]u8 = undefined;
    var magic: [4]u8 = undefined;
    var reader = file.reader(ctx.io, &reader_buffer);
    const count = reader.interface.readSliceShort(&magic) catch return false;
    if (count != magic.len) return false;

    const known_magics = [_][4]u8{
        .{ 0xfe, 0xed, 0xfa, 0xce },
        .{ 0xce, 0xfa, 0xed, 0xfe },
        .{ 0xfe, 0xed, 0xfa, 0xcf },
        .{ 0xcf, 0xfa, 0xed, 0xfe },
        .{ 0xca, 0xfe, 0xba, 0xbe },
        .{ 0xbe, 0xba, 0xfe, 0xca },
        .{ 0xca, 0xfe, 0xba, 0xbf },
        .{ 0xbf, 0xba, 0xfe, 0xca },
    };
    for (known_magics) |known| {
        if (std.mem.eql(u8, &magic, &known)) return true;
    }
    return false;
}

fn codesignPath(
    ctx: *const Context,
    developer_id: []const u8,
    path: []const u8,
    entitlements_path: ?[]const u8,
    hardened_runtime: bool,
) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.allocator);
    try argv.appendSlice(ctx.allocator, &.{
        "codesign",
        "--force",
        "--verbose",
        "--timestamp",
        "--sign",
        developer_id,
    });
    if (hardened_runtime) {
        try argv.appendSlice(ctx.allocator, &.{ "--options", "runtime" });
    }
    if (entitlements_path) |entitlements| {
        try argv.appendSlice(ctx.allocator, &.{ "--entitlements", entitlements });
    }
    try argv.append(ctx.allocator, path);
    try runReleaseCommand(ctx, argv.items, ctx.project_root, null);
}

fn codesignDmg(ctx: *const Context, dmg_path: []const u8) !void {
    if (builtin.os.tag != .macos) return;
    const developer_id = ctx.environ_map.get("ELECTROBUN_DEVELOPER_ID") orelse {
        ctx.writeStderr(
            "hutch electrobun: ELECTROBUN_DEVELOPER_ID is required for code signing\n",
            .{},
        );
        return error.MissingDeveloperId;
    };
    try codesignPath(ctx, developer_id, dmg_path, null, false);
    try runReleaseCommand(
        ctx,
        &.{ "codesign", "--verify", "--verbose=2", dmg_path },
        ctx.project_root,
        null,
    );
}

fn notarizeAndStaple(ctx: *const Context, app_or_dmg_path: []const u8) !void {
    if (builtin.os.tag != .macos) return;

    var submission_path = app_or_dmg_path;
    var archive_path: ?[]const u8 = null;
    if (std.mem.endsWith(u8, app_or_dmg_path, ".app")) {
        const zip_path = try std.mem.concat(ctx.allocator, u8, &.{ app_or_dmg_path, ".zip" });
        std.Io.Dir.cwd().deleteFile(ctx.io, zip_path) catch {};
        try runReleaseCommand(
            ctx,
            &.{ "/usr/bin/ditto", "-c", "-k", "--keepParent", app_or_dmg_path, zip_path },
            ctx.project_root,
            null,
        );
        submission_path = zip_path;
        archive_path = zip_path;
    }
    defer if (archive_path) |path| {
        std.Io.Dir.cwd().deleteFile(ctx.io, path) catch {};
    };

    const api_issuer = ctx.environ_map.get("ELECTROBUN_APPLEAPIISSUER");
    const api_key_id = ctx.environ_map.get("ELECTROBUN_APPLEAPIKEY");
    const api_key_path = ctx.environ_map.get("ELECTROBUN_APPLEAPIKEYPATH");
    const apple_id = ctx.environ_map.get("ELECTROBUN_APPLEID");
    const apple_id_password = ctx.environ_map.get("ELECTROBUN_APPLEIDPASS");
    const team_id = ctx.environ_map.get("ELECTROBUN_TEAMID");

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.allocator);
    try argv.appendSlice(ctx.allocator, &.{ "xcrun", "notarytool", "submit" });
    if (api_issuer != null and api_key_id != null and api_key_path != null) {
        if (!pathExists(ctx.io, api_key_path.?)) {
            ctx.writeStderr(
                "hutch electrobun: ELECTROBUN_APPLEAPIKEYPATH does not exist: {s}\n",
                .{api_key_path.?},
            );
            return error.AppleApiKeyNotFound;
        }
        try argv.appendSlice(ctx.allocator, &.{
            "--key",
            api_key_path.?,
            "--key-id",
            api_key_id.?,
            "--issuer",
            api_issuer.?,
        });
    } else if (apple_id != null and apple_id_password != null and team_id != null) {
        try argv.appendSlice(ctx.allocator, &.{
            "--apple-id",
            apple_id.?,
            "--password",
            apple_id_password.?,
            "--team-id",
            team_id.?,
        });
    } else {
        ctx.writeStderr(
            "hutch electrobun: notarization requires App Store Connect API key credentials " ++
                "(ELECTROBUN_APPLEAPIISSUER, ELECTROBUN_APPLEAPIKEY, " ++
                "ELECTROBUN_APPLEAPIKEYPATH) or Apple ID credentials " ++
                "(ELECTROBUN_APPLEID, ELECTROBUN_APPLEIDPASS, ELECTROBUN_TEAMID)\n",
            .{},
        );
        return error.MissingNotarizationCredentials;
    }
    try argv.appendSlice(ctx.allocator, &.{
        "--wait",
        "--output-format",
        "json",
        submission_path,
    });

    ctx.writeStdout("submitting {s} for notarization...\n", .{std.fs.path.basename(app_or_dmg_path)});
    const result = try std.process.run(ctx.allocator, ctx.io, .{
        .argv = argv.items,
        .cwd = .{ .path = ctx.project_root },
        .environ_map = ctx.environ_map,
        .create_no_window = true,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);
    if (result.stderr.len > 0) ctx.writeStderr("{s}", .{result.stderr});
    if (termExitCode(result.term) != 0) return error.NotarizationFailed;
    if (!try notarizationAccepted(ctx.allocator, result.stdout)) {
        ctx.writeStderr("hutch electrobun: Apple rejected the notarization submission\n{s}\n", .{result.stdout});
        return error.NotarizationRejected;
    }
    try runReleaseCommand(
        ctx,
        &.{ "xcrun", "stapler", "staple", app_or_dmg_path },
        ctx.project_root,
        null,
    );
    try runReleaseCommand(
        ctx,
        &.{ "xcrun", "stapler", "validate", app_or_dmg_path },
        ctx.project_root,
        null,
    );
}

fn notarizationAccepted(allocator: std.mem.Allocator, response: []const u8) !bool {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, response, .{});
    const status = getStringField(parsed, "status") orelse return false;
    return std.ascii.eqlIgnoreCase(status, "Accepted");
}

fn finishRelease(ctx: *const Context, config: CommandContext, state: ReleaseState) !void {
    var installer_path: ?[]const u8 = null;
    switch (builtin.os.tag) {
        .macos => {
            if (shouldCodesign(config)) {
                const entitlements_path = try writeEntitlementsFile(ctx, config);
                try codesignBundle(ctx, config, state.bundle.bundle_root, entitlements_path);
                if (shouldNotarize(ctx, config)) {
                    try notarizeAndStaple(ctx, state.bundle.bundle_root);
                }
            }
            if (shouldCreateDmg(config)) {
                installer_path = try createDmg(ctx, config, state.bundle);
                if (shouldCodesign(config)) {
                    try codesignDmg(ctx, installer_path.?);
                    if (shouldNotarize(ctx, config)) {
                        try notarizeAndStaple(ctx, installer_path.?);
                    }
                }
            }
        },
        .windows => installer_path = try createWindowsInstaller(ctx, config, state),
        .linux => installer_path = try createLinuxInstaller(ctx, config, state),
        else => {},
    }

    try writeReleaseArtifacts(ctx, config, state, installer_path);
}

fn createDmg(ctx: *const Context, config: CommandContext, bundle: AppBundlePaths) ![]const u8 {
    const app_file_name = try artifactAppFileName(ctx, config);
    const output_path = try std.fs.path.join(
        ctx.allocator,
        &.{ bundle.build_root, try std.mem.concat(ctx.allocator, u8, &.{ app_file_name, ".dmg" }) },
    );
    const creation_path = if (config.build_env == .production)
        try std.fs.path.join(
            ctx.allocator,
            &.{ bundle.build_root, try std.mem.concat(ctx.allocator, u8, &.{ app_file_name, "-production.dmg" }) },
        )
    else
        output_path;
    const staging = try std.fs.path.join(ctx.allocator, &.{ bundle.build_root, ".dmg-staging" });
    try recreateDir(ctx, staging);
    defer std.Io.Dir.cwd().deleteTree(ctx.io, staging) catch {};

    const staged_app = try std.fs.path.join(ctx.allocator, &.{ staging, std.fs.path.basename(bundle.bundle_root) });
    try runReleaseCommand(ctx, &.{ "/usr/bin/ditto", bundle.bundle_root, staged_app }, ctx.project_root, null);
    try std.Io.Dir.cwd().symLink(
        ctx.io,
        "/Applications",
        try std.fs.path.join(ctx.allocator, &.{ staging, "Applications" }),
        .{},
    );

    const volume_name = try dmgVolumeName(ctx, config);
    std.Io.Dir.cwd().deleteFile(ctx.io, output_path) catch {};
    if (!std.mem.eql(u8, creation_path, output_path)) {
        std.Io.Dir.cwd().deleteFile(ctx.io, creation_path) catch {};
    }
    ctx.writeStdout("creating macOS disk image...\n", .{});
    try runReleaseCommand(
        ctx,
        &.{ "hdiutil", "create", "-volname", volume_name, "-srcfolder", staging, "-ov", "-format", "ULFO", creation_path },
        ctx.project_root,
        null,
    );
    if (!std.mem.eql(u8, creation_path, output_path)) {
        try std.Io.Dir.cwd().rename(creation_path, std.Io.Dir.cwd(), output_path, ctx.io);
    }
    return output_path;
}

fn dmgVolumeName(ctx: *const Context, config: CommandContext) ![]const u8 {
    const app_name = try getAppName(ctx, config.root);
    var sanitized: std.ArrayList(u8) = .empty;
    for (app_name) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == ' ') {
            try sanitized.append(ctx.allocator, byte);
        }
    }
    const base = try sanitized.toOwnedSlice(ctx.allocator);
    return switch (config.build_env) {
        .production => base,
        .canary => std.mem.concat(ctx.allocator, u8, &.{ base, "-canary" }),
        .dev => std.mem.concat(ctx.allocator, u8, &.{ base, "-dev" }),
    };
}

fn createWindowsInstaller(ctx: *const Context, config: CommandContext, state: ReleaseState) ![]const u8 {
    const platform_paths = try getPlatformPaths(ctx);
    const setup_name = try windowsSetupFileName(ctx, config);
    const setup_path = try std.fs.path.join(ctx.allocator, &.{ state.bundle.build_root, setup_name });
    try copyPath(ctx, platform_paths.extractor, setup_path);

    const stem = setup_name[0 .. setup_name.len - ".exe".len];
    const metadata_name = try std.mem.concat(ctx.allocator, u8, &.{ stem, ".metadata.json" });
    const archive_name = try std.mem.concat(ctx.allocator, u8, &.{ stem, ".tar.zst" });
    const metadata_path = try std.fs.path.join(ctx.allocator, &.{ state.bundle.build_root, metadata_name });
    const archive_path = try std.fs.path.join(ctx.allocator, &.{ state.bundle.build_root, archive_name });
    try writeExtractorMetadata(ctx, config, state.hash, metadata_path);
    try copyPath(ctx, state.compressed_tar_path, archive_path);
    try embedWindowsInstallerIcon(ctx, config, setup_path);

    const staging = try std.fs.path.join(ctx.allocator, &.{ state.bundle.build_root, ".installer-zip" });
    try recreateDir(ctx, staging);
    defer std.Io.Dir.cwd().deleteTree(ctx.io, staging) catch {};
    const hidden = try std.fs.path.join(ctx.allocator, &.{ staging, ".installer" });
    try std.Io.Dir.cwd().createDirPath(ctx.io, hidden);
    try copyPath(ctx, setup_path, try std.fs.path.join(ctx.allocator, &.{ staging, setup_name }));
    try copyPath(ctx, metadata_path, try std.fs.path.join(ctx.allocator, &.{ hidden, metadata_name }));
    try copyPath(ctx, archive_path, try std.fs.path.join(ctx.allocator, &.{ hidden, archive_name }));

    const zip_name = try std.mem.concat(ctx.allocator, u8, &.{ try removeAsciiSpaces(ctx.allocator, stem), ".zip" });
    const zip_path = try std.fs.path.join(ctx.allocator, &.{ state.bundle.build_root, zip_name });
    const quoted_staging = try powershellSingleQuote(ctx.allocator, staging);
    const quoted_zip = try powershellSingleQuote(ctx.allocator, zip_path);
    const quoted_setup_name = try powershellSingleQuote(ctx.allocator, setup_name);
    const command = try std.fmt.allocPrint(
        ctx.allocator,
        "Compress-Archive -Path @((Join-Path '{s}' '{s}'), (Join-Path '{s}' '.installer')) -DestinationPath '{s}' -Force",
        .{ quoted_staging, quoted_setup_name, quoted_staging, quoted_zip },
    );
    try runReleaseCommand(
        ctx,
        &.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", command },
        ctx.project_root,
        null,
    );
    return zip_path;
}

fn windowsSetupFileName(ctx: *const Context, config: CommandContext) ![]const u8 {
    const app_name = try getAppName(ctx, config.root);
    return switch (config.build_env) {
        .production => std.mem.concat(ctx.allocator, u8, &.{ app_name, "-Setup.exe" }),
        .canary => std.mem.concat(ctx.allocator, u8, &.{ app_name, "-Setup-canary.exe" }),
        .dev => std.mem.concat(ctx.allocator, u8, &.{ app_name, "-Setup-dev.exe" }),
    };
}

fn powershellSingleQuote(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    for (value) |byte| {
        try output.append(allocator, byte);
        if (byte == '\'') try output.append(allocator, '\'');
    }
    return output.toOwnedSlice(allocator);
}

fn embedWindowsInstallerIcon(ctx: *const Context, config: CommandContext, setup_path: []const u8) !void {
    const icon_path = try prepareWindowsIcon(ctx, config) orelse return;
    try embedWindowsIcon(ctx, setup_path, icon_path);
}

fn prepareWindowsIcon(ctx: *const Context, config: CommandContext) !?[]const u8 {
    const platform = platformBuildObject(config.root) orelse return null;
    const icon = getStringFieldFromObject(platform, "icon") orelse return null;
    const source = try absoluteProjectPath(ctx, icon);
    if (!pathExists(ctx.io, source)) {
        ctx.writeStderr("hutch electrobun: Windows icon not found: {s}\n", .{source});
        return null;
    }
    if (std.ascii.endsWithIgnoreCase(source, ".ico")) return source;
    if (!std.ascii.endsWithIgnoreCase(source, ".png")) {
        ctx.writeStderr(
            "hutch electrobun: Windows icons must be PNG or ICO files; leaving the default icon unchanged\n",
            .{},
        );
        return null;
    }

    const package_root = (try resolveElectrobunPackageRoot(ctx)) orelse return null;
    const converted_path = try std.fs.path.join(
        ctx.allocator,
        &.{ try buildOutputRoot(ctx, config), ".dash-windows-icon.ico" },
    );
    if (pathExists(ctx.io, converted_path)) return converted_path;

    const dependency_root = std.fs.path.dirname(package_root) orelse package_root;
    const converter_candidates = [_][]const u8{
        try std.fs.path.join(ctx.allocator, &.{ package_root, "node_modules", "png-to-ico", "bin", "cli.js" }),
        try std.fs.path.join(ctx.allocator, &.{ dependency_root, "png-to-ico", "bin", "cli.js" }),
    };
    for (converter_candidates) |converter| {
        if (!pathExists(ctx.io, converter)) continue;
        const result = try std.process.run(ctx.allocator, ctx.io, .{
            .argv = &.{ try resolveCottontailBinary(ctx), converter, source },
            .cwd = .{ .path = package_root },
            .environ_map = ctx.environ_map,
            .create_no_window = true,
            .stdout_limit = .limited(64 * 1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        });
        defer ctx.allocator.free(result.stdout);
        defer ctx.allocator.free(result.stderr);
        if (termExitCode(result.term) != 0 or result.stdout.len == 0) {
            ctx.writeStderr(
                "hutch electrobun: PNG-to-ICO conversion failed; leaving the default Windows icon unchanged\n{s}",
                .{result.stderr},
            );
            return null;
        }
        try std.Io.Dir.cwd().writeFile(ctx.io, .{
            .sub_path = converted_path,
            .data = result.stdout,
        });
        return converted_path;
    }

    ctx.writeStderr(
        "hutch electrobun: png-to-ico is unavailable; leaving the default Windows icon unchanged\n",
        .{},
    );
    return null;
}

fn embedWindowsIcon(ctx: *const Context, executable_path: []const u8, icon_path: []const u8) !void {
    const package_root = (try resolveElectrobunPackageRoot(ctx)) orelse return;
    const dependency_root = std.fs.path.dirname(package_root) orelse package_root;
    const candidates = [_][]const u8{
        try std.fs.path.join(ctx.allocator, &.{ package_root, "node_modules", "rcedit", "bin", "rcedit-x64.exe" }),
        try std.fs.path.join(ctx.allocator, &.{ package_root, "node_modules", "rcedit", "bin", "rcedit.exe" }),
        try std.fs.path.join(ctx.allocator, &.{ dependency_root, "rcedit", "bin", "rcedit-x64.exe" }),
        try std.fs.path.join(ctx.allocator, &.{ dependency_root, "rcedit", "bin", "rcedit.exe" }),
    };
    for (candidates) |rcedit| {
        if (!pathExists(ctx.io, rcedit)) continue;
        if (!try runReleaseCommandSuccess(ctx, &.{ rcedit, executable_path, "--set-icon", icon_path }, ctx.project_root, null)) {
            ctx.writeStderr("hutch electrobun: rcedit failed; leaving the extractor icon unchanged\n", .{});
        }
        return;
    }
    ctx.writeStderr("hutch electrobun: rcedit is unavailable; leaving the extractor icon unchanged\n", .{});
}

fn createLinuxInstaller(ctx: *const Context, config: CommandContext, state: ReleaseState) ![]const u8 {
    const platform_paths = try getPlatformPaths(ctx);
    const app_file_name = try artifactAppFileName(ctx, config);
    const installer_name = try std.mem.concat(ctx.allocator, u8, &.{ app_file_name, "-Setup" });
    const staging = try std.fs.path.join(ctx.allocator, &.{ state.bundle.build_root, try std.mem.concat(ctx.allocator, u8, &.{ installer_name, "-staging" }) });
    try recreateDir(ctx, staging);
    defer std.Io.Dir.cwd().deleteTree(ctx.io, staging) catch {};

    const installer_path = try std.fs.path.join(ctx.allocator, &.{ staging, "installer" });
    const metadata = try extractorMetadataJson(ctx, config, state.hash);
    try concatenateLinuxInstaller(
        ctx,
        platform_paths.extractor,
        metadata,
        state.compressed_tar_path,
        installer_path,
    );

    const app_name = try getAppName(ctx, config.root);
    const readme = try std.fmt.allocPrint(
        ctx.allocator,
        "{s} Installer\n========================\n\nRun ./installer to install {s}.\n\nThe installer extracts the application to ~/.local/share/ and creates a desktop shortcut.\n",
        .{ app_name, app_name },
    );
    try std.Io.Dir.cwd().writeFile(ctx.io, .{
        .sub_path = try std.fs.path.join(ctx.allocator, &.{ staging, "README.txt" }),
        .data = readme,
    });

    const archive_path = try std.fs.path.join(
        ctx.allocator,
        &.{ state.bundle.build_root, try std.mem.concat(ctx.allocator, u8, &.{ installer_name, ".tar.gz" }) },
    );
    var env_map = std.process.Environ.Map.init(ctx.allocator);
    defer env_map.deinit();
    try inheritCurrentEnvironmentFromContext(ctx, &env_map);
    try env_map.put("COPYFILE_DISABLE", "1");
    try runReleaseCommand(ctx, &.{ "tar", "-czf", archive_path, "-C", staging, "." }, ctx.project_root, &env_map);
    return archive_path;
}

fn extractorMetadataJson(ctx: *const Context, config: CommandContext, hash: []const u8) ![]const u8 {
    var object: std.json.ObjectMap = .empty;
    try object.put(ctx.allocator, "identifier", .{ .string = try getAppIdentifier(ctx, config.root) });
    try object.put(ctx.allocator, "name", .{ .string = try getAppName(ctx, config.root) });
    try object.put(ctx.allocator, "channel", .{ .string = buildEnvironmentName(config.build_env) });
    try object.put(ctx.allocator, "hash", .{ .string = hash });
    return std.json.Stringify.valueAlloc(ctx.allocator, std.json.Value{ .object = object }, .{});
}

fn concatenateLinuxInstaller(
    ctx: *const Context,
    extractor_path: []const u8,
    metadata: []const u8,
    archive_path: []const u8,
    output_path: []const u8,
) !void {
    const output = try std.Io.Dir.createFileAbsolute(ctx.io, output_path, .{
        .permissions = .executable_file,
    });
    defer output.close(ctx.io);
    var output_buffer: [64 * 1024]u8 = undefined;
    var writer = output.writer(ctx.io, &output_buffer);

    for ([_][]const u8{ extractor_path, archive_path }, 0..) |input_path, index| {
        if (index == 1) {
            try writer.interface.writeAll("ELECTROBUN_METADATA_V1");
            try writer.interface.writeAll(metadata);
            try writer.interface.writeAll("ELECTROBUN_ARCHIVE_V1");
        }
        const input = try std.Io.Dir.openFileAbsolute(ctx.io, input_path, .{});
        defer input.close(ctx.io);
        var input_buffer: [64 * 1024]u8 = undefined;
        var reader = input.reader(ctx.io, &input_buffer);
        _ = try reader.interface.streamRemaining(&writer.interface);
    }
    try writer.interface.flush();
}

fn writeReleaseArtifacts(
    ctx: *const Context,
    config: CommandContext,
    state: ReleaseState,
    installer_path: ?[]const u8,
) !void {
    const artifact_root = try artifactOutputRoot(ctx, config.root);
    try recreateDir(ctx, artifact_root);
    const prefix = try releasePlatformPrefix(ctx, config);

    var update: std.json.ObjectMap = .empty;
    try update.put(ctx.allocator, "version", .{ .string = try getAppVersion(ctx, config.root) });
    try update.put(ctx.allocator, "hash", .{ .string = state.hash });
    try update.put(ctx.allocator, "platform", .{ .string = osName() });
    try update.put(ctx.allocator, "arch", .{ .string = archName() });
    const update_json = try std.json.Stringify.valueAlloc(
        ctx.allocator,
        std.json.Value{ .object = update },
        .{},
    );
    try std.Io.Dir.cwd().writeFile(ctx.io, .{
        .sub_path = try std.fs.path.join(
            ctx.allocator,
            &.{ artifact_root, try std.mem.concat(ctx.allocator, u8, &.{ prefix, "-update.json" }) },
        ),
        .data = update_json,
    });

    const candidates = [_]?[]const u8{
        state.compressed_tar_path,
        state.patch_path,
        installer_path,
    };
    for (candidates) |candidate| {
        const source = candidate orelse continue;
        if (!pathExists(ctx.io, source)) continue;
        const destination = try std.fs.path.join(
            ctx.allocator,
            &.{ artifact_root, try std.mem.concat(ctx.allocator, u8, &.{ prefix, "-", std.fs.path.basename(source) }) },
        );
        try copyPath(ctx, source, destination);
        std.Io.Dir.cwd().deleteFile(ctx.io, source) catch {};
    }
}

fn runBuiltApp(ctx: *const Context, config: CommandContext) !void {
    const main_process = getMainProcess(config.root);
    switch (main_process) {
        .bun, .cottontail, .zig, .rust, .go, .odin => try runBundledElectrobunApp(ctx, config),
    }
}

fn runInit(ctx: *const Context, args: []const [:0]const u8) !void {
    const templates_root = (try resolveElectrobunTemplatesRoot(ctx)) orelse return error.TemplateRootNotFound;

    var template_name: ?[]const u8 = null;
    var project_name: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--template=")) {
            template_name = arg["--template=".len..];
        } else if (!std.mem.startsWith(u8, arg, "--")) {
            if (project_name == null) {
                project_name = arg;
            } else if (template_name == null) {
                template_name = arg;
            }
        }
    }

    if (template_name == null) {
        if (project_name) |name| {
            const candidate = try std.fs.path.join(ctx.allocator, &.{ templates_root, name });
            if (pathExists(ctx.io, candidate)) {
                template_name = name;
            }
        }
    }

    if (template_name == null) {
        ctx.writeStdout("Available templates:\n", .{});
        var templates_dir = try std.Io.Dir.openDirAbsolute(ctx.io, templates_root, .{ .iterate = true });
        defer templates_dir.close(ctx.io);

        var iterator = templates_dir.iterate();
        while (try iterator.next(ctx.io)) |entry| {
            if (entry.kind == .directory) {
                ctx.writeStdout("  {s}\n", .{entry.name});
            }
        }
        ctx.writeStdout("\nUsage: hutch electrobun init <project-name> --template=<name>\n", .{});
        return;
    }

    if (project_name == null) {
        project_name = template_name;
    }

    const source_dir = try std.fs.path.join(ctx.allocator, &.{ templates_root, template_name.? });
    if (!pathExists(ctx.io, source_dir)) return error.TemplateNotFound;

    const project_dir = try std.fs.path.join(ctx.allocator, &.{ ctx.project_root, project_name.? });
    if (pathExists(ctx.io, project_dir)) return error.ProjectAlreadyExists;

    try copyPath(ctx, source_dir, project_dir);
    ctx.writeStdout("Created Electrobun project at {s}\n", .{project_dir});
    ctx.writeStdout("Next steps:\n  cd {s}\n  hutch run dev\n", .{project_name.?});
}

fn runDevWatch(ctx: *const Context, config: CommandContext) !void {
    try runBuild(ctx, config);

    var child = try spawnBuiltApp(ctx, config);
    defer {
        child.kill(ctx.io);
        _ = child.wait(ctx.io) catch {};
    }

    var last_signature = try watchSignature(ctx, config.root);
    ctx.writeStdout("[electrobun dev --watch] Watching for changes...\n", .{});

    while (true) {
        std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(350), .awake) catch {};
        const next_signature = try watchSignature(ctx, config.root);
        if (next_signature == last_signature) continue;

        last_signature = next_signature;
        ctx.writeStdout("[electrobun dev --watch] Change detected, rebuilding...\n", .{});

        child.kill(ctx.io);
        _ = child.wait(ctx.io) catch {};

        try runBuild(ctx, config);
        child = try spawnBuiltApp(ctx, config);
    }
}

fn buildCottontailApp(ctx: *const Context, config: CommandContext) !void {
    const build_root = try buildOutputRoot(ctx, config);
    const app_dir = try std.fs.path.join(ctx.allocator, &.{ build_root, "app" });
    try std.Io.Dir.cwd().createDirPath(ctx.io, app_dir);

    const main_source = try resolveMainEntrypoint(ctx, config.root, .cottontail);
    const main_output = try std.fs.path.join(ctx.allocator, &.{ app_dir, "main.js" });
    try buildMainEntrypoint(ctx, config.root, .cottontail, main_source, main_output);
    try buildViews(ctx, config.root, app_dir);
    try copyStaticAssets(ctx, config.root, app_dir);
}

fn runCottontailApp(ctx: *const Context, config: CommandContext) !void {
    const build_root = try buildOutputRoot(ctx, config);
    const app_dir = try std.fs.path.join(ctx.allocator, &.{ build_root, "app" });
    const main_script = try std.fs.path.join(ctx.allocator, &.{ app_dir, "main.js" });

    if (!pathExists(ctx.io, main_script)) {
        return error.BuiltMainNotFound;
    }

    var env_map = std.process.Environ.Map.init(ctx.allocator);
    defer env_map.deinit();

    try inheritCurrentEnvironmentFromContext(ctx, &env_map);
    try env_map.put("COTTONTAIL_ELECTROBUN_NAME", try getAppName(ctx, config.root));
    try env_map.put("COTTONTAIL_ELECTROBUN_IDENTIFIER", try getAppIdentifier(ctx, config.root));
    try env_map.put("COTTONTAIL_ELECTROBUN_CHANNEL", buildEnvironmentName(config.build_env));

    if (try resolveElectrobunDist(ctx)) |dist_dir| {
        try env_map.put("COTTONTAIL_ELECTROBUN_DIST", dist_dir);
    }

    const cottontail_binary = try resolveCottontailBinary(ctx);

    var child = try std.process.spawn(ctx.io, .{
        .argv = &[_][]const u8{ cottontail_binary, main_script },
        .cwd = .{ .path = app_dir },
        .environ_map = &env_map,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .create_no_window = true,
    });
    defer child.kill(ctx.io);

    const term = try child.wait(ctx.io);
    if (termExitCode(term) != 0) {
        return error.RunFailed;
    }
}

fn executableFileName(comptime basename: []const u8) []const u8 {
    return switch (builtin.os.tag) {
        .windows => basename ++ ".exe",
        else => basename,
    };
}

fn zigTargetName() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "x86_64-windows",
        .linux => switch (builtin.cpu.arch) {
            .aarch64 => "aarch64-linux",
            else => "x86_64-linux",
        },
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => "aarch64-macos",
            else => "x86_64-macos",
        },
        else => "native",
    };
}

fn appendZigStringLiteral(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
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

fn writeZigMainBuildScript(ctx: *const Context, build_script_path: []const u8, relative_sdk_path: []const u8, relative_entrypoint_path: []const u8) !void {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(ctx.allocator);

    try source.appendSlice(ctx.allocator,
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\
        \\    const electrobun = b.createModule(.{
        \\        .root_source_file = b.path(
    );
    try appendZigStringLiteral(ctx.allocator, &source, relative_sdk_path);
    try source.appendSlice(ctx.allocator,
        \\),
        \\    });
        \\
        \\    const exe = b.addExecutable(.{
        \\        .name = "main",
        \\        .root_source_file = b.path(
    );
    try appendZigStringLiteral(ctx.allocator, &source, relative_entrypoint_path);
    try source.appendSlice(ctx.allocator,
        \\),
        \\        .target = target,
        \\        .optimize = optimize,
        \\    });
        \\
        \\    exe.root_module.addImport("electrobun", electrobun);
        \\    exe.linkLibC();
        \\    b.installArtifact(exe);
        \\}
        \\
    );

    try std.Io.Dir.cwd().writeFile(ctx.io, .{
        .sub_path = build_script_path,
        .data = source.items,
    });
}

fn buildZigMainExecutable(ctx: *const Context, config: CommandContext, platform_paths: PlatformPaths, bundle: AppBundlePaths) ![]const u8 {
    const zig_binary = try std.fs.path.join(ctx.allocator, &.{ platform_paths.package_root, "vendors", "zig", executableFileName("zig") });
    if (!pathExists(ctx.io, zig_binary)) return error.ZigCompilerNotFound;

    const zig_sdk_path = try std.fs.path.join(ctx.allocator, &.{ platform_paths.shared_dist_dir, "zig-sdk", "electrobun.zig" });
    if (!pathExists(ctx.io, zig_sdk_path)) return error.ZigSdkNotFound;

    const entrypoint = try resolveMainEntrypoint(ctx, config.root, .zig);
    if (!pathExists(ctx.io, entrypoint)) return error.ZigEntrypointNotFound;

    const temp_build_dir = try std.fs.path.join(ctx.allocator, &.{ bundle.build_root, ".electrobun-zig-main", try std.fmt.allocPrint(ctx.allocator, "{s}-{s}", .{ osName(), archName() }) });
    try std.Io.Dir.cwd().createDirPath(ctx.io, temp_build_dir);

    const relative_sdk_path = try std.fs.path.relative(ctx.allocator, ctx.project_root, ctx.environ_map, temp_build_dir, zig_sdk_path);
    const relative_entrypoint_path = try std.fs.path.relative(ctx.allocator, ctx.project_root, ctx.environ_map, temp_build_dir, entrypoint);
    const build_script_path = try std.fs.path.join(ctx.allocator, &.{ temp_build_dir, "build.zig" });
    try writeZigMainBuildScript(ctx, build_script_path, relative_sdk_path, relative_entrypoint_path);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.allocator);
    try argv.append(ctx.allocator, zig_binary);
    try argv.append(ctx.allocator, "build");
    try argv.append(ctx.allocator, try std.fmt.allocPrint(ctx.allocator, "-Dtarget={s}", .{zigTargetName()}));
    if (builtin.os.tag == .windows) {
        try argv.append(ctx.allocator, "-Dcpu=baseline");
    }
    if (config.build_env != .dev) {
        try argv.append(ctx.allocator, "-Doptimize=ReleaseSmall");
    }

    const result = try std.process.run(ctx.allocator, ctx.io, .{
        .argv = argv.items,
        .cwd = .{ .path = temp_build_dir },
        .create_no_window = true,
    });
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);

    if (termExitCode(result.term) != 0) {
        if (result.stdout.len > 0) ctx.writeStdout("{s}", .{result.stdout});
        if (result.stderr.len > 0) ctx.writeStderr("{s}", .{result.stderr});
        return error.ZigBuildFailed;
    }

    const zig_out_bin = try std.fs.path.join(ctx.allocator, &.{ temp_build_dir, "zig-out", "bin", executableFileName("main") });
    if (!pathExists(ctx.io, zig_out_bin)) return error.ZigMainBinaryNotFound;
    return zig_out_bin;
}

fn rustTargetName() []const u8 {
    return switch (builtin.os.tag) {
        .windows => switch (builtin.cpu.arch) {
            .aarch64 => "aarch64-pc-windows-msvc",
            else => "x86_64-pc-windows-msvc",
        },
        .linux => switch (builtin.cpu.arch) {
            .aarch64 => "aarch64-unknown-linux-gnu",
            else => "x86_64-unknown-linux-gnu",
        },
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => "aarch64-apple-darwin",
            else => "x86_64-apple-darwin",
        },
        else => "unknown",
    };
}

fn buildRustMainExecutable(ctx: *const Context, config: CommandContext, platform_paths: PlatformPaths, bundle: AppBundlePaths) ![]const u8 {
    const rust_binary = try std.fs.path.join(ctx.allocator, &.{ platform_paths.package_root, "vendors", "rust", "bin", executableFileName("rustc") });
    if (!pathExists(ctx.io, rust_binary)) return error.RustCompilerNotFound;

    const rust_sdk_path = try std.fs.path.join(ctx.allocator, &.{ platform_paths.shared_dist_dir, "rust-sdk", "electrobun.rs" });
    if (!pathExists(ctx.io, rust_sdk_path)) return error.RustSdkNotFound;

    const entrypoint = try resolveMainEntrypoint(ctx, config.root, .rust);
    if (!pathExists(ctx.io, entrypoint)) return error.RustEntrypointNotFound;

    const temp_build_dir = try std.fs.path.join(ctx.allocator, &.{ bundle.build_root, ".electrobun-rust-main", try std.fmt.allocPrint(ctx.allocator, "{s}-{s}", .{ osName(), archName() }) });
    try std.Io.Dir.cwd().createDirPath(ctx.io, temp_build_dir);

    const rust_out_bin = try std.fs.path.join(ctx.allocator, &.{ temp_build_dir, executableFileName("main") });
    const wrapper_path = try std.fs.path.join(ctx.allocator, &.{ temp_build_dir, "main.rs" });
    const rust_sdk_literal = try jsonStringLiteral(ctx, rust_sdk_path);
    const entrypoint_literal = try jsonStringLiteral(ctx, entrypoint);
    const wrapper_source = try std.fmt.allocPrint(
        ctx.allocator,
        \\#[path = {s}]
        \\pub mod electrobun;
        \\
        \\#[path = {s}]
        \\mod user_main;
        \\
        \\fn main() {{
        \\    user_main::main();
        \\}}
        \\
    ,
        .{ rust_sdk_literal, entrypoint_literal },
    );
    try std.Io.Dir.cwd().writeFile(ctx.io, .{
        .sub_path = wrapper_path,
        .data = wrapper_source,
    });

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.allocator);
    try argv.appendSlice(ctx.allocator, &.{ rust_binary, "--edition=2021", wrapper_path, "--target", rustTargetName(), "-o", rust_out_bin });
    if (config.build_env == .dev) {
        try argv.appendSlice(ctx.allocator, &.{ "-C", "opt-level=2", "-C", "debuginfo=0" });
    } else {
        try argv.appendSlice(ctx.allocator, &.{ "-C", "opt-level=z", "-C", "strip=symbols" });
    }

    const result = try std.process.run(ctx.allocator, ctx.io, .{
        .argv = argv.items,
        .cwd = .{ .path = temp_build_dir },
        .create_no_window = true,
    });
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);

    if (termExitCode(result.term) != 0) {
        if (result.stdout.len > 0) ctx.writeStdout("{s}", .{result.stdout});
        if (result.stderr.len > 0) ctx.writeStderr("{s}", .{result.stderr});
        return error.RustBuildFailed;
    }

    if (!pathExists(ctx.io, rust_out_bin)) return error.RustMainBinaryNotFound;
    return rust_out_bin;
}

fn buildGoMainExecutable(ctx: *const Context, config: CommandContext, platform_paths: PlatformPaths, bundle: AppBundlePaths) ![]const u8 {
    const go_binary = try std.fs.path.join(ctx.allocator, &.{ platform_paths.package_root, "vendors", "go", "bin", executableFileName("go") });
    if (!pathExists(ctx.io, go_binary)) return error.GoCompilerNotFound;

    const go_sdk_path = try std.fs.path.join(ctx.allocator, &.{ platform_paths.shared_dist_dir, "go-sdk" });
    if (!pathExists(ctx.io, go_sdk_path)) return error.GoSdkNotFound;

    const entrypoint = try resolveMainEntrypoint(ctx, config.root, .go);
    if (!pathExists(ctx.io, entrypoint)) return error.GoEntrypointNotFound;

    const temp_build_dir = try std.fs.path.join(ctx.allocator, &.{ bundle.build_root, ".electrobun-go-main", try std.fmt.allocPrint(ctx.allocator, "{s}-{s}", .{ osName(), archName() }) });
    try recreateDir(ctx, temp_build_dir);

    const go_path = try std.fs.path.join(ctx.allocator, &.{ temp_build_dir, "gopath" });
    const go_src_path = try std.fs.path.join(ctx.allocator, &.{ go_path, "src" });
    const sdk_dest_path = try std.fs.path.join(ctx.allocator, &.{ go_src_path, "electrobun" });
    const app_dest_path = try std.fs.path.join(ctx.allocator, &.{ go_src_path, "electrobun-app" });
    try std.Io.Dir.cwd().createDirPath(ctx.io, go_src_path);
    try copyPath(ctx, go_sdk_path, sdk_dest_path);
    try copyPath(ctx, std.fs.path.dirname(entrypoint) orelse entrypoint, app_dest_path);

    const go_out_bin = try std.fs.path.join(ctx.allocator, &.{ temp_build_dir, executableFileName("main") });
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.allocator);
    try argv.appendSlice(ctx.allocator, &.{ go_binary, "build", "-o", go_out_bin });
    if (config.build_env != .dev) {
        try argv.append(ctx.allocator, "-ldflags=-s -w");
    }
    try argv.append(ctx.allocator, "electrobun-app");

    var env_map = std.process.Environ.Map.init(ctx.allocator);
    defer env_map.deinit();
    try inheritCurrentEnvironmentFromContext(ctx, &env_map);
    try env_map.put("CGO_ENABLED", "1");
    try env_map.put("GO111MODULE", "off");
    try env_map.put("GOARCH", if (builtin.cpu.arch == .aarch64) "arm64" else "amd64");
    try env_map.put("GOOS", switch (builtin.os.tag) {
        .windows => "windows",
        .macos => "darwin",
        else => "linux",
    });
    try env_map.put("GOPATH", go_path);
    try env_map.put("GOROOT", try std.fs.path.join(ctx.allocator, &.{ platform_paths.package_root, "vendors", "go" }));
    try env_map.put("GOTOOLCHAIN", "local");
    if (builtin.os.tag == .windows) {
        const zig_binary = try std.fs.path.join(ctx.allocator, &.{ platform_paths.package_root, "vendors", "zig", executableFileName("zig") });
        try env_map.put("CC", try std.fmt.allocPrint(ctx.allocator, "{s} cc", .{zig_binary}));
    }

    const result = try std.process.run(ctx.allocator, ctx.io, .{
        .argv = argv.items,
        .cwd = .{ .path = temp_build_dir },
        .environ_map = &env_map,
        .create_no_window = true,
    });
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);

    if (termExitCode(result.term) != 0) {
        if (result.stdout.len > 0) ctx.writeStdout("{s}", .{result.stdout});
        if (result.stderr.len > 0) ctx.writeStderr("{s}", .{result.stderr});
        return error.GoBuildFailed;
    }

    if (!pathExists(ctx.io, go_out_bin)) return error.GoMainBinaryNotFound;
    return go_out_bin;
}

fn buildOdinMainExecutable(ctx: *const Context, config: CommandContext, platform_paths: PlatformPaths, bundle: AppBundlePaths) ![]const u8 {
    const odin_binary = try std.fs.path.join(ctx.allocator, &.{ platform_paths.package_root, "vendors", "odin", executableFileName("odin") });
    if (!pathExists(ctx.io, odin_binary)) return error.OdinCompilerNotFound;

    const odin_sdk_collection = try std.fs.path.join(ctx.allocator, &.{ platform_paths.shared_dist_dir, "odin-sdk" });
    const odin_sdk_path = try std.fs.path.join(ctx.allocator, &.{ odin_sdk_collection, "electrobun", "electrobun.odin" });
    if (!pathExists(ctx.io, odin_sdk_path)) return error.OdinSdkNotFound;

    const entrypoint = try resolveMainEntrypoint(ctx, config.root, .odin);
    if (!pathExists(ctx.io, entrypoint)) return error.OdinEntrypointNotFound;

    const temp_build_dir = try std.fs.path.join(ctx.allocator, &.{ bundle.build_root, ".electrobun-odin-main", try std.fmt.allocPrint(ctx.allocator, "{s}-{s}", .{ osName(), archName() }) });
    try std.Io.Dir.cwd().createDirPath(ctx.io, temp_build_dir);
    const odin_out_bin = try std.fs.path.join(ctx.allocator, &.{ temp_build_dir, executableFileName("main") });
    const entrypoint_dir = std.fs.path.dirname(entrypoint) orelse entrypoint;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.allocator);
    try argv.appendSlice(ctx.allocator, &.{
        odin_binary,
        "build",
        entrypoint_dir,
        try std.fmt.allocPrint(ctx.allocator, "-out:{s}", .{odin_out_bin}),
        try std.fmt.allocPrint(ctx.allocator, "-collection:electrobun_sdk={s}", .{odin_sdk_collection}),
    });
    if (config.build_env != .dev) {
        try argv.append(ctx.allocator, "-o:size");
    }

    const result = try std.process.run(ctx.allocator, ctx.io, .{
        .argv = argv.items,
        .cwd = .{ .path = ctx.project_root },
        .create_no_window = true,
    });
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);

    if (termExitCode(result.term) != 0) {
        if (result.stdout.len > 0) ctx.writeStdout("{s}", .{result.stdout});
        if (result.stderr.len > 0) ctx.writeStderr("{s}", .{result.stderr});
        if (builtin.os.tag == .windows) {
            ctx.writeStderr("Odin on Windows requires link.exe from Visual Studio Build Tools.\n", .{});
        }
        return error.OdinBuildFailed;
    }

    if (!pathExists(ctx.io, odin_out_bin)) return error.OdinMainBinaryNotFound;
    return odin_out_bin;
}

fn copyBundledPreloadScripts(
    ctx: *const Context,
    bundle: AppBundlePaths,
    platform_paths: PlatformPaths,
) !void {
    try copyPath(
        ctx,
        platform_paths.preload_full_js,
        try std.fs.path.join(ctx.allocator, &.{ bundle.resources_dir, "preload-full.js" }),
    );
    try copyPath(
        ctx,
        platform_paths.preload_sandboxed_js,
        try std.fs.path.join(ctx.allocator, &.{ bundle.resources_dir, "preload-sandboxed.js" }),
    );
}

fn buildBundledElectrobunApp(ctx: *const Context, config: CommandContext) !void {
    const platform_paths = try getPlatformPaths(ctx);
    const bundle = try appBundlePaths(ctx, config);
    const main_process = getMainProcess(config.root);

    try std.Io.Dir.cwd().createDirPath(ctx.io, bundle.exec_dir);
    try std.Io.Dir.cwd().createDirPath(ctx.io, bundle.resources_dir);
    try std.Io.Dir.cwd().createDirPath(ctx.io, bundle.app_code_dir);
    if (bundle.frameworks_dir) |frameworks_dir| {
        try std.Io.Dir.cwd().createDirPath(ctx.io, frameworks_dir);
    }

    if (builtin.os.tag == .macos) {
        try writeInfoPlist(ctx, config, bundle);
    }

    try copyPath(ctx, platform_paths.launcher, try std.fs.path.join(ctx.allocator, &.{ bundle.exec_dir, launcherFileName() }));
    if (main_process == .bun) {
        try copyPath(ctx, platform_paths.bun_binary, try std.fs.path.join(ctx.allocator, &.{ bundle.exec_dir, bunBinaryFileName() }));
    }
    if (main_process == .cottontail) {
        try copyPath(ctx, try resolveCottontailBinary(ctx), try std.fs.path.join(ctx.allocator, &.{ bundle.exec_dir, cottontailBinaryFileName() }));
    }
    try copyPath(ctx, platform_paths.core_lib, try std.fs.path.join(ctx.allocator, &.{ bundle.exec_dir, std.fs.path.basename(platform_paths.core_lib) }));
    const native_wrapper_source = selectNativeWrapperPath(
        bundleUsesCef(config.root),
        platform_paths.native_wrapper,
        platform_paths.native_wrapper_cef,
    );
    try copyPath(ctx, native_wrapper_source, try std.fs.path.join(ctx.allocator, &.{ bundle.exec_dir, std.fs.path.basename(platform_paths.native_wrapper) }));
    try copyPath(ctx, platform_paths.libasar, try std.fs.path.join(ctx.allocator, &.{ bundle.exec_dir, std.fs.path.basename(platform_paths.libasar) }));
    if (pathExists(ctx.io, platform_paths.bspatch)) {
        try copyPath(ctx, platform_paths.bspatch, try std.fs.path.join(ctx.allocator, &.{ bundle.exec_dir, std.fs.path.basename(platform_paths.bspatch) }));
    }
    if (pathExists(ctx.io, platform_paths.zig_zstd)) {
        try copyPath(ctx, platform_paths.zig_zstd, try std.fs.path.join(ctx.allocator, &.{ bundle.exec_dir, std.fs.path.basename(platform_paths.zig_zstd) }));
    }

    if (main_process == .bun) {
        try copyPath(ctx, platform_paths.main_js, try std.fs.path.join(ctx.allocator, &.{ bundle.resources_dir, "main.js" }));
    }
    if (main_process == .cottontail) {
        try buildCottontailLauncherScript(ctx, bundle);
    }
    try copyBundledPreloadScripts(ctx, bundle, platform_paths);

    if (bundleUsesWgpu(config.root) and pathExists(ctx.io, platform_paths.wgpu_lib)) {
        try copyPath(ctx, platform_paths.wgpu_lib, try std.fs.path.join(ctx.allocator, &.{ bundle.exec_dir, std.fs.path.basename(platform_paths.wgpu_lib) }));
    }

    if (bundleUsesCef(config.root)) {
        try copyBundledCef(ctx, bundle, platform_paths, main_process);
    }

    try writeBundledRuntimeMetadata(ctx, config, bundle);

    switch (main_process) {
        .bun => {
            const main_source = try resolveMainEntrypoint(ctx, config.root, .bun);
            const bun_dir = try std.fs.path.join(ctx.allocator, &.{ bundle.app_code_dir, "bun" });
            try std.Io.Dir.cwd().createDirPath(ctx.io, bun_dir);
            const main_output = try std.fs.path.join(ctx.allocator, &.{ bun_dir, "index.js" });
            try buildMainEntrypoint(ctx, config.root, .bun, main_source, main_output);
        },
        .zig => {
            const main_binary = try buildZigMainExecutable(ctx, config, platform_paths, bundle);
            try copyPath(ctx, main_binary, try std.fs.path.join(ctx.allocator, &.{ bundle.exec_dir, executableFileName("main") }));
        },
        .rust => {
            const main_binary = try buildRustMainExecutable(ctx, config, platform_paths, bundle);
            try copyPath(ctx, main_binary, try std.fs.path.join(ctx.allocator, &.{ bundle.exec_dir, executableFileName("main") }));
        },
        .go => {
            const main_binary = try buildGoMainExecutable(ctx, config, platform_paths, bundle);
            try copyPath(ctx, main_binary, try std.fs.path.join(ctx.allocator, &.{ bundle.exec_dir, executableFileName("main") }));
        },
        .odin => {
            const main_binary = try buildOdinMainExecutable(ctx, config, platform_paths, bundle);
            try copyPath(ctx, main_binary, try std.fs.path.join(ctx.allocator, &.{ bundle.exec_dir, executableFileName("main") }));
        },
        .cottontail => {
            const main_source = try resolveMainEntrypoint(ctx, config.root, .cottontail);
            const bun_dir = try std.fs.path.join(ctx.allocator, &.{ bundle.app_code_dir, "bun" });
            try std.Io.Dir.cwd().createDirPath(ctx.io, bun_dir);
            const main_output = try std.fs.path.join(ctx.allocator, &.{ bun_dir, "index.js" });
            try buildMainEntrypoint(ctx, config.root, .cottontail, main_source, main_output);
        },
    }

    try buildViews(ctx, config.root, bundle.app_code_dir);
    try copyStaticAssets(ctx, config.root, bundle.app_code_dir);
    try installBundleAssets(ctx, config, bundle);

    const carrot_dir = try buildCarrotOutput(ctx, config, bundle);
    if (carrot_dir) |dir| {
        var extra_env = std.process.Environ.Map.init(ctx.allocator);
        defer extra_env.deinit();
        try extra_env.put("ELECTROBUN_CARROT_DIR", dir);
        try runHook(ctx, config, "postBuild", &extra_env);
    } else {
        try runHook(ctx, config, "postBuild", null);
    }
}

fn relativePathObject(ctx: *const Context, path: []const u8) !std.json.ObjectMap {
    var object: std.json.ObjectMap = .empty;
    try object.put(ctx.allocator, "relativePath", .{ .string = path });
    return object;
}

fn normalizeCarrotDependencies(ctx: *const Context, dependencies: std.json.ObjectMap) !std.json.ObjectMap {
    var normalized: std.json.ObjectMap = .empty;
    var it = dependencies.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == .string and
            (std.mem.startsWith(u8, entry.value_ptr.*.string, "file:") or
                std.mem.startsWith(u8, entry.value_ptr.*.string, "workspace:")))
        {
            try normalized.put(ctx.allocator, entry.key_ptr.*, .{ .string = "*" });
        } else {
            try normalized.put(ctx.allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    return normalized;
}

fn resolvedUiManifest(ctx: *const Context, source: std.json.ObjectMap) !?std.json.ObjectMap {
    var resolved: std.json.ObjectMap = .empty;
    var it = source.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const path = getStringFieldFromObject(entry.value_ptr.*.object, "path") orelse continue;
        const name = getStringFieldFromObject(entry.value_ptr.*.object, "name") orelse entry.key_ptr.*;
        var item: std.json.ObjectMap = .empty;
        try item.put(ctx.allocator, "name", .{ .string = name });
        try item.put(ctx.allocator, "path", .{ .string = path });
        try resolved.put(ctx.allocator, entry.key_ptr.*, .{ .object = item });
    }
    if (resolved.count() == 0) return null;
    return resolved;
}

fn buildCarrotOutput(ctx: *const Context, config: CommandContext, bundle: AppBundlePaths) !?[]const u8 {
    const build = getObjectField(config.root, "build") orelse return null;
    const carrot = getObjectFieldFromObject(build, "carrot") orelse return null;
    const carrot_id = getStringFieldFromObject(carrot, "id") orelse return error.InvalidConfig;
    const carrot_name = getStringFieldFromObject(carrot, "name") orelse carrot_id;
    const carrot_description = getStringFieldFromObject(carrot, "description") orelse "";
    const carrot_mode = getStringFieldFromObject(carrot, "mode") orelse "window";

    const build_root = try buildOutputRoot(ctx, config);
    const carrot_dir = try std.fs.path.join(ctx.allocator, &.{ build_root, "carrot", carrot_id });
    try recreateDir(ctx, carrot_dir);

    const worker_src = try std.fs.path.join(ctx.allocator, &.{ bundle.app_code_dir, "bun", "index.js" });
    if (pathExists(ctx.io, worker_src)) {
        try copyPath(ctx, worker_src, try std.fs.path.join(ctx.allocator, &.{ carrot_dir, "worker.js" }));
    }

    const views_src = try std.fs.path.join(ctx.allocator, &.{ bundle.app_code_dir, "views" });
    if (pathExists(ctx.io, views_src)) {
        try copyPath(ctx, views_src, try std.fs.path.join(ctx.allocator, &.{ carrot_dir, "views" }));
    }

    if (getObjectFieldFromObject(build, "copy")) |copy| {
        var it = copy.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string) continue;
            const built_asset = try std.fs.path.join(ctx.allocator, &.{ bundle.app_code_dir, entry.value_ptr.*.string });
            if (pathExists(ctx.io, built_asset)) {
                try copyPath(ctx, built_asset, try std.fs.path.join(ctx.allocator, &.{ carrot_dir, entry.value_ptr.*.string }));
            }
        }
    }

    var manifest: std.json.ObjectMap = .empty;
    try manifest.put(ctx.allocator, "id", .{ .string = carrot_id });
    try manifest.put(ctx.allocator, "name", .{ .string = carrot_name });
    try manifest.put(ctx.allocator, "version", .{ .string = try getAppVersion(ctx, config.root) });
    try manifest.put(ctx.allocator, "description", .{ .string = carrot_description });
    try manifest.put(ctx.allocator, "mode", .{ .string = carrot_mode });
    if (getObjectFieldFromObject(carrot, "dependencies")) |dependencies| {
        try manifest.put(ctx.allocator, "dependencies", .{ .object = try normalizeCarrotDependencies(ctx, dependencies) });
    } else {
        try manifest.put(ctx.allocator, "dependencies", .{ .object = .empty });
    }
    if (getObjectFieldFromObject(carrot, "contributions")) |contributions| {
        if (contributions.count() > 0) try manifest.put(ctx.allocator, "contributions", .{ .object = contributions });
    }
    try manifest.put(ctx.allocator, "worker", .{ .object = try relativePathObject(ctx, "worker.js") });
    if (pathExists(ctx.io, views_src)) {
        try manifest.put(ctx.allocator, "view", .{ .object = try relativePathObject(ctx, "views/index.html") });
    }
    if (getObjectFieldFromObject(carrot, "remoteUIs")) |remote_uis| {
        if (try resolvedUiManifest(ctx, remote_uis)) |resolved| {
            try manifest.put(ctx.allocator, "remoteUIs", .{ .object = resolved });
        }
    }
    if (getObjectFieldFromObject(carrot, "slateUIs")) |slate_uis| {
        if (try resolvedUiManifest(ctx, slate_uis)) |resolved| {
            try manifest.put(ctx.allocator, "slateUIs", .{ .object = resolved });
        }
    }

    const manifest_json = try std.json.Stringify.valueAlloc(ctx.allocator, std.json.Value{ .object = manifest }, .{});
    try std.Io.Dir.cwd().writeFile(ctx.io, .{
        .sub_path = try std.fs.path.join(ctx.allocator, &.{ carrot_dir, "carrot.json" }),
        .data = manifest_json,
    });
    ctx.writeStdout("Carrot built: {s} v{s}\n", .{ carrot_id, try getAppVersion(ctx, config.root) });
    return carrot_dir;
}

fn runBundledElectrobunApp(ctx: *const Context, config: CommandContext) !void {
    var child = try spawnBuiltApp(ctx, config);
    defer child.kill(ctx.io);

    const term = try child.wait(ctx.io);
    if (termExitCode(term) != 0) {
        return error.RunFailed;
    }
}

fn buildCottontailLauncherScript(ctx: *const Context, bundle: AppBundlePaths) !void {
    const output_path = try std.fs.path.join(ctx.allocator, &.{ bundle.resources_dir, "main.js" });
    try std.Io.Dir.cwd().writeFile(ctx.io, .{
        .sub_path = output_path,
        .data = "import \"./app/bun/index.js\";\n",
    });
}

fn spawnBuiltApp(ctx: *const Context, config: CommandContext) !std.process.Child {
    return switch (getMainProcess(config.root)) {
        .bun, .cottontail, .zig, .rust, .go, .odin => blk: {
            const bundle = try appBundlePaths(ctx, config);
            const launcher_path = try std.fs.path.join(ctx.allocator, &.{ bundle.exec_dir, launcherFileName() });
            if (!pathExists(ctx.io, launcher_path)) return error.BuiltMainNotFound;

            break :blk try std.process.spawn(ctx.io, .{
                .argv = &[_][]const u8{launcher_path},
                .cwd = .{ .path = bundle.exec_dir },
                .stdin = .inherit,
                .stdout = .inherit,
                .stderr = .inherit,
                .create_no_window = true,
            });
        },
    };
}

fn runHook(ctx: *const Context, config: CommandContext, hook_name: []const u8, extra_env: ?*const std.process.Environ.Map) !void {
    const scripts = getObjectField(config.root, "scripts") orelse return;
    const hook_value = scripts.get(hook_name) orelse return;
    if (hook_value != .string or hook_value.string.len == 0) return;

    const tmp_dir = try ensureCliTempDir(ctx);
    const hook_source = try absoluteProjectPath(ctx, hook_value.string);
    const hook_wrapper = try std.fs.path.join(ctx.allocator, &.{ tmp_dir, "hook.runner.ts" });
    const hook_source_literal = try jsonStringLiteral(ctx, hook_source);

    const helper_source = try std.mem.replaceOwned(
        u8,
        ctx.allocator,
        run_hook_template,
        "\"./__MODULE_NAME__\"",
        hook_source_literal,
    );
    try std.Io.Dir.cwd().writeFile(ctx.io, .{
        .sub_path = hook_wrapper,
        .data = helper_source,
    });

    var env_map = std.process.Environ.Map.init(ctx.allocator);
    defer env_map.deinit();

    try inheritCurrentEnvironmentFromContext(ctx, &env_map);
    try env_map.put("ELECTROBUN_BUILD_ENV", buildEnvironmentName(config.build_env));
    try env_map.put("ELECTROBUN_OS", osName());
    try env_map.put("ELECTROBUN_ARCH", archName());
    try env_map.put("ELECTROBUN_BUILD_DIR", try buildOutputRoot(ctx, config));
    try env_map.put("ELECTROBUN_APP_NAME", try getAppName(ctx, config.root));
    try env_map.put("ELECTROBUN_APP_VERSION", try getAppVersion(ctx, config.root));
    try env_map.put("ELECTROBUN_APP_IDENTIFIER", try getAppIdentifier(ctx, config.root));
    try env_map.put("ELECTROBUN_ARTIFACT_DIR", try artifactOutputRoot(ctx, config.root));

    if (extra_env) |map| {
        var it = map.iterator();
        while (it.next()) |entry| {
            try env_map.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    var child = try std.process.spawn(ctx.io, .{
        .argv = &[_][]const u8{ try resolveCottontailBinary(ctx), hook_wrapper },
        .cwd = .{ .path = ctx.project_root },
        .environ_map = &env_map,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .create_no_window = true,
    });
    defer child.kill(ctx.io);

    const term = try child.wait(ctx.io);
    if (termExitCode(term) != 0) {
        return error.HookFailed;
    }
}

fn jsonStringLiteral(ctx: *const Context, value: []const u8) ![]const u8 {
    return try std.json.Stringify.valueAlloc(ctx.allocator, std.json.Value{ .string = value }, .{});
}

fn buildMainEntrypoint(ctx: *const Context, root: std.json.Value, main_process: MainProcess, source_path: []const u8, output_path: []const u8) !void {
    const build = getObjectField(root, "build") orelse return error.InvalidConfig;
    const options = switch (main_process) {
        .cottontail => getObjectFieldFromObject(build, "cottontail") orelse getObjectFieldFromObject(build, "main") orelse getObjectFieldFromObject(build, "bun"),
        .bun => getObjectFieldFromObject(build, "bun") orelse std.json.ObjectMap.empty,
        .zig, .rust, .go, .odin => null,
    } orelse return error.InvalidConfig;

    const entry_path = source_path;

    var spec: std.json.ObjectMap = .empty;
    try spec.put(ctx.allocator, "entryPoints", .{ .array = try singleValueArray(ctx.allocator, .{ .string = entry_path }) });
    try spec.put(ctx.allocator, "bundle", .{ .bool = true });
    try spec.put(ctx.allocator, "platform", .{ .string = switch (main_process) {
        .bun => "node",
        else => "neutral",
    } });
    try spec.put(ctx.allocator, "format", .{ .string = "esm" });
    try spec.put(ctx.allocator, "outfile", .{ .string = output_path });

    try appendSharedEsbuildOptions(ctx, &spec, options, .main);
    if (main_process == .bun) {
        try addExternalStrings(ctx, &spec, &.{ "bun", "bun:ffi" });
    }
    try addElectrobunImportAliases(ctx, &spec, main_process, getObjectFieldFromObject(build, "carrot") != null);
    try runCottontailBuild(ctx, .{ .object = spec });
}

fn buildViews(ctx: *const Context, root: std.json.Value, app_dir: []const u8) !void {
    const build = getObjectField(root, "build") orelse return;
    const views = getObjectFieldFromObject(build, "views") orelse return;

    var it = views.iterator();
    while (it.next()) |entry| {
        const view_name = entry.key_ptr.*;
        const view_value = entry.value_ptr.*;
        if (view_value != .object) continue;

        const entrypoint = getStringFieldFromObject(view_value.object, "entrypoint") orelse continue;
        const source_path = try absoluteProjectPath(ctx, entrypoint);
        const output_dir = try std.fs.path.join(ctx.allocator, &.{ app_dir, "views", view_name });
        const output_file = try std.fs.path.join(ctx.allocator, &.{ output_dir, "index.js" });

        try std.Io.Dir.cwd().createDirPath(ctx.io, output_dir);

        var spec: std.json.ObjectMap = .empty;
        try spec.put(ctx.allocator, "entryPoints", .{ .array = try singleValueArray(ctx.allocator, .{ .string = source_path }) });
        try spec.put(ctx.allocator, "bundle", .{ .bool = true });
        try spec.put(ctx.allocator, "platform", .{ .string = "browser" });
        try spec.put(ctx.allocator, "outfile", .{ .string = output_file });

        try appendSharedEsbuildOptions(ctx, &spec, view_value.object, .view);
        try addElectrobunImportAliases(ctx, &spec, null, getObjectFieldFromObject(build, "carrot") != null);
        try runCottontailBuild(ctx, .{ .object = spec });
    }
}

fn copyStaticAssets(ctx: *const Context, root: std.json.Value, app_dir: []const u8) !void {
    const build = getObjectField(root, "build") orelse return;
    const copy = getObjectFieldFromObject(build, "copy") orelse return;

    var it = copy.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;

        const source_path = try absoluteProjectPath(ctx, entry.key_ptr.*);
        const dest_path = try std.fs.path.join(ctx.allocator, &.{ app_dir, entry.value_ptr.*.string });
        try copyPath(ctx, source_path, dest_path);
    }
}

fn appendSharedEsbuildOptions(
    ctx: *const Context,
    spec: *std.json.ObjectMap,
    object: std.json.ObjectMap,
    comptime kind: enum { main, view },
) !void {
    if (getBoolFieldFromObject(object, "minify")) {
        try spec.put(ctx.allocator, "minify", .{ .bool = true });
    }

    if (getValueFieldFromObject(object, "sourcemap")) |value| {
        switch (value) {
            .bool, .string => try spec.put(ctx.allocator, "sourcemap", value),
            else => {},
        }
    }

    if (kind == .view) {
        if (getStringFieldFromObject(object, "format")) |format| {
            try spec.put(ctx.allocator, "format", .{ .string = format });
        }
    }

    if (getValueFieldFromObject(object, "target")) |value| {
        switch (value) {
            .string, .array => try spec.put(ctx.allocator, "target", value),
            else => {},
        }
    }

    if (getValueFieldFromObject(object, "external")) |value| {
        if (value == .array) try spec.put(ctx.allocator, "external", value);
    }

    if (getValueFieldFromObject(object, "define")) |value| {
        if (value == .object) try spec.put(ctx.allocator, "define", value);
    }

    if (getValueFieldFromObject(object, "alias")) |value| {
        if (value == .object) try spec.put(ctx.allocator, "alias", value);
    }
}

fn addElectrobunImportAliases(
    ctx: *const Context,
    spec: *std.json.ObjectMap,
    main_process: ?MainProcess,
    use_runtime_sdk_aliases: bool,
) !void {
    const package_root = (try resolveElectrobunPackageRoot(ctx)) orelse return;

    const default_bun_sdk = try std.fs.path.join(ctx.allocator, &.{ package_root, "dist", "api", "sdks", "bun", "index.ts" });
    const default_view_sdk = try std.fs.path.join(ctx.allocator, &.{ package_root, "dist", "api", "browser", "index.ts" });
    const bun_sdk = if (use_runtime_sdk_aliases)
        (try optionalEnvProjectPath(ctx, "DASH_RUNTIME_SDK_BUN_MODULE")) orelse default_bun_sdk
    else
        default_bun_sdk;
    const view_sdk = if (use_runtime_sdk_aliases)
        (try optionalEnvProjectPath(ctx, "DASH_RUNTIME_SDK_VIEW_MODULE")) orelse default_view_sdk
    else
        default_view_sdk;

    var alias: std.json.ObjectMap = .empty;
    try alias.put(ctx.allocator, "electrobun", .{ .string = bun_sdk });
    try alias.put(ctx.allocator, "electrobun/bun", .{ .string = bun_sdk });
    try alias.put(ctx.allocator, "electrobun/cottontail", .{ .string = bun_sdk });
    try alias.put(ctx.allocator, "electrobun/view", .{ .string = view_sdk });

    // Cottontail's Bun.build resolves its Bun and Node compatibility modules
    // from the runtime blob embedded in the binary. Only Electrobun SDK imports
    // need filesystem aliases here.
    _ = main_process;

    if (getValueFieldFromObject(spec.*, "alias")) |existing_alias| {
        if (existing_alias == .object) {
            var it = existing_alias.object.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* == .string) {
                    try alias.put(ctx.allocator, entry.key_ptr.*, entry.value_ptr.*);
                }
            }
        }
    }

    try spec.put(ctx.allocator, "alias", .{ .object = alias });
}

fn optionalEnvProjectPath(ctx: *const Context, name: []const u8) !?[]const u8 {
    const raw = ctx.environ_map.get(name) orelse return null;
    const value = std.mem.trim(u8, raw, " \r\n\t");
    if (value.len == 0) return null;
    return try absoluteProjectPath(ctx, value);
}

fn runCottontailBuild(ctx: *const Context, build_spec: std.json.Value) !void {
    if (build_spec != .object) {
        return error.InvalidBuildSpec;
    }

    const tmp_dir = try ensureCliTempDir(ctx);
    const helper_path = try std.fs.path.join(ctx.allocator, &.{ tmp_dir, "cottontail-build-helper.mjs" });
    const spec_path = try std.fs.path.join(ctx.allocator, &.{ tmp_dir, "cottontail-build-spec.json" });
    const spec_json = try std.json.Stringify.valueAlloc(ctx.allocator, build_spec, .{});
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = helper_path, .data = build_helper_template });
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = spec_path, .data = spec_json });

    const result = try std.process.run(ctx.allocator, ctx.io, .{
        .argv = &[_][]const u8{ try resolveCottontailBinary(ctx), helper_path, spec_path },
        .cwd = .{ .path = ctx.project_root },
        .create_no_window = true,
    });
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);

    if (termExitCode(result.term) != 0) {
        if (result.stdout.len > 0) ctx.writeStdout("{s}", .{result.stdout});
        if (result.stderr.len > 0) ctx.writeStderr("{s}", .{result.stderr});
        return error.CottontailBuildFailed;
    }
}

fn copyPath(ctx: *const Context, source_path: []const u8, dest_path: []const u8) !void {
    if (std.Io.Dir.cwd().statFile(ctx.io, source_path, .{})) |stat| {
        switch (stat.kind) {
            .file, .sym_link => {
                try ensureParentDir(ctx, dest_path);
                try std.Io.Dir.copyFileAbsolute(source_path, dest_path, ctx.io, .{});
                return;
            },
            .directory => {
                try std.Io.Dir.cwd().createDirPath(ctx.io, dest_path);
                var src_dir = try std.Io.Dir.openDirAbsolute(ctx.io, source_path, .{ .iterate = true });
                defer src_dir.close(ctx.io);

                var walker = try src_dir.walk(ctx.allocator);
                defer walker.deinit();

                while (try walker.next(ctx.io)) |entry| {
                    const target_path = try std.fs.path.join(ctx.allocator, &.{ dest_path, entry.path });
                    switch (entry.kind) {
                        .directory => try std.Io.Dir.cwd().createDirPath(ctx.io, target_path),
                        .file, .sym_link => {
                            const source_file = try std.fs.path.join(ctx.allocator, &.{ source_path, entry.path });
                            try ensureParentDir(ctx, target_path);
                            try std.Io.Dir.copyFileAbsolute(source_file, target_path, ctx.io, .{});
                        },
                        else => {},
                    }
                }
                return;
            },
            else => return,
        }
    } else |_| {
        return error.CopySourceMissing;
    }
}

fn ensureParentDir(ctx: *const Context, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    try std.Io.Dir.cwd().createDirPath(ctx.io, parent);
}

fn recreateDir(ctx: *const Context, absolute_path: []const u8) !void {
    if (pathExists(ctx.io, absolute_path)) {
        std.Io.Dir.cwd().deleteTree(ctx.io, absolute_path) catch {};
    }
    try std.Io.Dir.cwd().createDirPath(ctx.io, absolute_path);
}

fn ensureCliTempDir(ctx: *const Context) ![]const u8 {
    const tmp_dir = try std.fs.path.join(ctx.allocator, &.{ ctx.project_root, ".cottontail-tmp", "electrobun" });
    try std.Io.Dir.cwd().createDirPath(ctx.io, tmp_dir);
    return tmp_dir;
}

fn singleValueArray(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Array {
    const items = try allocator.alloc(std.json.Value, 1);
    items[0] = value;
    return .fromOwnedSlice(allocator, items);
}

fn addExternalStrings(ctx: *const Context, spec: *std.json.ObjectMap, values: []const []const u8) !void {
    const existing = spec.get("external");
    const existing_items = if (existing != null and existing.? == .array) existing.?.array.items else &[_]std.json.Value{};
    const items = try ctx.allocator.alloc(std.json.Value, existing_items.len + values.len);

    for (existing_items, 0..) |item, index| {
        items[index] = item;
    }
    for (values, 0..) |value, index| {
        items[existing_items.len + index] = .{ .string = value };
    }

    try spec.put(ctx.allocator, "external", .{ .array = .fromOwnedSlice(ctx.allocator, items) });
}

fn findConfigPath(ctx: *const Context) ?[]const u8 {
    const candidates = [_][]const u8{
        "electrobun.config.ts",
        "electrobun.config.mts",
        "electrobun.config.js",
        "electrobun.config.mjs",
    };

    for (candidates) |candidate| {
        const absolute = std.fs.path.join(ctx.allocator, &.{ ctx.project_root, candidate }) catch continue;
        if (pathExists(ctx.io, absolute)) return absolute;
    }

    return null;
}

fn resolveMainEntrypoint(ctx: *const Context, root: std.json.Value, main_process: MainProcess) ![]const u8 {
    const build = getObjectField(root, "build") orelse return error.InvalidConfig;

    const relative = switch (main_process) {
        .cottontail => blk: {
            if (getObjectFieldFromObject(build, "cottontail")) |object| {
                if (getStringFieldFromObject(object, "entrypoint")) |path| break :blk path;
            }
            if (getObjectFieldFromObject(build, "main")) |object| {
                if (getStringFieldFromObject(object, "entrypoint")) |path| break :blk path;
            }
            if (getObjectFieldFromObject(build, "bun")) |object| {
                if (getStringFieldFromObject(object, "entrypoint")) |path| break :blk path;
            }
            break :blk "src/main.ts";
        },
        .bun => blk: {
            if (getObjectFieldFromObject(build, "bun")) |object| {
                if (getStringFieldFromObject(object, "entrypoint")) |path| break :blk path;
            }
            break :blk "src/bun/index.ts";
        },
        .zig => blk: {
            if (getObjectFieldFromObject(build, "zig")) |object| {
                if (getStringFieldFromObject(object, "entrypoint")) |path| break :blk path;
            }
            break :blk "src/zig/main.zig";
        },
        .rust => blk: {
            if (getObjectFieldFromObject(build, "rust")) |object| {
                if (getStringFieldFromObject(object, "entrypoint")) |path| break :blk path;
            }
            break :blk "src/rust/main.rs";
        },
        .go => blk: {
            if (getObjectFieldFromObject(build, "go")) |object| {
                if (getStringFieldFromObject(object, "entrypoint")) |path| break :blk path;
            }
            break :blk "src/go/main.go";
        },
        .odin => blk: {
            if (getObjectFieldFromObject(build, "odin")) |object| {
                if (getStringFieldFromObject(object, "entrypoint")) |path| break :blk path;
            }
            break :blk "src/odin/main.odin";
        },
    };

    return absoluteProjectPath(ctx, relative);
}

fn absoluteProjectPath(ctx: *const Context, relative_or_absolute: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(relative_or_absolute)) {
        return relative_or_absolute;
    }
    return std.fs.path.join(ctx.allocator, &.{ ctx.project_root, relative_or_absolute });
}

fn buildOutputRoot(ctx: *const Context, config: CommandContext) ![]const u8 {
    const build = getObjectField(config.root, "build") orelse return error.InvalidConfig;
    const build_folder = getStringFieldFromObject(build, "buildFolder") orelse "build";
    const prefix = try std.fmt.allocPrint(ctx.allocator, "{s}-{s}-{s}", .{
        buildEnvironmentName(config.build_env),
        osName(),
        archName(),
    });
    return std.fs.path.join(ctx.allocator, &.{ ctx.project_root, build_folder, prefix });
}

fn artifactOutputRoot(ctx: *const Context, root: std.json.Value) ![]const u8 {
    const build = getObjectField(root, "build") orelse return error.InvalidConfig;
    const artifact_folder = getStringFieldFromObject(build, "artifactFolder") orelse "artifacts";
    return std.fs.path.join(ctx.allocator, &.{ ctx.project_root, artifact_folder });
}

fn getMainProcess(root: std.json.Value) MainProcess {
    const build = getObjectField(root, "build") orelse return .cottontail;
    const value = getStringFieldFromObject(build, "mainProcess") orelse "cottontail";
    if (std.mem.eql(u8, value, "cottontail")) return .cottontail;
    if (std.mem.eql(u8, value, "zig")) return .zig;
    if (std.mem.eql(u8, value, "rust")) return .rust;
    if (std.mem.eql(u8, value, "go")) return .go;
    if (std.mem.eql(u8, value, "odin")) return .odin;
    return .bun;
}

fn mainProcessName(main_process: MainProcess) []const u8 {
    return switch (main_process) {
        .bun => "bun",
        .cottontail => "cottontail",
        .zig => "zig",
        .rust => "rust",
        .go => "go",
        .odin => "odin",
    };
}

fn getAppName(_: *const Context, root: std.json.Value) ![]const u8 {
    const app = getObjectField(root, "app") orelse return error.InvalidConfig;
    return getStringFieldFromObject(app, "name") orelse error.InvalidConfig;
}

fn getAppIdentifier(_: *const Context, root: std.json.Value) ![]const u8 {
    const app = getObjectField(root, "app") orelse return error.InvalidConfig;
    return getStringFieldFromObject(app, "identifier") orelse error.InvalidConfig;
}

fn getAppVersion(_: *const Context, root: std.json.Value) ![]const u8 {
    const app = getObjectField(root, "app") orelse return error.InvalidConfig;
    return getStringFieldFromObject(app, "version") orelse error.InvalidConfig;
}

fn getObjectField(value: std.json.Value, field: []const u8) ?std.json.ObjectMap {
    if (value != .object) return null;
    return getObjectFieldFromObject(value.object, field);
}

fn getObjectFieldFromObject(object: std.json.ObjectMap, field: []const u8) ?std.json.ObjectMap {
    const value = object.get(field) orelse return null;
    if (value != .object) return null;
    return value.object;
}

fn getStringFieldFromObject(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn getBoolFieldFromObject(object: std.json.ObjectMap, field: []const u8) bool {
    const value = object.get(field) orelse return false;
    if (value != .bool) return false;
    return value.bool;
}

fn getValueFieldFromObject(object: std.json.ObjectMap, field: []const u8) ?std.json.Value {
    return object.get(field);
}

fn buildEnvironmentName(build_env: BuildEnvironment) []const u8 {
    return switch (build_env) {
        .dev => "dev",
        .canary => "canary",
        .production => "production",
    };
}

fn osName() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "win",
        .macos => "macos",
        else => "linux",
    };
}

fn archName() []const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x64",
        else => "unknown",
    };
}

fn inheritCurrentEnvironmentFromContext(ctx: *const Context, env_map: *std.process.Environ.Map) !void {
    var it = ctx.environ_map.iterator();
    while (it.next()) |entry| {
        try env_map.put(entry.key_ptr.*, entry.value_ptr.*);
    }
}

fn watchSignature(ctx: *const Context, root: std.json.Value) !u64 {
    var roots = try collectWatchRoots(ctx, root);
    defer roots.deinit(ctx.allocator);

    var hasher = std.hash.Wyhash.init(0);
    for (roots.items) |root_path| {
        if (!pathExists(ctx.io, root_path)) continue;

        if (std.Io.Dir.cwd().statFile(ctx.io, root_path, .{})) |stat| {
            if (stat.kind == .file) {
                if (!shouldIgnoreWatchPath(ctx, root, root_path)) {
                    hasher.update(root_path);
                    hasher.update(std.mem.asBytes(&stat.size));
                    hasher.update(std.mem.asBytes(&stat.mtime));
                }
                continue;
            }
        } else |_| {}

        var dir = try std.Io.Dir.openDirAbsolute(ctx.io, root_path, .{ .iterate = true });
        defer dir.close(ctx.io);

        var walker = try dir.walk(ctx.allocator);
        defer walker.deinit();

        while (try walker.next(ctx.io)) |entry| {
            if (entry.kind != .file) continue;
            const full_path = try std.fs.path.join(ctx.allocator, &.{ root_path, entry.path });
            if (shouldIgnoreWatchPath(ctx, root, full_path)) continue;
            const stat = std.Io.Dir.cwd().statFile(ctx.io, full_path, .{}) catch continue;
            hasher.update(full_path);
            hasher.update(std.mem.asBytes(&stat.size));
            hasher.update(std.mem.asBytes(&stat.mtime));
        }
    }

    return hasher.final();
}

fn collectWatchRoots(ctx: *const Context, root: std.json.Value) !std.ArrayList([]const u8) {
    var roots: std.ArrayList([]const u8) = .empty;
    const build = getObjectField(root, "build") orelse return roots;

    const main_process = getMainProcess(root);
    if (main_process != .zig) {
        const main_entry = try resolveMainEntrypoint(ctx, root, main_process);
        try appendWatchRoot(ctx, &roots, dirnameOrSelf(main_entry));
    }

    if (getObjectFieldFromObject(build, "views")) |views| {
        var it = views.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .object) continue;
            const entrypoint = getStringFieldFromObject(entry.value_ptr.*.object, "entrypoint") orelse continue;
            try appendWatchRoot(ctx, &roots, dirnameOrSelf(try absoluteProjectPath(ctx, entrypoint)));
        }
    }

    if (getObjectFieldFromObject(build, "copy")) |copy| {
        var it = copy.iterator();
        while (it.next()) |entry| {
            const source_path = try absoluteProjectPath(ctx, entry.key_ptr.*);
            try appendWatchRoot(ctx, &roots, dirnameOrSelf(source_path));
        }
    }

    if (getValueFieldFromObject(build, "watch")) |watch_value| {
        if (watch_value == .array) {
            for (watch_value.array.items) |item| {
                if (item != .string) continue;
                try appendWatchRoot(ctx, &roots, dirnameOrSelf(try absoluteProjectPath(ctx, item.string)));
            }
        }
    }

    return roots;
}

fn appendWatchRoot(ctx: *const Context, roots: *std.ArrayList([]const u8), path: []const u8) !void {
    for (roots.items) |existing| {
        if (std.mem.eql(u8, existing, path)) return;
    }
    try roots.append(ctx.allocator, path);
}

fn dirnameOrSelf(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse path;
}

fn shouldIgnoreWatchPath(ctx: *const Context, root: std.json.Value, full_path: []const u8) bool {
    if (std.mem.indexOf(u8, full_path, "/node_modules/") != null) return true;
    if (std.mem.indexOf(u8, full_path, "\\node_modules\\") != null) return true;
    if (std.mem.indexOf(u8, full_path, "/.cottontail-tmp/") != null) return true;

    const build = getObjectField(root, "build") orelse return false;
    const build_folder = getStringFieldFromObject(build, "buildFolder") orelse "build";
    const artifact_folder = getStringFieldFromObject(build, "artifactFolder") orelse "artifacts";
    const build_root = std.fs.path.join(ctx.allocator, &.{ ctx.project_root, build_folder }) catch return false;
    const artifact_root = std.fs.path.join(ctx.allocator, &.{ ctx.project_root, artifact_folder }) catch return false;

    if (std.mem.startsWith(u8, full_path, build_root)) return true;
    if (std.mem.startsWith(u8, full_path, artifact_root)) return true;

    if (getValueFieldFromObject(build, "watchIgnore")) |ignore_value| {
        if (ignore_value == .array) {
            const relative = if (std.mem.startsWith(u8, full_path, ctx.project_root))
                full_path[@min(full_path.len, ctx.project_root.len + 1)..]
            else
                full_path;

            for (ignore_value.array.items) |item| {
                if (item != .string) continue;
                if (watchIgnoreMatches(relative, item.string)) return true;
            }
        }
    }

    return false;
}

fn watchIgnoreMatches(relative_path: []const u8, pattern: []const u8) bool {
    if (std.mem.eql(u8, relative_path, pattern)) return true;
    if (std.mem.endsWith(u8, pattern, "/**")) {
        const prefix = pattern[0 .. pattern.len - 3];
        return std.mem.startsWith(u8, relative_path, prefix);
    }
    return false;
}

fn launcherFileName() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "launcher.exe",
        else => "launcher",
    };
}

fn bunBinaryFileName() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "bun.exe",
        else => "bun",
    };
}

fn cottontailBinaryFileName() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "cottontail.exe",
        else => "cottontail",
    };
}

fn resolveCottontailBinary(ctx: *const Context) ![]const u8 {
    if (!pathExists(ctx.io, ctx.cottontail_binary)) return error.CottontailNotFound;
    return ctx.cottontail_binary;
}

fn resolveElectrobunPackageRoot(ctx: *const Context) !?[]const u8 {
    if (ctx.environ_map.get("COTTONTAIL_ELECTROBUN_PACKAGE")) |package_root| {
        if (pathExists(ctx.io, package_root)) return package_root;
    }

    const exe_dir = std.fs.path.dirname(ctx.self_exe_path) orelse ".";
    const executable_candidates = [_][]const u8{
        exe_dir,
        try std.fs.path.join(ctx.allocator, &.{ exe_dir, ".." }),
    };
    for (executable_candidates) |candidate| {
        if (pathExists(ctx.io, try std.fs.path.join(ctx.allocator, &.{ candidate, "package.json" }))) return candidate;
    }

    const sibling_repo = try std.fs.path.join(ctx.allocator, &.{ ctx.cottontail_home, "..", "electrobun", "package" });
    if (pathExists(ctx.io, try std.fs.path.join(ctx.allocator, &.{ sibling_repo, "package.json" }))) return sibling_repo;

    var current = ctx.project_root;

    while (true) {
        const candidate = try std.fs.path.join(ctx.allocator, &.{ current, "node_modules", "electrobun" });
        if (pathExists(ctx.io, try std.fs.path.join(ctx.allocator, &.{ candidate, "package.json" }))) return candidate;

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        current = parent;
    }

    return null;
}

fn resolveElectrobunDist(ctx: *const Context) !?[]const u8 {
    const package_root = (try resolveElectrobunPackageRoot(ctx)) orelse return null;
    const candidate = try std.fs.path.join(ctx.allocator, &.{ package_root, "dist" });
    if (pathExists(ctx.io, candidate)) return candidate;
    return null;
}

fn resolveElectrobunTemplatesRoot(ctx: *const Context) !?[]const u8 {
    const package_root = (try resolveElectrobunPackageRoot(ctx)) orelse return null;
    const in_package = try std.fs.path.join(ctx.allocator, &.{ package_root, "templates" });
    if (pathExists(ctx.io, in_package)) return in_package;

    const sibling_templates = try std.fs.path.join(ctx.allocator, &.{ package_root, "..", "templates" });
    if (pathExists(ctx.io, sibling_templates)) return sibling_templates;

    return null;
}

fn getPlatformPaths(ctx: *const Context) !PlatformPaths {
    const package_root = (try resolveElectrobunPackageRoot(ctx)) orelse return error.ElectrobunPackageNotFound;
    const shared_dist_dir = try std.fs.path.join(ctx.allocator, &.{ package_root, "dist" });
    const platform_dist_dir = blk: {
        // Local package builds place a complete, current host runtime in dist/.
        // Prefer it over a potentially stale downloaded dist-<os>-<arch>/ cache.
        const shared_launcher = try std.fs.path.join(ctx.allocator, &.{ shared_dist_dir, launcherFileName() });
        if (pathExists(ctx.io, shared_launcher)) break :blk shared_dist_dir;

        const candidate = try std.fmt.allocPrint(ctx.allocator, "{s}/dist-{s}-{s}", .{
            package_root,
            osName(),
            archName(),
        });
        if (pathExists(ctx.io, candidate)) break :blk candidate;
        break :blk shared_dist_dir;
    };

    return .{
        .package_root = package_root,
        .shared_dist_dir = shared_dist_dir,
        .platform_dist_dir = platform_dist_dir,
        .launcher = try std.fs.path.join(ctx.allocator, &.{ platform_dist_dir, launcherFileName() }),
        .bun_binary = try std.fs.path.join(ctx.allocator, &.{ platform_dist_dir, bunBinaryFileName() }),
        .main_js = try std.fs.path.join(ctx.allocator, &.{ platform_dist_dir, "main.js" }),
        .preload_full_js = try std.fs.path.join(ctx.allocator, &.{ platform_dist_dir, "preload-full.js" }),
        .preload_sandboxed_js = try std.fs.path.join(ctx.allocator, &.{ platform_dist_dir, "preload-sandboxed.js" }),
        .core_lib = try std.fs.path.join(ctx.allocator, &.{ platform_dist_dir, switch (builtin.os.tag) {
            .windows => "ElectrobunCore.dll",
            .macos => "libElectrobunCore.dylib",
            else => "libElectrobunCore.so",
        } }),
        .native_wrapper = try std.fs.path.join(ctx.allocator, &.{ platform_dist_dir, switch (builtin.os.tag) {
            .windows => "libNativeWrapper.dll",
            .macos => "libNativeWrapper.dylib",
            else => "libNativeWrapper.so",
        } }),
        .native_wrapper_cef = try std.fs.path.join(ctx.allocator, &.{ platform_dist_dir, switch (builtin.os.tag) {
            .linux => "libNativeWrapper_cef.so",
            .windows => "libNativeWrapper.dll",
            .macos => "libNativeWrapper.dylib",
            else => "libNativeWrapper.so",
        } }),
        .libasar = try std.fs.path.join(ctx.allocator, &.{ platform_dist_dir, switch (builtin.os.tag) {
            .windows => "libasar.dll",
            .macos => "libasar.dylib",
            else => "libasar.so",
        } }),
        .process_helper = try std.fs.path.join(ctx.allocator, &.{ platform_dist_dir, switch (builtin.os.tag) {
            .windows => "process_helper.exe",
            else => "process_helper",
        } }),
        .cef_dir = try std.fs.path.join(ctx.allocator, &.{ platform_dist_dir, "cef" }),
        .wgpu_lib = try std.fs.path.join(ctx.allocator, &.{ platform_dist_dir, switch (builtin.os.tag) {
            .windows => "webgpu_dawn.dll",
            .macos => "libwebgpu_dawn.dylib",
            else => "libwebgpu_dawn.so",
        } }),
        .extractor = try std.fs.path.join(ctx.allocator, &.{ platform_dist_dir, switch (builtin.os.tag) {
            .windows => "extractor.exe",
            else => "extractor",
        } }),
        .bsdiff = try std.fs.path.join(ctx.allocator, &.{ platform_dist_dir, switch (builtin.os.tag) {
            .windows => "bsdiff.exe",
            else => "bsdiff",
        } }),
        .bspatch = try std.fs.path.join(ctx.allocator, &.{ platform_dist_dir, switch (builtin.os.tag) {
            .windows => "bspatch.exe",
            else => "bspatch",
        } }),
        .zig_zstd = try std.fs.path.join(ctx.allocator, &.{ platform_dist_dir, switch (builtin.os.tag) {
            .windows => "zig-zstd.exe",
            else => "zig-zstd",
        } }),
    };
}

fn appBundlePaths(ctx: *const Context, config: CommandContext) !AppBundlePaths {
    const build_root = try buildOutputRoot(ctx, config);
    const bundle_name = try bundleDisplayName(ctx, config);

    if (builtin.os.tag == .macos) {
        const bundle_root = try std.fs.path.join(ctx.allocator, &.{ build_root, bundle_name });
        const contents_dir = try std.fs.path.join(ctx.allocator, &.{ bundle_root, "Contents" });
        const exec_dir = try std.fs.path.join(ctx.allocator, &.{ contents_dir, "MacOS" });
        const resources_dir = try std.fs.path.join(ctx.allocator, &.{ contents_dir, "Resources" });
        const frameworks_dir = try std.fs.path.join(ctx.allocator, &.{ contents_dir, "Frameworks" });
        const app_code_dir = try std.fs.path.join(ctx.allocator, &.{ resources_dir, "app" });
        return .{
            .build_root = build_root,
            .bundle_root = bundle_root,
            .exec_dir = exec_dir,
            .resources_dir = resources_dir,
            .frameworks_dir = frameworks_dir,
            .app_code_dir = app_code_dir,
        };
    }

    const bundle_root = try std.fs.path.join(ctx.allocator, &.{ build_root, bundle_name });
    const exec_dir = try std.fs.path.join(ctx.allocator, &.{ bundle_root, "bin" });
    const resources_dir = try std.fs.path.join(ctx.allocator, &.{ bundle_root, "Resources" });
    const app_code_dir = try std.fs.path.join(ctx.allocator, &.{ resources_dir, "app" });
    return .{
        .build_root = build_root,
        .bundle_root = bundle_root,
        .exec_dir = exec_dir,
        .resources_dir = resources_dir,
        .frameworks_dir = null,
        .app_code_dir = app_code_dir,
    };
}

fn bundleDisplayName(ctx: *const Context, config: CommandContext) ![]const u8 {
    if (builtin.os.tag == .macos) {
        return std.fmt.allocPrint(ctx.allocator, "{s}.app", .{try appDisplayName(ctx, config)});
    }
    return artifactAppFileName(ctx, config);
}

fn appDisplayName(ctx: *const Context, config: CommandContext) ![]const u8 {
    const app_name = try getAppName(ctx, config.root);
    return switch (config.build_env) {
        .production => app_name,
        else => std.fmt.allocPrint(ctx.allocator, "{s}-{s}", .{ app_name, buildEnvironmentName(config.build_env) }),
    };
}

fn bundleUsesCef(root: std.json.Value) bool {
    const platform = platformBuildObject(root) orelse return false;
    return getBoolFieldFromObject(platform, "bundleCEF");
}

fn selectNativeWrapperPath(use_cef: bool, native_wrapper: []const u8, native_wrapper_cef: []const u8) []const u8 {
    return if (builtin.os.tag == .linux and use_cef) native_wrapper_cef else native_wrapper;
}

test "Linux CEF bundles select the CEF native wrapper" {
    const expected = if (builtin.os.tag == .linux) "cef" else "native";
    try std.testing.expectEqualStrings(expected, selectNativeWrapperPath(true, "native", "cef"));
    try std.testing.expectEqualStrings("native", selectNativeWrapperPath(false, "native", "cef"));
}

fn bundleUsesWgpu(root: std.json.Value) bool {
    const platform = platformBuildObject(root) orelse return false;
    return getBoolFieldFromObject(platform, "bundleWGPU");
}

fn platformBuildObject(root: std.json.Value) ?std.json.ObjectMap {
    const build = getObjectField(root, "build") orelse return null;
    return switch (builtin.os.tag) {
        .macos => getObjectFieldFromObject(build, "mac"),
        .windows => getObjectFieldFromObject(build, "win"),
        else => getObjectFieldFromObject(build, "linux"),
    };
}

const EntitlementUsageDescription = struct {
    entitlement: []const u8,
    plist_key: []const u8,
};

const entitlement_usage_descriptions = [_]EntitlementUsageDescription{
    .{ .entitlement = "com.apple.security.device.camera", .plist_key = "NSCameraUsageDescription" },
    .{ .entitlement = "com.apple.security.device.microphone", .plist_key = "NSMicrophoneUsageDescription" },
    .{ .entitlement = "com.apple.security.device.audio-input", .plist_key = "NSMicrophoneUsageDescription" },
    .{ .entitlement = "com.apple.security.personal-information.location", .plist_key = "NSLocationUsageDescription" },
    .{ .entitlement = "com.apple.security.personal-information.location-when-in-use", .plist_key = "NSLocationWhenInUseUsageDescription" },
    .{ .entitlement = "com.apple.security.personal-information.contacts", .plist_key = "NSContactsUsageDescription" },
    .{ .entitlement = "com.apple.security.personal-information.calendars", .plist_key = "NSCalendarsUsageDescription" },
    .{ .entitlement = "com.apple.security.personal-information.reminders", .plist_key = "NSRemindersUsageDescription" },
    .{ .entitlement = "com.apple.security.personal-information.photos-library", .plist_key = "NSPhotoLibraryUsageDescription" },
    .{ .entitlement = "com.apple.security.personal-information.apple-music-library", .plist_key = "NSAppleMusicUsageDescription" },
    .{ .entitlement = "com.apple.security.personal-information.motion", .plist_key = "NSMotionUsageDescription" },
    .{ .entitlement = "com.apple.security.personal-information.speech-recognition", .plist_key = "NSSpeechRecognitionUsageDescription" },
    .{ .entitlement = "com.apple.security.device.bluetooth", .plist_key = "NSBluetoothAlwaysUsageDescription" },
    .{ .entitlement = "com.apple.security.files.user-selected.read-write", .plist_key = "NSDocumentsFolderUsageDescription" },
    .{ .entitlement = "com.apple.security.files.downloads.read-write", .plist_key = "NSDownloadsFolderUsageDescription" },
    .{ .entitlement = "com.apple.security.files.desktop.read-write", .plist_key = "NSDesktopFolderUsageDescription" },
};

fn writeInfoPlist(ctx: *const Context, config: CommandContext, bundle: AppBundlePaths) !void {
    const contents = try infoPlistContents(ctx, config);
    const plist_path = try std.fs.path.join(ctx.allocator, &.{ bundle.bundle_root, "Contents", "Info.plist" });
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = plist_path, .data = contents });
}

fn infoPlistContents(ctx: *const Context, config: CommandContext) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    try output.appendSlice(
        ctx.allocator,
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" " ++
            "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" ++
            "<plist version=\"1.0\">\n<dict>\n",
    );
    try appendPlistStringEntry(&output, ctx.allocator, 4, "CFBundleExecutable", "launcher");
    try appendPlistStringEntry(
        &output,
        ctx.allocator,
        4,
        "CFBundleIdentifier",
        try getAppIdentifier(ctx, config.root),
    );
    try appendPlistStringEntry(
        &output,
        ctx.allocator,
        4,
        "CFBundleName",
        try appDisplayName(ctx, config),
    );
    try appendPlistStringEntry(
        &output,
        ctx.allocator,
        4,
        "CFBundleVersion",
        try getAppVersion(ctx, config.root),
    );
    try appendPlistStringEntry(&output, ctx.allocator, 4, "CFBundlePackageType", "APPL");
    try appendPlistStringEntry(&output, ctx.allocator, 4, "CFBundleIconFile", "AppIcon");

    const build = getObjectField(config.root, "build");
    const mac = if (build) |object| getObjectFieldFromObject(object, "mac") else null;
    if (mac) |platform| {
        if (getStringFieldFromObject(platform, "icons")) |icons| {
            if (std.mem.endsWith(u8, icons, ".icon")) {
                try appendPlistStringEntry(
                    &output,
                    ctx.allocator,
                    4,
                    "CFBundleIconName",
                    std.fs.path.stem(std.fs.path.basename(icons)),
                );
            }
        }
        if (getObjectFieldFromObject(platform, "entitlements")) |entitlements| {
            try appendUsageDescriptions(&output, ctx.allocator, entitlements);
        }
    }

    const app = getObjectField(config.root, "app") orelse return error.InvalidConfig;
    try appendUrlTypes(
        &output,
        ctx.allocator,
        app,
        try getAppIdentifier(ctx, config.root),
    );
    try appendDocumentTypes(ctx, &output, app, try getAppIdentifier(ctx, config.root));

    try output.appendSlice(ctx.allocator, "</dict>\n</plist>\n");
    return output.toOwnedSlice(ctx.allocator);
}

fn appendPlistKey(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    indent: usize,
    key: []const u8,
) !void {
    try appendSpaces(output, allocator, indent);
    try output.appendSlice(allocator, "<key>");
    try appendXmlEscaped(output, allocator, key);
    try output.appendSlice(allocator, "</key>\n");
}

fn appendPlistStringEntry(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    indent: usize,
    key: []const u8,
    value: []const u8,
) !void {
    try appendPlistKey(output, allocator, indent, key);
    try appendSpaces(output, allocator, indent);
    try output.appendSlice(allocator, "<string>");
    try appendXmlEscaped(output, allocator, value);
    try output.appendSlice(allocator, "</string>\n");
}

fn appendUsageDescriptions(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    entitlements: std.json.ObjectMap,
) !void {
    for (entitlement_usage_descriptions) |mapping| {
        const value = entitlements.get(mapping.entitlement) orelse continue;
        if (!entitlementRequestsUsageDescription(value)) continue;
        try appendPlistKey(output, allocator, 4, mapping.plist_key);
        try appendSpaces(output, allocator, 4);
        try output.appendSlice(allocator, "<string>");
        if (value == .string) {
            try appendXmlEscaped(output, allocator, value.string);
        } else {
            try output.appendSlice(allocator, "This app requires access for ");
            const suffix_start = if (std.mem.lastIndexOfScalar(u8, mapping.entitlement, '.')) |index|
                index + 1
            else
                0;
            for (mapping.entitlement[suffix_start..]) |byte| {
                try output.append(allocator, if (byte == '-') ' ' else byte);
            }
        }
        try output.appendSlice(allocator, "</string>\n");
    }
}

fn entitlementRequestsUsageDescription(value: std.json.Value) bool {
    return switch (value) {
        .bool => |enabled| enabled,
        .string => |description| description.len > 0,
        .array => true,
        else => false,
    };
}

fn appendUrlTypes(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    app: std.json.ObjectMap,
    identifier: []const u8,
) !void {
    const value = app.get("urlSchemes") orelse return;
    if (value != .array) return;
    var valid_count: usize = 0;
    for (value.array.items) |scheme| {
        if (scheme == .string and scheme.string.len > 0) valid_count += 1;
    }
    if (valid_count == 0) return;

    try appendPlistKey(output, allocator, 4, "CFBundleURLTypes");
    try output.appendSlice(
        allocator,
        "    <array>\n" ++
            "        <dict>\n",
    );
    try appendPlistStringEntry(output, allocator, 12, "CFBundleURLName", identifier);
    try appendPlistStringEntry(output, allocator, 12, "CFBundleTypeRole", "Viewer");
    try appendPlistKey(output, allocator, 12, "CFBundleURLSchemes");
    try output.appendSlice(allocator, "            <array>\n");
    for (value.array.items) |scheme| {
        if (scheme != .string or scheme.string.len == 0) continue;
        try appendSpaces(output, allocator, 16);
        try output.appendSlice(allocator, "<string>");
        try appendXmlEscaped(output, allocator, scheme.string);
        try output.appendSlice(allocator, "</string>\n");
    }
    try output.appendSlice(
        allocator,
        "            </array>\n" ++
            "        </dict>\n" ++
            "    </array>\n",
    );
}

fn appendDocumentTypes(
    ctx: *const Context,
    output: *std.ArrayList(u8),
    app: std.json.ObjectMap,
    identifier: []const u8,
) !void {
    const value = app.get("fileAssociations") orelse return;
    if (value != .array) return;

    var valid_count: usize = 0;
    for (value.array.items) |association| {
        if (validFileAssociation(association)) valid_count += 1;
    }
    if (valid_count == 0) return;

    try appendPlistKey(output, ctx.allocator, 4, "CFBundleDocumentTypes");
    try output.appendSlice(ctx.allocator, "    <array>\n");
    for (value.array.items) |association| {
        if (!validFileAssociation(association)) continue;
        const object = association.object;
        const extensions = object.get("ext").?.array;
        const name = getStringFieldFromObject(object, "name").?;
        const role = getStringFieldFromObject(object, "role") orelse "Viewer";
        const icon_stem = try documentIconStem(ctx, object);

        try output.appendSlice(ctx.allocator, "        <dict>\n");
        try appendPlistStringEntry(output, ctx.allocator, 12, "CFBundleTypeName", name);
        try appendPlistStringEntry(output, ctx.allocator, 12, "CFBundleTypeRole", role);
        if (icon_stem) |icon| {
            try appendPlistStringEntry(output, ctx.allocator, 12, "CFBundleTypeIconFile", icon);
        }
        try appendPlistKey(output, ctx.allocator, 12, "LSItemContentTypes");
        try output.appendSlice(ctx.allocator, "            <array>\n");
        for (extensions.items) |extension_value| {
            const extension = cleanFileExtension(extension_value) orelse continue;
            try appendUtiString(output, ctx.allocator, 16, identifier, extension);
        }
        try output.appendSlice(ctx.allocator, "            </array>\n");
        try appendPlistKey(output, ctx.allocator, 12, "CFBundleTypeExtensions");
        try output.appendSlice(ctx.allocator, "            <array>\n");
        for (extensions.items) |extension_value| {
            const extension = cleanFileExtension(extension_value) orelse continue;
            try appendXmlString(output, ctx.allocator, 16, extension);
        }
        try output.appendSlice(ctx.allocator, "            </array>\n        </dict>\n");
    }
    try output.appendSlice(ctx.allocator, "    </array>\n");

    try appendPlistKey(output, ctx.allocator, 4, "UTExportedTypeDeclarations");
    try output.appendSlice(ctx.allocator, "    <array>\n");
    for (value.array.items) |association| {
        if (!validFileAssociation(association)) continue;
        const object = association.object;
        const extensions = object.get("ext").?.array;
        const name = getStringFieldFromObject(object, "name").?;
        const icon_stem = try documentIconStem(ctx, object);
        for (extensions.items) |extension_value| {
            const extension = cleanFileExtension(extension_value) orelse continue;
            try output.appendSlice(ctx.allocator, "        <dict>\n");
            try appendPlistKey(output, ctx.allocator, 12, "UTTypeIdentifier");
            try appendUtiString(output, ctx.allocator, 12, identifier, extension);
            try appendPlistStringEntry(output, ctx.allocator, 12, "UTTypeDescription", name);
            try appendPlistKey(output, ctx.allocator, 12, "UTTypeConformsTo");
            try output.appendSlice(
                ctx.allocator,
                "            <array>\n" ++
                    "                <string>public.data</string>\n" ++
                    "            </array>\n",
            );
            if (icon_stem) |icon| {
                try appendPlistKey(output, ctx.allocator, 12, "UTTypeIconFiles");
                try output.appendSlice(ctx.allocator, "            <array>\n");
                try appendXmlString(output, ctx.allocator, 16, icon);
                try output.appendSlice(ctx.allocator, "            </array>\n");
            }
            try appendPlistKey(output, ctx.allocator, 12, "UTTypeTagSpecification");
            try output.appendSlice(ctx.allocator, "            <dict>\n");
            try appendPlistKey(output, ctx.allocator, 16, "public.filename-extension");
            try output.appendSlice(ctx.allocator, "                <array>\n");
            try appendXmlString(output, ctx.allocator, 20, extension);
            try output.appendSlice(
                ctx.allocator,
                "                </array>\n" ++
                    "            </dict>\n" ++
                    "        </dict>\n",
            );
        }
    }
    try output.appendSlice(ctx.allocator, "    </array>\n");
}

fn validFileAssociation(value: std.json.Value) bool {
    if (value != .object) return false;
    const name = getStringFieldFromObject(value.object, "name") orelse return false;
    if (name.len == 0) return false;
    const extensions = value.object.get("ext") orelse return false;
    if (extensions != .array) return false;
    for (extensions.array.items) |extension| {
        if (cleanFileExtension(extension) != null) return true;
    }
    return false;
}

fn cleanFileExtension(value: std.json.Value) ?[]const u8 {
    if (value != .string) return null;
    const cleaned = if (std.mem.startsWith(u8, value.string, "."))
        value.string[1..]
    else
        value.string;
    return if (cleaned.len == 0) null else cleaned;
}

fn documentIconStem(ctx: *const Context, association: std.json.ObjectMap) !?[]const u8 {
    const icon = getStringFieldFromObject(association, "icon") orelse return null;
    const source = try absoluteProjectPath(ctx, icon);
    if (!pathExists(ctx.io, source)) return null;
    return std.fs.path.stem(std.fs.path.basename(icon));
}

fn appendUtiString(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    indent: usize,
    identifier: []const u8,
    extension: []const u8,
) !void {
    try appendSpaces(output, allocator, indent);
    try output.appendSlice(allocator, "<string>");
    try appendXmlEscaped(output, allocator, identifier);
    try output.append(allocator, '.');
    try appendXmlEscaped(output, allocator, extension);
    try output.appendSlice(allocator, "</string>\n");
}

fn appendXmlString(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    indent: usize,
    value: []const u8,
) !void {
    try appendSpaces(output, allocator, indent);
    try output.appendSlice(allocator, "<string>");
    try appendXmlEscaped(output, allocator, value);
    try output.appendSlice(allocator, "</string>\n");
}

fn cefHelperBaseName(main_process: MainProcess) []const u8 {
    return switch (main_process) {
        .bun => "bun",
        .cottontail => "cottontail",
        .zig => "main",
        .rust, .go, .odin => "main",
    };
}

const cef_helper_suffixes = [_][]const u8{
    " Helper",
    " Helper (Alerts)",
    " Helper (GPU)",
    " Helper (Plugin)",
    " Helper (Renderer)",
};

// libNativeWrapper.dll is delay-linked against libcef.dll and checks for CEF
// beside the main executable before initializing it. Keep these root copies in
// sync with Electrobun's TypeScript packager while retaining the complete cef/
// directory for resources and locales.
const windows_cef_root_files = [_][]const u8{
    "libcef.dll",
    "chrome_elf.dll",
    "d3dcompiler_47.dll",
    "dxcompiler.dll",
    "dxil.dll",
    "libEGL.dll",
    "libGLESv2.dll",
    "vk_swiftshader.dll",
    "vulkan-1.dll",
    "icudtl.dat",
    "chrome_100_percent.pak",
    "resources.pak",
    "v8_context_snapshot.bin",
};

const linux_cef_shared_libraries = [_][]const u8{
    "libcef.so",
    "libEGL.so",
    "libGLESv2.so",
    "libvk_swiftshader.so",
    "libvulkan.so.1",
};

const linux_cef_root_resources = [_][]const u8{
    "icudtl.dat",
    "v8_context_snapshot.bin",
    "snapshot_blob.bin",
    "resources.pak",
    "chrome_100_percent.pak",
    "chrome_200_percent.pak",
    "locales",
    "chrome-sandbox",
    "vk_swiftshader_icd.json",
};

fn copyWindowsBundledCef(ctx: *const Context, bundle: AppBundlePaths, platform_paths: PlatformPaths, main_process: MainProcess) !void {
    try copyPath(ctx, platform_paths.cef_dir, try std.fs.path.join(ctx.allocator, &.{ bundle.exec_dir, "cef" }));

    for (windows_cef_root_files) |file_name| {
        const source_path = try std.fs.path.join(ctx.allocator, &.{ platform_paths.cef_dir, file_name });
        if (pathExists(ctx.io, source_path)) {
            try copyPath(ctx, source_path, try std.fs.path.join(ctx.allocator, &.{ bundle.exec_dir, file_name }));
        }
    }

    if (!pathExists(ctx.io, platform_paths.process_helper)) return;

    const base_name = cefHelperBaseName(main_process);
    for (cef_helper_suffixes) |suffix| {
        const helper_name = try std.fmt.allocPrint(ctx.allocator, "{s}{s}.exe", .{ base_name, suffix });
        try copyPath(ctx, platform_paths.process_helper, try std.fs.path.join(ctx.allocator, &.{ bundle.exec_dir, helper_name }));
    }
}

fn copyLinuxBundledCef(ctx: *const Context, bundle: AppBundlePaths, platform_paths: PlatformPaths, main_process: MainProcess) !void {
    const cef_dest = try std.fs.path.join(ctx.allocator, &.{ bundle.exec_dir, "cef" });
    try copyPath(ctx, platform_paths.cef_dir, cef_dest);

    for (linux_cef_root_resources) |file_name| {
        const source_path = try std.fs.path.join(ctx.allocator, &.{ platform_paths.cef_dir, file_name });
        if (pathExists(ctx.io, source_path)) {
            try copyPath(ctx, source_path, try std.fs.path.join(ctx.allocator, &.{ bundle.exec_dir, file_name }));
        }
    }

    for (linux_cef_shared_libraries) |file_name| {
        const source_path = try std.fs.path.join(ctx.allocator, &.{ platform_paths.cef_dir, file_name });
        if (!pathExists(ctx.io, source_path)) continue;

        const dest_path = try std.fs.path.join(ctx.allocator, &.{ bundle.exec_dir, file_name });
        std.Io.Dir.cwd().deleteFile(ctx.io, dest_path) catch {};
        const link_target = try std.fs.path.join(ctx.allocator, &.{ "cef", file_name });
        std.Io.Dir.cwd().symLink(ctx.io, link_target, dest_path, .{}) catch {
            try copyPath(ctx, source_path, dest_path);
        };
    }

    if (!pathExists(ctx.io, platform_paths.process_helper)) return;

    const base_name = cefHelperBaseName(main_process);
    for (cef_helper_suffixes) |suffix| {
        const helper_name = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ base_name, suffix });
        try copyPath(ctx, platform_paths.process_helper, try std.fs.path.join(ctx.allocator, &.{ bundle.exec_dir, helper_name }));
    }
}

fn copyBundledCef(ctx: *const Context, bundle: AppBundlePaths, platform_paths: PlatformPaths, main_process: MainProcess) !void {
    if (!pathExists(ctx.io, platform_paths.cef_dir)) return;

    switch (builtin.os.tag) {
        .macos => {
            const frameworks_dir = bundle.frameworks_dir orelse return;
            const framework_source = try std.fs.path.join(ctx.allocator, &.{ platform_paths.cef_dir, "Chromium Embedded Framework.framework" });
            const framework_dest = try std.fs.path.join(ctx.allocator, &.{ frameworks_dir, "Chromium Embedded Framework.framework" });
            try copyPath(ctx, framework_source, framework_dest);

            const base_name = cefHelperBaseName(main_process);
            const helper_names = [_][]const u8{
                try std.fmt.allocPrint(ctx.allocator, "{s} Helper", .{base_name}),
                try std.fmt.allocPrint(ctx.allocator, "{s} Helper (Alerts)", .{base_name}),
                try std.fmt.allocPrint(ctx.allocator, "{s} Helper (GPU)", .{base_name}),
                try std.fmt.allocPrint(ctx.allocator, "{s} Helper (Plugin)", .{base_name}),
                try std.fmt.allocPrint(ctx.allocator, "{s} Helper (Renderer)", .{base_name}),
            };
            for (helper_names) |helper_name| {
                const helper_app_name = try std.fmt.allocPrint(ctx.allocator, "{s}.app", .{helper_name});
                const helper_dest = try std.fs.path.join(ctx.allocator, &.{ frameworks_dir, helper_app_name, "Contents", "MacOS", helper_name });
                try copyPath(ctx, platform_paths.process_helper, helper_dest);
            }
        },
        .windows => try copyWindowsBundledCef(ctx, bundle, platform_paths, main_process),
        .linux => try copyLinuxBundledCef(ctx, bundle, platform_paths, main_process),
        else => {},
    }
}

test "preload scripts are resources rather than code-directory files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "platform");
    try tmp.dir.createDirPath(io, "bundle/Contents/MacOS");
    try tmp.dir.createDirPath(io, "bundle/Contents/Resources");
    try tmp.dir.writeFile(io, .{ .sub_path = "platform/preload-full.js", .data = "full" });
    try tmp.dir.writeFile(io, .{ .sub_path = "platform/preload-sandboxed.js", .data = "sandboxed" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const relative_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const absolute_root = try std.Io.Dir.cwd().realPathFileAlloc(io, relative_root, allocator);
    const exec_dir = try std.fs.path.join(allocator, &.{ absolute_root, "bundle", "Contents", "MacOS" });
    const resources_dir = try std.fs.path.join(allocator, &.{ absolute_root, "bundle", "Contents", "Resources" });

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    const ctx = Context{
        .io = io,
        .allocator = allocator,
        .environ_map = &env_map,
        .self_exe_path = "",
        .cottontail_home = "",
        .cottontail_binary = "",
        .project_root = absolute_root,
    };
    const bundle = AppBundlePaths{
        .build_root = absolute_root,
        .bundle_root = absolute_root,
        .exec_dir = exec_dir,
        .resources_dir = resources_dir,
        .frameworks_dir = null,
        .app_code_dir = resources_dir,
    };
    const platform_paths = PlatformPaths{
        .package_root = absolute_root,
        .shared_dist_dir = absolute_root,
        .platform_dist_dir = absolute_root,
        .launcher = "",
        .bun_binary = "",
        .main_js = "",
        .preload_full_js = try std.fs.path.join(allocator, &.{ absolute_root, "platform", "preload-full.js" }),
        .preload_sandboxed_js = try std.fs.path.join(allocator, &.{ absolute_root, "platform", "preload-sandboxed.js" }),
        .core_lib = "",
        .native_wrapper = "",
        .native_wrapper_cef = "",
        .libasar = "",
        .process_helper = "",
        .cef_dir = "",
        .wgpu_lib = "",
        .extractor = "",
        .bsdiff = "",
        .bspatch = "",
        .zig_zstd = "",
    };

    try copyBundledPreloadScripts(&ctx, bundle, platform_paths);

    try std.testing.expect(pathExists(io, try std.fs.path.join(allocator, &.{ resources_dir, "preload-full.js" })));
    try std.testing.expect(pathExists(io, try std.fs.path.join(allocator, &.{ resources_dir, "preload-sandboxed.js" })));
    try std.testing.expect(!pathExists(io, try std.fs.path.join(allocator, &.{ exec_dir, "preload-full.js" })));
    try std.testing.expect(!pathExists(io, try std.fs.path.join(allocator, &.{ exec_dir, "preload-sandboxed.js" })));
}

test "bundled CEF layouts match the native wrapper contract" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "platform/cef/Resources/locales");
    try tmp.dir.createDirPath(io, "bundle/bin");
    for (windows_cef_root_files) |file_name| {
        const source_sub_path = try std.fs.path.join(std.testing.allocator, &.{ "platform", "cef", file_name });
        defer std.testing.allocator.free(source_sub_path);
        try tmp.dir.writeFile(io, .{
            .sub_path = source_sub_path,
            .data = file_name,
        });
    }
    for (linux_cef_shared_libraries) |file_name| {
        const source_sub_path = try std.fs.path.join(std.testing.allocator, &.{ "platform", "cef", file_name });
        defer std.testing.allocator.free(source_sub_path);
        try tmp.dir.writeFile(io, .{ .sub_path = source_sub_path, .data = file_name });
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "platform/cef/icudtl.dat", .data = "icu" });
    try tmp.dir.createDirPath(io, "platform/cef/locales");
    try tmp.dir.writeFile(io, .{ .sub_path = "platform/cef/locales/en-US.pak", .data = "locale" });
    try tmp.dir.writeFile(io, .{ .sub_path = "platform/cef/Resources/locales/en-US.pak", .data = "locale" });
    try tmp.dir.writeFile(io, .{ .sub_path = "platform/process_helper.exe", .data = "helper" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const relative_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const absolute_root = try std.Io.Dir.cwd().realPathFileAlloc(io, relative_root, allocator);
    const cef_dir = try std.fs.path.join(allocator, &.{ absolute_root, "platform", "cef" });
    const process_helper = try std.fs.path.join(allocator, &.{ absolute_root, "platform", "process_helper.exe" });
    const exec_dir = try std.fs.path.join(allocator, &.{ absolute_root, "bundle", "bin" });

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    const ctx = Context{
        .io = io,
        .allocator = allocator,
        .environ_map = &env_map,
        .self_exe_path = "",
        .cottontail_home = "",
        .cottontail_binary = "",
        .project_root = absolute_root,
    };
    const bundle = AppBundlePaths{
        .build_root = absolute_root,
        .bundle_root = absolute_root,
        .exec_dir = exec_dir,
        .resources_dir = absolute_root,
        .frameworks_dir = null,
        .app_code_dir = absolute_root,
    };
    const platform_paths = PlatformPaths{
        .package_root = absolute_root,
        .shared_dist_dir = absolute_root,
        .platform_dist_dir = absolute_root,
        .launcher = "",
        .bun_binary = "",
        .main_js = "",
        .preload_full_js = "",
        .preload_sandboxed_js = "",
        .core_lib = "",
        .native_wrapper = "",
        .native_wrapper_cef = "",
        .libasar = "",
        .process_helper = process_helper,
        .cef_dir = cef_dir,
        .wgpu_lib = "",
        .extractor = "",
        .bsdiff = "",
        .bspatch = "",
        .zig_zstd = "",
    };

    try copyWindowsBundledCef(&ctx, bundle, platform_paths, .bun);

    for (windows_cef_root_files) |file_name| {
        try std.testing.expect(pathExists(io, try std.fs.path.join(allocator, &.{ exec_dir, file_name })));
    }
    try std.testing.expect(pathExists(io, try std.fs.path.join(allocator, &.{ exec_dir, "cef", "Resources", "locales", "en-US.pak" })));
    for (cef_helper_suffixes) |suffix| {
        const helper_name = try std.fmt.allocPrint(allocator, "bun{s}.exe", .{suffix});
        try std.testing.expect(pathExists(io, try std.fs.path.join(allocator, &.{ exec_dir, helper_name })));
    }

    if (builtin.os.tag == .linux) {
        try copyLinuxBundledCef(&ctx, bundle, platform_paths, .bun);
        for (linux_cef_shared_libraries) |file_name| {
            try std.testing.expect(pathExists(io, try std.fs.path.join(allocator, &.{ exec_dir, file_name })));
        }
        try std.testing.expect(pathExists(io, try std.fs.path.join(allocator, &.{ exec_dir, "icudtl.dat" })));
        try std.testing.expect(pathExists(io, try std.fs.path.join(allocator, &.{ exec_dir, "locales", "en-US.pak" })));
        for (cef_helper_suffixes) |suffix| {
            const helper_name = try std.fmt.allocPrint(allocator, "bun{s}", .{suffix});
            try std.testing.expect(pathExists(io, try std.fs.path.join(allocator, &.{ exec_dir, helper_name })));
        }
    }
}

fn writeBundledRuntimeMetadata(ctx: *const Context, config: CommandContext, bundle: AppBundlePaths) !void {
    const identifier = try getAppIdentifier(ctx, config.root);
    const app_name = try appDisplayName(ctx, config);
    const version_name = try getAppVersion(ctx, config.root);
    const runtime_value = getValueFieldFromObject(config.root.object, "runtime") orelse std.json.Value{ .object = .empty };
    const runtime_json = try std.json.Stringify.valueAlloc(ctx.allocator, runtime_value, .{});
    const default_renderer = if (platformBuildObject(config.root)) |platform| getStringFieldFromObject(platform, "defaultRenderer") orelse "native" else "native";
    const available_renderers = if (bundleUsesCef(config.root)) "[\"native\",\"cef\"]" else "[\"native\"]";
    const main_process = mainProcessName(getMainProcess(config.root));
    const build_json = try std.fmt.allocPrint(
        ctx.allocator,
        "{{\"mainProcess\":\"{s}\",\"defaultRenderer\":\"{s}\",\"availableRenderers\":{s},\"runtime\":{s}}}",
        .{ main_process, default_renderer, available_renderers, runtime_json },
    );
    const version_json = try std.fmt.allocPrint(
        ctx.allocator,
        "{{\"version\":\"{s}\",\"hash\":\"dev\",\"channel\":\"{s}\",\"name\":\"{s}\",\"identifier\":\"{s}\",\"baseUrl\":\"\"}}",
        .{ version_name, buildEnvironmentName(config.build_env), app_name, identifier },
    );

    try std.Io.Dir.cwd().writeFile(ctx.io, .{
        .sub_path = try std.fs.path.join(ctx.allocator, &.{ bundle.resources_dir, "build.json" }),
        .data = build_json,
    });
    try std.Io.Dir.cwd().writeFile(ctx.io, .{
        .sub_path = try std.fs.path.join(ctx.allocator, &.{ bundle.resources_dir, "version.json" }),
        .data = version_json,
    });
}

fn termExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| @intCast(code),
        .signal => 1,
        .stopped => 1,
        .unknown => 1,
    };
}

test "native Electrobun main process names are recognized" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    inline for (.{ "zig", "rust", "go", "odin", "cottontail" }) |name| {
        const source = try std.fmt.allocPrint(
            arena.allocator(),
            \\{{"build":{{"mainProcess":"{s}"}}}}
        ,
            .{name},
        );
        const config = try std.json.parseFromSliceLeaky(
            std.json.Value,
            arena.allocator(),
            source,
            .{},
        );
        try std.testing.expectEqualStrings(name, mainProcessName(getMainProcess(config)));
    }
}

test "release base36 formatting is stable" {
    const allocator = std.testing.allocator;
    const zero = try formatBase36(allocator, 0);
    defer allocator.free(zero);
    const thirty_five = try formatBase36(allocator, 35);
    defer allocator.free(thirty_five);
    const thirty_six = try formatBase36(allocator, 36);
    defer allocator.free(thirty_six);
    const large = try formatBase36(allocator, 4_294_967_295);
    defer allocator.free(large);

    try std.testing.expectEqualStrings("0", zero);
    try std.testing.expectEqualStrings("z", thirty_five);
    try std.testing.expectEqualStrings("10", thirty_six);
    try std.testing.expectEqualStrings("1z141z3", large);
}

test "release entitlements plist preserves types and escapes XML" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parsed = try std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        \\{
        \\  "com.example.enabled": true,
        \\  "com.example.disabled": false,
        \\  "com.example.message": "camera & <microphone>",
        \\  "com.example.groups": ["group.one", "group.&two"]
        \\}
    ,
        .{},
    );
    const plist = try entitlementsPlist(allocator, parsed.object);
    try std.testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" " ++
            "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" ++
            "<plist version=\"1.0\">\n" ++
            "<dict>\n" ++
            "    <key>com.example.enabled</key>\n" ++
            "    <true/>\n" ++
            "    <key>com.example.disabled</key>\n" ++
            "    <false/>\n" ++
            "    <key>com.example.message</key>\n" ++
            "    <string>camera &amp; &lt;microphone&gt;</string>\n" ++
            "    <key>com.example.groups</key>\n" ++
            "    <array>\n" ++
            "        <string>group.one</string>\n" ++
            "        <string>group.&amp;two</string>\n" ++
            "    </array>\n" ++
            "</dict>\n" ++
            "</plist>\n",
        plist,
    );
}

test "release bundle hashes are deterministic and content sensitive" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "bundle/nested");
    try tmp.dir.writeFile(io, .{ .sub_path = "bundle/z.txt", .data = "last" });
    try tmp.dir.writeFile(io, .{ .sub_path = "bundle/nested/a.txt", .data = "first" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const relative_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const absolute_root = try std.Io.Dir.cwd().realPathFileAlloc(io, relative_root, allocator);
    const bundle_root = try std.fs.path.join(allocator, &.{ absolute_root, "bundle" });
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    const ctx = Context{
        .io = io,
        .allocator = allocator,
        .environ_map = &env_map,
        .self_exe_path = "",
        .cottontail_home = "",
        .cottontail_binary = "",
        .project_root = absolute_root,
    };

    const first = try hashBundle(&ctx, bundle_root);
    const second = try hashBundle(&ctx, bundle_root);
    try std.testing.expectEqualStrings(first, second);

    try tmp.dir.writeFile(io, .{ .sub_path = "bundle/nested/a.txt", .data = "changed" });
    const changed = try hashBundle(&ctx, bundle_root);
    try std.testing.expect(!std.mem.eql(u8, first, changed));
}

test "release metadata and macOS plist preserve public app configuration" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const relative_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const absolute_root = try std.Io.Dir.cwd().realPathFileAlloc(io, relative_root, allocator);
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    const ctx = Context{
        .io = io,
        .allocator = allocator,
        .environ_map = &env_map,
        .self_exe_path = "",
        .cottontail_home = "",
        .cottontail_binary = "",
        .project_root = absolute_root,
    };
    const root = try std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        \\{
        \\  "app": {
        \\    "name": "Dash & Draw",
        \\    "identifier": "com.example.dash",
        \\    "version": "1.2.3",
        \\    "urlSchemes": ["dash&draw"],
        \\    "fileAssociations": [{
        \\      "ext": [".dash"],
        \\      "name": "Dash & Document",
        \\      "role": "Editor"
        \\    }]
        \\  },
        \\  "build": {
        \\    "mac": {
        \\      "icons": "Dash.icon",
        \\      "entitlements": {
        \\        "com.apple.security.device.camera": "Camera <required>",
        \\        "com.apple.security.device.microphone": true
        \\      }
        \\    }
        \\  }
        \\}
    ,
        .{},
    );
    const config = CommandContext{
        .raw_json = "",
        .root = root,
        .build_env = .canary,
    };
    const expected_bundle_name = if (builtin.os.tag == .macos)
        "Dash & Draw-canary.app"
    else
        "Dash&Draw-canary";
    try std.testing.expectEqualStrings(expected_bundle_name, try bundleDisplayName(&ctx, config));

    const metadata = try extractorMetadataJson(&ctx, config, "hash-123");
    const parsed_metadata = try std.json.parseFromSliceLeaky(std.json.Value, allocator, metadata, .{});
    try std.testing.expectEqualStrings("com.example.dash", getStringField(parsed_metadata, "identifier").?);
    try std.testing.expectEqualStrings("Dash & Draw", getStringField(parsed_metadata, "name").?);
    try std.testing.expectEqualStrings("canary", getStringField(parsed_metadata, "channel").?);
    try std.testing.expectEqualStrings("hash-123", getStringField(parsed_metadata, "hash").?);

    const plist = try infoPlistContents(&ctx, config);
    for ([_][]const u8{
        "<string>Dash &amp; Draw-canary</string>",
        "<key>CFBundleIconName</key>",
        "<string>Dash</string>",
        "<key>NSCameraUsageDescription</key>",
        "<string>Camera &lt;required&gt;</string>",
        "<key>NSMicrophoneUsageDescription</key>",
        "<string>This app requires access for microphone</string>",
        "<key>CFBundleURLTypes</key>",
        "<string>dash&amp;draw</string>",
        "<key>CFBundleDocumentTypes</key>",
        "<string>Dash &amp; Document</string>",
        "<string>com.example.dash.dash</string>",
        "<key>UTExportedTypeDeclarations</key>",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, plist, needle) != null);
    }
}

test "PowerShell installer paths escape single quotes" {
    const escaped = try powershellSingleQuote(std.testing.allocator, "O'Brien's App");
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings("O''Brien''s App", escaped);
}

test "notarization response must explicitly be accepted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(try notarizationAccepted(
        arena.allocator(),
        "{\"id\":\"submission-id\",\"status\":\"Accepted\"}",
    ));
    try std.testing.expect(!try notarizationAccepted(
        arena.allocator(),
        "{\"id\":\"submission-id\",\"status\":\"Invalid\"}",
    ));
    try std.testing.expect(!try notarizationAccepted(
        arena.allocator(),
        "{\"id\":\"submission-id\"}",
    ));
}

test "Linux installer payload uses the extractor marker contract" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "extractor", .data = "EXTRACTOR" });
    try tmp.dir.writeFile(io, .{ .sub_path = "archive.tar.zst", .data = "ARCHIVE" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const relative_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const absolute_root = try std.Io.Dir.cwd().realPathFileAlloc(io, relative_root, allocator);
    const extractor_path = try std.fs.path.join(allocator, &.{ absolute_root, "extractor" });
    const archive_path = try std.fs.path.join(allocator, &.{ absolute_root, "archive.tar.zst" });
    const output_path = try std.fs.path.join(allocator, &.{ absolute_root, "installer" });
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    const ctx = Context{
        .io = io,
        .allocator = allocator,
        .environ_map = &env_map,
        .self_exe_path = "",
        .cottontail_home = "",
        .cottontail_binary = "",
        .project_root = absolute_root,
    };

    try concatenateLinuxInstaller(
        &ctx,
        extractor_path,
        "{\"hash\":\"abc\"}",
        archive_path,
        output_path,
    );
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        output_path,
        allocator,
        .limited(1024),
    );
    try std.testing.expectEqualStrings(
        "EXTRACTORELECTROBUN_METADATA_V1" ++
            "{\"hash\":\"abc\"}" ++
            "ELECTROBUN_ARCHIVE_V1ARCHIVE",
        bytes,
    );
}
