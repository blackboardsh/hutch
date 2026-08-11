const std = @import("std");
const builtin = @import("builtin");
const archive_util = @import("archive.zig");
const release_store = @import("release_store.zig");

const default_releases_base_url =
    "https://github.com/blackboardsh/electrobun/releases/download";
const max_core_archive_bytes = 512 * 1024 * 1024;
const max_cef_archive_bytes = 1024 * 1024 * 1024;

pub const Kind = enum {
    core,
    cef,

    fn name(self: Kind) []const u8 {
        return @tagName(self);
    }
};

pub fn ensureCore(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    version: []const u8,
) ![]const u8 {
    return ensure(init, allocator, version, .core);
}

pub fn ensureCef(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    version: []const u8,
) ![]const u8 {
    _ = try ensure(init, allocator, version, .core);
    return ensure(init, allocator, version, .cef);
}

fn ensure(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    version: []const u8,
    kind: Kind,
) ![]const u8 {
    try validateVersion(version);
    const home = try release_store.dashHome(init, allocator);
    const platform = try platformKey();
    const root = try std.fs.path.join(allocator, &.{
        home,
        "products",
        "electrobun",
        version,
        platform,
    });
    const base_url = try releasesBaseUrl(init, allocator);
    const url = try artifactUrl(allocator, base_url, version, kind);

    if (try installationMatches(init.io, allocator, root, kind, url)) return root;

    const parent = std.fs.path.dirname(root) orelse return error.InvalidElectrobunInstallPath;
    try std.Io.Dir.cwd().createDirPath(init.io, parent);
    const lock_path = try std.mem.concat(allocator, u8, &.{ root, ".lock" });
    const lock = try std.Io.Dir.cwd().createFile(init.io, lock_path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
    });
    defer lock.close(init.io);

    if (try installationMatches(init.io, allocator, root, kind, url)) return root;

    std.debug.print(
        "hutch: downloading Electrobun {s} {s} for {s}\n",
        .{ version, kind.name(), platform },
    );
    const archive = try release_store.fetchBytes(
        init,
        allocator,
        url,
        if (kind == .core) max_core_archive_bytes else max_cef_archive_bytes,
    );

    switch (kind) {
        .core => try installCore(init.io, allocator, root, archive, url),
        .cef => try installCef(init.io, allocator, root, archive, url),
    }
    return root;
}

fn installCore(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    archive: []const u8,
    url: []const u8,
) !void {
    const temporary = try std.mem.concat(allocator, u8, &.{ root, ".core-tmp" });
    std.Io.Dir.cwd().deleteTree(io, temporary) catch {};
    try std.Io.Dir.cwd().createDirPath(io, temporary);
    errdefer std.Io.Dir.cwd().deleteTree(io, temporary) catch {};

    {
        var destination = try std.Io.Dir.cwd().openDir(io, temporary, .{});
        defer destination.close(io);
        try archive_util.extractTarGzip(
            io,
            allocator,
            destination,
            archive,
            .{ .strip_components = 0 },
        );
    }
    try validateCoreFiles(io, allocator, temporary);
    try writeMarker(io, allocator, temporary, .core, url);

    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), root, io);
}

fn installCef(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    archive: []const u8,
    url: []const u8,
) !void {
    if (!try installationMatches(io, allocator, root, .core, null)) {
        return error.ElectrobunCoreNotInstalled;
    }

    const temporary = try std.mem.concat(allocator, u8, &.{ root, ".cef-tmp" });
    std.Io.Dir.cwd().deleteTree(io, temporary) catch {};
    try std.Io.Dir.cwd().createDirPath(io, temporary);
    defer std.Io.Dir.cwd().deleteTree(io, temporary) catch {};

    {
        var destination = try std.Io.Dir.cwd().openDir(io, temporary, .{});
        defer destination.close(io);
        try archive_util.extractTarGzip(
            io,
            allocator,
            destination,
            archive,
            .{ .strip_components = 0 },
        );
    }

    const extracted_cef = try std.fs.path.join(allocator, &.{ temporary, "cef" });
    if (!pathIsDirectory(io, extracted_cef)) return error.ElectrobunCefArchiveInvalid;
    const installed_cef = try std.fs.path.join(allocator, &.{ root, "cef" });
    std.Io.Dir.cwd().deleteTree(io, installed_cef) catch {};
    try std.Io.Dir.cwd().rename(extracted_cef, std.Io.Dir.cwd(), installed_cef, io);
    try writeMarker(io, allocator, root, .cef, url);
}

