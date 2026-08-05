const std = @import("std");
const builtin = @import("builtin");
const package_manager = @import("package_manager/root.zig");
const package_manager_options = @import("package_manager/support/options/root.zig");
const runtime_entrypoint = @import("runtime_entrypoint.zig");

pub const Mode = enum {
    auto,
    fallback,
    force,
    disable,
};

pub const LeadingInvocation = struct {
    entry_index: usize,
    mode: Mode,
};

const AutoInstallRequest = struct {
    install_specifier: []const u8,
    package_name: []const u8,
    requested_version: ?[]const u8,
};

pub fn parseLeadingInvocation(args: []const [:0]const u8) ?LeadingInvocation {
    if (args.len < 3) return null;

    var index: usize = 1;
    var mode: Mode = .auto;
    var found = false;
    while (index < args.len) {
        const arg: []const u8 = args[index];
        if (std.mem.eql(u8, arg, "-i")) {
            mode = .fallback;
            found = true;
            index += 1;
        } else if (std.mem.eql(u8, arg, "--no-install")) {
            mode = .disable;
            found = true;
            index += 1;
        } else if (std.mem.startsWith(u8, arg, "--install=")) {
            mode = parseMode(arg["--install=".len..]) orelse return null;
            found = true;
            index += 1;
        } else if (std.mem.eql(u8, arg, "--install")) {
            if (index + 1 >= args.len) return null;
            mode = parseMode(args[index + 1]) orelse return null;
            found = true;
            index += 2;
        } else {
            break;
        }
    }

    if (!found or index >= args.len) return null;
    return .{ .entry_index = index, .mode = mode };
}

pub fn prepare(
    init: std.process.Init,
    entrypoint: []const u8,
    mode: Mode,
    stderr: *std.Io.Writer,
) !void {
    if (mode == .disable) return;

    const allocator = init.arena.allocator();
    const resolved = (try runtime_entrypoint.resolve(init.io, allocator, entrypoint)) orelse return;
    if (!canContainPackageImports(resolved)) return;
    const entry_absolute = if (std.fs.path.isAbsolute(resolved))
        try std.fs.path.resolve(allocator, &.{resolved})
    else
        try std.Io.Dir.cwd().realPathFileAlloc(init.io, resolved, allocator);
    const entry_dir = std.fs.path.dirname(entry_absolute) orelse ".";

    const cache_root = try autoInstallCacheRoot(init, allocator);
    const staging_root = try std.fs.path.join(allocator, &.{
        cache_root,
        ".hutch-auto-install",
    });
    const staging_node_modules = try std.fs.path.join(allocator, &.{
        staging_root,
        "node_modules",
    });
    const bunfig_path = try findBunfig(init.io, allocator, entry_dir);
    if (pathIsDirectory(init.io, staging_node_modules)) {
        try prependNodePath(init, allocator, staging_node_modules);
    }

    var scan_errors: std.Io.Writer.Allocating = .init(allocator);
    defer scan_errors.deinit();
    const dependencies = package_manager.host.scanDependencies(
        init,
        allocator,
        &.{entry_absolute},
        entry_dir,
        &scan_errors.writer,
    ) catch |err| {
        if (scan_errors.written().len > 0) try stderr.writeAll(scan_errors.written());
        return err;
    };

    var missing: std.ArrayList(AutoInstallRequest) = .empty;
    defer missing.deinit(allocator);
    for (dependencies) |dependency| {
        const request = autoInstallRequestFromSpecifier(dependency) orelse continue;
        if (request.requested_version == null and
            packageIsInstalled(init.io, allocator, entry_dir, request.package_name))
        {
            continue;
        }

        const installed_alias = try std.fs.path.join(allocator, &.{
            staging_node_modules,
            request.install_specifier,
        });
        if (pathIsDirectory(init.io, installed_alias)) {
            try exposeInstalledPackage(
                init,
                allocator,
                cache_root,
                staging_node_modules,
                request,
                bunfig_path,
            );
            continue;
        }

        var duplicate = false;
        for (missing.items) |existing| {
            if (std.mem.eql(
                u8,
                existing.install_specifier,
                request.install_specifier,
            )) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) try missing.append(allocator, request);
    }
    if (missing.items.len == 0) return;

    try std.Io.Dir.cwd().createDirPath(init.io, staging_root);

    var args: std.ArrayList([:0]const u8) = .empty;
    defer args.deinit(allocator);
    try args.appendSlice(allocator, &.{
        "hutch",
        "add",
        "--silent",
        "--save-text-lockfile",
        "--cwd",
    });
    try args.append(allocator, try allocator.dupeZ(u8, staging_root));
    if (bunfig_path) |path| {
        try args.appendSlice(allocator, &.{
            "--config",
            try allocator.dupeZ(u8, path),
        });
    }
    if (mode == .force) try args.append(allocator, "--force");
    for (missing.items) |request| {
        try args.append(
            allocator,
            try allocator.dupeZ(u8, request.install_specifier),
        );
    }

    var install_environment = try init.environ_map.clone(allocator);
    defer install_environment.deinit();
    const download_cache = try std.fs.path.join(allocator, &.{
        cache_root,
        ".hutch-download-cache",
    });
    try std.Io.Dir.cwd().createDirPath(init.io, download_cache);
    try install_environment.put("BUN_INSTALL_CACHE_DIR", download_cache);
    var install_init = init;
    install_init.environ_map = &install_environment;

    var install_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer install_stdout.deinit();
    var install_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer install_stderr.deinit();
    const exit_code = try package_manager.cli.run(
        install_init,
        args.items,
        &install_stdout.writer,
        &install_stderr.writer,
    );
    if (exit_code != 0) {
        if (install_stdout.written().len > 0) try stderr.writeAll(install_stdout.written());
        if (install_stderr.written().len > 0) try stderr.writeAll(install_stderr.written());
        return error.AutoInstallFailed;
    }

    try prependNodePath(init, allocator, staging_node_modules);
    for (missing.items) |request| {
        try exposeInstalledPackage(
            init,
            allocator,
            cache_root,
            staging_node_modules,
            request,
            bunfig_path,
        );
    }
}

