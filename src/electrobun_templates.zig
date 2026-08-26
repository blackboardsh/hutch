const std = @import("std");
const archive_util = @import("archive.zig");
const release_store = @import("release_store.zig");

const default_base_url = "https://electrobun-artifacts.blackboard.sh/electrobun/templates";
const manifest_schema = 1;
const max_manifest_bytes = 1024 * 1024;
const max_archive_bytes = 16 * 1024 * 1024;

pub const Channel = enum {
    // Electrobun has exactly two channels. `name()` is used for the R2 path
    // (electrobun/templates/channels/<name>.json).
    stable,
    beta,

    pub fn name(self: Channel) []const u8 {
        return @tagName(self);
    }
};

pub const Archive = struct {
    url: []const u8,
    sha256: []const u8,
    size: usize,
};

pub const Template = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    main_process: []const u8,
    archive: Archive,
};

pub const Catalog = struct {
    channel: Channel,
    version: []const u8,
    revision: []const u8,
    hutch_version: []const u8,
    cottontail_version: []const u8,
    templates: []const Template,

    pub fn find(self: Catalog, id: []const u8) ?Template {
        for (self.templates) |template| {
            if (std.mem.eql(u8, template.id, id)) return template;
        }
        return null;
    }
};

/// Validate the tool contract published with a template catalog against the
/// Hutch release doing the initialization. `tools.hutch` is a minimum: a
/// newer Hutch can consume a catalog produced by an older release. Cottontail
/// is deliberately exact because the catalog is generated from Electrobun's
/// tested `// @hutch ... cottontail=<version>` pin and the contract does not
/// promise compatibility between different Cottontail releases.
pub fn validateToolCompatibility(
    catalog: Catalog,
    current_hutch_version: []const u8,
    paired_cottontail_version: []const u8,
) !void {
    const required_hutch = try parseExactToolVersion(
        catalog.hutch_version,
        error.InvalidTemplateHutchVersion,
    );
    const current_hutch = std.SemanticVersion.parse(current_hutch_version) catch
        return error.InvalidCurrentHutchVersion;
    if (current_hutch.order(required_hutch) == .lt) {
        return error.TemplateRequiresNewerHutch;
    }

    // Build metadata is part of an exact artifact selector even though SemVer
    // intentionally ignores it for ordering, so use byte equality here.
    if (!std.mem.eql(u8, paired_cottontail_version, catalog.cottontail_version)) {
        return error.IncompatibleTemplateCottontail;
    }
}

pub fn parseChannel(value: []const u8) !Channel {
    // Accept the new stable/beta names plus the legacy production/canary aliases
    // so older callers and env values keep working.
    if (std.mem.eql(u8, value, "stable") or std.mem.eql(u8, value, "production")) return .stable;
    if (std.mem.eql(u8, value, "beta") or std.mem.eql(u8, value, "canary")) return .beta;
    return error.InvalidTemplateChannel;
}

test "template channel parsing accepts stable/beta and legacy aliases" {
    try std.testing.expectEqual(Channel.stable, try parseChannel("stable"));
    try std.testing.expectEqual(Channel.stable, try parseChannel("production"));
    try std.testing.expectEqual(Channel.beta, try parseChannel("beta"));
    try std.testing.expectEqual(Channel.beta, try parseChannel("canary"));
}

pub fn activeChannel(environment: *const std.process.Environ.Map) !Channel {
    return parseChannel(environment.get("HUTCH_ACTIVE_CHANNEL") orelse "stable");
}

pub fn load(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    channel: Channel,
) !Catalog {
    const base_url = try baseUrl(init, allocator);
    const url = try std.fmt.allocPrint(
        allocator,
        "{s}/channels/{s}.json",
        .{ base_url, channel.name() },
    );
    const downloaded = try release_store.fetchBytes(init, allocator, url, max_manifest_bytes);
    return parseCatalog(allocator, downloaded, base_url, channel);
}

