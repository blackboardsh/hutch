const std = @import("std");
const Host = @import("package_manager_host.zig");
const PackageHash = @import("support/package_hash.zig");

const binary_header = "#!/usr/bin/env bun\nbun-lockfile-format-v0\n";
const config_version_tag = "cNfGvRsN";
const lockfile_service = "--cottontail-lockfile-service";

pub const lifecycle_script_names = [_][]const u8{
    "preinstall",
    "install",
    "postinstall",
    "preprepare",
    "prepare",
    "postprepare",
};

pub const WorkspaceLifecycleScripts = struct {
    path: []u8,
    commands: [lifecycle_script_names.len][]u8,

    fn deinit(scripts: *WorkspaceLifecycleScripts, allocator: std.mem.Allocator) void {
        allocator.free(scripts.path);
        for (scripts.commands) |command| allocator.free(command);
        scripts.* = undefined;
    }
};

pub const BinaryText = struct {
    text: []u8,
    migrated_from_v2: bool,
    trusted_dependency_hashes: ?[]PackageHash.TruncatedPackageNameHash,
    lifecycle_scripts: []WorkspaceLifecycleScripts,

    pub fn deinit(converted: *BinaryText, allocator: std.mem.Allocator) void {
        allocator.free(converted.text);
        if (converted.trusted_dependency_hashes) |hashes| allocator.free(hashes);
        deinitWorkspaceLifecycleScripts(allocator, converted.lifecycle_scripts);
        converted.* = undefined;
    }
};

const BinaryTextMetadata = struct {
    migrated_from_v2: bool,
    trusted_dependency_hashes: ?[]const PackageHash.TruncatedPackageNameHash = null,
    lifecycle_scripts: []const WorkspaceLifecycleScriptsWire = &.{},
};

const WorkspaceLifecycleScriptsWire = struct {
    path: []const u8,
    commands: [lifecycle_script_names.len][]const u8,
};

pub fn isBinaryLockfile(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, binary_header);
}

/// Binary lockfiles written before configVersion existed omit this trailer.
/// Bun interprets that omission as config v0 rather than the current default.
pub fn savedConfigVersion(bytes: []const u8) ?u64 {
    const tag_index = std.mem.lastIndexOf(u8, bytes, config_version_tag) orelse return null;
    const value_start = tag_index + config_version_tag.len;
    if (bytes.len - value_start < @sizeOf(u64)) return null;
    return std.mem.readInt(u64, bytes[value_start..][0..@sizeOf(u64)], .little);
}

pub fn textToBinary(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    text: []const u8,
) ![]u8 {
    return textToBinaryAtRoot(init, allocator, text, null);
}

pub fn textToBinaryAtRoot(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    text: []const u8,
    root_dir: ?[]const u8,
) ![]u8 {
    const extra_args: []const []const u8 = if (root_dir) |root| &.{root} else &.{};
    return call(init, allocator, "text-to-binary", text, extra_args);
}

pub fn migrateNpmToBinary(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    source_text: []const u8,
    source_path: []const u8,
    registry_url: []const u8,
) ![]u8 {
    return call(
        init,
        allocator,
        "npm-to-binary",
        source_text,
        &.{ registry_url, source_path },
    );
}

pub fn writeTextMetaHash(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    text: []const u8,
    writer: *std.Io.Writer,
) !void {
    return writeResult(init, allocator, "text-meta-hash", text, &.{}, writer);
}

pub fn writeTextMetaHashString(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    text: []const u8,
    writer: *std.Io.Writer,
) !void {
    return writeResult(init, allocator, "text-meta-hash-string", text, &.{}, writer);
}

pub fn writeBinaryMetaHash(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    binary: []const u8,
    writer: *std.Io.Writer,
) !void {
    return writeResult(init, allocator, "binary-meta-hash", binary, &.{}, writer);
}

pub fn writeBinaryMetaHashString(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    binary: []const u8,
    writer: *std.Io.Writer,
) !void {
    return writeResult(init, allocator, "binary-meta-hash-string", binary, &.{}, writer);
}

pub fn binaryToText(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    binary: []const u8,
) ![]u8 {
    return call(init, allocator, "binary-to-text", binary, &.{});
}

