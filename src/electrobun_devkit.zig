const std = @import("std");
const builtin = @import("builtin");
const release_store = @import("release_store.zig");

const manifest_file_name = "native-devkit.json";
const max_manifest_bytes = 1024 * 1024;
const supported_schema_version = 1;
const supported_core_abi_version = 1;
const supported_sdk_abi_version = 1;
const projection_kind = "electrobun-devkit-projection";
const projected_api_root = "api";
const projected_zig_root = "zig-sdk";
const projected_rust_root = "rust-sdk";
const projected_go_root = "go-sdk";
const projected_odin_root = "odin-sdk";

pub const ToolchainVersions = struct {
    zig: []const u8,
    rust: []const u8,
    go: []const u8,
    odin: []const u8,
    bun: []const u8,
    /// The Cottontail runtime this Electrobun release bundles into apps with
    /// `mainProcess: "cottontail"` — an app runtime component like the
    /// bundled Bun, distinct from the build-time Cottontail that executes
    /// configs and scripts. Null for devkits published before the pin
    /// existed; those bundle the build-time binary they were tested with.
    cottontail: ?[]const u8 = null,
};

pub const RuntimePaths = struct {
    main: []const u8,
    preload_full: []const u8,
    preload_sandboxed: []const u8,
    /// Schema-1 devkits through Electrobun 2.0.1-beta.18 shipped Bun in the
    /// core archive and described it at `layout.runtime.bun`. Newer schema-1
    /// devkits omit the path and pin a separately managed Bun toolchain.
    bun: ?[]const u8,
    launcher: []const u8,
    extractor: []const u8,
    core_library: []const u8,
    native_wrapper: []const u8,
    native_wrapper_cef: []const u8,
    asar_library: []const u8,
    wgpu_library: []const u8,
    wgpu_auxiliary_libraries: []const []const u8,
    process_helper: []const u8,
    bsdiff: []const u8,
    bspatch: []const u8,
    zig_asar: []const u8,
    zig_zstd: []const u8,
};

pub const JavaScriptSdkPaths = struct {
    root: []const u8,
    relative_root: []const u8,
    main: []const u8,
    browser: []const u8,
    config: []const u8,
    preload: []const u8,
    exports: []const JavaScriptExport,
};

pub const JavaScriptExport = struct {
    specifier: []const u8,
    relative_path: []const u8,
    absolute_path: []const u8,
};

pub const NativeSdkPaths = struct {
    root: []const u8,
    relative_root: []const u8,
    entrypoint: []const u8,
    relative_entrypoint: []const u8,
};

pub const RustSdkPaths = struct {
    root: []const u8,
    relative_root: []const u8,
    manifest: []const u8,
    relative_manifest: []const u8,
};

pub const GoSdkPaths = struct {
    root: []const u8,
    relative_root: []const u8,
    manifest: []const u8,
    relative_manifest: []const u8,
    module: []const u8,
};

pub const OdinSdkPaths = struct {
    root: []const u8,
    relative_root: []const u8,
    entrypoint: []const u8,
    relative_entrypoint: []const u8,
    collection: []const u8,
    relative_collection: []const u8,
    collection_name: []const u8,
};

pub const SdkPaths = struct {
    javascript: JavaScriptSdkPaths,
    zig: NativeSdkPaths,
    rust: RustSdkPaths,
    go: GoSdkPaths,
    odin: OdinSdkPaths,
};

pub const Resolution = struct {
    root: []const u8,
    version: []const u8,
    source_manifest_sha256: []const u8,
    toolchains: ToolchainVersions,
    runtime: RuntimePaths,
    sdks: SdkPaths,
};

pub const Projection = struct {
    root: []const u8,
    package_root: []const u8,
    tsconfig: []const u8,
    zig_root: []const u8,
    zig_entrypoint: []const u8,
    rust_root: []const u8,
    rust_manifest: []const u8,
    go_root: []const u8,
    go_manifest: []const u8,
    go_module: []const u8,
    odin_root: []const u8,
    odin_entrypoint: []const u8,
    odin_collection: []const u8,
};

pub const ProjectOptions = struct {
    force: bool = false,
};

pub fn projectedJavaScriptPath(
    allocator: std.mem.Allocator,
    projection_root: []const u8,
    source_root: []const u8,
    source_path: []const u8,
) ![]const u8 {
    return projectedAbsolutePath(
        allocator,
        projection_root,
        projected_api_root,
        source_root,
        source_path,
    );
}

pub fn configuredVersion(root: std.json.Value) ![]const u8 {
    if (root != .object) return error.InvalidHutchConfig;

    const electrobun = root.object.get("electrobun") orelse
        return error.ElectrobunVersionMissing;
    if (electrobun != .object) return error.InvalidHutchConfig;

    const version = electrobun.object.get("version") orelse
        return error.ElectrobunVersionMissing;
    if (version != .string) return error.InvalidElectrobunVersionType;
    try validateExactVersion(version.string);
    return version.string;
}

