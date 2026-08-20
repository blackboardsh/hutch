const std = @import("std");
const builtin = @import("builtin");
const file_locks = @import("file_locks.zig");
const store_locks = @import("store_locks.zig");
const release_store = @import("release_store.zig");

const max_archive_bytes = 1536 * 1024 * 1024;

// Hutch's own bun default for invocations with no hutch.config.ts, where no
// devkit manifest exists to supply toolchains.bun.defaultVersion.
pub const default_bun_version = "1.3.13";

pub const Kind = enum {
    zig,
    rust,
    go,
    odin,
    bun,

    pub fn name(self: Kind) []const u8 {
        return @tagName(self);
    }

    fn executableName(self: Kind) []const u8 {
        return switch (self) {
            .zig => if (builtin.os.tag == .windows) "zig.exe" else "zig",
            .rust => if (builtin.os.tag == .windows) "rustc.exe" else "rustc",
            .go => if (builtin.os.tag == .windows) "go.exe" else "go",
            .odin => if (builtin.os.tag == .windows) "odin.exe" else "odin",
            .bun => if (builtin.os.tag == .windows) "bun.exe" else "bun",
        };
    }

    fn systemExecutable(self: Kind) []const u8 {
        return switch (self) {
            .zig => "zig",
            .rust => "rustc",
            .go => "go",
            .odin => "odin",
            .bun => "bun",
        };
    }

    fn versionArgs(self: Kind) []const []const u8 {
        return switch (self) {
            .zig, .odin => &.{"version"},
            .rust, .bun => &.{"--version"},
            .go => &.{"version"},
        };
    }
};

pub const Resolution = struct {
    binary: []const u8,
    root: ?[]const u8,
    version: []const u8,
    system: bool,
};

pub const LeasedResolution = struct {
    resolution: Resolution,
    lease: ?store_locks.ObjectLease,

    pub fn close(self: LeasedResolution, io: std.Io) void {
        if (self.lease) |lease| lease.close(io);
    }
};

pub fn rustCargoBinary(
    allocator: std.mem.Allocator,
    resolution: Resolution,
) ![]const u8 {
    const root = resolution.root orelse return "cargo";
    return std.fs.path.join(allocator, &.{
        root,
        "bin",
        if (builtin.os.tag == .windows) "cargo.exe" else "cargo",
    });
}

const Archive = struct {
    url: []const u8,
    filename: []const u8,
};

pub fn resolveVersion(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    kind: Kind,
    version: []const u8,
) !LeasedResolution {
    try validateVersion(kind, version);
    if (try systemResolution(init, allocator, kind, version)) |system| return .{
        .resolution = system,
        .lease = null,
    };

    const home = try release_store.hutchHome(init, allocator);
    const graph = try store_locks.acquireGraph(init.io, allocator, home, .shared);
    defer graph.close(init.io);
    return resolveManagedVersionUnderGraph(init, allocator, home, kind, version);
}

/// Resolves while the caller already holds the store graph shared. This is
/// used by project preparation so it does not recursively acquire graph.lock.
pub fn resolveVersionUnderGraph(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    kind: Kind,
    version: []const u8,
) !LeasedResolution {
    try validateVersion(kind, version);
    if (try systemResolution(init, allocator, kind, version)) |system| return .{
        .resolution = system,
        .lease = null,
    };
    const home = try release_store.hutchHome(init, allocator);
    return resolveManagedVersionUnderGraph(init, allocator, home, kind, version);
}

/// Resolves only the managed install, never a PATH executable. Bundled
/// runtimes ship the resolved binary itself, so a system executable (often a
/// version-manager shim) is never an acceptable artifact source.
pub fn resolveManagedOnlyVersion(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    kind: Kind,
    version: []const u8,
) !LeasedResolution {
    try validateVersion(kind, version);
    const home = try release_store.hutchHome(init, allocator);
    const graph = try store_locks.acquireGraph(init.io, allocator, home, .shared);
    defer graph.close(init.io);
    return resolveManagedVersionUnderGraph(init, allocator, home, kind, version);
}

pub fn resolveManagedOnlyVersionUnderGraph(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    kind: Kind,
    version: []const u8,
) !LeasedResolution {
    try validateVersion(kind, version);
    const home = try release_store.hutchHome(init, allocator);
    return resolveManagedVersionUnderGraph(init, allocator, home, kind, version);
}

fn systemResolution(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    kind: Kind,
    version: []const u8,
) !?Resolution {
    const executable_matches = try systemExecutableMatchesVersion(
        init.io,
        allocator,
        kind.systemExecutable(),
        kind,
        version,
    );
    const system_cargo_matches = kind != .rust or
        try cargoMatchesVersion(init.io, allocator, "cargo", version);
    if (executable_matches and system_cargo_matches) {
        return Resolution{
            .binary = kind.systemExecutable(),
            .root = null,
            .version = version,
            .system = true,
        };
    }
    return null;
}

fn resolveManagedVersionUnderGraph(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    home: []const u8,
    kind: Kind,
    version: []const u8,
) !LeasedResolution {
    const root = try toolchainRoot(allocator, home, kind, version);
    const binary = try installedBinaryPath(allocator, root, kind);
    const initial_state = try installedToolchainState(
        init.io,
        allocator,
        root,
        binary,
        kind,
        version,
    );
    if (initial_state == .valid) {
        return leaseManagedResolutionUnderGraph(init.io, allocator, home, .{
            .binary = binary,
            .root = root,
            .version = version,
            .system = false,
        });
    }

    return resolveAfterInstalledMiss(init, allocator, home, root, binary, kind, version);
}