fn canContainPackageImports(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    if (extension.len == 0) return true;

    const supported = [_][]const u8{
        ".js",
        ".jsx",
        ".ts",
        ".tsx",
        ".mjs",
        ".cjs",
        ".mts",
        ".cts",
    };
    for (supported) |candidate| {
        if (std.ascii.eqlIgnoreCase(extension, candidate)) return true;
    }
    return false;
}

pub fn prepareSource(
    init: std.process.Init,
    source: []const u8,
    mode: Mode,
    stderr: *std.Io.Writer,
) !void {
    if (mode == .disable) return;

    const allocator = init.arena.allocator();
    var suffix: u64 = undefined;
    init.io.random(std.mem.asBytes(&suffix));
    const source_path = try std.fmt.allocPrint(
        allocator,
        ".hutch-eval-{x}.ts",
        .{suffix},
    );
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = source_path,
        .data = source,
    });
    defer std.Io.Dir.cwd().deleteFile(init.io, source_path) catch {};

    try prepare(init, source_path, mode, stderr);
}

fn parseMode(value: []const u8) ?Mode {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "fallback")) return .fallback;
    if (std.mem.eql(u8, value, "force")) return .force;
    if (std.mem.eql(u8, value, "disable")) return .disable;
    return null;
}

fn autoInstallRequestFromSpecifier(specifier: []const u8) ?AutoInstallRequest {
    if (specifier.len == 0 or
        std.fs.path.isAbsolute(specifier) or
        isNodeBuiltinSpecifier(specifier) or
        std.mem.startsWith(u8, specifier, "./") or
        std.mem.startsWith(u8, specifier, "../") or
        std.mem.startsWith(u8, specifier, "node:") or
        std.mem.startsWith(u8, specifier, "bun:") or
        std.mem.startsWith(u8, specifier, "data:") or
        std.mem.startsWith(u8, specifier, "file:"))
    {
        return null;
    }

    const package_end = if (specifier[0] == '@') blk: {
        const scope_end = std.mem.indexOfScalarPos(u8, specifier, 1, '/') orelse
            return null;
        break :blk std.mem.indexOfScalarPos(
            u8,
            specifier,
            scope_end + 1,
            '/',
        ) orelse specifier.len;
    } else std.mem.indexOfScalar(u8, specifier, '/') orelse specifier.len;

    const install_specifier = specifier[0..package_end];
    const version_separator = std.mem.lastIndexOfScalar(u8, install_specifier, '@');
    const has_version = if (version_separator) |separator|
        separator > 0 and
            (specifier[0] != '@' or
                std.mem.indexOfScalarPos(u8, install_specifier, 1, '/').? < separator)
    else
        false;
    const package_name = if (has_version)
        install_specifier[0..version_separator.?]
    else
        install_specifier;
    const requested_version = if (has_version and
        version_separator.? + 1 < install_specifier.len)
        install_specifier[version_separator.? + 1 ..]
    else
        null;

    return .{
        .install_specifier = install_specifier,
        .package_name = package_name,
        .requested_version = requested_version,
    };
}