pub fn load(
    io: std.Io,
    allocator: std.mem.Allocator,
    core_root: []const u8,
    requested_version: []const u8,
) !Resolution {
    try validateExactVersion(requested_version);
    const manifest_path = try std.fs.path.join(allocator, &.{ core_root, manifest_file_name });
    const source = std.Io.Dir.cwd().readFileAlloc(
        io,
        manifest_path,
        allocator,
        .limited(max_manifest_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.ElectrobunDevkitManifestNotFound,
        else => return err,
    };
    const manifest = std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        source,
        .{ .duplicate_field_behavior = .@"error" },
    ) catch return error.InvalidElectrobunDevkitManifest;
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &manifest_digest, .{});
    const manifest_digest_hex = std.fmt.bytesToHex(manifest_digest, .lower);

    const root = try requiredObject(manifest, null);
    if (try requiredInteger(root, "schemaVersion") != supported_schema_version) {
        return error.UnsupportedElectrobunDevkitSchema;
    }

    const product = try requiredObjectField(root, "product");
    if (!std.mem.eql(u8, try requiredString(product, "name"), "electrobun")) {
        return error.InvalidElectrobunDevkitProduct;
    }
    const manifest_version = try requiredString(product, "version");
    try validateExactVersion(manifest_version);
    if (!std.mem.eql(u8, manifest_version, requested_version)) {
        return error.ElectrobunDevkitVersionMismatch;
    }

    const target = try requiredObjectField(root, "target");
    if (!std.mem.eql(u8, try requiredString(target, "os"), targetOs()) or
        !std.mem.eql(u8, try requiredString(target, "arch"), targetArch()))
    {
        return error.ElectrobunDevkitTargetMismatch;
    }

    const abi = try requiredObjectField(root, "abi");
    try validateAbi(
        try requiredObjectField(abi, "core"),
        "electrobun-core",
        supported_core_abi_version,
    );
    try validateAbi(
        try requiredObjectField(abi, "sdk"),
        "electrobun-sdk",
        supported_sdk_abi_version,
    );

    const toolchains = try requiredObjectField(root, "toolchains");
    const has_managed_bun_toolchain = toolchains.get("bun") != null;
    const toolchain_versions: ToolchainVersions = .{
        .zig = try toolchainVersion(toolchains, "zig"),
        .rust = try toolchainVersion(toolchains, "rust"),
        .go = try toolchainVersion(toolchains, "go"),
        .odin = try toolchainVersion(toolchains, "odin"),
        .bun = if (has_managed_bun_toolchain)
            try toolchainVersion(toolchains, "bun")
        else
            try runtimeVersion(try requiredObjectField(root, "runtimes"), "bun"),
        .cottontail = try optionalToolchainVersion(toolchains, "cottontail"),
    };

    const layout = try requiredObjectField(root, "layout");
    const runtime = try requiredObjectField(layout, "runtime");
    const runtime_paths: RuntimePaths = .{
        .main = try requiredExistingPath(io, allocator, core_root, runtime, "main", .file),
        .preload_full = try requiredExistingPath(io, allocator, core_root, runtime, "preloadFull", .file),
        .preload_sandboxed = try requiredExistingPath(io, allocator, core_root, runtime, "preloadSandboxed", .file),
        .bun = if (has_managed_bun_toolchain)
            null
        else
            try requiredExistingPath(io, allocator, core_root, runtime, "bun", .file),
        .launcher = try requiredExistingPath(io, allocator, core_root, runtime, "launcher", .file),
        .extractor = try requiredExistingPath(io, allocator, core_root, runtime, "extractor", .file),
        .core_library = try requiredExistingPath(io, allocator, core_root, runtime, "coreLibrary", .file),
        .native_wrapper = try requiredExistingPath(io, allocator, core_root, runtime, "nativeWrapper", .file),
        .native_wrapper_cef = try requiredExistingPath(io, allocator, core_root, runtime, "nativeWrapperCef", .file),
        .asar_library = try requiredExistingPath(io, allocator, core_root, runtime, "asarLibrary", .file),
        .wgpu_library = try requiredExistingPath(io, allocator, core_root, runtime, "wgpuLibrary", .file),
        .wgpu_auxiliary_libraries = try optionalExistingPaths(io, allocator, core_root, runtime, "wgpuAuxiliaryLibraries", .file),
        .process_helper = try requiredExistingPath(io, allocator, core_root, runtime, "processHelper", .file),
        .bsdiff = try requiredExistingPath(io, allocator, core_root, runtime, "bsdiff", .file),
        .bspatch = try requiredExistingPath(io, allocator, core_root, runtime, "bspatch", .file),
        .zig_asar = try requiredExistingPath(io, allocator, core_root, runtime, "zigAsar", .file),
        .zig_zstd = try requiredExistingPath(io, allocator, core_root, runtime, "zigZstd", .file),
    };

    const sdks = try requiredObjectField(layout, "sdks");
    const javascript = try requiredObjectField(sdks, "javascript");
    const javascript_root = try requiredString(javascript, "root");
    const javascript_paths: JavaScriptSdkPaths = .{
        .root = try existingPath(io, allocator, core_root, javascript_root, .directory),
        .relative_root = javascript_root,
        .main = try requiredExistingPath(io, allocator, core_root, javascript, "main", .file),
        .browser = try requiredExistingPath(io, allocator, core_root, javascript, "browser", .file),
        .config = try requiredExistingPath(io, allocator, core_root, javascript, "config", .file),
        .preload = try requiredExistingPath(io, allocator, core_root, javascript, "preload", .directory),
        .exports = try javascriptExports(io, allocator, core_root, javascript),
    };

    const sdk_paths: SdkPaths = .{
        .javascript = javascript_paths,
        .zig = try nativeSdkPaths(io, allocator, core_root, sdks, "zig"),
        .rust = try rustSdkPaths(io, allocator, core_root, sdks),
        .go = try goSdkPaths(io, allocator, core_root, sdks),
        .odin = try odinSdkPaths(io, allocator, core_root, sdks),
    };

    return .{
        .root = core_root,
        .version = manifest_version,
        .source_manifest_sha256 = try allocator.dupe(u8, &manifest_digest_hex),
        .toolchains = toolchain_versions,
        .runtime = runtime_paths,
        .sdks = sdk_paths,
    };
}

pub fn project(
    io: std.Io,
    allocator: std.mem.Allocator,
    project_root: []const u8,
    resolution: Resolution,
    options: ProjectOptions,
) !Projection {
    const hutch_root = try std.fs.path.join(allocator, &.{ project_root, ".hutch" });
    try std.Io.Dir.cwd().createDirPath(io, hutch_root);

    const lock_path = try std.fs.path.join(allocator, &.{ hutch_root, "devkit.lock" });
    const lock = try release_store.acquirePersistentFileLock(io, lock_path);
    defer lock.close(io);

    const final_root = try std.fs.path.join(allocator, &.{ hutch_root, "devkit" });
    const marker = try projectionMarker(allocator, resolution);
    if (!options.force and try projectionMatches(io, allocator, final_root, marker, resolution)) {
        return projectionPaths(allocator, final_root, resolution);
    }

    const process_id = switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        else => @as(u64, @intCast(std.posix.system.getpid())),
    };
    const temporary = try std.fs.path.join(allocator, &.{
        hutch_root,
        try std.fmt.allocPrint(allocator, ".devkit-tmp-{d}", .{process_id}),
    });
    const backup = try std.fs.path.join(allocator, &.{
        hutch_root,
        try std.fmt.allocPrint(allocator, ".devkit-old-{d}", .{process_id}),
    });
    std.Io.Dir.cwd().deleteTree(io, temporary) catch {};
    std.Io.Dir.cwd().deleteTree(io, backup) catch {};
    try std.Io.Dir.cwd().createDirPath(io, temporary);
    errdefer std.Io.Dir.cwd().deleteTree(io, temporary) catch {};

    const copy_roots = [_]struct { source: []const u8, relative: []const u8 }{
        .{ .source = resolution.sdks.javascript.root, .relative = projected_api_root },
        .{ .source = resolution.sdks.zig.root, .relative = projected_zig_root },
        .{ .source = resolution.sdks.rust.root, .relative = projected_rust_root },
        .{ .source = resolution.sdks.go.root, .relative = projected_go_root },
        .{ .source = resolution.sdks.odin.collection, .relative = projected_odin_root },
    };
    for (copy_roots) |copy_root| {
        try validateRelativePosixPath(copy_root.relative);
        try copyTree(
            io,
            allocator,
            copy_root.source,
            try std.fs.path.join(allocator, &.{ temporary, copy_root.relative }),
        );
    }

    try writeFacadePackage(io, allocator, temporary, resolution);
    try writeProjectionTsconfig(io, allocator, temporary, resolution);
    try writeProjectionMetadata(io, allocator, temporary, resolution);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ temporary, ".complete" }),
        .data = marker,
    });

    var moved_existing = false;
    if (pathExists(io, final_root)) {
        try std.Io.Dir.cwd().rename(final_root, std.Io.Dir.cwd(), backup, io);
        moved_existing = true;
    }
    std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), final_root, io) catch |err| {
        if (moved_existing and !pathExists(io, final_root)) {
            std.Io.Dir.cwd().rename(backup, std.Io.Dir.cwd(), final_root, io) catch {};
        }
        return err;
    };
    if (moved_existing) std.Io.Dir.cwd().deleteTree(io, backup) catch {};
    return projectionPaths(allocator, final_root, resolution);
}