pub fn binaryToTextWithMetadata(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    binary: []const u8,
) !BinaryText {
    const output = try call(init, allocator, "binary-to-text-metadata", binary, &.{});
    defer allocator.free(output);
    if (output.len < @sizeOf(u64)) return error.InvalidLockfileServiceResponse;

    const metadata_length = std.mem.readInt(
        u64,
        output[0..@sizeOf(u64)],
        .little,
    );
    const metadata_end = std.math.add(
        usize,
        @sizeOf(u64),
        std.math.cast(usize, metadata_length) orelse
            return error.InvalidLockfileServiceResponse,
    ) catch return error.InvalidLockfileServiceResponse;
    if (metadata_end > output.len) return error.InvalidLockfileServiceResponse;

    const parsed = try std.json.parseFromSlice(
        BinaryTextMetadata,
        allocator,
        output[@sizeOf(u64)..metadata_end],
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const trusted_hashes = if (parsed.value.trusted_dependency_hashes) |hashes|
        try allocator.dupe(PackageHash.TruncatedPackageNameHash, hashes)
    else
        null;
    errdefer if (trusted_hashes) |hashes| allocator.free(hashes);

    const lifecycle_scripts = try cloneWorkspaceLifecycleScripts(
        allocator,
        parsed.value.lifecycle_scripts,
    );
    errdefer deinitWorkspaceLifecycleScripts(allocator, lifecycle_scripts);

    return .{
        .text = try allocator.dupe(u8, output[metadata_end..]),
        .migrated_from_v2 = parsed.value.migrated_from_v2,
        .trusted_dependency_hashes = trusted_hashes,
        .lifecycle_scripts = lifecycle_scripts,
    };
}

pub fn upgradeBinaryFormat(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    binary: []const u8,
) ![]u8 {
    return call(init, allocator, "upgrade-binary", binary, &.{});
}

pub fn updateBinaryTrustedDependencies(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    binary: []const u8,
    trusted_names: []const []const u8,
) ![]u8 {
    return call(init, allocator, "update-trusted", binary, trusted_names);
}

pub fn writeYarnFromBinary(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    binary: []const u8,
    writer: *std.Io.Writer,
) !void {
    return writeResult(init, allocator, "yarn-from-binary", binary, &.{}, writer);
}

pub fn packageResolutionURLFromBinary(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    binary: []const u8,
    package_name: []const u8,
) !?[]u8 {
    const output = try call(init, allocator, "package-url", binary, &.{package_name});
    if (output.len == 0) {
        allocator.free(output);
        return null;
    }
    return output;
}

pub fn writeYarnFromText(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    text: []const u8,
    writer: *std.Io.Writer,
) !void {
    return writeResult(init, allocator, "yarn-from-text", text, &.{}, writer);
}

fn call(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    operation: []const u8,
    input: []const u8,
    extra_args: []const []const u8,
) ![]u8 {
    return Host.runRuntimeService(
        init,
        allocator,
        lockfile_service,
        operation,
        input,
        extra_args,
    );
}

fn writeResult(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    operation: []const u8,
    input: []const u8,
    extra_args: []const []const u8,
    writer: *std.Io.Writer,
) !void {
    const output = try call(init, allocator, operation, input, extra_args);
    defer allocator.free(output);
    try writer.writeAll(output);
}

fn cloneWorkspaceLifecycleScripts(
    allocator: std.mem.Allocator,
    source: []const WorkspaceLifecycleScriptsWire,
) ![]WorkspaceLifecycleScripts {
    const cloned = try allocator.alloc(WorkspaceLifecycleScripts, source.len);
    var completed: usize = 0;
    errdefer {
        for (cloned[0..completed]) |*scripts| scripts.deinit(allocator);
        allocator.free(cloned);
    }

    for (source, cloned) |wire, *scripts| {
        scripts.path = try allocator.dupe(u8, wire.path);
        var command_count: usize = 0;
        errdefer {
            allocator.free(scripts.path);
            for (scripts.commands[0..command_count]) |command| allocator.free(command);
        }
        for (wire.commands, 0..) |command, index| {
            scripts.commands[index] = try allocator.dupe(u8, command);
            command_count += 1;
        }
        completed += 1;
    }
    return cloned;
}

fn deinitWorkspaceLifecycleScripts(
    allocator: std.mem.Allocator,
    lifecycle_scripts: []WorkspaceLifecycleScripts,
) void {
    for (lifecycle_scripts) |*scripts| scripts.deinit(allocator);
    allocator.free(lifecycle_scripts);
}

test "Bun binary lockfile detection remains local to Hutch" {
    try std.testing.expect(isBinaryLockfile(binary_header ++ "payload"));
    try std.testing.expect(!isBinaryLockfile("{\"lockfileVersion\":1}"));
}

test "Bun binary config version trailer preserves omitted v0 semantics" {
    try std.testing.expectEqual(@as(?u64, null), savedConfigVersion(binary_header ++ "payload"));

    const v0 = binary_header ++ "payload" ++ config_version_tag ++ "\x00\x00\x00\x00\x00\x00\x00\x00";
    const v1 = binary_header ++ "payload" ++ config_version_tag ++ "\x01\x00\x00\x00\x00\x00\x00\x00";
    try std.testing.expectEqual(@as(?u64, 0), savedConfigVersion(v0));
    try std.testing.expectEqual(@as(?u64, 1), savedConfigVersion(v1));
}