fn resolveAfterInstalledMiss(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    home: []const u8,
    root: []const u8,
    binary: []const u8,
    kind: Kind,
    version: []const u8,
) !LeasedResolution {
    const parent = std.fs.path.dirname(root) orelse return error.InvalidToolchainInstallPath;
    try std.Io.Dir.cwd().createDirPath(init.io, parent);
    const lock_path = try std.mem.concat(allocator, u8, &.{ root, ".lock" });
    const lock = try release_store.acquirePersistentFileLock(init.io, lock_path);
    var lock_open = true;
    defer if (lock_open) lock.close(init.io);

    const locked_state = try installedToolchainState(init.io, allocator, root, binary, kind, version);
    if (locked_state == .valid) {
        lock.close(init.io);
        lock_open = false;
        return leaseManagedResolutionUnderGraph(init.io, allocator, home, .{
            .binary = binary,
            .root = root,
            .version = version,
            .system = false,
        });
    }
    if (environmentFlagEnabled(init.environ_map, "DASH_RELEASE_OFFLINE")) {
        return offlineError(locked_state);
    }
    switch (locked_state) {
        .valid => unreachable,
        .missing => {},
        .damaged => std.Io.Dir.cwd().deleteTree(init.io, root) catch {},
    }

    const archive = try archiveFor(allocator, kind, version);
    std.debug.print(
        "hutch: downloading {s} {s} toolchain for {s}\n",
        .{ kind.name(), version, try platformKey() },
    );
    const bytes = try release_store.fetchBytes(init, allocator, archive.url, max_archive_bytes);
    try install(init, allocator, home, root, kind, version, archive.filename, bytes);

    const installed_binary = try installedBinaryPath(allocator, root, kind);
    if (!try executableMatchesVersion(init.io, allocator, installed_binary, kind, version)) {
        return error.ToolchainVersionMismatch;
    }
    const resolution: Resolution = .{
        .binary = installed_binary,
        .root = root,
        .version = version,
        .system = false,
    };
    lock.close(init.io);
    lock_open = false;
    return leaseManagedResolutionUnderGraph(init.io, allocator, home, resolution);
}

fn leaseManagedResolutionUnderGraph(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    resolution: Resolution,
) !LeasedResolution {
    const root = resolution.root orelse return error.ManagedToolchainRootMissing;
    return .{
        .resolution = resolution,
        .lease = try store_locks.acquireObjectLease(io, allocator, home, root),
    };
}

fn install(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    home: []const u8,
    root: []const u8,
    kind: Kind,
    version: []const u8,
    archive_filename: []const u8,
    archive: []const u8,
) !void {
    const extraction = try std.mem.concat(allocator, u8, &.{ root, ".extract-tmp" });
    const temporary = try std.mem.concat(allocator, u8, &.{ root, ".install-tmp" });
    const archive_path = try temporaryArchivePath(init.io, allocator, home, archive_filename);
    std.Io.Dir.cwd().deleteTree(init.io, extraction) catch {};
    std.Io.Dir.cwd().deleteTree(init.io, temporary) catch {};
    std.Io.Dir.cwd().deleteFile(init.io, archive_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(init.io, extraction) catch {};
    defer std.Io.Dir.cwd().deleteTree(init.io, temporary) catch {};
    defer std.Io.Dir.cwd().deleteFile(init.io, archive_path) catch {};

    try std.Io.Dir.cwd().createDirPath(init.io, extraction);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = archive_path, .data = archive });
    try extractArchive(init, allocator, archive_path, extraction);

    const extracted_root = try extractedRoot(init.io, allocator, extraction);
    if (kind == .rust) {
        try installRustDistribution(init, allocator, extracted_root, temporary);
    } else {
        try std.Io.Dir.cwd().rename(extracted_root, std.Io.Dir.cwd(), temporary, init.io);
    }

    try publishInstalledToolchain(init.io, allocator, root, temporary, kind, version);
}

fn temporaryArchivePath(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    archive_filename: []const u8,
) ![]const u8 {
    var random: [12]u8 = undefined;
    io.random(&random);
    const suffix = std.fmt.bytesToHex(random, .lower);
    const temporary_root = try std.fs.path.join(allocator, &.{ home, "state", "tmp" });
    try std.Io.Dir.cwd().createDirPath(io, temporary_root);
    // The archive filename stays last so extension-based extraction
    // detection (".zip.tmp") sees the real archive format.
    return std.fs.path.join(allocator, &.{
        temporary_root,
        try std.fmt.allocPrint(allocator, "toolchain-{s}-{s}.tmp", .{ &suffix, archive_filename }),
    });
}

fn publishInstalledToolchain(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    temporary: []const u8,
    kind: Kind,
    version: []const u8,
) !void {
    const installed_binary = try installedBinaryPath(allocator, temporary, kind);
    if (!pathExists(io, installed_binary)) return error.ToolchainExecutableMissing;
    if (builtin.os.tag != .windows) try makeExecutable(io, installed_binary);
    if (!try executableMatchesVersion(io, allocator, installed_binary, kind, version)) {
        return error.ToolchainVersionMismatch;
    }
    if (kind == .rust) {
        const cargo_binary = try rustCargoBinary(allocator, .{
            .binary = installed_binary,
            .root = temporary,
            .version = version,
            .system = false,
        });
        if (!pathExists(io, cargo_binary)) return error.ToolchainExecutableMissing;
        if (builtin.os.tag != .windows) try makeExecutable(io, cargo_binary);
        if (!try cargoMatchesVersion(io, allocator, cargo_binary, version)) {
            return error.ToolchainVersionMismatch;
        }
    }

    const marker = try std.fs.path.join(allocator, &.{ temporary, ".hutch-toolchain" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = version });
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), root, io);
}

fn extractArchive(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    archive_path: []const u8,
    destination: []const u8,
) !void {
    // Zip extraction is native: Expand-Archive refuses non-.zip filenames and
    // minimal Linux hosts lack unzip, so neither is an acceptable dependency.
    if (std.mem.endsWith(u8, archive_path, ".zip.tmp")) {
        return extractZipArchive(init.io, archive_path, destination);
    }
    try runCommand(init, allocator, &.{ "tar", "-xf", archive_path, "-C", destination });
}

