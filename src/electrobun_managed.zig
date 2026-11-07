//! Managed Deploys is a native Hutch operation. Build emits public JSON defaults;
//! neither uploading nor publishing evaluates project code or installs a runtime.
const std = @import("std");
const builtin = @import("builtin");
const inventory_module = @import("electrobun_managed_inventory.zig");
const request_timeout = @import("electrobun_managed_timeout.zig");
const part_size = 8 * 1024 * 1024;

const Options = struct {
    app: []const u8,
    api_url: []const u8,
    api_key: ?[]const u8,
    artifacts: []const u8,
    release: ?[]const u8,
    audience: []const u8,
    channel: ?[]const u8,
    targets: ?[]const []const u8,
    dry_run: bool,
    offline: bool,
    local_http: bool,
};

pub fn isCommand(command: []const u8) bool {
    return equal(command, "upload") or equal(command, "deploy") or equal(command, "publish");
}

pub fn run(init: std.process.Init, command: []const u8, args: []const [:0]const u8) !u8 {
    var out_buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &out_buffer);
    defer out.interface.flush() catch {};
    for (args) |arg| {
        if (equal(arg, "--help") or equal(arg, "-h")) {
            try out.interface.writeAll(
                \\hutch electrobun upload [--artifacts=<folder>] [--app=<id>] [--release=<id>] [--dry-run]
                \\hutch electrobun publish --release=<channel-version> [--audience=prerelease|public] [--app=<id>] [--dry-run]
                \\
                \\Upload discovers canary/stable builds and targets from generated manifests.
                \\Publish checks the accumulated release after all uploads finish.
                \\--audience=prerelease publishes to registered prerelease installs; public publishes to all installs (default).
                \\Release IDs are <channel>-<version>; upload infers them from generated artifacts.
                \\Use ELECTROBUN_API_KEY or --api-key. Public app defaults are saved during build.
                \\Optional: --api-url=<origin>, upload --env=canary|stable, upload --targets=<list>.
                \\No JavaScript runtime, package installation, or config evaluation is required.
                \\
            );
            return 0;
        }
    }
    execute(init, command, args, &out.interface) catch |err| {
        try out.interface.flush();
        var buffer: [2048]u8 = undefined;
        var writer = std.Io.File.stderr().writerStreaming(init.io, &buffer);
        try writer.interface.print("hutch electrobun {s}: {s}\n", .{ command, message(err) });
        try writer.interface.flush();
        return 1;
    };
    return 0;
}

fn message(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidManagedAppId => "Set --app or build release.managed.appId before uploading (public defaults are read from .hutch/managed-deploy.json).",
        error.MissingReleaseId => "--release is required; use the release ID reported by upload.",
        error.InvalidReleaseId => "Use a plain release ID of up to 128 letters, digits, periods, hyphens, underscores, or plus signs.",
        error.MissingApiKey => "Set ELECTROBUN_API_KEY or --api-key to an Electrobun Managed Deploys API key.",
        error.InvalidApiUrl => "The API URL must use HTTPS with no credentials, query, or fragment. Explicit loopback HTTP is allowed for local testing.",
        error.InvalidChannel => "--env must be canary or stable; dev builds do not create release artifacts.",
        error.InvalidAudience => "--audience must be prerelease or public.",
        error.ManagedReleaseIdMismatch => "--release must match <channel>-<version> from the uploaded artifacts; omit it to infer the release.",
        error.UnknownOption, error.DuplicateOption, error.MissingOptionValue => "Invalid command options; use --help for usage.",
        error.NetworkDisabled => "This operation requires network access; unset DASH_RELEASE_OFFLINE or use upload --dry-run.",
        error.ApiRedirected => "Managed Deploys API redirected; use its canonical API URL. Credentials were not forwarded.",
        error.ApiRequestFailed => "Managed Deploys request failed; retry the same release to resume uploaded files.",
        error.ManagedRequestTimedOut => "Managed Deploys request timed out after 120 seconds; retry the same release to resume uploaded files.",
        error.InvalidApiResponse => "Managed Deploys returned an invalid response.",
        error.InvalidUploadGrant => "Managed Deploys returned an invalid signed upload grant.",
        error.ArtifactChanged => "An artifact changed after inventory; finish the build before uploading.",
        error.ReleaseNotReady => "Release checks failed; complete the missing uploads before publishing.",
        else => @errorName(err),
    };
}