pub fn install(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    template: Template,
    destination: []const u8,
    hutch_version: []const u8,
    cottontail_version: []const u8,
) !void {
    if (pathExists(init.io, destination)) return error.ProjectAlreadyExists;
    const parent = std.fs.path.dirname(destination) orelse return error.InvalidProjectPath;
    try std.Io.Dir.cwd().createDirPath(init.io, parent);

    const destination_basename = std.fs.path.basename(destination);
    if (destination_basename.len == 0) return error.InvalidProjectPath;
    const lock_name = try std.mem.concat(allocator, u8, &.{
        ".",
        destination_basename,
        ".hutch-template.lock",
    });
    const lock_path = try std.fs.path.join(allocator, &.{ parent, lock_name });
    const destination_lock = try release_store.acquirePersistentFileLock(
        init.io,
        lock_path,
    );
    defer destination_lock.close(init.io);
    if (pathExists(init.io, destination)) return error.ProjectAlreadyExists;

    const archive = try loadArchive(init, allocator, template);
    const temporary = try createTemplateTemporaryDirectory(
        init,
        allocator,
        parent,
        destination_basename,
    );
    errdefer std.Io.Dir.cwd().deleteTree(init.io, temporary) catch {};

    {
        var output = try std.Io.Dir.cwd().openDir(init.io, temporary, .{});
        defer output.close(init.io);
        try archive_util.extractTarGzip(init.io, allocator, output, archive, .{
            .strip_components = 1,
        });
    }
    const electrobun_config = try std.fs.path.join(allocator, &.{ temporary, "electrobun.config.ts" });
    if (!pathExists(init.io, electrobun_config)) return error.InvalidTemplateArchive;
    try stampInstalledToolchain(
        init,
        allocator,
        temporary,
        hutch_version,
        cottontail_version,
    );
    try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), destination, init.io);
}

fn stampInstalledToolchain(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    template_root: []const u8,
    hutch_version: []const u8,
    cottontail_version: []const u8,
) !void {
    const config_path = try std.fs.path.join(allocator, &.{ template_root, "hutch.config.ts" });
    const source = std.Io.Dir.cwd().readFileAlloc(
        init.io,
        config_path,
        allocator,
        .limited(1024 * 1024),
    ) catch return error.InvalidTemplateArchive;
    if (std.mem.startsWith(u8, source, "// @hutch")) return error.InvalidTemplateArchive;
    const stamped = try std.fmt.allocPrint(
        allocator,
        "// @hutch cli={s} cottontail={s}\n{s}",
        .{ hutch_version, cottontail_version, source },
    );
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = config_path,
        .data = stamped,
    });
}

fn createTemplateTemporaryDirectory(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    parent: []const u8,
    destination_basename: []const u8,
) ![]const u8 {
    var attempt: usize = 0;
    while (attempt < 16) : (attempt += 1) {
        var random: [12]u8 = undefined;
        init.io.random(&random);
        const suffix = std.fmt.bytesToHex(random, .lower);
        const name = try std.fmt.allocPrint(
            allocator,
            ".{s}.hutch-template-tmp-{s}",
            .{ destination_basename, &suffix },
        );
        const path = try std.fs.path.join(allocator, &.{ parent, name });
        std.Io.Dir.cwd().createDir(init.io, path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return path;
    }
    return error.TemplateTemporaryDirectoryCollision;
}

fn loadArchive(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    template: Template,
) ![]const u8 {
    const downloaded = try release_store.fetchBytes(
        init,
        allocator,
        template.archive.url,
        max_archive_bytes,
    );
    if (!archiveMatches(downloaded, template.archive)) {
        return error.TemplateArchiveIntegrityMismatch;
    }
    return downloaded;
}

fn archiveMatches(bytes: []const u8, archive: Archive) bool {
    return bytes.len == archive.size and release_store.sha256Matches(bytes, archive.sha256);
}

fn parseCatalog(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    base_url: []const u8,
    expected_channel: Channel,
) !Catalog {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
    });
    if (try jsonPositiveUsize(root, "schema") != manifest_schema) {
        return error.UnsupportedTemplateCatalogSchema;
    }
    if (!std.mem.eql(u8, try jsonString(root, "kind"), "electrobun-template-channel")) {
        return error.InvalidTemplateCatalog;
    }
    const channel = try parseChannel(try jsonString(root, "channel"));
    if (channel != expected_channel) return error.TemplateCatalogChannelMismatch;
    const version = try jsonString(root, "version");
    if (version.len == 0) return error.InvalidTemplateCatalog;
    const revision = try jsonString(root, "revision");
    try validateRevision(revision);
    const tools = try jsonObject(root, "tools");
    const hutch_version = try jsonString(tools, "hutch");
    const cottontail_version = try jsonString(tools, "cottontail");
    _ = try parseExactToolVersion(hutch_version, error.InvalidTemplateHutchVersion);
    _ = try parseExactToolVersion(cottontail_version, error.InvalidTemplateCottontailVersion);

    const template_values = try jsonArray(root, "templates");
    if (template_values.len == 0 or template_values.len > 256) {
        return error.InvalidTemplateCatalog;
    }
    var templates: std.ArrayList(Template) = .empty;
    for (template_values) |value| {
        const id = try jsonString(value, "id");
        try validateTemplateId(id);
        for (templates.items) |existing| {
            if (std.mem.eql(u8, existing.id, id)) return error.DuplicateTemplateId;
        }
        const archive_value = try jsonObject(value, "archive");
        const checksum = try jsonString(archive_value, "sha256");
        try validateSha256(checksum);
        const size = try jsonPositiveUsize(archive_value, "size");
        if (size > max_archive_bytes) return error.TemplateArchiveTooLarge;
        const url = try jsonString(archive_value, "url");
        const expected_url = try std.fmt.allocPrint(
            allocator,
            "{s}/artifacts/{s}.tar.gz",
            .{ base_url, checksum },
        );
        if (!std.mem.eql(u8, url, expected_url)) return error.UntrustedTemplateArchiveUrl;

        try templates.append(allocator, .{
            .id = id,
            .name = try jsonString(value, "name"),
            .description = try jsonString(value, "description"),
            .main_process = try jsonString(value, "mainProcess"),
            .archive = .{ .url = url, .sha256 = checksum, .size = size },
        });
    }

    return .{
        .channel = channel,
        .version = version,
        .revision = revision,
        .hutch_version = hutch_version,
        .cottontail_version = cottontail_version,
        .templates = try templates.toOwnedSlice(allocator),
    };
}