fn projectionPaths(
    allocator: std.mem.Allocator,
    root: []const u8,
    resolution: Resolution,
) !Projection {
    return .{
        .root = root,
        .package_root = root,
        .tsconfig = try std.fs.path.join(allocator, &.{ root, "tsconfig.json" }),
        .zig_root = try std.fs.path.join(allocator, &.{ root, projected_zig_root }),
        .zig_entrypoint = try projectedAbsolutePath(allocator, root, projected_zig_root, resolution.sdks.zig.relative_root, resolution.sdks.zig.relative_entrypoint),
        .rust_root = try std.fs.path.join(allocator, &.{ root, projected_rust_root }),
        .rust_manifest = try projectedAbsolutePath(allocator, root, projected_rust_root, resolution.sdks.rust.relative_root, resolution.sdks.rust.relative_manifest),
        .go_root = try std.fs.path.join(allocator, &.{ root, projected_go_root }),
        .go_manifest = try projectedAbsolutePath(allocator, root, projected_go_root, resolution.sdks.go.relative_root, resolution.sdks.go.relative_manifest),
        .go_module = resolution.sdks.go.module,
        .odin_root = try projectedAbsolutePath(allocator, root, projected_odin_root, resolution.sdks.odin.relative_collection, resolution.sdks.odin.relative_root),
        .odin_entrypoint = try projectedAbsolutePath(allocator, root, projected_odin_root, resolution.sdks.odin.relative_collection, resolution.sdks.odin.relative_entrypoint),
        .odin_collection = try std.fs.path.join(allocator, &.{ root, projected_odin_root }),
    };
}

fn projectionMarker(allocator: std.mem.Allocator, resolution: Resolution) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "schema=1\nelectrobun={s}\ntarget={s}-{s}\nsource-manifest-sha256={s}\n",
        .{ resolution.version, targetOs(), targetArch(), resolution.source_manifest_sha256 },
    );
}

fn projectionMatches(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    expected_marker: []const u8,
    resolution: Resolution,
) !bool {
    const marker_path = try std.fs.path.join(allocator, &.{ root, ".complete" });
    const marker = std.Io.Dir.cwd().readFileAlloc(
        io,
        marker_path,
        allocator,
        .limited(1024),
    ) catch return false;
    if (!std.mem.eql(u8, marker, expected_marker)) return false;
    for ([_][]const u8{ "tsconfig.json", "projection.json", "package.json" }) |relative| {
        if (!pathExists(io, try std.fs.path.join(allocator, &.{ root, relative }))) return false;
    }
    if (!try projectionIdentityMatches(io, allocator, root, resolution)) return false;
    const paths = projectionPaths(allocator, root, resolution) catch return false;
    for ([_][]const u8{
        paths.zig_root,
        paths.zig_entrypoint,
        paths.rust_root,
        paths.rust_manifest,
        paths.go_root,
        paths.go_manifest,
        paths.odin_root,
        paths.odin_entrypoint,
        paths.odin_collection,
    }) |path| {
        if (!pathExists(io, path)) return false;
    }
    return true;
}

fn projectionIdentityMatches(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    resolution: Resolution,
) !bool {
    const path = try std.fs.path.join(allocator, &.{ root, "projection.json" });
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(128 * 1024)) catch return false;
    const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, source, .{
        .duplicate_field_behavior = .@"error",
    }) catch return false;
    const metadata = requiredObject(value, null) catch return false;
    if ((requiredInteger(metadata, "schemaVersion") catch return false) != 1) return false;
    if (!std.mem.eql(u8, requiredString(metadata, "kind") catch return false, projection_kind)) return false;

    const product = requiredObjectField(metadata, "product") catch return false;
    if (!std.mem.eql(u8, requiredString(product, "name") catch return false, "electrobun")) return false;
    if (!std.mem.eql(u8, requiredString(product, "version") catch return false, resolution.version)) return false;

    const target = requiredObjectField(metadata, "target") catch return false;
    if (!std.mem.eql(u8, requiredString(target, "os") catch return false, targetOs())) return false;
    if (!std.mem.eql(u8, requiredString(target, "arch") catch return false, targetArch())) return false;

    const abi = requiredObjectField(metadata, "abi") catch return false;
    validateAbi(requiredObjectField(abi, "core") catch return false, "electrobun-core", supported_core_abi_version) catch return false;
    validateAbi(requiredObjectField(abi, "sdk") catch return false, "electrobun-sdk", supported_sdk_abi_version) catch return false;
    if (!std.mem.eql(u8, requiredString(metadata, "sourceManifestSha256") catch return false, resolution.source_manifest_sha256)) return false;

    const layout = requiredObjectField(metadata, "layout") catch return false;
    if (!std.mem.eql(u8, requiredString(layout, "api") catch return false, projected_api_root)) return false;
    const sdks = requiredObjectField(layout, "sdks") catch return false;
    inline for (.{
        .{ "zig", projected_zig_root },
        .{ "rust", projected_rust_root },
        .{ "go", projected_go_root },
        .{ "odin", projected_odin_root },
    }) |field| {
        if (!std.mem.eql(u8, requiredString(sdks, field[0]) catch return false, field[1])) return false;
    }
    return true;
}

fn writeFacadePackage(
    io: std.Io,
    allocator: std.mem.Allocator,
    package_root: []const u8,
    resolution: Resolution,
) !void {
    var exports: std.json.ObjectMap = .empty;
    for (resolution.sdks.javascript.exports) |item| {
        try exports.put(
            allocator,
            item.specifier,
            .{ .string = try std.mem.concat(allocator, u8, &.{ "./", try projectedRelativePath(
                allocator,
                projected_api_root,
                resolution.sdks.javascript.relative_root,
                item.relative_path,
            ) }) },
        );
    }

    var package: std.json.ObjectMap = .empty;
    try package.put(allocator, "name", .{ .string = "electrobun" });
    try package.put(allocator, "version", .{ .string = resolution.version });
    try package.put(allocator, "private", .{ .bool = true });
    try package.put(allocator, "type", .{ .string = "module" });
    try package.put(
        allocator,
        "types",
        .{ .string = try std.mem.concat(allocator, u8, &.{ "./", try projectedRelativePath(
            allocator,
            projected_api_root,
            resolution.sdks.javascript.relative_root,
            relativeFromRoot(resolution.root, resolution.sdks.javascript.main),
        ) }) },
    );
    try package.put(allocator, "exports", .{ .object = exports });
    try writeJson(io, allocator, try std.fs.path.join(allocator, &.{ package_root, "package.json" }), .{ .object = package });
}