fn extractZipArchive(io: std.Io, archive_path: []const u8, destination: []const u8) !void {
    var destination_dir = try std.Io.Dir.cwd().openDir(io, destination, .{});
    defer destination_dir.close(io);
    var archive = try std.Io.Dir.cwd().openFile(io, archive_path, .{});
    defer archive.close(io);
    var buffer: [16 * 1024]u8 = undefined;
    var reader = archive.reader(io, &buffer);
    try std.zip.extract(destination_dir, &reader, .{});
}

fn installRustDistribution(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    source: []const u8,
    destination: []const u8,
) !void {
    try std.Io.Dir.cwd().createDirPath(init.io, destination);
    if (builtin.os.tag != .windows) {
        const installer = try std.fs.path.join(allocator, &.{ source, "install.sh" });
        if (!pathExists(init.io, installer)) return error.RustInstallerMissing;
        const prefix = try std.fmt.allocPrint(allocator, "--prefix={s}", .{destination});
        try runCommand(init, allocator, &.{ "sh", installer, prefix, "--disable-ldconfig" });
        return;
    }

    const source_literal = try powerShellLiteral(allocator, source);
    const destination_literal = try powerShellLiteral(allocator, destination);
    const script = try std.fmt.allocPrint(
        allocator,
        "$src={s};$dst={s};$components=Get-Content -LiteralPath (Join-Path $src 'components');" ++
            "foreach($component in $components){{$dir=Join-Path $src $component;" ++
            "Get-ChildItem -LiteralPath $dir | Where-Object {{$_.Name -ne 'manifest.in'}} | " ++
            "ForEach-Object {{$target=Join-Path $dst $_.Name;" ++
            "if($_.PSIsContainer){{New-Item -ItemType Directory -Force -Path $target | Out-Null;" ++
            "Copy-Item -Path (Join-Path $_.FullName '*') -Destination $target -Recurse -Force}}" ++
            "else{{Copy-Item -LiteralPath $_.FullName -Destination $target -Force}}}}}}",
        .{ source_literal, destination_literal },
    );
    try runCommand(init, allocator, &.{ "powershell", "-NoProfile", "-Command", script });
}

fn extractedRoot(io: std.Io, allocator: std.mem.Allocator, extraction: []const u8) ![]const u8 {
    var directory = try std.Io.Dir.cwd().openDir(io, extraction, .{ .iterate = true });
    defer directory.close(io);
    var iterator = directory.iterate();
    var only_directory: ?[]const u8 = null;
    var count: usize = 0;
    while (try iterator.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".DS_Store")) continue;
        count += 1;
        if (entry.kind == .directory and only_directory == null) {
            only_directory = try allocator.dupe(u8, entry.name);
        } else {
            only_directory = null;
        }
    }
    if (count == 0) return error.EmptyToolchainArchive;
    if (count == 1 and only_directory != null) {
        return std.fs.path.join(allocator, &.{ extraction, only_directory.? });
    }
    return extraction;
}

fn archiveFor(allocator: std.mem.Allocator, kind: Kind, version: []const u8) !Archive {
    const filename = switch (kind) {
        .zig => try zigArchiveName(allocator, version),
        .rust => try std.fmt.allocPrint(
            allocator,
            "rust-{s}-{s}.tar.xz",
            .{ version, rustHostTriple() },
        ),
        .go => try std.fmt.allocPrint(
            allocator,
            "go{s}.{s}-{s}.{s}",
            .{
                version,
                if (builtin.os.tag == .macos) "darwin" else if (builtin.os.tag == .windows) "windows" else "linux",
                if (builtin.cpu.arch == .aarch64 and builtin.os.tag != .windows) "arm64" else "amd64",
                if (builtin.os.tag == .windows) "zip" else "tar.gz",
            },
        ),
        .odin => try odinArchiveName(allocator, version),
        .bun => try bunArchiveName(allocator),
    };
    const url = switch (kind) {
        .zig => try std.fmt.allocPrint(allocator, "https://ziglang.org/download/{s}/{s}", .{ version, filename }),
        .rust => try std.fmt.allocPrint(allocator, "https://static.rust-lang.org/dist/{s}", .{filename}),
        .go => try std.fmt.allocPrint(allocator, "https://go.dev/dl/{s}", .{filename}),
        .odin => try std.fmt.allocPrint(
            allocator,
            "https://github.com/odin-lang/Odin/releases/download/{s}/{s}",
            .{ version, filename },
        ),
        .bun => try std.fmt.allocPrint(
            allocator,
            "https://github.com/oven-sh/bun/releases/download/bun-v{s}/{s}",
            .{ version, filename },
        ),
    };
    return .{ .url = url, .filename = filename };
}

fn bunArchiveName(allocator: std.mem.Allocator) ![]const u8 {
    // Windows uses the baseline build: the binary ships inside end-user app
    // bundles, and the non-baseline build requires AVX2.
    if (builtin.os.tag == .windows) {
        return allocator.dupe(u8, "bun-windows-x64-baseline.zip");
    }
    const os = switch (builtin.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        else => return error.UnsupportedToolchainPlatform,
    };
    const arch = if (builtin.cpu.arch == .aarch64) "aarch64" else "x64";
    return std.fmt.allocPrint(allocator, "bun-{s}-{s}.zip", .{ os, arch });
}