fn parseExactToolVersion(
    value: []const u8,
    comptime invalid_error: anyerror,
) !std.SemanticVersion {
    return std.SemanticVersion.parse(value) catch return invalid_error;
}

fn baseUrl(init: std.process.Init, allocator: std.mem.Allocator) ![]const u8 {
    const configured = init.environ_map.get("ELECTROBUN_TEMPLATES_BASE_URL") orelse default_base_url;
    const trimmed = std.mem.trimEnd(u8, configured, "/");
    if (!std.mem.startsWith(u8, trimmed, "https://") and
        !std.mem.startsWith(u8, trimmed, "http://127.0.0.1") and
        !std.mem.startsWith(u8, trimmed, "http://localhost"))
    {
        return error.InvalidTemplateBaseUrl;
    }
    return allocator.dupe(u8, trimmed);
}

fn validateTemplateId(value: []const u8) !void {
    if (value.len == 0 or value.len > 80) return error.InvalidTemplateId;
    for (value) |byte| {
        if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '-') {
            return error.InvalidTemplateId;
        }
    }
}

fn validateRevision(value: []const u8) !void {
    if (value.len != 40 and value.len != 64) return error.InvalidTemplateRevision;
    for (value) |byte| {
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) {
            return error.InvalidTemplateRevision;
        }
    }
}

fn validateSha256(value: []const u8) !void {
    if (value.len != 64) return error.InvalidTemplateChecksum;
    for (value) |byte| {
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) {
            return error.InvalidTemplateChecksum;
        }
    }
}

fn jsonObject(value: std.json.Value, name: []const u8) !std.json.Value {
    if (value != .object) return error.InvalidTemplateCatalog;
    const field = value.object.get(name) orelse return error.InvalidTemplateCatalog;
    if (field != .object) return error.InvalidTemplateCatalog;
    return field;
}

fn jsonArray(value: std.json.Value, name: []const u8) ![]const std.json.Value {
    if (value != .object) return error.InvalidTemplateCatalog;
    const field = value.object.get(name) orelse return error.InvalidTemplateCatalog;
    if (field != .array) return error.InvalidTemplateCatalog;
    return field.array.items;
}

fn jsonString(value: std.json.Value, name: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidTemplateCatalog;
    const field = value.object.get(name) orelse return error.InvalidTemplateCatalog;
    if (field != .string) return error.InvalidTemplateCatalog;
    return field.string;
}