fn writeProjectionTsconfig(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    resolution: Resolution,
) !void {
    var paths: std.json.ObjectMap = .empty;
    for (resolution.sdks.javascript.exports) |item| {
        const module_name = if (std.mem.eql(u8, item.specifier, "."))
            "electrobun"
        else if (std.mem.startsWith(u8, item.specifier, "./"))
            try std.mem.concat(allocator, u8, &.{ "electrobun/", item.specifier[2..] })
        else
            return error.InvalidElectrobunDevkitManifest;
        var targets = std.json.Array.init(allocator);
        try targets.append(.{
            .string = try std.mem.concat(allocator, u8, &.{ "./", try projectedRelativePath(
                allocator,
                projected_api_root,
                resolution.sdks.javascript.relative_root,
                item.relative_path,
            ) }),
        });
        try paths.put(allocator, module_name, .{ .array = targets });
    }

    var compiler_options: std.json.ObjectMap = .empty;
    try compiler_options.put(allocator, "baseUrl", .{ .string = "." });
    try compiler_options.put(allocator, "paths", .{ .object = paths });
    var tsconfig: std.json.ObjectMap = .empty;
    try tsconfig.put(allocator, "compilerOptions", .{ .object = compiler_options });
    try writeJson(io, allocator, try std.fs.path.join(allocator, &.{ root, "tsconfig.json" }), .{ .object = tsconfig });
}

fn writeProjectionMetadata(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    resolution: Resolution,
) !void {
    var sdks: std.json.ObjectMap = .empty;
    try sdks.put(allocator, "zig", .{ .string = projected_zig_root });
    try sdks.put(allocator, "rust", .{ .string = projected_rust_root });
    try sdks.put(allocator, "go", .{ .string = projected_go_root });
    try sdks.put(allocator, "odin", .{ .string = projected_odin_root });
    var layout: std.json.ObjectMap = .empty;
    try layout.put(allocator, "api", .{ .string = projected_api_root });
    try layout.put(allocator, "sdks", .{ .object = sdks });

    var product: std.json.ObjectMap = .empty;
    try product.put(allocator, "name", .{ .string = "electrobun" });
    try product.put(allocator, "version", .{ .string = resolution.version });
    var target: std.json.ObjectMap = .empty;
    try target.put(allocator, "os", .{ .string = targetOs() });
    try target.put(allocator, "arch", .{ .string = targetArch() });
    var core_abi: std.json.ObjectMap = .empty;
    try core_abi.put(allocator, "name", .{ .string = "electrobun-core" });
    try core_abi.put(allocator, "version", .{ .integer = supported_core_abi_version });
    var sdk_abi: std.json.ObjectMap = .empty;
    try sdk_abi.put(allocator, "name", .{ .string = "electrobun-sdk" });
    try sdk_abi.put(allocator, "version", .{ .integer = supported_sdk_abi_version });
    var abi: std.json.ObjectMap = .empty;
    try abi.put(allocator, "core", .{ .object = core_abi });
    try abi.put(allocator, "sdk", .{ .object = sdk_abi });

    var metadata: std.json.ObjectMap = .empty;
    try metadata.put(allocator, "schemaVersion", .{ .integer = 1 });
    try metadata.put(allocator, "kind", .{ .string = projection_kind });
    try metadata.put(allocator, "product", .{ .object = product });
    try metadata.put(allocator, "target", .{ .object = target });
    try metadata.put(allocator, "abi", .{ .object = abi });
    try metadata.put(allocator, "sourceManifestSha256", .{ .string = resolution.source_manifest_sha256 });
    try metadata.put(allocator, "layout", .{ .object = layout });
    try writeJson(io, allocator, try std.fs.path.join(allocator, &.{ root, "projection.json" }), .{ .object = metadata });
}

fn relativeChildPath(parent: []const u8, child: []const u8) ![]const u8 {
    try validateRelativePosixPath(parent);
    try validateRelativePosixPath(child);
    if (std.mem.eql(u8, parent, child)) return "";
    if (child.len <= parent.len or !std.mem.startsWith(u8, child, parent) or child[parent.len] != '/') {
        return error.InvalidElectrobunDevkitLayout;
    }
    return child[parent.len + 1 ..];
}

fn projectedRelativePath(
    allocator: std.mem.Allocator,
    projected_root: []const u8,
    source_root: []const u8,
    source_path: []const u8,
) ![]const u8 {
    const child = try relativeChildPath(source_root, source_path);
    if (child.len == 0) return projected_root;
    return std.mem.concat(allocator, u8, &.{ projected_root, "/", child });
}

fn projectedAbsolutePath(
    allocator: std.mem.Allocator,
    projection_root: []const u8,
    projected_root: []const u8,
    source_root: []const u8,
    source_path: []const u8,
) ![]const u8 {
    const child = try relativeChildPath(source_root, source_path);
    if (child.len == 0) return std.fs.path.join(allocator, &.{ projection_root, projected_root });
    return std.fs.path.join(allocator, &.{ projection_root, projected_root, child });
}

fn writeJson(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    value: std.json.Value,
) !void {
    const source = try std.json.Stringify.valueAlloc(allocator, value, .{});
    const with_newline = try std.mem.concat(allocator, u8, &.{ source, "\n" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = with_newline });
}

fn relativeFromRoot(root: []const u8, absolute: []const u8) []const u8 {
    if (std.mem.startsWith(u8, absolute, root) and absolute.len > root.len and
        (absolute[root.len] == '/' or absolute[root.len] == '\\'))
    {
        return absolute[root.len + 1 ..];
    }
    return absolute;
}