fn isNodeBuiltinSpecifier(specifier: []const u8) bool {
    const root = specifier[0 .. std.mem.indexOfScalar(u8, specifier, '/') orelse specifier.len];
    for ([_][]const u8{
        "_http_agent",
        "_http_client",
        "_http_common",
        "_http_incoming",
        "_http_outgoing",
        "_http_server",
        "_stream_duplex",
        "_stream_passthrough",
        "_stream_readable",
        "_stream_transform",
        "_stream_wrap",
        "_stream_writable",
        "_tls_common",
        "_tls_wrap",
        "assert",
        "async_hooks",
        "buffer",
        "child_process",
        "cluster",
        "console",
        "constants",
        "crypto",
        "dgram",
        "diagnostics_channel",
        "dns",
        "domain",
        "events",
        "fs",
        "http",
        "http2",
        "https",
        "inspector",
        "module",
        "net",
        "os",
        "path",
        "perf_hooks",
        "process",
        "punycode",
        "querystring",
        "readline",
        "repl",
        "stream",
        "string_decoder",
        "sys",
        "timers",
        "tls",
        "trace_events",
        "tty",
        "url",
        "util",
        "v8",
        "vm",
        "wasi",
        "worker_threads",
        "zlib",
    }) |builtin_name| {
        if (std.mem.eql(u8, root, builtin_name)) return true;
    }
    return false;
}

fn autoInstallCacheRoot(
    init: std.process.Init,
    allocator: std.mem.Allocator,
) ![]const u8 {
    if (init.environ_map.get("BUN_INSTALL_CACHE_DIR")) |configured| {
        if (std.fs.path.isAbsolute(configured)) {
            return allocator.dupe(u8, configured);
        }
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(
            init.io,
            ".",
            allocator,
        );
        return std.fs.path.resolve(allocator, &.{ cwd, configured });
    }

    const dash_home = if (init.environ_map.get("DASH_HOME")) |home|
        try allocator.dupe(u8, home)
    else if (init.environ_map.get("HOME")) |home|
        try std.fs.path.join(allocator, &.{ home, ".dash" })
    else if (init.environ_map.get("USERPROFILE")) |home|
        try std.fs.path.join(allocator, &.{ home, ".dash" })
    else blk: {
        const temporary = init.environ_map.get("BUN_TMPDIR") orelse
            init.environ_map.get("TMPDIR") orelse
            init.environ_map.get("TEMP") orelse
            init.environ_map.get("TMP") orelse
            if (builtin.os.tag == .windows) "." else "/tmp";
        break :blk try std.fs.path.join(allocator, &.{
            temporary,
            "hutch-user-cache",
        });
    };

    return std.fs.path.join(allocator, &.{
        dash_home,
        "cache",
        "runtime-auto-install",
    });
}

fn pathIsDirectory(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .directory;
}

fn prependNodePath(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    node_modules: []const u8,
) !void {
    const existing = init.environ_map.get("NODE_PATH") orelse "";
    var iterator = std.mem.splitScalar(u8, existing, std.fs.path.delimiter);
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry, node_modules)) return;
    }

    const value = if (existing.len == 0)
        try allocator.dupe(u8, node_modules)
    else
        try std.fmt.allocPrint(
            allocator,
            "{s}{c}{s}",
            .{ node_modules, std.fs.path.delimiter, existing },
        );
    try init.environ_map.put("NODE_PATH", value);
}

fn findBunfig(
    io: std.Io,
    allocator: std.mem.Allocator,
    start_dir: []const u8,
) !?[]const u8 {
    var current = start_dir;
    while (true) {
        const path = try std.fs.path.join(allocator, &.{ current, "bunfig.toml" });
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch null;
        if (stat != null and stat.?.kind == .file) return path;

        const parent = std.fs.path.dirname(current) orelse return null;
        if (std.mem.eql(u8, parent, current)) return null;
        current = parent;
    }
}

fn installedPackageVersion(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    package_dir: []const u8,
) ?[]const u8 {
    const package_json = std.fs.path.join(
        allocator,
        &.{ package_dir, "package.json" },
    ) catch return null;
    const contents = std.Io.Dir.cwd().readFileAlloc(
        init.io,
        package_json,
        allocator,
        .limited(16 * 1024 * 1024),
    ) catch return null;
    const parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        contents,
        .{},
    ) catch return null;
    if (parsed != .object) return null;
    const version = parsed.object.get("version") orelse return null;
    return if (version == .string) version.string else null;
}

