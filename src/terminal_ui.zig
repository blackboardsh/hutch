const std = @import("std");
const builtin = @import("builtin");

pub const Item = struct {
    label: []const u8,
    detail: []const u8 = "",
};

pub const SelectResult = union(enum) {
    selected: usize,
    cancelled,
    unavailable,
};

pub const PromptResult = union(enum) {
    value: []const u8,
    cancelled,
    unavailable,
};

const Key = enum {
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    enter,
    cancel,
    other,
};

const SelectionState = struct {
    cursor: usize = 0,
    first_visible: usize = 0,

    fn apply(state: *SelectionState, key: Key, item_count: usize, page_size: usize) ?SelectResult {
        if (item_count == 0) return .cancelled;

        switch (key) {
            .up => state.cursor = if (state.cursor == 0) item_count - 1 else state.cursor - 1,
            .down => state.cursor = if (state.cursor + 1 == item_count) 0 else state.cursor + 1,
            .home => state.cursor = 0,
            .end => state.cursor = item_count - 1,
            .page_up => state.cursor -|= @min(page_size, state.cursor),
            .page_down => state.cursor = @min(item_count - 1, state.cursor +| page_size),
            .enter => return .{ .selected = state.cursor },
            .cancel => return .cancelled,
            .other => return null,
        }
        state.keepVisible(item_count, page_size);
        return null;
    }

    fn keepVisible(state: *SelectionState, item_count: usize, page_size: usize) void {
        const visible = @max(@min(page_size, item_count), 1);
        if (state.cursor < state.first_visible) {
            state.first_visible = state.cursor;
        } else if (state.cursor >= state.first_visible + visible) {
            state.first_visible = state.cursor + 1 - visible;
        }
    }
};

const TerminalSize = struct {
    columns: usize = 80,
    rows: usize = 24,
};

pub fn select(
    init: std.process.Init,
    items: []const Item,
    title: []const u8,
) !SelectResult {
    if (items.len == 0) return .cancelled;
    if (!(std.Io.File.stdin().isTty(init.io) catch false) or
        !(std.Io.File.stdout().isTty(init.io) catch false))
    {
        return .unavailable;
    }

    var terminal = TerminalMode.enter(init.io) catch return .unavailable;
    defer terminal.restore();

    var output_buffer: [4096]u8 = undefined;
    var output_file = std.Io.File.stdout().writer(init.io, &output_buffer);
    const output = &output_file.interface;
    const size = terminal.size(init.environ_map);
    const page_size = @max(@min(items.len, size.rows -| 6), 1);
    const row_width = renderedRowWidth(items, size.columns);
    const frame_lines = page_size + 2;
    var state: SelectionState = .{};
    var rendered = false;
    var cursor_hidden = false;

    defer {
        if (rendered) clearFrame(output, frame_lines) catch {};
        if (cursor_hidden) output.writeAll("\x1b[?25h") catch {};
        output.flush() catch {};
    }

    try output.writeAll("\x1b[?25l");
    cursor_hidden = true;

    while (true) {
        if (rendered) try rewindFrame(output, frame_lines);
        try renderFrame(output, items, title, state, page_size, row_width);
        try output.flush();
        rendered = true;

        const key = try terminal.readKey();
        const result = state.apply(key, items.len, page_size) orelse continue;
        try clearFrame(output, frame_lines);
        rendered = false;
        try output.writeAll("\x1b[?25h");
        cursor_hidden = false;
        switch (result) {
            .selected => |index| try output.print("Selected {s}\n", .{items[index].label}),
            .cancelled => try output.writeAll("Cancelled\n"),
            .unavailable => unreachable,
        }
        try output.flush();
        return result;
    }
}

pub fn prompt(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    label: []const u8,
    suggested: []const u8,
) !PromptResult {
    if (!(std.Io.File.stdin().isTty(init.io) catch false) or
        !(std.Io.File.stdout().isTty(init.io) catch false))
    {
        return .unavailable;
    }

    var output_buffer: [1024]u8 = undefined;
    var output_file = std.Io.File.stdout().writer(init.io, &output_buffer);
    const output = &output_file.interface;
    try output.print("{s} [{s}]: ", .{ label, suggested });
    try output.flush();

    var input_buffer: [1024]u8 = undefined;
    var input_file = std.Io.File.stdin().readerStreaming(init.io, &input_buffer);
    const line = (input_file.interface.takeDelimiter('\n') catch null) orelse {
        try output.writeAll("\nCancelled\n");
        try output.flush();
        return .cancelled;
    };
    return .{ .value = try allocator.dupe(u8, promptValue(suggested, line)) };
}

fn promptValue(suggested: []const u8, input: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r");
    return if (trimmed.len == 0) suggested else trimmed;
}

fn renderedRowWidth(items: []const Item, terminal_columns: usize) usize {
    var width: usize = 4;
    for (items) |item| {
        const detail_width = if (item.detail.len == 0) 0 else item.detail.len + 2;
        width = @max(width, item.label.len + detail_width + 2);
    }
    return @min(width, @max(terminal_columns -| 1, 20));
}