fn execute(init: std.process.Init, command: []const u8, args: []const [:0]const u8, out: *std.Io.Writer) !void {
    const allocator = init.arena.allocator();
    const options = try parse(init, command, args);
    if (options.offline and (equal(command, "publish") or !options.dry_run)) return error.NetworkDisabled;
    var client: std.http.Client = .{ .allocator = allocator, .io = init.io };
    defer client.deinit();
    client.initDefaultProxies(allocator, init.environ_map) catch {};
    const api = Api{ .allocator = allocator, .client = &client, .options = options, .out = out };
    if (equal(command, "publish")) return publish(api, out);
    // Validate and hash every channel before creating any remote release.
    const releases = try inventory_module.inventory(init.io, allocator, options.artifacts, options.channel, options.release, options.targets);
    for (releases) |release| {
        try out.print("App {s}, release {s}: {s} {s}, {d} files\n", .{ options.app, release.id, release.channel, release.version, release.files.len });
        if (options.dry_run) {
            for (release.files) |file| try out.print("  {s} ({d} bytes)\n", .{ file.filename, file.size });
            continue;
        }
        try upload(init.io, api, release, out);
    }
    if (options.dry_run) try out.writeAll("Dry run: no files uploaded.\n");
}

fn equal(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn string(value: std.json.Value, name: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const item = value.object.get(name) orelse return null;
    return if (item == .string) item.string else null;
}
fn field(value: std.json.Value, name: []const u8) !std.json.Value {
    if (value != .object) return error.InvalidApiResponse;
    return value.object.get(name) orelse error.InvalidApiResponse;
}
fn number(value: std.json.Value) !u64 {
    if (value != .integer or value.integer < 0) return error.InvalidApiResponse;
    return @intCast(value.integer);
}
fn validId(value: []const u8, release: bool) bool {
    if (value.len == 0 or value.len > 128 or !std.ascii.isAlphanumeric(value[0])) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and !(release and (byte == '.' or byte == '+'))) return false;
    return !release or (std.mem.find(u8, value, "..") == null and value[value.len - 1] != '.');
}
fn validTarget(value: []const u8) bool {
    for ([_][]const u8{ "macos-arm64", "macos-x64", "win-arm64", "win-x64", "linux-arm64", "linux-x64" }) |target| if (equal(value, target)) return true;
    return false;
}
fn readDefaults(init: std.process.Init, path: []const u8) !?std.json.Value {
    const data = std.Io.Dir.cwd().readFileAlloc(init.io, path, init.arena.allocator(), .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const parsed = try std.json.parseFromSlice(std.json.Value, init.arena.allocator(), data, .{ .allocate = .alloc_always });
    if (parsed.value != .object) return error.InvalidManagedDefaults;
    return parsed.value;
}

fn parse(init: std.process.Init, command: []const u8, args: []const [:0]const u8) !Options {
    const allocator = init.arena.allocator();
    var values: std.StringHashMap([]const u8) = .init(allocator);
    var dry_run = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg: []const u8 = args[index];
        if (equal(arg, "--dry-run")) {
            dry_run = true;
            continue;
        }
        if (!std.mem.startsWith(u8, arg, "--")) return error.UnknownOption;
        const split = std.mem.findScalar(u8, arg, '=');
        const name = arg[2..(split orelse arg.len)];
        const allowed = equal(name, "app") or equal(name, "release") or equal(name, "api-url") or equal(name, "api-key") or
            (equal(command, "publish") and equal(name, "audience")) or
            (!equal(command, "publish") and (equal(name, "artifacts") or equal(name, "env") or equal(name, "targets")));
        if (!allowed) return error.UnknownOption;
        if (values.contains(name)) return error.DuplicateOption;
        const value: []const u8 = if (split) |at| arg[at + 1 ..] else blk: {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            break :blk args[index];
        };
        if (value.len == 0 or std.mem.startsWith(u8, value, "--")) return error.MissingOptionValue;
        try values.put(name, value);
    }
    const explicit_app = values.get("app") orelse init.environ_map.get("ELECTROBUN_APP_ID");
    const need_project_defaults = explicit_app == null or !values.contains("api-url") or (!equal(command, "publish") and !values.contains("artifacts"));
    const project_defaults = if (need_project_defaults) try readDefaults(init, ".hutch/managed-deploy.json") else null;
    const artifact_folder = values.get("artifacts") orelse (if (project_defaults) |defaults| string(defaults, "artifactFolder") else null) orelse "artifacts";
    const artifact_defaults = if (!equal(command, "publish")) try readDefaults(init, try std.fs.path.join(allocator, &.{ artifact_folder, "managed-deploy.json" })) else null;
    const defaults = artifact_defaults orelse project_defaults;
    const app = explicit_app orelse (if (defaults) |value| string(value, "appId") else null) orelse return error.InvalidManagedAppId;
    if (!validId(app, false)) return error.InvalidManagedAppId;
    const release = values.get("release");
    if (equal(command, "publish") and release == null) return error.MissingReleaseId;
    if (release) |id| if (!validId(id, true)) return error.InvalidReleaseId;
    const audience = values.get("audience") orelse "public";
    if (!equal(audience, "prerelease") and !equal(audience, "public")) return error.InvalidAudience;
    const channel = values.get("env");
    if (channel) |name| if (!equal(name, "canary") and !equal(name, "stable")) return error.InvalidChannel;
    const api_key_input = values.get("api-key") orelse init.environ_map.get("ELECTROBUN_API_KEY");
    const api_key = if (api_key_input) |key| if (key.len > 0) key else null else null;
    if (api_key) |key| {
        if (key.len == 0 or std.mem.findAny(u8, key, "\r\n") != null) return error.MissingApiKey;
    } else if (equal(command, "publish") or !dry_run) return error.MissingApiKey;
    const api_input = values.get("api-url") orelse (if (defaults) |value| string(value, "apiUrl") else null) orelse "https://api.electrobun.dev";
    const uri = std.Uri.parse(api_input) catch return error.InvalidApiUrl;
    const host = if (uri.host) |host| try host.toRawMaybeAlloc(allocator) else return error.InvalidApiUrl;
    const secure = std.ascii.eqlIgnoreCase(uri.scheme, "https");
    const local = equal(host, "localhost") or equal(host, "127.0.0.1") or equal(host, "[::1]");
    const local_http = local and std.ascii.eqlIgnoreCase(uri.scheme, "http") and values.contains("api-url");
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null or (!secure and !local_http)) return error.InvalidApiUrl;
    const path = std.mem.trimEnd(u8, try uri.path.toRawMaybeAlloc(allocator), "/");
    if (path.len != 0 and !equal(path, "/v1/electrobun")) return error.InvalidApiUrl;
    const api_url = if (uri.port) |port| try std.fmt.allocPrint(allocator, "{s}://{s}:{d}/v1/electrobun", .{ uri.scheme, host, port }) else try std.fmt.allocPrint(allocator, "{s}://{s}/v1/electrobun", .{ uri.scheme, host });
    var targets: ?[]const []const u8 = null;
    if (values.get("targets")) |list| {
        var items: std.ArrayList([]const u8) = .empty;
        var iter = std.mem.splitScalar(u8, list, ',');
        while (iter.next()) |target| {
            if (!validTarget(target)) return error.InvalidTargets;
            var present = false;
            for (items.items) |item| if (equal(item, target)) {
                present = true;
                break;
            };
            if (!present) try items.append(allocator, target);
        }
        std.mem.sort([]const u8, items.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        targets = items.items;
    }
    const offline = if (init.environ_map.get("DASH_RELEASE_OFFLINE")) |value| value.len != 0 and !equal(value, "0") and !std.ascii.eqlIgnoreCase(value, "false") and !std.ascii.eqlIgnoreCase(value, "no") else false;
    return .{ .app = app, .api_url = api_url, .api_key = api_key, .artifacts = artifact_folder, .release = release, .audience = audience, .channel = channel, .targets = targets, .dry_run = dry_run, .offline = offline, .local_http = local_http };
}