fn copyTree(
    io: std.Io,
    allocator: std.mem.Allocator,
    source: []const u8,
    destination: []const u8,
) !void {
    try std.Io.Dir.cwd().createDirPath(io, destination);
    var source_dir = try std.Io.Dir.openDirAbsolute(io, source, .{ .iterate = true });
    defer source_dir.close(io);
    var walker = try source_dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        const target = try std.fs.path.join(allocator, &.{ destination, entry.path });
        switch (entry.kind) {
            .directory => try std.Io.Dir.cwd().createDirPath(io, target),
            .file, .sym_link => {
                if (std.fs.path.dirname(target)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
                try std.Io.Dir.copyFileAbsolute(
                    try std.fs.path.join(allocator, &.{ source, entry.path }),
                    target,
                    io,
                    .{},
                );
            },
            else => {},
        }
    }
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

const ExpectedPathKind = enum { file, directory };

pub fn validateExactVersion(version: []const u8) !void {
    if (version.len == 0 or version.len > 128) return error.InvalidElectrobunVersion;
    _ = std.SemanticVersion.parse(version) catch return error.InvalidElectrobunVersion;
}

fn validateAbi(object: std.json.ObjectMap, expected_name: []const u8, expected_version: i64) !void {
    if (!std.mem.eql(u8, try requiredString(object, "name"), expected_name)) {
        return error.UnsupportedElectrobunDevkitAbi;
    }
    if (try requiredInteger(object, "version") != expected_version) {
        return error.UnsupportedElectrobunDevkitAbi;
    }
}

fn optionalToolchainVersion(
    toolchains: std.json.ObjectMap,
    name: []const u8,
) !?[]const u8 {
    if (toolchains.get(name) == null) return null;
    return try toolchainVersion(toolchains, name);
}

fn toolchainVersion(toolchains: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const toolchain = try requiredObjectField(toolchains, name);
    const version = try requiredString(toolchain, "defaultVersion");
    if (std.mem.eql(u8, name, "odin")) {
        try validateExactOdinVersion(version);
    } else {
        _ = std.SemanticVersion.parse(version) catch return error.InvalidElectrobunToolchainVersion;
    }
    return version;
}

fn runtimeVersion(runtimes: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const runtime = try requiredObjectField(runtimes, name);
    const version = try requiredString(runtime, "version");
    if (version.len > 128) return error.InvalidElectrobunRuntimeVersion;
    _ = std.SemanticVersion.parse(version) catch return error.InvalidElectrobunRuntimeVersion;
    return version;
}

fn validateExactOdinVersion(version: []const u8) !void {
    if (std.SemanticVersion.parse(version)) |_| return else |_| {}
    if (version.len != 11 and version.len != 12) return error.InvalidElectrobunToolchainVersion;
    if (!std.mem.startsWith(u8, version, "dev-") or version[8] != '-') {
        return error.InvalidElectrobunToolchainVersion;
    }
    for (version[4..8]) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidElectrobunToolchainVersion;
    for (version[9..11]) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidElectrobunToolchainVersion;
    const month = std.fmt.parseInt(u8, version[9..11], 10) catch return error.InvalidElectrobunToolchainVersion;
    if (month < 1 or month > 12) return error.InvalidElectrobunToolchainVersion;
    if (version.len == 12 and !std.ascii.isLower(version[11])) return error.InvalidElectrobunToolchainVersion;
}

fn nativeSdkPaths(
    io: std.Io,
    allocator: std.mem.Allocator,
    core_root: []const u8,
    sdks: std.json.ObjectMap,
    name: []const u8,
) !NativeSdkPaths {
    const sdk = try requiredObjectField(sdks, name);
    const root = try requiredString(sdk, "root");
    const entrypoint = try requiredString(sdk, "entrypoint");
    return .{
        .root = try existingPath(io, allocator, core_root, root, .directory),
        .relative_root = root,
        .entrypoint = try existingPath(io, allocator, core_root, entrypoint, .file),
        .relative_entrypoint = entrypoint,
    };
}

fn rustSdkPaths(
    io: std.Io,
    allocator: std.mem.Allocator,
    core_root: []const u8,
    sdks: std.json.ObjectMap,
) !RustSdkPaths {
    const sdk = try requiredObjectField(sdks, "rust");
    const root = try requiredString(sdk, "root");
    const manifest = try requiredString(sdk, "manifest");
    return .{
        .root = try existingPath(io, allocator, core_root, root, .directory),
        .relative_root = root,
        .manifest = try existingPath(io, allocator, core_root, manifest, .file),
        .relative_manifest = manifest,
    };
}

fn goSdkPaths(
    io: std.Io,
    allocator: std.mem.Allocator,
    core_root: []const u8,
    sdks: std.json.ObjectMap,
) !GoSdkPaths {
    const sdk = try requiredObjectField(sdks, "go");
    const root = try requiredString(sdk, "root");
    const manifest = try requiredString(sdk, "manifest");
    const module = try requiredString(sdk, "module");
    if (!std.mem.eql(u8, module, "electrobun")) return error.InvalidElectrobunGoSdkModule;
    const manifest_path = try existingPath(io, allocator, core_root, manifest, .file);
    try validateGoModule(io, allocator, manifest_path, module);
    return .{
        .root = try existingPath(io, allocator, core_root, root, .directory),
        .relative_root = root,
        .manifest = manifest_path,
        .relative_manifest = manifest,
        .module = module,
    };
}

fn validateGoModule(
    io: std.Io,
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    expected_module: []const u8,
) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        io,
        manifest_path,
        allocator,
        .limited(1024 * 1024),
    );
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "module ")) continue;
        const module = std.mem.trim(u8, trimmed["module ".len..], " \t\r");
        if (!std.mem.eql(u8, module, expected_module)) return error.InvalidElectrobunGoSdkModule;
        return;
    }
    return error.InvalidElectrobunGoSdkModule;
}

fn odinSdkPaths(
    io: std.Io,
    allocator: std.mem.Allocator,
    core_root: []const u8,
    sdks: std.json.ObjectMap,
) !OdinSdkPaths {
    const sdk = try requiredObjectField(sdks, "odin");
    const root = try requiredString(sdk, "root");
    const entrypoint = try requiredString(sdk, "entrypoint");
    const collection = try requiredString(sdk, "collection");
    const collection_name = try requiredString(sdk, "collectionName");
    if (collection_name.len == 0 or collection_name.len > 128) {
        return error.InvalidElectrobunDevkitManifest;
    }
    for (collection_name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') {
            return error.InvalidElectrobunDevkitManifest;
        }
    }
    return .{
        .root = try existingPath(io, allocator, core_root, root, .directory),
        .relative_root = root,
        .entrypoint = try existingPath(io, allocator, core_root, entrypoint, .file),
        .relative_entrypoint = entrypoint,
        .collection = try existingPath(io, allocator, core_root, collection, .directory),
        .relative_collection = collection,
        .collection_name = collection_name,
    };
}

fn javascriptExports(
    io: std.Io,
    allocator: std.mem.Allocator,
    core_root: []const u8,
    javascript: std.json.ObjectMap,
) ![]const JavaScriptExport {
    const exports_value = javascript.get("exports") orelse
        return error.InvalidElectrobunDevkitManifest;
    if (exports_value != .object or exports_value.object.count() == 0) {
        return error.InvalidElectrobunDevkitManifest;
    }

    const exports = try allocator.alloc(JavaScriptExport, exports_value.object.count());
    var iterator = exports_value.object.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| : (index += 1) {
        if (entry.key_ptr.len == 0 or entry.value_ptr.* != .string) {
            return error.InvalidElectrobunDevkitManifest;
        }
        exports[index] = .{
            .specifier = entry.key_ptr.*,
            .relative_path = entry.value_ptr.*.string,
            .absolute_path = try existingPath(io, allocator, core_root, entry.value_ptr.*.string, .file),
        };
    }
    return exports;
}