fn renderFrame(
    writer: *std.Io.Writer,
    items: []const Item,
    title: []const u8,
    state: SelectionState,
    page_size: usize,
    row_width: usize,
) !void {
    try writer.print("{s}\n\n", .{title});
    const end = @min(items.len, state.first_visible + page_size);
    for (items[state.first_visible..end], state.first_visible..) |item, index| {
        try renderRow(writer, item, index == state.cursor, row_width);
    }
}

fn renderRow(writer: *std.Io.Writer, item: Item, selected: bool, row_width: usize) !void {
    if (selected) try writer.writeAll("\x1b[7m");
    try writer.writeAll(if (selected) "> " else "  ");

    const content_width = row_width -| 2;
    const detail_width = if (item.detail.len == 0) 0 else item.detail.len + 2;
    const label_limit = content_width -| detail_width;
    const label = item.label[0..@min(item.label.len, label_limit)];
    try writer.writeAll(label);

    var written = label.len;
    if (item.detail.len > 0 and written + detail_width <= content_width) {
        try writer.writeAll("  ");
        try writer.writeAll(item.detail);
        written += detail_width;
    }
    try writer.splatByteAll(' ', content_width -| written);
    if (selected) try writer.writeAll("\x1b[0m");
    try writer.writeByte('\n');
}

fn rewindFrame(writer: *std.Io.Writer, lines: usize) !void {
    try writer.print("\x1b[{d}A", .{lines});
}

fn clearFrame(writer: *std.Io.Writer, lines: usize) !void {
    try rewindFrame(writer, lines);
    for (0..lines) |_| try writer.writeAll("\r\x1b[2K\n");
    try rewindFrame(writer, lines);
}

const TerminalMode = if (builtin.os.tag == .windows) WindowsTerminal else PosixTerminal;