const Api = struct {
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    options: Options,
    out: *std.Io.Writer,

    fn request(api: Api, method: std.http.Method, path: []const u8, payload: ?[]const u8) !std.json.Value {
        return request_timeout.run(api.client.io, requestInner, .{ api, method, path, payload });
    }

    fn requestInner(api: Api, method: std.http.Method, path: []const u8, payload: ?[]const u8) !std.json.Value {
        const url = try std.mem.concat(api.allocator, u8, &.{ api.options.api_url, path });
        const authorization = try std.mem.concat(api.allocator, u8, &.{ "Bearer ", api.options.api_key orelse return error.MissingApiKey });
        var req = api.client.request(method, try std.Uri.parse(url), .{
            .redirect_behavior = .unhandled,
            .keep_alive = builtin.os.tag != .windows,
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
            .extra_headers = &.{ .{ .name = "Authorization", .value = authorization }, .{ .name = "Content-Type", .value = "application/json" } },
        }) catch return error.ApiRequestFailed;
        defer req.deinit();
        try send(&req, payload);
        var response = req.receiveHead(&.{}) catch return error.ApiRequestFailed;
        const status: u16 = @backingInt(response.head.status);
        if (status >= 300 and status < 400) return error.ApiRedirected;
        if (status < 200 or status >= 300) {
            const safe_path = if (api.options.api_key) |key| try std.mem.replaceOwned(u8, api.allocator, path, key, "[redacted]") else path;
            try api.out.print("Managed Deploys {s} {s}: HTTP {d}\n", .{ @tagName(method), safe_path, status });
            return error.ApiRequestFailed;
        }
        var transfer_buffer: [4096]u8 = undefined;
        const data = response.reader(&transfer_buffer).allocRemaining(api.allocator, .limited(4 * 1024 * 1024)) catch return error.InvalidApiResponse;
        const parsed = std.json.parseFromSlice(std.json.Value, api.allocator, data, .{ .allocate = .alloc_always }) catch return error.InvalidApiResponse;
        return parsed.value;
    }

    fn json(api: Api, method: std.http.Method, path: []const u8, value: anytype) !std.json.Value {
        return api.request(method, path, try std.json.Stringify.valueAlloc(api.allocator, value, .{}));
    }

    fn releasePath(api: Api, release: []const u8) ![]const u8 {
        return std.fmt.allocPrint(api.allocator, "/apps/{s}/releases/{s}", .{ api.options.app, try encode(api.allocator, release) });
    }
};