fn createDirectoryLink(
    init: std.process.Init,
    target: []const u8,
    link_path: []const u8,
) !void {
    if (pathIsDirectory(init.io, link_path)) return;
    if (std.fs.path.dirname(link_path)) |parent| {
        try std.Io.Dir.cwd().createDirPath(init.io, parent);
    }
    std.Io.Dir.symLinkAbsolute(
        init.io,
        target,
        link_path,
        .{ .is_directory = true },
    ) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn copyDirectory(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    source: []const u8,
    destination: []const u8,
) !void {
    try std.Io.Dir.cwd().createDirPath(init.io, destination);
    var source_dir = try std.Io.Dir.cwd().openDir(
        init.io,
        source,
        .{ .iterate = true },
    );
    defer source_dir.close(init.io);
    var iterator = source_dir.iterate();
    while (try iterator.next(init.io)) |entry| {
        const source_path = try std.fs.path.join(allocator, &.{
            source,
            entry.name,
        });
        const destination_path = try std.fs.path.join(allocator, &.{
            destination,
            entry.name,
        });
        switch (entry.kind) {
            .directory => try copyDirectory(
                init,
                allocator,
                source_path,
                destination_path,
            ),
            .file => try std.Io.Dir.copyFileAbsolute(
                source_path,
                destination_path,
                init.io,
                .{ .replace = true, .make_path = true },
            ),
            .sym_link => {
                var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const target_len = try std.Io.Dir.readLinkAbsolute(
                    init.io,
                    source_path,
                    &target_buffer,
                );
                if (std.fs.path.dirname(destination_path)) |parent| {
                    try std.Io.Dir.cwd().createDirPath(init.io, parent);
                }
                const target_stat = std.Io.Dir.cwd().statFile(
                    init.io,
                    source_path,
                    .{},
                ) catch null;
                std.Io.Dir.cwd().symLink(
                    init.io,
                    target_buffer[0..target_len],
                    destination_path,
                    .{
                        .is_directory = target_stat != null and
                            target_stat.?.kind == .directory,
                    },
                ) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
            },
            else => {},
        }
    }
}

fn registryUrl(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    bunfig_path: ?[]const u8,
    package_name: []const u8,
) !?[]const u8 {
    inline for (&.{
        "BUN_CONFIG_REGISTRY",
        "npm_config_registry",
        "NPM_CONFIG_REGISTRY",
    }) |name| {
        if (init.environ_map.get(name)) |configured| {
            return @as(?[]const u8, try allocator.dupe(u8, configured));
        }
    }

    const path = bunfig_path orelse return null;
    const source = std.Io.Dir.cwd().readFileAlloc(
        init.io,
        path,
        allocator,
        .limited(1024 * 1024),
    ) catch return null;
    var options = package_manager_options.InstallOptions.init(allocator);
    defer options.deinit();
    package_manager_options.parseBunfig(&options, source) catch return null;

    if (package_name.len > 0 and package_name[0] == '@') {
        const slash = std.mem.indexOfScalar(u8, package_name, '/') orelse
            return null;
        if (options.scopes.get(package_name[1..slash])) |configured| {
            return @as(?[]const u8, try allocator.dupe(u8, configured.url));
        }
    }
    if (options.default_registry) |configured| {
        return @as(?[]const u8, try allocator.dupe(u8, configured.url));
    }
    return null;
}

fn registryHostname(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    bunfig_path: ?[]const u8,
    package_name: []const u8,
) !?[]const u8 {
    const url = try registryUrl(init, allocator, bunfig_path, package_name) orelse
        return null;
    const uri = std.Uri.parse(url) catch return null;
    const host = uri.getHostAlloc(allocator) catch return null;
    if (std.mem.eql(u8, host.bytes, "registry.npmjs.org")) return null;
    return host.bytes;
}

fn exposeInstalledPackage(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    staging_node_modules: []const u8,
    request: AutoInstallRequest,
    bunfig_path: ?[]const u8,
) !void {
    const installed_dir = try std.fs.path.join(allocator, &.{
        staging_node_modules,
        request.package_name,
    });
    if (!pathIsDirectory(init.io, installed_dir)) {
        return error.AutoInstallFailed;
    }

    const version = installedPackageVersion(init, allocator, installed_dir) orelse
        request.requested_version orelse
        "latest";
    const hostname = try registryHostname(
        init,
        allocator,
        bunfig_path,
        request.package_name,
    );
    const cache_entry_name = if (hostname) |custom_hostname|
        try std.fmt.allocPrint(
            allocator,
            "{s}@@{s}@@@1",
            .{ version, custom_hostname },
        )
    else
        try std.fmt.allocPrint(allocator, "{s}@@@1", .{version});
    const canonical_name = try std.fmt.allocPrint(
        allocator,
        "{s}@{s}",
        .{ request.package_name, cache_entry_name },
    );
    const canonical_entry = try std.fs.path.join(
        allocator,
        &.{ cache_root, canonical_name },
    );
    if (!pathIsDirectory(init.io, canonical_entry)) {
        try copyDirectory(init, allocator, installed_dir, canonical_entry);
    }

    const package_cache = try std.fs.path.join(
        allocator,
        &.{ cache_root, request.package_name },
    );
    try std.Io.Dir.cwd().createDirPath(init.io, package_cache);
    const cache_entry = try std.fs.path.join(
        allocator,
        &.{ package_cache, cache_entry_name },
    );
    try createDirectoryLink(init, canonical_entry, cache_entry);

    if (!std.mem.eql(
        u8,
        request.install_specifier,
        request.package_name,
    )) {
        const alias = try std.fs.path.join(allocator, &.{
            staging_node_modules,
            request.install_specifier,
        });
        try createDirectoryLink(init, installed_dir, alias);
    }
}

fn packageIsInstalled(
    io: std.Io,
    allocator: std.mem.Allocator,
    start_dir: []const u8,
    package_name: []const u8,
) bool {
    var current = start_dir;
    while (true) {
        const path = std.fs.path.join(
            allocator,
            &.{ current, "node_modules", package_name, "package.json" },
        ) catch return false;
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch null;
        if (stat != null and stat.?.kind == .file) return true;

        const parent = std.fs.path.dirname(current) orelse return false;
        if (std.mem.eql(u8, parent, current)) return false;
        current = parent;
    }
}

test "leading runtime install modes are parsed before the entrypoint" {
    const fallback = [_][:0]const u8{ "hutch", "--install=fallback", "index.ts" };
    const force = [_][:0]const u8{ "hutch", "--install", "force", "index.ts" };
    const disabled = [_][:0]const u8{ "hutch", "--no-install", "index.ts" };
    const normal = [_][:0]const u8{ "hutch", "index.ts" };

    try std.testing.expectEqual(Mode.fallback, parseLeadingInvocation(&fallback).?.mode);
    try std.testing.expectEqual(@as(usize, 3), parseLeadingInvocation(&force).?.entry_index);
    try std.testing.expectEqual(Mode.disable, parseLeadingInvocation(&disabled).?.mode);
    try std.testing.expect(parseLeadingInvocation(&normal) == null);
}

test "runtime auto-install parses package names, versions, and subpaths" {
    const versioned = autoInstallRequestFromSpecifier("uglify-js@3.17.4").?;
    try std.testing.expectEqualStrings("uglify-js@3.17.4", versioned.install_specifier);
    try std.testing.expectEqualStrings("uglify-js", versioned.package_name);
    try std.testing.expectEqualStrings("3.17.4", versioned.requested_version.?);

    const scoped = autoInstallRequestFromSpecifier("@scope/pkg@1.2.3/subpath").?;
    try std.testing.expectEqualStrings("@scope/pkg@1.2.3", scoped.install_specifier);
    try std.testing.expectEqualStrings("@scope/pkg", scoped.package_name);
    try std.testing.expectEqualStrings("1.2.3", scoped.requested_version.?);

    const unversioned_scoped = autoInstallRequestFromSpecifier("@scope/pkg").?;
    try std.testing.expectEqualStrings("@scope/pkg", unversioned_scoped.install_specifier);
    try std.testing.expectEqualStrings("@scope/pkg", unversioned_scoped.package_name);
    try std.testing.expect(unversioned_scoped.requested_version == null);

    const subpath = autoInstallRequestFromSpecifier("package/subpath").?;
    try std.testing.expectEqualStrings("package", subpath.install_specifier);
    try std.testing.expectEqualStrings("package", subpath.package_name);
    try std.testing.expect(subpath.requested_version == null);
}

test "runtime auto-install ignores non-package module specifiers" {
    for ([_][]const u8{
        "",
        "./local.js",
        "../local.js",
        "fs",
        "fs/promises",
        "assert/strict",
        "node:fs",
        "bun:test",
        "data:text/javascript,export default 1",
        "file:///tmp/local.js",
    }) |specifier| {
        try std.testing.expect(autoInstallRequestFromSpecifier(specifier) == null);
    }
}

test "runtime auto-install only scans JavaScript and TypeScript entrypoints" {
    try std.testing.expect(canContainPackageImports("script"));
    try std.testing.expect(canContainPackageImports("script.ts"));
    try std.testing.expect(canContainPackageImports("script.MJS"));
    try std.testing.expect(!canContainPackageImports("script.sh"));
    try std.testing.expect(!canContainPackageImports("script.py"));
}