fn jsonPositiveUsize(value: std.json.Value, name: []const u8) !usize {
    if (value != .object) return error.InvalidTemplateCatalog;
    const field = value.object.get(name) orelse return error.InvalidTemplateCatalog;
    if (field != .integer or field.integer <= 0) return error.InvalidTemplateCatalog;
    return std.math.cast(usize, field.integer) orelse error.InvalidTemplateCatalog;
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

test "template catalogs expose the selected channel and immutable archive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const bytes =
        \\{
        \\  "schema": 1,
        \\  "kind": "electrobun-template-channel",
        \\  "channel": "beta",
        \\  "version": "2.0.0-beta.1",
        \\  "revision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "tools": { "hutch": "0.5.0-canary.1+release.1", "cottontail": "0.2.3-beta.2+build.4" },
        \\  "templates": [{
        \\    "id": "hello-world",
        \\    "name": "Hello World",
        \\    "description": "A starter",
        \\    "mainProcess": "cottontail",
        \\    "archive": {
        \\      "url": "https://example.test/electrobun/templates/artifacts/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.tar.gz",
        \\      "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        \\      "size": 123
        \\    }
        \\  }]
        \\}
    ;
    const catalog = try parseCatalog(
        allocator,
        bytes,
        "https://example.test/electrobun/templates",
        .beta,
    );
    try std.testing.expectEqual(Channel.beta, catalog.channel);
    try std.testing.expectEqualStrings("2.0.0-beta.1", catalog.version);
    try std.testing.expectEqualStrings("hello-world", catalog.templates[0].id);
    try std.testing.expectEqualStrings("0.5.0-canary.1+release.1", catalog.hutch_version);
    try std.testing.expectEqualStrings("0.2.3-beta.2+build.4", catalog.cottontail_version);
    try std.testing.expect(catalog.find("missing") == null);
}

test "template catalogs require exact semantic tool versions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const catalog_format =
        \\{{
        \\  "schema": 1,
        \\  "kind": "electrobun-template-channel",
        \\  "channel": "stable",
        \\  "version": "2.0.0",
        \\  "revision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "tools": {{ "hutch": "{s}", "cottontail": "{s}" }},
        \\  "templates": [{{
        \\    "id": "hello-world",
        \\    "name": "Hello World",
        \\    "description": "A starter",
        \\    "mainProcess": "cottontail",
        \\    "archive": {{
        \\      "url": "https://example.test/electrobun/templates/artifacts/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.tar.gz",
        \\      "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        \\      "size": 123
        \\    }}
        \\  }}]
        \\}}
    ;

    for ([_][]const u8{ "^0.5.0", "latest", "v0.5.0", "00.5.0", "0.5" }) |version| {
        const bytes = try std.fmt.allocPrint(arena.allocator(), catalog_format, .{ version, "0.2.3" });
        try std.testing.expectError(
            error.InvalidTemplateHutchVersion,
            parseCatalog(
                arena.allocator(),
                bytes,
                "https://example.test/electrobun/templates",
                .stable,
            ),
        );
    }
    for ([_][]const u8{ "~0.2.3", "stable", "0.2", "0.2.3-", "0.2.3+" }) |version| {
        const bytes = try std.fmt.allocPrint(arena.allocator(), catalog_format, .{ "0.5.0", version });
        try std.testing.expectError(
            error.InvalidTemplateCottontailVersion,
            parseCatalog(
                arena.allocator(),
                bytes,
                "https://example.test/electrobun/templates",
                .stable,
            ),
        );
    }
}

test "template catalog tool compatibility uses a Hutch minimum and exact Cottontail" {
    const catalog = Catalog{
        .channel = .stable,
        .version = "2.0.0",
        .revision = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .hutch_version = "0.23.0-beta.2+catalog-build",
        .cottontail_version = "0.5.0-beta.2+paired-build",
        .templates = &.{},
    };

    try validateToolCompatibility(catalog, "0.23.0-beta.2+other-build", "0.5.0-beta.2+paired-build");
    try validateToolCompatibility(catalog, "0.23.0", "0.5.0-beta.2+paired-build");
    try std.testing.expectError(
        error.TemplateRequiresNewerHutch,
        validateToolCompatibility(catalog, "0.23.0-beta.1", "0.5.0-beta.2+paired-build"),
    );
    try std.testing.expectError(
        error.IncompatibleTemplateCottontail,
        validateToolCompatibility(catalog, "0.24.0", "0.5.0-beta.2+other-build"),
    );
}

test "template catalogs reject archive URLs outside their artifact origin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bytes =
        \\{
        \\  "schema": 1,
        \\  "kind": "electrobun-template-channel",
        \\  "channel": "stable",
        \\  "version": "2.0.0",
        \\  "revision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "tools": { "hutch": "0.5.0", "cottontail": "0.2.3" },
        \\  "templates": [{
        \\    "id": "hello-world",
        \\    "name": "Hello World",
        \\    "description": "A starter",
        \\    "mainProcess": "cottontail",
        \\    "archive": {
        \\      "url": "https://attacker.test/template.tar.gz",
        \\      "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        \\      "size": 123
        \\    }
        \\  }]
        \\}
    ;
    try std.testing.expectError(
        error.UntrustedTemplateArchiveUrl,
        parseCatalog(
            arena.allocator(),
            bytes,
            "https://example.test/electrobun/templates",
            .stable,
        ),
    );
}