fn zigArchiveName(allocator: std.mem.Allocator, version: []const u8) ![]const u8 {
    const os = switch (builtin.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => return error.UnsupportedToolchainPlatform,
    };
    const arch = if (builtin.cpu.arch == .aarch64 and builtin.os.tag != .windows)
        "aarch64"
    else
        "x86_64";
    const ext = if (builtin.os.tag == .windows) "zip" else "tar.xz";
    // ziglang.org flipped archive naming from zig-<os>-<arch>-<version> to
    // zig-<arch>-<os>-<version> starting with 0.14.1 (verified: 0.14.0 only
    // serves the old form, 0.14.1 only the new form). Older electrobun
    // packages still pin 0.13.0, so both forms must resolve.
    if (zigLegacyArchiveNaming(version)) {
        return std.fmt.allocPrint(allocator, "zig-{s}-{s}-{s}.{s}", .{ os, arch, version, ext });
    }
    return std.fmt.allocPrint(allocator, "zig-{s}-{s}-{s}.{s}", .{ arch, os, version, ext });
}

fn zigLegacyArchiveNaming(version: []const u8) bool {
    const parsed = std.SemanticVersion.parse(version) catch return false;
    const flip = std.SemanticVersion{ .major = 0, .minor = 14, .patch = 1 };
    return parsed.order(flip) == .lt;
}

fn odinArchiveName(allocator: std.mem.Allocator, version: []const u8) ![]const u8 {
    const os = switch (builtin.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => return error.UnsupportedToolchainPlatform,
    };
    const arch = if (builtin.cpu.arch == .aarch64 and builtin.os.tag != .windows)
        "arm64"
    else
        "amd64";
    return std.fmt.allocPrint(
        allocator,
        "odin-{s}-{s}-{s}.{s}",
        .{ os, arch, version, if (builtin.os.tag == .windows) "zip" else "tar.gz" },
    );
}

fn rustHostTriple() []const u8 {
    return switch (builtin.os.tag) {
        .macos => if (builtin.cpu.arch == .aarch64) "aarch64-apple-darwin" else "x86_64-apple-darwin",
        .linux => if (builtin.cpu.arch == .aarch64) "aarch64-unknown-linux-gnu" else "x86_64-unknown-linux-gnu",
        .windows => "x86_64-pc-windows-msvc",
        else => "unsupported",
    };
}

fn installedBinaryPath(allocator: std.mem.Allocator, root: []const u8, kind: Kind) ![]const u8 {
    return switch (kind) {
        .rust, .go => std.fs.path.join(allocator, &.{ root, "bin", kind.executableName() }),
        .zig, .odin, .bun => std.fs.path.join(allocator, &.{ root, kind.executableName() }),
    };
}

const InstalledState = enum {
    missing,
    damaged,
    valid,
};

fn installedToolchainState(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    binary: []const u8,
    kind: Kind,
    version: []const u8,
) !InstalledState {
    if (!pathExists(io, root)) return .missing;
    if (!pathExists(io, binary)) return .damaged;
    if (kind == .rust) {
        const cargo_binary = try rustCargoBinary(allocator, .{
            .binary = binary,
            .root = root,
            .version = version,
            .system = false,
        });
        if (!pathExists(io, cargo_binary)) return .damaged;
        if (!try cargoMatchesVersion(io, allocator, cargo_binary, version)) return .damaged;
    }
    const marker = try std.fs.path.join(allocator, &.{ root, ".hutch-toolchain" });
    const value = std.Io.Dir.cwd().readFileAlloc(
        io,
        marker,
        allocator,
        .limited(256),
    ) catch return .damaged;
    if (!std.mem.eql(u8, std.mem.trim(u8, value, " \t\r\n"), version)) return .damaged;
    if (!try executableMatchesVersion(io, allocator, binary, kind, version)) return .damaged;
    return .valid;
}

fn offlineError(state: InstalledState) anyerror {
    return switch (state) {
        .missing => error.ToolchainNotInstalledOffline,
        .damaged => error.ToolchainDamagedOffline,
        .valid => unreachable,
    };
}

fn cargoMatchesVersion(
    io: std.Io,
    allocator: std.mem.Allocator,
    executable: []const u8,
    version: []const u8,
) !bool {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ executable, "--version" },
        .create_no_window = true,
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (termExitCode(result.term) != 0) return false;
    const output = std.mem.trim(u8, result.stdout, " \t\r\n");
    return std.mem.startsWith(
        u8,
        output,
        try std.fmt.allocPrint(allocator, "cargo {s} ", .{version}),
    );
}

fn executableMatchesVersion(
    io: std.Io,
    allocator: std.mem.Allocator,
    executable: []const u8,
    kind: Kind,
    version: []const u8,
) !bool {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, executable);
    try argv.appendSlice(allocator, kind.versionArgs());
    const result = std.process.run(allocator, io, .{
        .argv = argv.items,
        .create_no_window = true,
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (termExitCode(result.term) != 0) return false;
    const output = std.mem.trim(u8, result.stdout, " \t\r\n");
    return switch (kind) {
        .zig, .bun => std.mem.eql(u8, output, version),
        .rust => std.mem.startsWith(u8, output, try std.fmt.allocPrint(allocator, "rustc {s} ", .{version})),
        .go => std.mem.startsWith(u8, output, try std.fmt.allocPrint(allocator, "go version go{s} ", .{version})),
        .odin => blk: {
            var prefix = version;
            if (prefix.len > 0 and std.ascii.isAlphabetic(prefix[prefix.len - 1])) {
                prefix = prefix[0 .. prefix.len - 1];
            }
            break :blk std.mem.indexOf(u8, output, prefix) != null;
        },
    };
}

fn systemExecutableMatchesVersion(
    io: std.Io,
    allocator: std.mem.Allocator,
    executable: []const u8,
    kind: Kind,
    version: []const u8,
) !bool {
    // Odin's `version` output identifies only the dated build month plus a
    // source revision, not the exact immutable release tag suffix (`a`, `b`,
    // ...). A same-month system binary therefore cannot prove it satisfies a
    // `dev-YYYY-MM[a-z]?` pin. Exact dated pins always use the URL-keyed install;
    // executable output remains an archive sanity check there.
    if (kind == .odin and std.mem.startsWith(u8, version, "dev-")) return false;
    return executableMatchesVersion(io, allocator, executable, kind, version);
}

fn runCommand(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) !void {
    const result = try std.process.run(allocator, init.io, .{
        .argv = argv,
        .create_no_window = true,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (termExitCode(result.term) != 0) {
        if (result.stdout.len > 0) std.debug.print("{s}", .{result.stdout});
        if (result.stderr.len > 0) std.debug.print("{s}", .{result.stderr});
        return error.ToolchainCommandFailed;
    }
}

fn termExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| @truncate(code),
        else => 1,
    };
}

fn powerShellLiteral(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    try result.append(allocator, '\'');
    for (value) |byte| {
        try result.append(allocator, byte);
        if (byte == '\'') try result.append(allocator, '\'');
    }
    try result.append(allocator, '\'');
    return result.toOwnedSlice(allocator);
}

fn makeExecutable(io: std.Io, path: []const u8) !void {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);
    try file.setPermissions(io, .executable_file);
}