fn requiredExistingPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    core_root: []const u8,
    object: std.json.ObjectMap,
    field: []const u8,
    kind: ExpectedPathKind,
) ![]const u8 {
    return existingPath(io, allocator, core_root, try requiredString(object, field), kind);
}

fn optionalExistingPaths(
    io: std.Io,
    allocator: std.mem.Allocator,
    core_root: []const u8,
    object: std.json.ObjectMap,
    field: []const u8,
    kind: ExpectedPathKind,
) ![]const []const u8 {
    const value = object.get(field) orelse return &.{};
    if (value != .array) return error.InvalidElectrobunDevkitManifest;
    const paths = try allocator.alloc([]const u8, value.array.items.len);
    for (value.array.items, 0..) |item, index| {
        if (item != .string or item.string.len == 0) {
            return error.InvalidElectrobunDevkitManifest;
        }
        paths[index] = try existingPath(io, allocator, core_root, item.string, kind);
    }
    return paths;
}

fn existingPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    core_root: []const u8,
    relative_path: []const u8,
    kind: ExpectedPathKind,
) ![]const u8 {
    try validateRelativePosixPath(relative_path);
    const absolute_path = try std.fs.path.join(allocator, &.{ core_root, relative_path });
    const stat = std.Io.Dir.cwd().statFile(io, absolute_path, .{}) catch
        return error.ElectrobunDevkitLayoutMissing;
    switch (kind) {
        .file => if (stat.kind != .file) return error.ElectrobunDevkitLayoutInvalid,
        .directory => if (stat.kind != .directory) return error.ElectrobunDevkitLayoutInvalid,
    }
    return absolute_path;
}

fn validateRelativePosixPath(path: []const u8) !void {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null or
        std.mem.indexOfScalar(u8, path, ':') != null)
    {
        return error.InvalidElectrobunDevkitPath;
    }
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, ".."))
        {
            return error.InvalidElectrobunDevkitPath;
        }
    }
}

fn requiredObject(value: std.json.Value, field: ?[]const u8) !std.json.ObjectMap {
    const selected = if (field) |name| blk: {
        if (value != .object) return error.InvalidElectrobunDevkitManifest;
        break :blk value.object.get(name) orelse return error.InvalidElectrobunDevkitManifest;
    } else value;
    if (selected != .object) return error.InvalidElectrobunDevkitManifest;
    return selected.object;
}

fn requiredObjectField(object: std.json.ObjectMap, field: []const u8) !std.json.ObjectMap {
    const value = object.get(field) orelse return error.InvalidElectrobunDevkitManifest;
    if (value != .object) return error.InvalidElectrobunDevkitManifest;
    return value.object;
}

fn requiredString(object: std.json.ObjectMap, field: []const u8) ![]const u8 {
    const value = object.get(field) orelse return error.InvalidElectrobunDevkitManifest;
    if (value != .string or value.string.len == 0) return error.InvalidElectrobunDevkitManifest;
    return value.string;
}

fn requiredInteger(object: std.json.ObjectMap, field: []const u8) !i64 {
    const value = object.get(field) orelse return error.InvalidElectrobunDevkitManifest;
    if (value != .integer) return error.InvalidElectrobunDevkitManifest;
    return value.integer;
}

fn targetOs() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "win",
        else => "unsupported",
    };
}

fn targetArch() []const u8 {
    if (builtin.os.tag == .windows) return "x64";
    return switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        else => "x64",
    };
}

fn parseTestJson(allocator: std.mem.Allocator, source: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, source, .{
        .duplicate_field_behavior = .@"error",
    });
}

test "v2 Electrobun versions are exact Hutch config pins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try parseTestJson(
        arena.allocator(),
        "{\"electrobun\":{\"version\":\"2.0.0-beta.1+build.4\"}}",
    );
    try std.testing.expectEqualStrings(
        "2.0.0-beta.1+build.4",
        try configuredVersion(root),
    );
}

test "v2 Hutch config requires an Electrobun version pin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try parseTestJson(
        arena.allocator(),
        "{\"app\":{\"version\":\"1.0.0\"}}",
    );
    try std.testing.expectError(error.ElectrobunVersionMissing, configuredVersion(root));
}

test "v2 Electrobun version rejects channels ranges and paths" {
    for ([_][]const u8{
        "latest",
        "production",
        "^2.0.0",
        "2.x",
        "v2.0.0",
        "../../2.0.0",
        "",
    }) |version| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const source = try std.fmt.allocPrint(
            arena.allocator(),
            "{{\"electrobun\":{{\"version\":\"{s}\"}}}}",
            .{version},
        );
        const root = try parseTestJson(arena.allocator(), source);
        try std.testing.expectError(error.InvalidElectrobunVersion, configuredVersion(root));
    }
}

test "present v2 Hutch product config requires a string version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const missing = try parseTestJson(arena.allocator(), "{\"electrobun\":{}}");
    try std.testing.expectError(error.ElectrobunVersionMissing, configuredVersion(missing));

    const wrong_type = try parseTestJson(arena.allocator(), "{\"electrobun\":{\"version\":2}}");
    try std.testing.expectError(error.InvalidElectrobunVersionType, configuredVersion(wrong_type));

    const wrong_container = try parseTestJson(arena.allocator(), "{\"electrobun\":\"2.0.0\"}");
    try std.testing.expectError(error.InvalidHutchConfig, configuredVersion(wrong_container));
}

test "native compiler defaults use exact versions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const toolchains = try parseTestJson(
        arena.allocator(),
        "{\"zig\":{\"defaultVersion\":\"0.16\"},\"go\":{\"defaultVersion\":\"stable\"},\"odin\":{\"defaultVersion\":\"dev-2026-07a\"}}",
    );
    try std.testing.expectError(error.InvalidElectrobunToolchainVersion, toolchainVersion(toolchains.object, "zig"));
    try std.testing.expectError(error.InvalidElectrobunToolchainVersion, toolchainVersion(toolchains.object, "go"));
    try std.testing.expectEqualStrings("dev-2026-07a", try toolchainVersion(toolchains.object, "odin"));
    try std.testing.expectError(error.InvalidElectrobunToolchainVersion, validateExactOdinVersion("latest"));
}

