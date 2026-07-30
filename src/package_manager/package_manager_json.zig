const std = @import("std");
const Diagnostic = @import("support/config/diagnostic.zig");
const Jsonc = @import("support/config/jsonc.zig");

const Value = std.json.Value;

pub fn parsePackageJSON(
    allocator: std.mem.Allocator,
    path: []const u8,
    contents: []const u8,
) !Value {
    return parsePackageJSONImpl(allocator, path, contents, null, false);
}

pub fn parseInstallPackageJSON(
    allocator: std.mem.Allocator,
    path: []const u8,
    contents: []const u8,
    stderr: *std.Io.Writer,
) !Value {
    return parsePackageJSONImpl(allocator, path, contents, stderr, true);
}

pub fn printDuplicateWorkspaceName(
    allocator: std.mem.Allocator,
    name: []const u8,
    duplicate_path: []const u8,
    duplicate_contents: []const u8,
    first_path: []const u8,
    first_contents: []const u8,
    stderr: *std.Io.Writer,
) !bool {
    var duplicate_failure: Jsonc.Failure = .{};
    const duplicate_document = Jsonc.parse(
        allocator,
        duplicate_contents,
        &duplicate_failure,
    ) catch return false;
    const duplicate_name = duplicate_document.root.get("name") orelse return false;

    var first_failure: Jsonc.Failure = .{};
    const first_document = Jsonc.parse(
        allocator,
        first_contents,
        &first_failure,
    ) catch return false;
    const first_name = first_document.root.get("name") orelse return false;

    try Diagnostic.print(
        stderr,
        duplicate_path,
        duplicate_contents,
        duplicate_name.span.start,
        .@"error",
        "Workspace name \"{s}\" already exists",
        .{name},
    );
    try stderr.writeByte('\n');
    try Diagnostic.print(
        stderr,
        first_path,
        first_contents,
        first_name.span.start,
        .note,
        "Package name is also declared here",
        .{},
    );
    return true;
}

fn parsePackageJSONImpl(
    allocator: std.mem.Allocator,
    path: []const u8,
    contents: []const u8,
    stderr: ?*std.Io.Writer,
    validate_install_shape: bool,
) !Value {
    var failure: Jsonc.Failure = .{};
    const document = Jsonc.parse(allocator, contents, &failure) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (stderr) |writer| {
                try printParseFailure(writer, path, contents, failure);
                try writer.print("ParserError: failed to parse '{s}'\n", .{path});
                return error.PackageManagerErrorReported;
            }
            return error.InvalidPackageJSON;
        },
    };

    if (validate_install_shape) {
        if (try validateInstallShape(
            path,
            contents,
            &document,
            stderr.?,
        )) {
            return error.PackageManagerErrorReported;
        }
    }

    return document.value;
}

fn validateInstallShape(
    path: []const u8,
    contents: []const u8,
    document: *const Jsonc.Document,
    stderr: *std.Io.Writer,
) !bool {
    const root = switch (document.value) {
        .object => |object| object,
        else => return false,
    };

    for ([_][]const u8{
        "dependencies",
        "devDependencies",
        "optionalDependencies",
        "peerDependencies",
    }) |section_name| {
        const dependencies = root.get(section_name) orelse continue;
        const dependencies_node = document.root.get(section_name) orelse document.root;

        if (dependencies != .object) {
            const section_offset = if (document.root.getProperty(section_name)) |property|
                property.key_span.start
            else
                dependencies_node.span.start;
            try printDependencyShapeError(
                stderr,
                path,
                contents,
                section_offset,
                section_name,
            );
            return true;
        }

        var iterator = dependencies.object.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.* == .string) continue;
            const value_node = dependencies_node.get(entry.key_ptr.*) orelse dependencies_node;
            try printDependencyShapeError(
                stderr,
                path,
                contents,
                value_node.span.start,
                section_name,
            );
            return true;
        }
    }

    const workspaces = root.get("workspaces") orelse return false;
    const workspaces_node = document.root.get("workspaces") orelse document.root;
    switch (workspaces) {
        .array => {},
        .object => |object| {
            if (object.get("packages")) |packages| {
                if (packages != .array) {
                    const packages_node = workspaces_node.get("packages") orelse workspaces_node;
                    try Diagnostic.print(
                        stderr,
                        path,
                        contents,
                        packages_node.span.start,
                        .@"error",
                        \\"workspaces.packages" expects an array of strings, e.g.
                        \\  "workspaces": {{
                        \\    "packages": [
                        \\      "path/to/package"
                        \\    ]
                        \\  }}
                    ,
                        .{},
                    );
                    return true;
                }
            }
        },
        else => {
            const workspaces_offset = if (document.root.getProperty("workspaces")) |property|
                property.key_span.start
            else
                workspaces_node.span.start;
            try Diagnostic.print(
                stderr,
                path,
                contents,
                workspaces_offset,
                .@"error",
                \\"workspaces" expects an array of strings, e.g.
                \\  <r><green>"workspaces"<r>: [
                \\    <green>"path/to/package"<r>
                \\  ]
            ,
                .{},
            );
            return true;
        },
    }

    return false;
}