pub fn validateVersion(kind: Kind, version: []const u8) !void {
    if (version.len == 0 or version.len > 128 or
        std.mem.eql(u8, version, ".") or std.mem.eql(u8, version, ".."))
    {
        return error.InvalidToolchainVersion;
    }
    for (version) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '-' and byte != '+') {
            return error.InvalidToolchainVersion;
        }
    }
    if (kind == .odin) {
        try validateExactOdinVersion(version);
    } else {
        _ = std.SemanticVersion.parse(version) catch return error.InvalidToolchainVersion;
    }
}

fn validateExactOdinVersion(version: []const u8) !void {
    if (std.SemanticVersion.parse(version)) |_| return else |_| {}
    if (version.len != 11 and version.len != 12) return error.InvalidToolchainVersion;
    if (!std.mem.startsWith(u8, version, "dev-") or version[8] != '-') return error.InvalidToolchainVersion;
    for (version[4..8]) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidToolchainVersion;
    for (version[9..11]) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidToolchainVersion;
    const month = std.fmt.parseInt(u8, version[9..11], 10) catch return error.InvalidToolchainVersion;
    if (month < 1 or month > 12) return error.InvalidToolchainVersion;
    if (version.len == 12 and !std.ascii.isLower(version[11])) return error.InvalidToolchainVersion;
}

fn toolchainRoot(
    allocator: std.mem.Allocator,
    home: []const u8,
    kind: Kind,
    version: []const u8,
) ![]const u8 {
    try validateVersion(kind, version);
    return std.fs.path.join(allocator, &.{
        home,
        "toolchains",
        kind.name(),
        version,
        try platformKey(),
    });
}

fn platformKey() ![]const u8 {
    return switch (builtin.os.tag) {
        .macos => if (builtin.cpu.arch == .aarch64) "macos-arm64" else "macos-x64",
        .linux => if (builtin.cpu.arch == .aarch64) "linux-arm64" else "linux-x64",
        .windows => "windows-x64",
        else => error.UnsupportedToolchainPlatform,
    };
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn environmentFlagEnabled(environment: *const std.process.Environ.Map, name: []const u8) bool {
    const value = environment.get(name) orelse return false;
    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes");
}

test "toolchain versions cannot escape their toolchain path" {
    try std.testing.expectError(error.InvalidToolchainVersion, validateVersion(.zig, "."));
    try std.testing.expectError(error.InvalidToolchainVersion, validateVersion(.go, ".."));
    try std.testing.expectError(error.InvalidToolchainVersion, validateVersion(.rust, "../1.88.0"));
    try std.testing.expectError(error.InvalidToolchainVersion, validateVersion(.go, "stable"));
    try std.testing.expectError(error.InvalidToolchainVersion, validateVersion(.go, "1.26"));
    try std.testing.expectError(error.InvalidToolchainVersion, validateVersion(.odin, "latest"));
    try std.testing.expectError(error.InvalidToolchainVersion, validateVersion(.odin, "stable"));
    try std.testing.expectError(error.InvalidToolchainVersion, validateVersion(.odin, "dev-2026-13"));
    try std.testing.expectError(error.InvalidToolchainVersion, validateVersion(.bun, "latest"));
    try std.testing.expectError(error.InvalidToolchainVersion, validateVersion(.bun, "1.3"));
    try validateVersion(.zig, "0.16.0");
    try validateVersion(.rust, "1.88.0");
    try validateVersion(.go, "1.26.4");
    try validateVersion(.odin, "dev-2026-07a");
    try validateVersion(.bun, "1.3.13");
}

test "bun archives resolve from upstream oven-sh releases" {
    const archive = try archiveFor(std.testing.allocator, .bun, "1.3.13");
    defer std.testing.allocator.free(archive.url);
    defer std.testing.allocator.free(archive.filename);
    try std.testing.expect(std.mem.startsWith(
        u8,
        archive.url,
        "https://github.com/oven-sh/bun/releases/download/bun-v1.3.13/bun-",
    ));
    try std.testing.expect(std.mem.endsWith(u8, archive.filename, ".zip"));
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("bun-windows-x64-baseline.zip", archive.filename);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, archive.filename, "baseline") == null);
    }
}

