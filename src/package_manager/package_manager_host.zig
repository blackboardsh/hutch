const std = @import("std");
const import_scan = @import("import_scan.zig");
const builtin = @import("builtin");
const runtime_resolver = @import("../runtime_resolver.zig");

const max_runtime_service_output_bytes = 768 * 1024 * 1024;

pub fn cliExecutable(
    io: std.Io,
    allocator: std.mem.Allocator,
) ![]u8 {
    return std.process.executablePathAlloc(io, allocator);
}

pub fn cliExecutableForInit(
    init: std.process.Init,
    allocator: std.mem.Allocator,
) ![]u8 {
    if (init.environ_map.get("HUTCH_LAUNCHER_PATH")) |configured| {
        return allocator.dupe(u8, configured);
    }
    return cliExecutable(init.io, allocator);
}

pub fn runtimeExecutable(
    init: std.process.Init,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const no_args: [0][:0]const u8 = .{};
    const resolution = try runtime_resolver.resolveCottontail(
        init,
        allocator,
        no_args[0..],
    );
    return resolution.executable;
}

pub fn scanDependencies(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    entry_points: []const []const u8,
    working_dir: []const u8,
    stderr: *std.Io.Writer,
) ![]const []const u8 {
    _ = stderr;
    // Scanning is native: shipped Cottontail runtimes carry no dev tooling,
    // so Hutch owns the lexical package-import scan itself.
    return import_scan.scan(init.io, allocator, entry_points, working_dir);
}

fn lastNonEmptyLine(output: []const u8) []const u8 {
    var lines = std.mem.splitBackwardsScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) return trimmed;
    }
    return "";
}

pub fn runRuntime(
    init: std.process.Init,
    script_path: [:0]const u8,
    script_args: []const [:0]const u8,
) !u8 {
    const allocator = init.arena.allocator();
    const runtime = try runtimeExecutable(init, allocator);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ runtime, script_path });
    for (script_args) |arg| try argv.append(allocator, arg);

    var child = try std.process.spawn(init.io, .{
        .argv = argv.items,
        .environ_map = init.environ_map,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .create_no_window = true,
    });
    defer child.kill(init.io);
    return childExitCode(try child.wait(init.io));
}

pub fn runRuntimeService(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    service: []const u8,
    operation: []const u8,
    input: []const u8,
    extra_args: []const []const u8,
) ![]u8 {
    const runtime = try runtimeExecutable(init, allocator);
    const temporary_root = temporaryDirectory(init.environ_map);
    const service_directory = try std.fs.path.join(allocator, &.{
        temporary_root,
        "hutch-runtime-services",
    });
    try std.Io.Dir.cwd().createDirPath(init.io, service_directory);

    var random_suffix: u64 = undefined;
    init.io.random(std.mem.asBytes(&random_suffix));
    const input_name = try std.fmt.allocPrint(
        allocator,
        "{s}-{d}-{x}.input",
        .{ service, currentProcessId(), random_suffix },
    );
    const input_path = try std.fs.path.join(allocator, &.{ service_directory, input_name });
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = input_path,
        .data = input,
    });
    defer std.Io.Dir.cwd().deleteFile(init.io, input_path) catch {};

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        runtime,
        service,
        operation,
        input_path,
    });
    try argv.appendSlice(allocator, extra_args);

    const result = try std.process.run(allocator, init.io, .{
        .argv = argv.items,
        .create_no_window = true,
        .environ_map = init.environ_map,
        .stdout_limit = .limited(max_runtime_service_output_bytes),
        .stderr_limit = .limited(16 * 1024 * 1024),
    });
    errdefer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (childExitCode(result.term) != 0) {
        reportRuntimeServiceFailure(init.io, service, operation, result.stderr);
        allocator.free(result.stdout);
        return error.RuntimeServiceFailed;
    }
    return result.stdout;
}

fn childExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| @intCast(@min(code, 255)),
        else => 1,
    };
}

fn temporaryDirectory(environment: *const std.process.Environ.Map) []const u8 {
    for ([_][]const u8{ "BUN_TMPDIR", "TMPDIR", "TEMP", "TMP" }) |name| {
        if (environment.get(name)) |value| {
            if (value.len > 0) return value;
        }
    }
    return if (builtin.os.tag == .windows) "." else "/tmp";
}

fn currentProcessId() u64 {
    return switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        else => @intCast(std.posix.system.getpid()),
    };
}

fn reportRuntimeServiceFailure(
    io: std.Io,
    service: []const u8,
    operation: []const u8,
    child_stderr: []const u8,
) void {
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stderr().writer(io, &buffer);
    const writer = &file_writer.interface;
    writer.print(
        "hutch: Cottontail service '{s} {s}' failed\n",
        .{ service, operation },
    ) catch return;
    if (child_stderr.len > 0) writer.writeAll(child_stderr) catch return;
    writer.flush() catch {};
}

test "runtime service JSON uses the final non-empty output line" {
    try std.testing.expectEqualStrings(
        "[\"react\"]",
        lastNonEmptyLine("compiler diagnostic\n[\"react\"]\n"),
    );
    try std.testing.expectEqualStrings("[]", lastNonEmptyLine("[]\r\n"));
}