fn printDependencyShapeError(
    stderr: *std.Io.Writer,
    path: []const u8,
    contents: []const u8,
    offset: usize,
    section_name: []const u8,
) !void {
    try Diagnostic.print(
        stderr,
        path,
        contents,
        offset,
        .@"error",
        \\{0s} expects a map of specifiers, e.g.
        \\  "{0s}": {{
        \\    <green>"bun"<r>: <green>"latest"<r>
        \\  }}
    ,
        .{section_name},
    );
}

fn printParseFailure(
    stderr: *std.Io.Writer,
    path: []const u8,
    contents: []const u8,
    failure: Jsonc.Failure,
) !void {
    switch (failure.reason) {
        .unexpected_end => try Diagnostic.print(
            stderr,
            path,
            contents,
            failure.offset,
            .@"error",
            "Unexpected end of file",
            .{},
        ),
        .unterminated_comment => try Diagnostic.print(
            stderr,
            path,
            contents,
            failure.offset,
            .@"error",
            "Unterminated comment",
            .{},
        ),
        .syntax => {
            const token = Jsonc.unexpectedToken(contents, failure);
            if (token.len > 0) {
                try Diagnostic.print(
                    stderr,
                    path,
                    contents,
                    failure.offset,
                    .@"error",
                    "Unexpected {s}",
                    .{token},
                );
            } else {
                try Diagnostic.print(
                    stderr,
                    path,
                    contents,
                    failure.offset,
                    .@"error",
                    "Invalid JSON",
                    .{},
                );
            }
        },
    }
}

test "install package JSON reports an invalid dependency map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const source = "{\"name\":\"foo\",\"version\":\"0.0.1\",\"dependencies\":[]}";
    try std.testing.expectError(
        error.PackageManagerErrorReported,
        parseInstallPackageJSON(
            arena.allocator(),
            "/tmp/package.json",
            source,
            &output.writer,
        ),
    );
    try std.testing.expectEqualStrings(
        \\1 | {"name":"foo","version":"0.0.1","dependencies":[]}
        \\                                    ^
        \\error: dependencies expects a map of specifiers, e.g.
        \\  "dependencies": {
        \\    <green>"bun"<r>: <green>"latest"<r>
        \\  }
        \\    at /tmp/package.json:1:33
        \\
    , output.written());
}

test "install package JSON rejects non-string dependency values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const source = "{\"dependencies\":{\"foo\":42}}";
    try std.testing.expectError(
        error.PackageManagerErrorReported,
        parseInstallPackageJSON(
            arena.allocator(),
            "package.json",
            source,
            &output.writer,
        ),
    );
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "package.json:1:24") != null);
}

test "install package JSON reports an invalid workspace package list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const source = "{\"name\":\"foo\",\"version\":\"0.0.1\",\"workspaces\":{\"packages\":{\"bar\":true}}}";
    try std.testing.expectError(
        error.PackageManagerErrorReported,
        parseInstallPackageJSON(
            arena.allocator(),
            "/tmp/package.json",
            source,
            &output.writer,
        ),
    );
    try std.testing.expectEqualStrings(
        \\1 | {"name":"foo","version":"0.0.1","workspaces":{"packages":{"bar":true}}}
        \\                                                             ^
        \\error: "workspaces.packages" expects an array of strings, e.g.
        \\  "workspaces": {
        \\    "packages": [
        \\      "path/to/package"
        \\    ]
        \\  }
        \\    at /tmp/package.json:1:58
        \\
    , output.written());
}

test "invalid package JSON retains source diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try std.testing.expectError(
        error.PackageManagerErrorReported,
        parseInstallPackageJSON(
            arena.allocator(),
            "/tmp/package.json",
            "foo",
            &output.writer,
        ),
    );
    try std.testing.expectEqualStrings(
        \\1 | foo
        \\    ^
        \\error: Unexpected foo
        \\    at /tmp/package.json:1:1
        \\ParserError: failed to parse '/tmp/package.json'
        \\
    , output.written());
}

test "duplicate workspace names report both package locations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const printed = try printDuplicateWorkspaceName(
        arena.allocator(),
        "moo",
        "/tmp/baz/package.json",
        "{\"name\":\"moo\",\"version\":\"0.0.3\"}",
        "/tmp/bar/package.json",
        "{\"name\":\"moo\",\"version\":\"0.0.2\"}",
        &output.writer,
    );
    try std.testing.expect(printed);
    try std.testing.expectEqualStrings(
        \\1 | {"name":"moo","version":"0.0.3"}
        \\            ^
        \\error: Workspace name "moo" already exists
        \\    at /tmp/baz/package.json:1:9
        \\
        \\1 | {"name":"moo","version":"0.0.2"}
        \\            ^
        \\note: Package name is also declared here
        \\   at /tmp/bar/package.json:1:9
        \\
    , output.written());
}