test "zip archives extract natively without external tools" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const name = "bun-fixture/bun";
    const content = "#!/bin/sh\necho fixture\n";
    const crc = std.hash.Crc32.hash(content);

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    const local: std.zip.LocalFileHeader = .{
        .signature = std.zip.local_file_header_sig,
        .version_needed_to_extract = 20,
        .flags = .{ .encrypted = false, ._ = 0 },
        .compression_method = .store,
        .last_modification_time = 0,
        .last_modification_date = 0,
        .crc32 = crc,
        .compressed_size = content.len,
        .uncompressed_size = content.len,
        .filename_len = name.len,
        .extra_len = 0,
    };
    try bytes.appendSlice(allocator, std.mem.asBytes(&local));
    try bytes.appendSlice(allocator, name);
    try bytes.appendSlice(allocator, content);
    const central_offset: u32 = @intCast(bytes.items.len);
    const central: std.zip.CentralDirectoryFileHeader = .{
        .signature = std.zip.central_file_header_sig,
        .version_made_by = 20,
        .version_needed_to_extract = 20,
        .flags = .{ .encrypted = false, ._ = 0 },
        .compression_method = .store,
        .last_modification_time = 0,
        .last_modification_date = 0,
        .crc32 = crc,
        .compressed_size = content.len,
        .uncompressed_size = content.len,
        .filename_len = name.len,
        .extra_len = 0,
        .comment_len = 0,
        .disk_number = 0,
        .internal_file_attributes = 0,
        .external_file_attributes = 0,
        .local_file_header_offset = 0,
    };
    try bytes.appendSlice(allocator, std.mem.asBytes(&central));
    try bytes.appendSlice(allocator, name);
    const end: std.zip.EndRecord = .{
        .signature = std.zip.end_record_sig,
        .disk_number = 0,
        .central_directory_disk_number = 0,
        .record_count_disk = 1,
        .record_count_total = 1,
        .central_directory_size = @intCast(bytes.items.len - central_offset),
        .central_directory_offset = central_offset,
        .comment_len = 0,
    };
    try bytes.appendSlice(allocator, std.mem.asBytes(&end));

    try tmp.dir.createDirPath(io, "out");
    try tmp.dir.writeFile(io, .{ .sub_path = "toolchain-fixture.zip.tmp", .data = bytes.items });
    const relative = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const fixture_root = try std.Io.Dir.cwd().realPathFileAlloc(io, relative, allocator);

    try extractZipArchive(
        io,
        try std.fs.path.join(allocator, &.{ fixture_root, "toolchain-fixture.zip.tmp" }),
        try std.fs.path.join(allocator, &.{ fixture_root, "out" }),
    );
    const extracted = try std.Io.Dir.cwd().readFileAlloc(
        io,
        try std.fs.path.join(allocator, &.{ fixture_root, "out", "bun-fixture", "bun" }),
        allocator,
        .limited(1024),
    );
    try std.testing.expectEqualStrings(content, extracted);
}

test "temporary toolchain archives keep the archive extension last" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const relative = try std.fs.path.join(arena.allocator(), &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const home = try std.Io.Dir.cwd().realPathFileAlloc(io, relative, arena.allocator());
    const path = try temporaryArchivePath(io, arena.allocator(), home, "bun-darwin-aarch64.zip");
    try std.testing.expect(std.mem.endsWith(u8, path, ".zip.tmp"));
}

test "Rust Cargo is selected from the resolved Rust toolchain" {
    const installed = Resolution{
        .binary = "/toolchains/rust/bin/rustc",
        .root = "/toolchains/rust",
        .version = "1.88.0",
        .system = false,
    };
    const cargo = try rustCargoBinary(std.testing.allocator, installed);
    defer std.testing.allocator.free(cargo);
    const expected = try std.fs.path.join(std.testing.allocator, &.{
        "/toolchains/rust",
        "bin",
        if (builtin.os.tag == .windows) "cargo.exe" else "cargo",
    });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(
        expected,
        cargo,
    );

    const system = Resolution{
        .binary = "rustc",
        .root = null,
        .version = "1.88.0",
        .system = true,
    };
    try std.testing.expectEqualStrings(
        "cargo",
        try rustCargoBinary(std.testing.allocator, system),
    );
}

test "a managed toolchain resolution retains its sibling object lease" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const relative = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const fixture = try std.Io.Dir.cwd().realPathFileAlloc(io, relative, allocator);
    const home = try std.fs.path.join(allocator, &.{ fixture, "home" });
    const root = try std.fs.path.join(allocator, &.{
        home,
        "toolchains",
        "zig",
        "0.16.0",
        try platformKey(),
    });
    try std.Io.Dir.cwd().createDirPath(io, root);

    const graph = try store_locks.acquireGraph(io, allocator, home, .shared);
    const leased = try leaseManagedResolutionUnderGraph(io, allocator, home, .{
        .binary = try installedBinaryPath(allocator, root, .zig),
        .root = root,
        .version = "0.16.0",
        .system = false,
    });
    graph.close(io);
    try std.testing.expect((try store_locks.tryAcquireObjectExclusive(
        io,
        allocator,
        root,
    )) == null);

    leased.close(io);
    const exclusive = (try store_locks.tryAcquireObjectExclusive(
        io,
        allocator,
        root,
    )).?;
    exclusive.close(io);
}

test "a mismatched toolchain executable is never published" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try tmp.dir.createDirPath(io, "candidate");
    try tmp.dir.writeFile(io, .{
        .sub_path = "candidate/zig",
        .data = "#!/bin/sh\nprintf '0.15.0\\n'\n",
    });
    const relative = try std.fs.path.join(arena.allocator(), &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const fixture_root = try std.Io.Dir.cwd().realPathFileAlloc(io, relative, arena.allocator());
    const candidate = try std.fs.path.join(arena.allocator(), &.{ fixture_root, "candidate" });
    const published = try std.fs.path.join(arena.allocator(), &.{ fixture_root, "published" });

    try std.testing.expectError(
        error.ToolchainVersionMismatch,
        publishInstalledToolchain(io, arena.allocator(), published, candidate, .zig, "0.16.0"),
    );
    try std.testing.expect(!pathExists(io, published));
    try std.testing.expect(pathExists(io, try std.fs.path.join(arena.allocator(), &.{ candidate, "zig" })));
    try std.testing.expect(!pathExists(io, try std.fs.path.join(arena.allocator(), &.{ candidate, ".hutch-toolchain" })));
}

