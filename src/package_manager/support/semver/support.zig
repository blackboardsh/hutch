const std = @import("std");
const builtin = @import("builtin");

pub const Environment = struct {
    pub const allow_assert = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;
    pub const isDebug = builtin.mode == .Debug;
};

pub const strings = struct {
    pub const whitespace_chars = " \t\n\r\x0b\x0c";

    pub inline fn trim(input: []const u8, characters: []const u8) []const u8 {
        return std.mem.trim(u8, input, characters);
    }

    pub inline fn split(input: []const u8, delimiter: []const u8) std.mem.SplitIterator(u8, .sequence) {
        return std.mem.splitSequence(u8, input, delimiter);
    }

    pub inline fn order(lhs: []const u8, rhs: []const u8) std.math.Order {
        return std.mem.order(u8, lhs, rhs);
    }

    pub inline fn eql(lhs: []const u8, rhs: []const u8) bool {
        return std.mem.eql(u8, lhs, rhs);
    }

    pub inline fn containsChar(input: []const u8, character: u8) bool {
        return std.mem.indexOfScalar(u8, input, character) != null;
    }

    pub fn lengthOfLeadingWhitespaceASCII(input: []const u8) usize {
        for (input, 0..) |character, index| {
            if (!std.ascii.isWhitespace(character)) return index;
        }
        return input.len;
    }

    pub fn isAllASCII(input: []const u8) bool {
        for (input) |character| {
            if (!std.ascii.isASCII(character)) return false;
        }
        return true;
    }
};

pub const Output = struct {
    pub const enable_ansi_colors_stdout = false;

    pub inline fn prettyFmt(comptime format: []const u8, comptime _: bool) []const u8 {
        return format;
    }

    pub fn prettyErrorln(comptime format: []const u8, args: anytype) void {
        std.debug.print(format ++ "\n", args);
    }
};

pub inline fn isSliceInBuffer(slice: []const u8, buffer: []const u8) bool {
    const buffer_start = @intFromPtr(buffer.ptr);
    const buffer_end = buffer_start + buffer.len;
    const slice_start = @intFromPtr(slice.ptr);
    const slice_end = slice_start + slice.len;
    return slice_start >= buffer_start and slice_end <= buffer_end;
}

pub fn IdentityContext(comptime Key: type) type {
    return struct {
        pub fn hash(_: @This(), key: Key) u64 {
            return switch (comptime @typeInfo(Key)) {
                .@"enum" => @intFromEnum(key),
                .int => key,
                else => @compileError("unexpected identity context type"),
            };
        }

        pub fn eql(_: @This(), lhs: Key, rhs: Key) bool {
            return lhs == rhs;
        }
    };
}