const test_manifest_template =
    \\{
    \\  "schemaVersion": 1,
    \\  "product": { "name": "electrobun", "version": "__VERSION__" },
    \\  "target": { "os": "__OS__", "arch": "__ARCH__" },
    \\  "abi": {
    \\    "core": { "name": "electrobun-core", "version": 1 },
    \\    "sdk": { "name": "electrobun-sdk", "version": 1 }
    \\  },
    \\  "toolchains": {
    \\    "zig": { "defaultVersion": "0.16.0" },
    \\    "rust": { "defaultVersion": "1.88.0" },
    \\    "go": { "defaultVersion": "1.26.4" },
    \\    "odin": { "defaultVersion": "dev-2026-07a" },
    \\    "bun": { "defaultVersion": "1.4.0" },
    \\    "cottontail": { "defaultVersion": "0.5.0" }
    \\  },
    \\  "layout": {
    \\    "runtime": {
    \\      "main": "main.js",
    \\      "preloadFull": "preload-full.js",
    \\      "preloadSandboxed": "preload-sandboxed.js",
    \\      "launcher": "bin/launcher",
    \\      "extractor": "bin/extractor",
    \\      "coreLibrary": "lib/core",
    \\      "nativeWrapper": "lib/native",
    \\      "nativeWrapperCef": "lib/native-cef",
    \\      "asarLibrary": "lib/asar",
    \\      "wgpuLibrary": "lib/wgpu",
    \\      "processHelper": "bin/helper",
    \\      "bsdiff": "bin/bsdiff",
    \\      "bspatch": "bin/bspatch",
    \\      "zigAsar": "bin/zig-asar",
    \\      "zigZstd": "bin/zig-zstd"
    \\    },
    \\    "sdks": {
    \\      "javascript": {
    \\        "root": "api",
    \\        "main": "api/sdks/main/index.ts",
    \\        "browser": "api/browser/index.ts",
    \\        "config": "api/config/ElectrobunConfig.ts",
    \\        "preload": "api/preload",
    \\        "exports": {
    \\          ".": "api/sdks/main/index.ts",
    \\          "./main": "api/sdks/main/index.ts",
    \\          "./view": "api/browser/index.ts"
    \\        }
    \\      },
    \\      "zig": { "root": "zig-sdk", "entrypoint": "zig-sdk/electrobun.zig" },
    \\      "rust": { "root": "rust-sdk", "manifest": "rust-sdk/Cargo.toml" },
    \\      "go": { "root": "go-sdk", "manifest": "go-sdk/go.mod", "module": "electrobun" },
    \\      "odin": {
    \\        "root": "odin-sdk/electrobun",
    \\        "entrypoint": "odin-sdk/electrobun/electrobun.odin",
    \\        "collection": "odin-sdk",
    \\        "collectionName": "electrobun_sdk"
    \\      }
    \\    }
    \\  }
    \\}
;

const test_fixture_directories = [_][]const u8{
    "api",
    "zig-sdk",
    "rust-sdk",
    "go-sdk",
    "odin-sdk/electrobun",
    "odin-sdk",
};

const test_fixture_files = [_][]const u8{
    "main.js",
    "preload-full.js",
    "preload-sandboxed.js",
    "bin/bun",
    "bin/launcher",
    "bin/extractor",
    "lib/core",
    "lib/native",
    "lib/native-cef",
    "lib/asar",
    "lib/wgpu",
    "bin/helper",
    "bin/bsdiff",
    "bin/bspatch",
    "bin/zig-asar",
    "bin/zig-zstd",
    "api/sdks/main/index.ts",
    "api/browser/index.ts",
    "api/config/ElectrobunConfig.ts",
    "api/preload/index.ts",
    "zig-sdk/electrobun.zig",
    "rust-sdk/Cargo.toml",
    "rust-sdk/electrobun.rs",
    "go-sdk/go.mod",
    "go-sdk/electrobun.go",
    "odin-sdk/electrobun/electrobun.odin",
};

fn testManifestSource(allocator: std.mem.Allocator, version: []const u8) ![]const u8 {
    const with_version = try std.mem.replaceOwned(u8, allocator, test_manifest_template, "__VERSION__", version);
    const with_os = try std.mem.replaceOwned(u8, allocator, with_version, "__OS__", targetOs());
    return std.mem.replaceOwned(u8, allocator, with_os, "__ARCH__", targetArch());
}

fn legacyTestManifestSource(allocator: std.mem.Allocator, version: []const u8) ![]const u8 {
    const current = try testManifestSource(allocator, version);
    const legacy_toolchains = try std.mem.replaceOwned(
        u8,
        allocator,
        current,
        \\    "odin": { "defaultVersion": "dev-2026-07a" },
        \\    "bun": { "defaultVersion": "1.4.0" },
        \\    "cottontail": { "defaultVersion": "0.5.0" }
    ,
        \\    "odin": { "defaultVersion": "dev-2026-07a" }
        ,
    );
    const with_runtime_version = try std.mem.replaceOwned(
        u8,
        allocator,
        legacy_toolchains,
        \\  "layout": {
    ,
        \\  "runtimes": {
        \\    "bun": { "version": "1.3.13" }
        \\  },
        \\  "layout": {
        ,
    );
    return std.mem.replaceOwned(
        u8,
        allocator,
        with_runtime_version,
        \\      "preloadSandboxed": "preload-sandboxed.js",
    ,
        \\      "preloadSandboxed": "preload-sandboxed.js",
        \\      "bun": "bin/bun",
        ,
    );
}

fn createTestDevkit(io: std.Io, allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, version: []const u8) ![]const u8 {
    for (test_fixture_directories) |path| try tmp.dir.createDirPath(io, path);
    for (test_fixture_files) |path| {
        if (std.fs.path.dirname(path)) |parent| try tmp.dir.createDirPath(io, parent);
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = path });
    }
    try tmp.dir.writeFile(io, .{
        .sub_path = "rust-sdk/Cargo.toml",
        .data = "[package]\nname = \"electrobun\"\nversion = \"2.0.0\"\nedition = \"2021\"\n[lib]\npath = \"electrobun.rs\"\n",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "go-sdk/go.mod", .data = "module electrobun\n\ngo 1.26\n" });
    try tmp.dir.writeFile(io, .{
        .sub_path = manifest_file_name,
        .data = try testManifestSource(allocator, version),
    });
    const relative_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    return std.Io.Dir.cwd().realPathFileAlloc(io, relative_root, allocator);
}

test "package-free v2 devkit resolves runtime SDKs and toolchain defaults" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try createTestDevkit(io, arena.allocator(), &tmp, "2.0.0-beta.1");
    const resolution = try load(io, arena.allocator(), root, "2.0.0-beta.1");

    try std.testing.expectEqualStrings("2.0.0-beta.1", resolution.version);
    try std.testing.expectEqualStrings("0.16.0", resolution.toolchains.zig);
    try std.testing.expectEqualStrings("1.4.0", resolution.toolchains.bun);
    try std.testing.expectEqualStrings("0.5.0", resolution.toolchains.cottontail.?);
    try std.testing.expect(resolution.runtime.bun == null);
    try std.testing.expect(std.mem.endsWith(u8, resolution.runtime.preload_full, "preload-full.js"));
    try std.testing.expect(std.mem.endsWith(u8, resolution.sdks.javascript.main, "api/sdks/main/index.ts"));
    try std.testing.expect(std.mem.endsWith(u8, resolution.sdks.go.root, "go-sdk"));
    try std.testing.expect(std.mem.endsWith(u8, resolution.sdks.odin.collection, "odin-sdk"));
}