test "a Rust toolchain with mismatched Cargo is never published" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try tmp.dir.createDirPath(io, "candidate/bin");
    try tmp.dir.writeFile(io, .{
        .sub_path = "candidate/bin/rustc",
        .data = "#!/bin/sh\nprintf 'rustc 1.88.0 (fixture)\\n'\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "candidate/bin/cargo",
        .data = "#!/bin/sh\nprintf 'cargo 1.87.0 (fixture)\\n'\n",
    });
    const relative = try std.fs.path.join(arena.allocator(), &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const fixture_root = try std.Io.Dir.cwd().realPathFileAlloc(io, relative, arena.allocator());
    const candidate = try std.fs.path.join(arena.allocator(), &.{ fixture_root, "candidate" });
    const published = try std.fs.path.join(arena.allocator(), &.{ fixture_root, "published" });

    try std.testing.expectError(
        error.ToolchainVersionMismatch,
        publishInstalledToolchain(io, arena.allocator(), published, candidate, .rust, "1.88.0"),
    );
    try std.testing.expect(!pathExists(io, published));
    try std.testing.expect(!pathExists(io, try std.fs.path.join(arena.allocator(), &.{ candidate, ".hutch-toolchain" })));
}

test "dated Odin pins never select an ambiguous system compiler" {
    if (builtin.os.tag == .windows) {
        try std.testing.expect(!try systemExecutableMatchesVersion(
            std.testing.io,
            std.testing.allocator,
            "odin.exe",
            .odin,
            "dev-2026-07a",
        ));
        return;
    }

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try tmp.dir.writeFile(io, .{
        .sub_path = "odin",
        .data = "#!/bin/sh\nprintf 'version dev-2026-07-nightly:819fdc7\\n'\n",
        .flags = .{ .permissions = .executable_file },
    });
    const relative = try std.fs.path.join(arena.allocator(), &.{ ".zig-cache", "tmp", &tmp.sub_path, "odin" });
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(io, relative, arena.allocator());

    try std.testing.expect(try executableMatchesVersion(
        io,
        arena.allocator(),
        executable,
        .odin,
        "dev-2026-07a",
    ));
    try std.testing.expect(!try systemExecutableMatchesVersion(
        io,
        arena.allocator(),
        executable,
        .odin,
        "dev-2026-07a",
    ));
}

test "toolchain archive URLs follow upstream release naming" {
    const archive = try archiveFor(std.testing.allocator, .odin, "dev-2026-07a");
    defer std.testing.allocator.free(archive.url);
    defer std.testing.allocator.free(archive.filename);
    try std.testing.expect(std.mem.indexOf(u8, archive.url, "/dev-2026-07a/odin-") != null);
}

test "offline toolchain resolution reuses a valid installed toolchain" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();

    const home = try tmp.dir.realPathFileAlloc(io, ".", arena.allocator());
    try environ_map.put("HUTCH_HOME", home);
    try environ_map.put("DASH_RELEASE_OFFLINE", "1");
    try environ_map.put("HTTPS_PROXY", "http://127.0.0.1:1");

    const version = "dev-2099-12z";
    const root = try toolchainRoot(arena.allocator(), home, .odin, version);
    const binary = try installedBinaryPath(arena.allocator(), root, .odin);
    try std.Io.Dir.cwd().createDirPath(io, root);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = binary,
        .data = "#!/bin/sh\nprintf 'version dev-2099-12-nightly:fixture\\n'\n",
        .flags = .{ .permissions = .executable_file },
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(arena.allocator(), &.{ root, ".hutch-toolchain" }),
        .data = version,
    });

    const resolution = try resolveVersion(
        testProcessInit(&arena, &environ_map),
        arena.allocator(),
        .odin,
        version,
    );
    defer resolution.close(io);
    try std.testing.expect(!resolution.resolution.system);
    try std.testing.expectEqualStrings(root, resolution.resolution.root.?);
    try std.testing.expectEqualStrings(binary, resolution.resolution.binary);
}

test "offline toolchain resolution rejects missing and damaged installs before HTTP" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();

    const home = try tmp.dir.realPathFileAlloc(io, ".", arena.allocator());
    try environ_map.put("HUTCH_HOME", home);
    try environ_map.put("DASH_RELEASE_OFFLINE", "yes");
    // If the offline guard regresses, network access fails locally rather than
    // reaching an upstream toolchain host.
    try environ_map.put("HTTPS_PROXY", "http://127.0.0.1:1");

    const version = "dev-2099-11z";
    try std.testing.expectError(
        error.ToolchainNotInstalledOffline,
        resolveVersion(
            testProcessInit(&arena, &environ_map),
            arena.allocator(),
            .odin,
            version,
        ),
    );

    const root = try toolchainRoot(arena.allocator(), home, .odin, version);
    try std.testing.expect(!pathExists(io, root));
    try std.Io.Dir.cwd().createDirPath(io, root);
    const marker = try std.fs.path.join(arena.allocator(), &.{ root, ".hutch-toolchain" });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = marker,
        .data = version,
    });
    try std.testing.expectError(
        error.ToolchainDamagedOffline,
        resolveVersion(
            testProcessInit(&arena, &environ_map),
            arena.allocator(),
            .odin,
            version,
        ),
    );
    try std.testing.expect(pathExists(io, root));
    try std.testing.expect(pathExists(io, marker));
}

