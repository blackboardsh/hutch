const std = @import("std");
const package_manager = @import("package_manager/root.zig");
const release_store = @import("release_store.zig");

const default_base_url = "https://electrobun-artifacts.blackboard.sh/electrobun/templates";
const manifest_schema = 1;
const max_manifest_bytes = 1024 * 1024;
const max_archive_bytes = 16 * 1024 * 1024;

pub const Channel = enum {
    production,
    canary,

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

pub const LoadOptions = struct {
    offline: bool = false,
};

pub fn parseChannel(value: []const u8) !Channel {
    if (std.mem.eql(u8, value, "production")) return .production;
    if (std.mem.eql(u8, value, "canary")) return .canary;
    return error.InvalidTemplateChannel;
}

pub fn activeChannel(environment: *const std.process.Environ.Map) !Channel {
    return parseChannel(environment.get("HUTCH_ACTIVE_CHANNEL") orelse "production");
}

pub fn load(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    channel: Channel,
    options: LoadOptions,
) !Catalog {
    const base_url = try baseUrl(init, allocator);
    const home = try release_store.dashHome(init, allocator);
    const cache_path = try std.fs.path.join(allocator, &.{
        home,
        "cache",
        "electrobun",
        "templates",
        "channels",
        try std.mem.concat(allocator, u8, &.{ channel.name(), ".json" }),
    });
    const cached = std.Io.Dir.cwd().readFileAlloc(
        init.io,
        cache_path,
        allocator,
        .limited(max_manifest_bytes),
    ) catch null;

    if (!options.offline) {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/channels/{s}.json",
            .{ base_url, channel.name() },
        );
        if (release_store.fetchBytes(init, allocator, url, max_manifest_bytes)) |downloaded| {
            const catalog = try parseCatalog(allocator, downloaded, base_url, channel);
            try release_store.writeCacheFile(init.io, allocator, cache_path, downloaded);
            return catalog;
        } else |_| {}
    }

    const bytes = cached orelse return error.TemplateCatalogUnavailable;
    return parseCatalog(allocator, bytes, base_url, channel);
}

pub fn install(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    template: Template,
    destination: []const u8,
    options: LoadOptions,
) !void {
    if (pathExists(init.io, destination)) return error.ProjectAlreadyExists;
    const archive = try loadArchive(init, allocator, template, options);
    const parent = std.fs.path.dirname(destination) orelse return error.InvalidProjectPath;
    try std.Io.Dir.cwd().createDirPath(init.io, parent);

    const temporary = try std.mem.concat(allocator, u8, &.{ destination, ".hutch-template-tmp" });
    std.Io.Dir.cwd().deleteTree(init.io, temporary) catch {};
    try std.Io.Dir.cwd().createDirPath(init.io, temporary);
    errdefer std.Io.Dir.cwd().deleteTree(init.io, temporary) catch {};

    {
        var output = try std.Io.Dir.cwd().openDir(init.io, temporary, .{});
        defer output.close(init.io);
        try package_manager.cli.extractTarballArchive(init.io, allocator, output, archive);
    }
    const package_json = try std.fs.path.join(allocator, &.{ temporary, "package.json" });
    if (!pathExists(init.io, package_json)) return error.InvalidTemplateArchive;
    try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), destination, init.io);
}

fn loadArchive(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    template: Template,
    options: LoadOptions,
) ![]const u8 {
    const home = try release_store.dashHome(init, allocator);
    const cache_path = try std.fs.path.join(allocator, &.{
        home,
        "cache",
        "electrobun",
        "templates",
        "archives",
        try std.mem.concat(allocator, u8, &.{ template.archive.sha256, ".tar.gz" }),
    });
    if (std.Io.Dir.cwd().readFileAlloc(
        init.io,
        cache_path,
        allocator,
        .limited(max_archive_bytes),
    )) |cached| {
        if (archiveMatches(cached, template.archive)) return cached;
        std.Io.Dir.cwd().deleteFile(init.io, cache_path) catch {};
    } else |_| {}

    if (options.offline) return error.TemplateArchiveNotCached;
    const downloaded = try release_store.fetchBytes(
        init,
        allocator,
        template.archive.url,
        max_archive_bytes,
    );
    if (!archiveMatches(downloaded, template.archive)) {
        return error.TemplateArchiveIntegrityMismatch;
    }
    try release_store.writeCacheFile(init.io, allocator, cache_path, downloaded);
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
    if (hutch_version.len == 0 or cottontail_version.len == 0) {
        return error.InvalidTemplateCatalog;
    }

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
    const bytes =
        \\{
        \\  "schema": 1,
        \\  "kind": "electrobun-template-channel",
        \\  "channel": "canary",
        \\  "version": "2.0.0-beta.1",
        \\  "revision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "tools": { "hutch": "0.5.0-canary.1", "cottontail": "0.2.3" },
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
        std.testing.allocator,
        bytes,
        "https://example.test/electrobun/templates",
        .canary,
    );
    defer std.testing.allocator.free(catalog.templates);
    try std.testing.expectEqual(Channel.canary, catalog.channel);
    try std.testing.expectEqualStrings("2.0.0-beta.1", catalog.version);
    try std.testing.expectEqualStrings("hello-world", catalog.templates[0].id);
    try std.testing.expect(catalog.find("missing") == null);
}

test "template catalogs reject archive URLs outside their artifact origin" {
    const bytes =
        \\{
        \\  "schema": 1,
        \\  "kind": "electrobun-template-channel",
        \\  "channel": "production",
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
            std.testing.allocator,
            bytes,
            "https://example.test/electrobun/templates",
            .production,
        ),
    );
}