const PosixTerminal = if (builtin.os.tag == .windows) struct {} else struct {
    saved: std.posix.termios,

    fn enter(io: std.Io) !PosixTerminal {
        _ = io;
        const saved = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        var raw = saved;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, raw);
        return .{ .saved = saved };
    }

    fn restore(terminal: PosixTerminal) void {
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, terminal.saved) catch {};
    }

    fn size(_: PosixTerminal, environment: *const std.process.Environ.Map) TerminalSize {
        return sizeFromEnvironment(environment);
    }

    fn readKey(_: *PosixTerminal) !Key {
        const first = (try readByte(null)) orelse return .cancel;
        return switch (first) {
            3, 4 => .cancel,
            '\r', '\n' => .enter,
            'j', 'J' => .down,
            'k', 'K' => .up,
            27 => try readEscapeSequence(),
            else => .other,
        };
    }

    fn readEscapeSequence() !Key {
        const prefix = (try readByte(40)) orelse return .cancel;
        if (prefix != '[' and prefix != 'O') return .cancel;

        var sequence: [6]u8 = undefined;
        var length: usize = 0;
        while (length < sequence.len) {
            const byte = (try readByte(40)) orelse return .cancel;
            sequence[length] = byte;
            length += 1;
            switch (byte) {
                'A' => return .up,
                'B' => return .down,
                'H' => return .home,
                'F' => return .end,
                '~' => {
                    const number = std.fmt.parseUnsigned(u8, sequence[0 .. length - 1], 10) catch return .other;
                    return switch (number) {
                        1, 7 => .home,
                        4, 8 => .end,
                        5 => .page_up,
                        6 => .page_down,
                        else => .other,
                    };
                },
                else => {},
            }
        }
        return .other;
    }

    fn readByte(timeout_ms: ?i32) !?u8 {
        if (timeout_ms) |timeout| {
            var descriptors = [_]std.posix.pollfd{.{
                .fd = std.posix.STDIN_FILENO,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            if (try std.posix.poll(&descriptors, timeout) == 0) return null;
        }
        var buffer: [1]u8 = undefined;
        const count = try std.posix.read(std.posix.STDIN_FILENO, &buffer);
        return if (count == 1) buffer[0] else null;
    }
};

const WindowsTerminal = if (builtin.os.tag != .windows) struct {} else struct {
    const windows = std.os.windows;
    const std_input_handle: windows.DWORD = 0xfffffff6;
    const std_output_handle: windows.DWORD = 0xfffffff5;
    const key_event: windows.WORD = 0x0001;
    const enable_processed_input: windows.DWORD = 0x0001;
    const enable_line_input: windows.DWORD = 0x0002;
    const enable_echo_input: windows.DWORD = 0x0004;

    const Character = extern union {
        unicode: windows.WCHAR,
        ascii: windows.CHAR,
    };

    const KeyEventRecord = extern struct {
        key_down: windows.BOOL,
        repeat_count: windows.WORD,
        virtual_key_code: windows.WORD,
        virtual_scan_code: windows.WORD,
        character: Character,
        control_key_state: windows.DWORD,
    };

    const InputEvent = extern union {
        key: KeyEventRecord,
        storage: [16]u8,
    };

    const InputRecord = extern struct {
        event_type: windows.WORD,
        event: InputEvent,
    };

    extern "kernel32" fn GetStdHandle(std_handle: windows.DWORD) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn GetConsoleMode(handle: windows.HANDLE, mode: *windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn SetConsoleMode(handle: windows.HANDLE, mode: windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn ReadConsoleInputW(
        input: windows.HANDLE,
        records: [*]InputRecord,
        length: windows.DWORD,
        read: *windows.DWORD,
    ) callconv(.winapi) windows.BOOL;

    input: windows.HANDLE,
    output: windows.HANDLE,
    saved_input_mode: windows.DWORD,
    saved_output_mode: windows.DWORD,

    fn enter(io: std.Io) !WindowsTerminal {
        _ = io;
        const input = GetStdHandle(std_input_handle);
        const output = GetStdHandle(std_output_handle);
        if (input == windows.INVALID_HANDLE_VALUE or output == windows.INVALID_HANDLE_VALUE) {
            return error.TerminalUnavailable;
        }

        var input_mode: windows.DWORD = 0;
        var output_mode: windows.DWORD = 0;
        if (!GetConsoleMode(input, &input_mode).toBool() or
            !GetConsoleMode(output, &output_mode).toBool())
        {
            return error.TerminalUnavailable;
        }

        const raw_input = input_mode & ~(enable_processed_input | enable_line_input | enable_echo_input);
        if (!SetConsoleMode(input, raw_input).toBool()) return error.TerminalUnavailable;
        errdefer _ = SetConsoleMode(input, input_mode);
        if (!SetConsoleMode(output, output_mode | windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING).toBool()) {
            return error.TerminalUnavailable;
        }

        return .{
            .input = input,
            .output = output,
            .saved_input_mode = input_mode,
            .saved_output_mode = output_mode,
        };
    }

    fn restore(terminal: WindowsTerminal) void {
        _ = SetConsoleMode(terminal.input, terminal.saved_input_mode);
        _ = SetConsoleMode(terminal.output, terminal.saved_output_mode);
    }

    fn size(_: WindowsTerminal, environment: *const std.process.Environ.Map) TerminalSize {
        return sizeFromEnvironment(environment);
    }

    fn readKey(terminal: *WindowsTerminal) !Key {
        while (true) {
            var record: InputRecord = undefined;
            var count: windows.DWORD = 0;
            if (!ReadConsoleInputW(terminal.input, @ptrCast(&record), 1, &count).toBool()) {
                return error.TerminalReadFailed;
            }
            if (count == 0 or record.event_type != key_event or !record.event.key.key_down.toBool()) continue;

            return switch (record.event.key.virtual_key_code) {
                0x21 => .page_up,
                0x22 => .page_down,
                0x23 => .end,
                0x24 => .home,
                0x26 => .up,
                0x28 => .down,
                0x0d => .enter,
                0x1b => .cancel,
                else => switch (record.event.key.character.unicode) {
                    3, 4 => .cancel,
                    'j', 'J' => .down,
                    'k', 'K' => .up,
                    else => .other,
                },
            };
        }
    }
};

fn sizeFromEnvironment(environment: *const std.process.Environ.Map) TerminalSize {
    var result: TerminalSize = .{};
    if (environment.get("COLUMNS")) |value| {
        const parsed = std.fmt.parseUnsigned(usize, value, 10) catch 0;
        if (parsed >= 20) result.columns = parsed;
    }
    if (environment.get("LINES")) |value| {
        const parsed = std.fmt.parseUnsigned(usize, value, 10) catch 0;
        if (parsed >= 8) result.rows = parsed;
    }
    return result;
}

test "selection navigation wraps and keeps the cursor visible" {
    var state: SelectionState = .{};
    try std.testing.expect(state.apply(.up, 12, 4) == null);
    try std.testing.expectEqual(@as(usize, 11), state.cursor);
    try std.testing.expectEqual(@as(usize, 8), state.first_visible);

    _ = state.apply(.down, 12, 4);
    try std.testing.expectEqual(@as(usize, 0), state.cursor);
    try std.testing.expectEqual(@as(usize, 0), state.first_visible);

    _ = state.apply(.page_down, 12, 4);
    try std.testing.expectEqual(@as(usize, 4), state.cursor);
    try std.testing.expectEqual(@as(usize, 1), state.first_visible);
    try std.testing.expectEqual(SelectResult{ .selected = 4 }, state.apply(.enter, 12, 4).?);
}

test "selected rows use reverse video across the padded row" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try renderRow(&output.writer, .{ .label = "Hello", .detail = "cottontail" }, true, 24);
    try std.testing.expectEqualStrings(
        "\x1b[7m> Hello  cottontail     \x1b[0m\n",
        output.written(),
    );
}

test "text prompts accept their suggestion or a trimmed replacement" {
    try std.testing.expectEqualStrings("hello-world", promptValue("hello-world", "\r"));
    try std.testing.expectEqualStrings("my-app", promptValue("hello-world", "  my-app \r"));
}