fn send(req: *std.http.Client.Request, payload: ?[]const u8) !void {
    if (payload) |bytes| {
        req.transfer_encoding = .{ .content_length = bytes.len };
        var body = req.sendBodyUnflushed(&.{}) catch return error.ApiRequestFailed;
        body.writer.writeAll(bytes) catch return error.ApiRequestFailed;
        body.end() catch return error.ApiRequestFailed;
        req.connection.?.flush() catch return error.ApiRequestFailed;
    } else req.sendBodiless() catch return error.ApiRequestFailed;
}

fn encode(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.') try output.writer.writeByte(byte) else try output.writer.print("%{X:0>2}", .{byte});
    }
    return output.toOwnedSlice();
}

const Part = struct { partNumber: u64, etag: []const u8 };

fn upload(io: std.Io, api: Api, release: inventory_module.Release, out: *std.Io.Writer) !void {
    const release_path = try api.releasePath(release.id);
    _ = try api.json(.POST, try std.fmt.allocPrint(api.allocator, "/apps/{s}/releases", .{api.options.app}), .{
        .releaseId = release.id,
        .channel = release.channel,
        .version = release.version,
        .expectedTargets = api.options.targets orelse release.targets,
    });
    const buffer = try api.allocator.alloc(u8, part_size);
    defer api.allocator.free(buffer);
    for (release.files) |file| {
        const input = try std.Io.Dir.cwd().openFile(io, file.path, .{ .follow_symlinks = false });
        defer input.close(io);
        const before = try input.stat(io);
        if (before.kind != .file or before.size != file.size) return error.ArtifactChanged;
        const initialized = try api.json(.POST, try std.mem.concat(api.allocator, u8, &.{ release_path, "/uploads" }), .{
            .filename = file.filename,
            .target = file.target,
            .size = file.size,
            .sha256 = file.sha256,
        });
        const item = try field(initialized, "upload");
        const upload_id = string(item, "id") orelse return error.InvalidApiResponse;
        if (!validId(upload_id, false)) return error.InvalidApiResponse;
        const status = string(item, "status") orelse return error.InvalidApiResponse;
        if (equal(status, "complete") or equal(status, "completed")) {
            try out.print("Already staged {s}\n", .{file.filename});
            continue;
        }
        const advertised_size = if (initialized == .object) initialized.object.get("partSize") orelse try field(item, "partSize") else return error.InvalidApiResponse;
        if (try number(advertised_size) != part_size) return error.InvalidApiResponse;
        const upload_path = try std.fmt.allocPrint(api.allocator, "{s}/uploads/{s}", .{ release_path, upload_id });
        const count = std.math.divCeil(u64, file.size, part_size) catch return error.InvalidApiResponse;
        var completed: std.AutoHashMap(u64, []const u8) = .init(api.allocator);
        if (item.object.get("parts")) |parts| {
            if (parts != .array) return error.InvalidApiResponse;
            for (parts.array.items) |part| {
                const id = try number(try field(part, "partNumber"));
                const etag = string(part, "etag") orelse return error.InvalidApiResponse;
                if (id == 0 or id > count or etag.len == 0 or completed.contains(id)) return error.InvalidApiResponse;
                try completed.put(id, etag);
            }
        }
        var parts: std.ArrayList(Part) = .empty;
        var sha = std.crypto.hash.sha2.Sha256.init(.{});
        var offset: u64 = 0;
        var part_number: u64 = 1;
        while (offset < file.size) : (part_number += 1) {
            const length: usize = @intCast(@min(part_size, file.size - offset));
            const bytes = buffer[0..length];
            if (try input.readPositionalAll(io, bytes, offset) != length) return error.ArtifactChanged;
            sha.update(bytes);
            var part_digest: [16]u8 = undefined;
            std.crypto.hash.Md5.hash(bytes, &part_digest, .{});
            const part_hex = std.fmt.bytesToHex(part_digest, .lower);
            // A failed earlier attempt may have left bytes from a changed file.
            // Reuse only a part whose S3 ETag proves it matches this local chunk.
            const resumable = if (completed.get(part_number)) |etag| if (std.ascii.eqlIgnoreCase(etag, &part_hex)) etag else null else null;
            const etag = resumable orelse blk: {
                var md5_buffer: [24]u8 = undefined;
                const md5 = std.base64.standard.Encoder.encode(&md5_buffer, &part_digest);
                const grant = try api.json(.POST, try std.fmt.allocPrint(api.allocator, "{s}/parts/{d}", .{ upload_path, part_number }), .{ .md5 = md5, .size = length });
                break :blk try putPart(api, grant, bytes, md5);
            };
            try parts.append(api.allocator, .{ .partNumber = part_number, .etag = etag });
            offset += length;
        }
        var digest: [32]u8 = undefined;
        sha.final(&digest);
        const hex = std.fmt.bytesToHex(digest, .lower);
        const after = try input.stat(io);
        if (!equal(&hex, file.sha256) or before.size != after.size or before.inode != after.inode or !std.meta.eql(before.mtime, after.mtime)) return error.ArtifactChanged;
        _ = try api.json(.POST, try std.mem.concat(api.allocator, u8, &.{ upload_path, "/complete" }), .{ .parts = parts.items });
        try out.print("Uploaded {s}\n", .{file.filename});
        try out.flush();
    }
    _ = try api.request(.GET, release_path, null);
    try out.print("Staged {s}. After all runners finish, publish to prerelease with: hutch electrobun publish --app={s} --release={s} --audience=prerelease\n", .{ release.id, api.options.app, release.id });
    try out.writeAll("Use --audience=public to publish to all installs.\n");
}