test "Electrobun 2.0.1-beta.18 schema-1 devkit preserves its embedded Bun runtime" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const version = "2.0.1-beta.18";
    const root = try createTestDevkit(io, allocator, &tmp, version);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ root, manifest_file_name }),
        .data = try legacyTestManifestSource(allocator, version),
    });

    const resolution = try load(io, allocator, root, version);
    try std.testing.expectEqualStrings(version, resolution.version);
    try std.testing.expectEqualStrings("1.3.13", resolution.toolchains.bun);
    try std.testing.expect(resolution.toolchains.cottontail == null);
    try std.testing.expect(std.mem.endsWith(u8, resolution.runtime.bun.?, "bin/bun"));

    const invalid_runtime_version = try std.mem.replaceOwned(
        u8,
        allocator,
        try legacyTestManifestSource(allocator, version),
        "\"version\": \"1.3.13\"",
        "\"version\": \"latest\"",
    );
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ root, manifest_file_name }),
        .data = invalid_runtime_version,
    });
    try std.testing.expectError(
        error.InvalidElectrobunRuntimeVersion,
        load(io, allocator, root, version),
    );
}

test "v2 devkit requires an exact bun toolchain default" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try createTestDevkit(io, arena.allocator(), &tmp, "2.0.0");
    const manifest_path = try std.fs.path.join(arena.allocator(), &.{ root, manifest_file_name });
    const valid_source = try std.Io.Dir.cwd().readFileAlloc(
        io,
        manifest_path,
        arena.allocator(),
        .limited(max_manifest_bytes),
    );

    for ([_][]const u8{ "latest", "^1.4.0" }) |invalid_version| {
        const replacement = try std.fmt.allocPrint(
            arena.allocator(),
            "\"bun\": {{ \"defaultVersion\": \"{s}\" }}",
            .{invalid_version},
        );
        const malformed = try std.mem.replaceOwned(
            u8,
            arena.allocator(),
            valid_source,
            "\"bun\": { \"defaultVersion\": \"1.4.0\" }",
            replacement,
        );
        try std.testing.expect(std.mem.indexOf(u8, malformed, invalid_version) != null);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest_path, .data = malformed });
        try std.testing.expectError(
            error.InvalidElectrobunToolchainVersion,
            load(io, arena.allocator(), root, "2.0.0"),
        );
    }

    const missing = try std.mem.replaceOwned(
        u8,
        arena.allocator(),
        valid_source,
        "    \"bun\": { \"defaultVersion\": \"1.4.0\" },\n",
        "",
    );
    try std.testing.expect(missing.len < valid_source.len);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest_path, .data = missing });
    try std.testing.expectError(
        error.InvalidElectrobunDevkitManifest,
        load(io, arena.allocator(), root, "2.0.0"),
    );
}

test "v2 devkit projects an atomic package facade and TypeScript paths" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try createTestDevkit(io, arena.allocator(), &tmp, "2.0.0");
    const project_root = try std.fs.path.join(arena.allocator(), &.{ root, "project" });
    try std.Io.Dir.cwd().createDirPath(io, project_root);
    const resolution = try load(io, arena.allocator(), root, "2.0.0");
    const projection = try project(io, arena.allocator(), project_root, resolution, .{});

    try std.testing.expect(pathExists(io, projection.tsconfig));
    try std.testing.expect(pathExists(io, projection.zig_entrypoint));
    try std.testing.expect(pathExists(io, projection.go_manifest));
    try std.testing.expectEqualStrings("electrobun", projection.go_module);
    try std.testing.expect(pathExists(io, projection.odin_collection));
    try std.testing.expect(!pathExists(io, try std.fs.path.join(arena.allocator(), &.{ project_root, "node_modules" })));

    const tsconfig = try std.Io.Dir.cwd().readFileAlloc(
        io,
        projection.tsconfig,
        arena.allocator(),
        .limited(128 * 1024),
    );
    try std.testing.expect(std.mem.indexOf(u8, tsconfig, "electrobun/main") != null);
    try std.testing.expect(std.mem.indexOf(u8, tsconfig, "./api/sdks/main/index.ts") != null);

    const package_json = try std.Io.Dir.cwd().readFileAlloc(
        io,
        try std.fs.path.join(arena.allocator(), &.{ projection.package_root, "package.json" }),
        arena.allocator(),
        .limited(128 * 1024),
    );
    try std.testing.expect(std.mem.indexOf(u8, package_json, "\"version\":\"2.0.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, package_json, "./api/browser/index.ts") != null);

    const projection_json = try std.Io.Dir.cwd().readFileAlloc(
        io,
        try std.fs.path.join(arena.allocator(), &.{ projection.root, "projection.json" }),
        arena.allocator(),
        .limited(128 * 1024),
    );
    try std.testing.expect(std.mem.indexOf(u8, projection_json, "\"kind\":\"electrobun-devkit-projection\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, projection_json, "\"sourceManifestSha256\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, projection_json, "\"api\":\"api\"") != null);

    const stale = try std.fs.path.join(arena.allocator(), &.{ projection.root, "stale" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = stale, .data = "stale" });
    const manifest_path = try std.fs.path.join(arena.allocator(), &.{ root, manifest_file_name });
    const manifest_source = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, arena.allocator(), .limited(max_manifest_bytes));
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = manifest_path,
        .data = try std.mem.concat(arena.allocator(), u8, &.{ manifest_source, "\n" }),
    });
    const changed_resolution = try load(io, arena.allocator(), root, "2.0.0");
    try std.testing.expect(!std.mem.eql(u8, resolution.source_manifest_sha256, changed_resolution.source_manifest_sha256));
    _ = try project(io, arena.allocator(), project_root, changed_resolution, .{});
    try std.testing.expect(!pathExists(io, stale));
}

test "v2 devkit rejects a different product version" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try createTestDevkit(io, arena.allocator(), &tmp, "2.0.1");
    try std.testing.expectError(
        error.ElectrobunDevkitVersionMismatch,
        load(io, arena.allocator(), root, "2.0.0"),
    );
}

test "v2 devkit rejects missing SDK layout entries" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try createTestDevkit(io, arena.allocator(), &tmp, "2.0.0");
    try tmp.dir.deleteFile(io, "go-sdk/go.mod");
    try std.testing.expectError(
        error.ElectrobunDevkitLayoutMissing,
        load(io, arena.allocator(), root, "2.0.0"),
    );
}

test "v2 devkit paths cannot escape the cached core root" {
    try std.testing.expectError(error.InvalidElectrobunDevkitPath, validateRelativePosixPath("../sdk"));
    try std.testing.expectError(error.InvalidElectrobunDevkitPath, validateRelativePosixPath("api/../sdk"));
    try std.testing.expectError(error.InvalidElectrobunDevkitPath, validateRelativePosixPath("/absolute"));
    try std.testing.expectError(error.InvalidElectrobunDevkitPath, validateRelativePosixPath("C:/absolute"));
    try std.testing.expectError(error.InvalidElectrobunDevkitPath, validateRelativePosixPath("api\\sdk"));
}