test "offline toolchain resolution revalidates after waiting for an installer" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();

    const home = try tmp.dir.realPathFileAlloc(io, ".", arena.allocator());
    try environ_map.put("HUTCH_HOME", home);
    try environ_map.put("DASH_RELEASE_OFFLINE", "1");
    try environ_map.put("HTTPS_PROXY", "http://127.0.0.1:1");

    const version = "dev-2099-10z";
    const root = try toolchainRoot(arena.allocator(), home, .odin, version);
    const binary = try installedBinaryPath(arena.allocator(), root, .odin);
    const parent = std.fs.path.dirname(root).?;
    try std.Io.Dir.cwd().createDirPath(io, parent);
    const lock_path = try std.mem.concat(arena.allocator(), u8, &.{ root, ".lock" });
    const publisher_lock = try release_store.acquirePersistentFileLock(io, lock_path);
    var publisher_lock_open = true;
    errdefer if (publisher_lock_open) publisher_lock.close(io);

    var context = OfflineWaitContext{
        .environ_map = &environ_map,
        .home = home,
        .root = root,
        .binary = binary,
        .version = version,
        .lock_path = lock_path,
    };
    const resolver_thread = try std.Thread.spawn(.{}, OfflineWaitContext.run, .{&context});
    var resolver_thread_joined = false;
    defer {
        if (publisher_lock_open) {
            publisher_lock.close(io);
            publisher_lock_open = false;
        }
        if (!resolver_thread_joined) resolver_thread.join();
    }
    try context.contended.wait(io);

    try std.Io.Dir.cwd().createDirPath(io, root);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = binary,
        .data = "#!/bin/sh\nprintf 'version dev-2099-10-nightly:fixture\\n'\n",
        .flags = .{ .permissions = .executable_file },
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(arena.allocator(), &.{ root, ".hutch-toolchain" }),
        .data = version,
    });
    publisher_lock.close(io);
    publisher_lock_open = false;
    resolver_thread.join();
    resolver_thread_joined = true;

    if (context.failure) |err| return err;
    try std.testing.expect(context.resolved_installed);
}

const OfflineWaitContext = struct {
    environ_map: *std.process.Environ.Map,
    home: []const u8,
    root: []const u8,
    binary: []const u8,
    version: []const u8,
    lock_path: []const u8,
    contended: std.Io.Event = .unset,
    failure: ?anyerror = null,
    resolved_installed: bool = false,

    fn run(context: *@This()) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const probe = file_locks.openNonblocking(
            std.testing.io,
            std.Io.Dir.cwd(),
            context.lock_path,
            .read_write,
            .exclusive,
        ) catch |err| switch (err) {
            error.WouldBlock => {
                context.contended.set(std.testing.io);
                return context.resolve(&arena);
            },
            else => {
                context.failure = err;
                context.contended.set(std.testing.io);
                return;
            },
        };
        probe.close(std.testing.io);
        context.failure = error.ExpectedToolchainLockContention;
        context.contended.set(std.testing.io);
    }

    fn resolve(context: *@This(), arena: *std.heap.ArenaAllocator) void {
        const resolution = resolveAfterInstalledMiss(
            testProcessInit(arena, context.environ_map),
            arena.allocator(),
            context.home,
            context.root,
            context.binary,
            .odin,
            context.version,
        ) catch |err| {
            context.failure = err;
            return;
        };
        defer resolution.close(std.testing.io);
        context.resolved_installed = !resolution.resolution.system;
    }
};

fn testProcessInit(
    arena: *std.heap.ArenaAllocator,
    environ_map: *std.process.Environ.Map,
) std.process.Init {
    return .{
        .minimal = .{
            .environ = .empty,
            .args = .{ .vector = &.{} },
        },
        .arena = arena,
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .environ_map = environ_map,
        .preopens = .empty,
    };
}

test "zig archive naming flips at 0.14.1" {
    // Old pins (<= 0.14.0) use zig-<os>-<arch>-<version>; 0.14.1+ uses
    // zig-<arch>-<os>-<version>. Both must resolve so older electrobun
    // packages keep working.
    try std.testing.expect(zigLegacyArchiveNaming("0.13.0"));
    try std.testing.expect(zigLegacyArchiveNaming("0.14.0"));
    try std.testing.expect(!zigLegacyArchiveNaming("0.14.1"));
    try std.testing.expect(!zigLegacyArchiveNaming("0.16.0"));

    const legacy = try zigArchiveName(std.testing.allocator, "0.13.0");
    defer std.testing.allocator.free(legacy);
    const modern = try zigArchiveName(std.testing.allocator, "0.16.0");
    defer std.testing.allocator.free(modern);
    const arch = if (builtin.cpu.arch == .aarch64 and builtin.os.tag != .windows)
        "aarch64"
    else
        "x86_64";
    try std.testing.expect(std.mem.startsWith(u8, legacy, "zig-") and
        std.mem.indexOf(u8, legacy, arch) != null);
    try std.testing.expect(std.mem.indexOf(u8, modern, "-0.16.0.") != null);
    // Modern names lead with the arch segment.
    var prefix_buf: [32]u8 = undefined;
    const modern_prefix = try std.fmt.bufPrint(&prefix_buf, "zig-{s}-", .{arch});
    try std.testing.expect(std.mem.startsWith(u8, modern, modern_prefix));
    try std.testing.expect(!std.mem.startsWith(u8, legacy, modern_prefix) or
        builtin.os.tag == .windows);
}

test "toolchain versions resolve to isolated toolchain roots without downloading" {
    const first = try toolchainRoot(std.testing.allocator, "/tmp/hutch-test-home", .zig, "0.14.1");
    defer std.testing.allocator.free(first);
    const second = try toolchainRoot(std.testing.allocator, "/tmp/hutch-test-home", .zig, "0.15.2");
    defer std.testing.allocator.free(second);

    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expect(std.mem.indexOf(u8, first, "0.14.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "0.15.2") != null);
}

test "toolchain versions reject unsafe path components" {
    for ([_][]const u8{ "", ".", "..", "0.16.0/../../escape", "0.16.0\\escape" }) |version| {
        try std.testing.expectError(error.InvalidToolchainVersion, validateVersion(.zig, version));
    }
}