fn putPart(api: Api, grant: std.json.Value, bytes: []const u8, md5: []const u8) ![]const u8 {
    return request_timeout.run(api.client.io, putPartInner, .{ api, grant, bytes, md5 });
}

fn putPartInner(api: Api, grant: std.json.Value, bytes: []const u8, md5: []const u8) ![]const u8 {
    const url = string(grant, "url") orelse return error.InvalidUploadGrant;
    const uri = std.Uri.parse(url) catch return error.InvalidUploadGrant;
    const host = if (uri.host) |host| try host.toRawMaybeAlloc(api.allocator) else return error.InvalidUploadGrant;
    const local = equal(host, "localhost") or equal(host, "127.0.0.1") or equal(host, "[::1]");
    if (uri.user != null or uri.password != null or uri.fragment != null or
        (!std.ascii.eqlIgnoreCase(uri.scheme, "https") and !(api.options.local_http and local and std.ascii.eqlIgnoreCase(uri.scheme, "http")))) return error.InvalidUploadGrant;
    const headers_value = try field(grant, "headers");
    if (headers_value != .object) return error.InvalidUploadGrant;
    var headers: std.ArrayList(std.http.Header) = .empty;
    var md5_found = false;
    var length_found = false;
    var iter = headers_value.object.iterator();
    while (iter.next()) |entry| {
        const name = entry.key_ptr.*;
        if (entry.value_ptr.* != .string) return error.InvalidUploadGrant;
        const value = entry.value_ptr.string;
        if (name.len == 0 or std.mem.findAny(u8, name, "\r\n:") != null or std.mem.findAny(u8, value, "\r\n") != null or
            std.ascii.eqlIgnoreCase(name, "authorization") or std.ascii.eqlIgnoreCase(name, "proxy-authorization") or std.ascii.eqlIgnoreCase(name, "cookie") or std.ascii.eqlIgnoreCase(name, "host") or std.ascii.eqlIgnoreCase(name, "transfer-encoding")) return error.InvalidUploadGrant;
        if (std.ascii.eqlIgnoreCase(name, "content-md5")) {
            if (md5_found or !equal(value, md5)) return error.InvalidUploadGrant;
            md5_found = true;
        }
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            if (length_found or (std.fmt.parseInt(usize, value, 10) catch return error.InvalidUploadGrant) != bytes.len) return error.InvalidUploadGrant;
            length_found = true;
            continue; // std.http emits exactly one length from transfer_encoding.
        }
        try headers.append(api.allocator, .{ .name = name, .value = value });
    }
    if (!md5_found or !length_found) return error.InvalidUploadGrant;
    // This is a separate request: Dash's bearer credential is never included.
    var req = api.client.request(.PUT, uri, .{ .redirect_behavior = .unhandled, .headers = .{ .accept_encoding = .{ .override = "identity" } }, .extra_headers = headers.items, .keep_alive = builtin.os.tag != .windows }) catch return error.ApiRequestFailed;
    defer req.deinit();
    try send(&req, bytes);
    var response = req.receiveHead(&.{}) catch return error.ApiRequestFailed;
    const status: u16 = @backingInt(response.head.status);
    if (status >= 300 and status < 400) return error.ApiRedirected;
    if (status < 200 or status >= 300) {
        try api.out.print("R2 part upload: HTTP {d}\n", .{status});
        return error.ApiRequestFailed;
    }
    var response_headers = response.head.iterateHeaders();
    var etag: ?[]const u8 = null;
    while (response_headers.next()) |header| if (std.ascii.eqlIgnoreCase(header.name, "etag")) {
        const token = if (header.value.len >= 2 and header.value[0] == '"' and header.value[header.value.len - 1] == '"') header.value[1 .. header.value.len - 1] else header.value;
        if (token.len == 0 or token.len > 1024) return error.InvalidApiResponse;
        for (token) |byte| if (byte < 0x21 or byte > 0x7e or byte == '"') return error.InvalidApiResponse;
        etag = try api.allocator.dupe(u8, token);
    };
    var transfer_buffer: [1024]u8 = undefined;
    _ = response.reader(&transfer_buffer).allocRemaining(api.allocator, .limited(64 * 1024)) catch return error.InvalidApiResponse;
    return etag orelse error.InvalidApiResponse;
}

