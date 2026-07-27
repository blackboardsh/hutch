const std = @import("std");
const windows = std.os.windows;

const expected_exit_code: u8 = 23;
const stdout_sentinel = "hutch child stdout";
const stderr_sentinel = "hutch child stderr";

const generic_read: windows.DWORD = 0x80000000;
const generic_write: windows.DWORD = 0x40000000;
const file_share_read: windows.DWORD = 0x00000001;
const file_share_write: windows.DWORD = 0x00000002;
const console_textmode_buffer: windows.DWORD = 1;
const std_output_handle: windows.DWORD = 0xfffffff5;
const std_error_handle: windows.DWORD = 0xfffffff4;

fn environmentFlagEnabled(environ_map: *const std.process.Environ.Map, name: []const u8) bool {
    const value = environ_map.get(name) orelse return false;
    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes");
}

const SmallRect = extern struct {
    left: i16,
    top: i16,
    right: i16,
    bottom: i16,
};

const ConsoleScreenBufferInfo = extern struct {
    size: windows.COORD,
    cursor_position: windows.COORD,
    attributes: windows.WORD,
    window: SmallRect,
    maximum_window_size: windows.COORD,
};

extern "kernel32" fn AllocConsole() callconv(.winapi) windows.BOOL;
extern "kernel32" fn FreeConsole() callconv(.winapi) windows.BOOL;
extern "kernel32" fn CreateConsoleScreenBuffer(
    desired_access: windows.DWORD,
    share_mode: windows.DWORD,
    security_attributes: ?*const windows.SECURITY_ATTRIBUTES,
    flags: windows.DWORD,
    screen_buffer_data: ?*anyopaque,
) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn GetStdHandle(std_handle: windows.DWORD) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn SetStdHandle(std_handle: windows.DWORD, handle: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetConsoleScreenBufferInfo(
    console_output: windows.HANDLE,
    info: *ConsoleScreenBufferInfo,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn ReadConsoleOutputCharacterW(
    console_output: windows.HANDLE,
    characters: [*]windows.WCHAR,
    length: windows.DWORD,
    read_coordinate: windows.COORD,
    characters_read: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

const ConsoleCapture = struct {
    stdout_handle: windows.HANDLE,
    stderr_handle: windows.HANDLE,
    previous_stdout_handle: windows.HANDLE,
    previous_stderr_handle: windows.HANDLE,
    allocated_console: bool,

    fn init() !ConsoleCapture {
        var allocated_console = false;
        var stdout_handle = createScreenBuffer();
        if (stdout_handle == windows.INVALID_HANDLE_VALUE) {
            if (!AllocConsole().toBool()) return error.ConsoleAllocationFailed;
            allocated_console = true;
            stdout_handle = createScreenBuffer();
        }
        if (stdout_handle == windows.INVALID_HANDLE_VALUE) {
            if (allocated_console) _ = FreeConsole();
            return error.ConsoleScreenBufferCreationFailed;
        }
        errdefer {
            if (allocated_console) _ = FreeConsole();
        }
        errdefer windows.CloseHandle(stdout_handle);

        const stderr_handle = createScreenBuffer();
        if (stderr_handle == windows.INVALID_HANDLE_VALUE) {
            return error.ConsoleScreenBufferCreationFailed;
        }
        errdefer windows.CloseHandle(stderr_handle);

        const previous_stdout_handle = GetStdHandle(std_output_handle);
        const previous_stderr_handle = GetStdHandle(std_error_handle);

        if (!SetStdHandle(std_output_handle, stdout_handle).toBool()) {
            return error.SetStdHandleFailed;
        }
        errdefer {
            _ = SetStdHandle(std_output_handle, previous_stdout_handle);
        }

        if (!SetStdHandle(std_error_handle, stderr_handle).toBool()) {
            return error.SetStdHandleFailed;
        }

        return .{
            .stdout_handle = stdout_handle,
            .stderr_handle = stderr_handle,
            .previous_stdout_handle = previous_stdout_handle,
            .previous_stderr_handle = previous_stderr_handle,
            .allocated_console = allocated_console,
        };
    }

    fn deinit(capture: *ConsoleCapture) void {
        _ = SetStdHandle(std_output_handle, capture.previous_stdout_handle);
        _ = SetStdHandle(std_error_handle, capture.previous_stderr_handle);
        windows.CloseHandle(capture.stdout_handle);
        windows.CloseHandle(capture.stderr_handle);
        if (capture.allocated_console) _ = FreeConsole();
        capture.* = undefined;
    }

    fn readStdout(capture: *const ConsoleCapture, buffer: []windows.WCHAR) !usize {
        return readScreenBuffer(capture.stdout_handle, buffer);
    }

    fn readStderr(capture: *const ConsoleCapture, buffer: []windows.WCHAR) !usize {
        return readScreenBuffer(capture.stderr_handle, buffer);
    }
};

fn createScreenBuffer() windows.HANDLE {
    var security_attributes: windows.SECURITY_ATTRIBUTES = .{
        .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = .TRUE,
    };
    return CreateConsoleScreenBuffer(
        generic_read | generic_write,
        file_share_read | file_share_write,
        &security_attributes,
        console_textmode_buffer,
        null,
    );
}

fn readScreenBuffer(handle: windows.HANDLE, buffer: []windows.WCHAR) !usize {
    var info: ConsoleScreenBufferInfo = undefined;
    if (!GetConsoleScreenBufferInfo(handle, &info).toBool()) {
        return error.ConsoleScreenBufferReadFailed;
    }

    const width: usize = @intCast(info.size.X);
    const height: usize = @intCast(info.size.Y);
    const requested: windows.DWORD = @intCast(@min(buffer.len, width * height));
    var read: windows.DWORD = 0;
    if (!ReadConsoleOutputCharacterW(handle, buffer.ptr, requested, .{ .X = 0, .Y = 0 }, &read).toBool()) {
        return error.ConsoleScreenBufferReadFailed;
    }
    return @intCast(read);
}

fn containsAscii(haystack: []const windows.WCHAR, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;

    outer: for (0..haystack.len - needle.len + 1) |start| {
        for (needle, 0..) |character, offset| {
            if (haystack[start + offset] != @as(windows.WCHAR, character)) continue :outer;
        }
        return true;
    }
    return false;
}

fn writeFailure(io: std.Io, comptime format: []const u8, args: anytype) void {
    var stderr_buffer: [2048]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    stderr.print(format, args) catch {};
    stderr.flush() catch {};
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) {
        writeFailure(init.io, "usage: {s} <hutch-executable> <hutch-root>\n", .{args[0]});
        return error.InvalidArguments;
    }

    const dash_executable = args[1];
    const dash_root = args[2];
    const cottontail_path = if (environmentFlagEnabled(init.environ_map, "DASH_USE_LOCAL_COTTONTAIL"))
        try std.fs.path.join(allocator, &.{ dash_root, "..", "..", "cottontail", "zig-out", "bin", "cottontail.exe" })
    else
        try std.fs.path.join(allocator, &.{ dash_root, "vendors", "cottontail", "bin", "cottontail.exe" });
    std.Io.Dir.accessAbsolute(init.io, cottontail_path, .{}) catch {
        writeFailure(init.io, "Windows console regression requires vendored Cottontail at {s}\n", .{cottontail_path});
        return error.CottontailNotFound;
    };

    const temp_root = init.environ_map.get("TEMP") orelse init.environ_map.get("TMP") orelse {
        writeFailure(init.io, "Windows console regression could not resolve a temporary directory\n", .{});
        return error.TempDirectoryNotFound;
    };
    const script_name = try std.fmt.allocPrint(allocator, "hutch-console-child-{d}.ts", .{windows.GetCurrentProcessId()});
    const script_path = try std.fs.path.join(allocator, &.{ temp_root, script_name });
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = script_path,
        .data =
        \\console.log("hutch child stdout");
        \\console.error("hutch child stderr");
        \\process.exitCode = 23;
        ,
    });
    defer std.Io.Dir.deleteFileAbsolute(init.io, script_path) catch {};

    var capture = try ConsoleCapture.init();
    var capture_active = true;
    defer if (capture_active) capture.deinit();

    var child = try std.process.spawn(init.io, .{
        .argv = &.{ dash_executable, script_path },
        .cwd = .{ .path = dash_root },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    defer child.kill(init.io);

    const term = try child.wait(init.io);
    var stdout_buffer: [4096]windows.WCHAR = undefined;
    var stderr_buffer: [4096]windows.WCHAR = undefined;
    const stdout_length = try capture.readStdout(&stdout_buffer);
    const stderr_length = try capture.readStderr(&stderr_buffer);

    capture.deinit();
    capture_active = false;

    const exit_code = switch (term) {
        .exited => |code| code,
        else => {
            writeFailure(init.io, "Hutch console child terminated unexpectedly: {s}\n", .{@tagName(term)});
            return error.UnexpectedChildTermination;
        },
    };
    if (exit_code != expected_exit_code) {
        writeFailure(init.io, "Hutch console child exited {d}; expected {d}\n", .{ exit_code, expected_exit_code });
        return error.UnexpectedChildExitCode;
    }
    if (!containsAscii(stdout_buffer[0..stdout_length], stdout_sentinel)) {
        writeFailure(init.io, "Hutch console child stdout was not inherited by Cottontail\n", .{});
        return error.ChildStdoutNotInherited;
    }
    if (!containsAscii(stderr_buffer[0..stderr_length], stderr_sentinel)) {
        writeFailure(init.io, "Hutch console child stderr was not inherited by Cottontail\n", .{});
        return error.ChildStderrNotInherited;
    }
}
