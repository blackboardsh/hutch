const std = @import("std");
const builtin = @import("builtin");
const release_store = @import("release_store.zig");

const max_archive_bytes = 1536 * 1024 * 1024;

pub const Kind = enum {
    zig,
    rust,
    go,
    odin,

    pub fn name(self: Kind) []const u8 {
        return @tagName(self);
    }

    fn executableName(self: Kind) []const u8 {
        return switch (self) {
            .zig => if (builtin.os.tag == .windows) "zig.exe" else "zig",
            .rust => if (builtin.os.tag == .windows) "rustc.exe" else "rustc",
            .go => if (builtin.os.tag == .windows) "go.exe" else "go",
            .odin => if (builtin.os.tag == .windows) "odin.exe" else "odin",
        };
    }

    fn systemExecutable(self: Kind) []const u8 {
        return switch (self) {
            .zig => "zig",
            .rust => "rustc",
            .go => "go",
            .odin => "odin",
        };
    }

    fn versionArgs(self: Kind) []const []const u8 {
        return switch (self) {
            .zig, .odin => &.{"version"},
            .rust => &.{"--version"},
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

const Archive = struct {
    url: []const u8,
    filename: []const u8,
};

pub fn resolveVersion(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    kind: Kind,
    version: []const u8,
) !Resolution {
    try validateVersion(version);
    if (try executableMatchesVersion(init.io, allocator, kind.systemExecutable(), kind, version)) {
        return .{
            .binary = kind.systemExecutable(),
            .root = null,
            .version = version,
            .system = true,
        };
    }

    const home = try release_store.dashHome(init, allocator);
    const root = try std.fs.path.join(allocator, &.{
        home,
        "toolchains",
        kind.name(),
        version,
        try platformKey(),
    });
    const binary = try cachedBinaryPath(allocator, root, kind);
    if (try cachedToolchainMatches(init.io, allocator, root, binary, kind, version)) {
        return .{ .binary = binary, .root = root, .version = version, .system = false };
    }

    const parent = std.fs.path.dirname(root) orelse return error.InvalidToolchainInstallPath;
    try std.Io.Dir.cwd().createDirPath(init.io, parent);
    const lock_path = try std.mem.concat(allocator, u8, &.{ root, ".lock" });
    const lock = try std.Io.Dir.cwd().createFile(init.io, lock_path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
    });
    defer lock.close(init.io);

    if (try cachedToolchainMatches(init.io, allocator, root, binary, kind, version)) {
        return .{ .binary = binary, .root = root, .version = version, .system = false };
    }
    std.Io.Dir.cwd().deleteTree(init.io, root) catch {};

    const archive = try archiveFor(allocator, kind, version);
    std.debug.print(
        "hutch: downloading {s} {s} toolchain for {s}\n",
        .{ kind.name(), version, try platformKey() },
    );
    const bytes = try release_store.fetchBytes(init, allocator, archive.url, max_archive_bytes);
    try install(init, allocator, root, kind, version, archive.filename, bytes);

    const installed_binary = try cachedBinaryPath(allocator, root, kind);
    if (!try executableMatchesVersion(init.io, allocator, installed_binary, kind, version)) {
        return error.ToolchainVersionMismatch;
    }
    return .{
        .binary = installed_binary,
        .root = root,
        .version = version,
        .system = false,
    };
}

fn install(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    root: []const u8,
    kind: Kind,
    version: []const u8,
    archive_filename: []const u8,
    archive: []const u8,
) !void {
    const extraction = try std.mem.concat(allocator, u8, &.{ root, ".extract-tmp" });
    const temporary = try std.mem.concat(allocator, u8, &.{ root, ".install-tmp" });
    const archive_path = try std.fs.path.join(allocator, &.{
        std.fs.path.dirname(root) orelse return error.InvalidToolchainInstallPath,
        try std.mem.concat(allocator, u8, &.{ ".", archive_filename, ".tmp" }),
    });
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

fn publishInstalledToolchain(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    temporary: []const u8,
    kind: Kind,
    version: []const u8,
) !void {
    const installed_binary = try cachedBinaryPath(allocator, temporary, kind);
    if (!pathExists(io, installed_binary)) return error.ToolchainExecutableMissing;
    if (builtin.os.tag != .windows) try makeExecutable(io, installed_binary);
    if (!try executableMatchesVersion(io, allocator, installed_binary, kind, version)) {
        return error.ToolchainVersionMismatch;
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
    if (std.mem.endsWith(u8, archive_path, ".zip.tmp")) {
        if (builtin.os.tag != .windows) {
            try runCommand(init, allocator, &.{ "unzip", "-q", archive_path, "-d", destination });
            return;
        }
        const archive_literal = try powerShellLiteral(allocator, archive_path);
        const destination_literal = try powerShellLiteral(allocator, destination);
        const script = try std.fmt.allocPrint(
            allocator,
            "Expand-Archive -LiteralPath {s} -DestinationPath {s} -Force",
            .{ archive_literal, destination_literal },
        );
        try runCommand(init, allocator, &.{ "powershell", "-NoProfile", "-Command", script });
        return;
    }
    try runCommand(init, allocator, &.{ "tar", "-xf", archive_path, "-C", destination });
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
    };
    return .{ .url = url, .filename = filename };
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

fn cachedBinaryPath(allocator: std.mem.Allocator, root: []const u8, kind: Kind) ![]const u8 {
    return switch (kind) {
        .rust, .go => std.fs.path.join(allocator, &.{ root, "bin", kind.executableName() }),
        .zig, .odin => std.fs.path.join(allocator, &.{ root, kind.executableName() }),
    };
}

fn cachedToolchainMatches(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    binary: []const u8,
    kind: Kind,
    version: []const u8,
) !bool {
    if (!pathExists(io, binary)) return false;
    const marker = try std.fs.path.join(allocator, &.{ root, ".hutch-toolchain" });
    const value = std.Io.Dir.cwd().readFileAlloc(
        io,
        marker,
        allocator,
        .limited(256),
    ) catch return false;
    if (!std.mem.eql(u8, std.mem.trim(u8, value, " \t\r\n"), version)) return false;
    return executableMatchesVersion(io, allocator, binary, kind, version);
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
        .zig => std.mem.eql(u8, output, version),
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

fn validateVersion(version: []const u8) !void {
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

test "toolchain versions cannot escape their cache path" {
    try std.testing.expectError(error.InvalidToolchainVersion, validateVersion("."));
    try std.testing.expectError(error.InvalidToolchainVersion, validateVersion(".."));
    try std.testing.expectError(error.InvalidToolchainVersion, validateVersion("../0.16.0"));
    try validateVersion("0.16.0");
    try validateVersion("dev-2026-07a");
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

test "toolchain archive URLs follow upstream release naming" {
    const archive = try archiveFor(std.testing.allocator, .odin, "dev-2026-07a");
    defer std.testing.allocator.free(archive.url);
    defer std.testing.allocator.free(archive.filename);
    try std.testing.expect(std.mem.indexOf(u8, archive.url, "/dev-2026-07a/odin-") != null);
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