fn installationMatches(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    kind: Kind,
    expected_url: ?[]const u8,
) !bool {
    switch (kind) {
        .core => validateCoreFiles(io, allocator, root) catch return false,
        .cef => {
            const cef = try std.fs.path.join(allocator, &.{ root, "cef" });
            if (!pathIsDirectory(io, cef)) return false;
        },
    }

    const marker = try markerPath(allocator, root, kind);
    const value = std.Io.Dir.cwd().readFileAlloc(
        io,
        marker,
        allocator,
        .limited(4096),
    ) catch return false;
    if (expected_url) |url| {
        return std.mem.eql(u8, std.mem.trim(u8, value, " \t\r\n"), url);
    }
    return std.mem.trim(u8, value, " \t\r\n").len > 0;
}

fn validateCoreFiles(io: std.Io, allocator: std.mem.Allocator, root: []const u8) !void {
    const required = [_][]const u8{
        launcherFileName(),
        coreLibraryFileName(),
        nativeWrapperFileName(),
        asarLibraryFileName(),
    };
    for (required) |name| {
        const path = try std.fs.path.join(allocator, &.{ root, name });
        if (!pathExists(io, path)) return error.ElectrobunCoreArchiveInvalid;
    }
}

fn writeMarker(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    kind: Kind,
    url: []const u8,
) !void {
    const marker = try markerPath(allocator, root, kind);
    const value = try std.mem.concat(allocator, u8, &.{ url, "\n" });
    try release_store.writeCacheFile(io, allocator, marker, value);
}

fn markerPath(allocator: std.mem.Allocator, root: []const u8, kind: Kind) ![]const u8 {
    return std.fs.path.join(allocator, &.{
        root,
        if (kind == .core) ".core-complete" else ".cef-complete",
    });
}

fn artifactUrl(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    version: []const u8,
    kind: Kind,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}/v{s}/electrobun-{s}-{s}-{s}.tar.gz",
        .{ base_url, version, kind.name(), releasePlatformName(), releaseArchName() },
    );
}

fn releasesBaseUrl(init: std.process.Init, allocator: std.mem.Allocator) ![]const u8 {
    const configured = init.environ_map.get("ELECTROBUN_RELEASES_BASE_URL") orelse
        default_releases_base_url;
    const value = std.mem.trimEnd(u8, configured, "/");
    if (!std.mem.startsWith(u8, value, "https://") and
        !std.mem.startsWith(u8, value, "http://127.0.0.1") and
        !std.mem.startsWith(u8, value, "http://localhost"))
    {
        return error.InvalidElectrobunReleasesBaseUrl;
    }
    return allocator.dupe(u8, value);
}

fn validateVersion(version: []const u8) !void {
    if (version.len == 0 or version.len > 128) return error.InvalidElectrobunVersion;
    for (version) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '-' and byte != '+') {
            return error.InvalidElectrobunVersion;
        }
    }
}

pub fn platformKey() ![]const u8 {
    return switch (builtin.os.tag) {
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => "macos-arm64",
            .x86_64 => "macos-x64",
            else => error.UnsupportedElectrobunPlatform,
        },
        .linux => switch (builtin.cpu.arch) {
            .aarch64 => "linux-arm64",
            .x86_64 => "linux-x64",
            else => error.UnsupportedElectrobunPlatform,
        },
        .windows => "windows-x64",
        else => error.UnsupportedElectrobunPlatform,
    };
}

fn releasePlatformName() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        .windows => "win",
        else => "unsupported",
    };
}

fn releaseArchName() []const u8 {
    if (builtin.os.tag == .windows) return "x64";
    return switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        else => "x64",
    };
}

fn launcherFileName() []const u8 {
    return if (builtin.os.tag == .windows) "launcher.exe" else "launcher";
}

fn coreLibraryFileName() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "ElectrobunCore.dll",
        .macos => "libElectrobunCore.dylib",
        else => "libElectrobunCore.so",
    };
}

fn nativeWrapperFileName() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "libNativeWrapper.dll",
        .macos => "libNativeWrapper.dylib",
        else => "libNativeWrapper.so",
    };
}

fn asarLibraryFileName() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "libasar.dll",
        .macos => "libasar.dylib",
        else => "libasar.so",
    };
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn pathIsDirectory(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .directory;
}

test "Electrobun release URLs use the published artifact contract" {
    const url = try artifactUrl(
        std.testing.allocator,
        "https://releases.example.test",
        "1.18.4-beta.17",
        .core,
    );
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.startsWith(
        u8,
        url,
        "https://releases.example.test/v1.18.4-beta.17/electrobun-core-",
    ));
    try std.testing.expect(std.mem.endsWith(u8, url, ".tar.gz"));
}

test "Electrobun versions cannot escape the shared cache" {
    try validateVersion("1.18.4-beta.17");
    try std.testing.expectError(error.InvalidElectrobunVersion, validateVersion("../../other"));
    try std.testing.expectError(error.InvalidElectrobunVersion, validateVersion("1.0.0/path"));
}