fn publish(api: Api, out: *std.Io.Writer) !void {
    const release_path = try api.releasePath(api.options.release.?);
    const details = try api.request(.GET, release_path, null);
    const release = try field(details, "release");
    const id = string(release, "id") orelse return error.InvalidApiResponse;
    const channel = string(release, "channel") orelse return error.InvalidApiResponse;
    const version = string(release, "version") orelse return error.InvalidApiResponse;
    if (!equal(id, api.options.release.?) or (!equal(channel, "stable") and !equal(channel, "canary")) or version.len == 0) return error.InvalidApiResponse;
    const canonical_id = try std.fmt.allocPrint(api.allocator, "{s}-{s}", .{ channel, version });
    if (!equal(id, canonical_id)) return error.InvalidApiResponse;
    const artifacts = try field(release, "artifacts");
    const targets = try field(release, "expectedTargets");
    const checks = try field(details, "checks");
    const ready = try field(checks, "ready");
    const errors = try field(checks, "errors");
    if (artifacts != .array or targets != .array or ready != .bool or errors != .array) return error.InvalidApiResponse;
    try out.print("Release {s}: {s}, {d} files\n", .{ api.options.release.?, channel, artifacts.array.items.len });
    // Server strings are not echoed: they may contain credential material.
    if (!ready.bool) return error.ReleaseNotReady;
    if (api.options.dry_run) {
        try out.writeAll(if (equal(api.options.audience, "prerelease")) "Release checks passed. Dry run: would publish to prerelease.\n" else "Release checks passed. Dry run: would publish to public.\n");
        return;
    }
    const result = try api.json(.POST, try std.mem.concat(api.allocator, u8, &.{ release_path, "/publish" }), .{ .audience = api.options.audience });
    const published = try field(result, "release");
    const expected_status: []const u8 = if (equal(api.options.audience, "prerelease")) "prerelease" else "published";
    if (!equal(string(published, "id") orelse return error.InvalidApiResponse, api.options.release.?) or !equal(string(published, "status") orelse return error.InvalidApiResponse, expected_status)) return error.InvalidApiResponse;
    if (equal(api.options.audience, "prerelease")) try out.print("Published {s} to prerelease.\n", .{api.options.release.?}) else try out.print("Published {s} to public.\n", .{api.options.release.?});
}
