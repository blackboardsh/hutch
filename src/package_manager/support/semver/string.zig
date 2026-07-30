const std = @import("std");
const support = @import("support.zig");
const Wyhash11 = @import("wyhash.zig").Wyhash11;

const Allocator = std.mem.Allocator;
const string = []const u8;

/// String storage used by Bun's semver representation. Values up to eight
/// bytes are inline; longer values are offsets into a caller-owned buffer.
pub const String = extern struct {
    pub const max_inline_len: usize = 8;
    pub const empty: String = .{};

    bytes: [max_inline_len]u8 = .{0} ** max_inline_len,

    pub fn from(comptime value: []const u8) String {
        comptime {
            if (value.len > max_inline_len or
                (value.len == max_inline_len and value[max_inline_len - 1] >= 0x80))
            {
                @compileError("string constant too long to be inlined");
            }
        }
        return init(value, value);
    }

    pub const Formatter = struct {
        value: *const String,
        buffer: string,

        pub fn format(formatter: Formatter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll(formatter.value.slice(formatter.buffer));
        }
    };

    pub inline fn fmt(self: *const String, buffer: string) Formatter {
        return .{ .value = self, .buffer = buffer };
    }

    pub const StorePathFormatter = struct {
        value: *const String,
        buffer: string,

        pub fn format(formatter: StorePathFormatter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            for (formatter.value.slice(formatter.buffer)) |character| {
                try writer.writeByte(switch (character) {
                    '/', '\\', ':', '#' => '+',
                    else => character,
                });
            }
        }
    };

    pub inline fn fmtStorePath(self: *const String, buffer: string) StorePathFormatter {
        return .{ .value = self, .buffer = buffer };
    }

    pub fn Sorter(comptime direction: enum { asc, desc }) type {
        return struct {
            lhs_buffer: string,
            rhs_buffer: string,

            pub fn lessThan(context: @This(), lhs: String, rhs: String) bool {
                return lhs.order(&rhs, context.lhs_buffer, context.rhs_buffer) ==
                    if (comptime direction == .asc) .lt else .gt;
            }
        };
    }

    pub inline fn order(
        lhs: *const String,
        rhs: *const String,
        lhs_buffer: string,
        rhs_buffer: string,
    ) std.math.Order {
        return std.mem.order(u8, lhs.slice(lhs_buffer), rhs.slice(rhs_buffer));
    }

    pub inline fn canInline(value: string) bool {
        return switch (value.len) {
            0...max_inline_len - 1 => true,
            max_inline_len => value[max_inline_len - 1] & 0x80 == 0,
            else => false,
        };
    }

    pub inline fn isInline(self: String) bool {
        return self.bytes[max_inline_len - 1] & 0x80 == 0;
    }

    pub inline fn sliced(self: *const String, buffer: string) SlicedString {
        return if (self.isInline())
            SlicedString.init(self.slice(""), self.slice(""))
        else
            SlicedString.init(buffer, self.slice(buffer));
    }

    const max_addressable_space = u63;

    comptime {
        if (@sizeOf(usize) != 8) {
            @compileError("semver String requires a 64-bit target");
        }
    }

    pub const HashContext = struct {
        arg_buffer: string,
        existing_buffer: string,

        pub fn eql(context: HashContext, arg: String, existing: String) bool {
            return arg.eql(existing, context.arg_buffer, context.existing_buffer);
        }

        pub fn hash(context: HashContext, arg: String) u64 {
            return std.hash.Wyhash.hash(0, arg.slice(context.arg_buffer));
        }
    };

    pub const ArrayHashContext = struct {
        arg_buffer: string,
        existing_buffer: string,

        pub fn eql(context: ArrayHashContext, arg: String, existing: String, _: usize) bool {
            return arg.eql(existing, context.arg_buffer, context.existing_buffer);
        }

        pub fn hash(context: ArrayHashContext, arg: String) u32 {
            return @truncate(std.hash.Wyhash.hash(0, arg.slice(context.arg_buffer)));
        }
    };

    pub fn init(buffer: string, value: string) String {
        return switch (value.len) {
            0 => .{},
            1 => .{ .bytes = .{ value[0], 0, 0, 0, 0, 0, 0, 0 } },
            2 => .{ .bytes = .{ value[0], value[1], 0, 0, 0, 0, 0, 0 } },
            3 => .{ .bytes = .{ value[0], value[1], value[2], 0, 0, 0, 0, 0 } },
            4 => .{ .bytes = .{ value[0], value[1], value[2], value[3], 0, 0, 0, 0 } },
            5 => .{ .bytes = .{ value[0], value[1], value[2], value[3], value[4], 0, 0, 0 } },
            6 => .{ .bytes = .{ value[0], value[1], value[2], value[3], value[4], value[5], 0, 0 } },
            7 => .{ .bytes = .{ value[0], value[1], value[2], value[3], value[4], value[5], value[6], 0 } },
            max_inline_len => if (value[max_inline_len - 1] >= 0x80)
                initExternal(buffer, value)
            else
                .{ .bytes = .{
                    value[0], value[1], value[2], value[3],
                    value[4], value[5], value[6], value[7],
                } },
            else => initExternal(buffer, value),
        };
    }

    fn initExternal(buffer: string, value: string) String {
        return @bitCast((@as(u64, @as(
            max_addressable_space,
            @truncate(@as(u64, @bitCast(Pointer.init(buffer, value)))),
        ))) | (@as(u64, 1) << 63));
    }

    pub fn initInline(value: string) String {
        std.debug.assert(canInline(value));
        return switch (value.len) {
            0 => .{},
            1 => .{ .bytes = .{ value[0], 0, 0, 0, 0, 0, 0, 0 } },
            2 => .{ .bytes = .{ value[0], value[1], 0, 0, 0, 0, 0, 0 } },
            3 => .{ .bytes = .{ value[0], value[1], value[2], 0, 0, 0, 0, 0 } },
            4 => .{ .bytes = .{ value[0], value[1], value[2], value[3], 0, 0, 0, 0 } },
            5 => .{ .bytes = .{ value[0], value[1], value[2], value[3], value[4], 0, 0, 0 } },
            6 => .{ .bytes = .{ value[0], value[1], value[2], value[3], value[4], value[5], 0, 0 } },
            7 => .{ .bytes = .{ value[0], value[1], value[2], value[3], value[4], value[5], value[6], 0 } },
            8 => .{ .bytes = .{
                value[0], value[1], value[2], value[3],
                value[4], value[5], value[6], value[7],
            } },
            else => unreachable,
        };
    }

    pub fn initAppendIfNeeded(
        allocator: Allocator,
        buffer: *std.ArrayListUnmanaged(u8),
        value: string,
    ) Allocator.Error!String {
        if (canInline(value)) return initInline(value);
        return initAppend(allocator, buffer, value);
    }

    pub fn initAppend(
        allocator: Allocator,
        buffer: *std.ArrayListUnmanaged(u8),
        value: string,
    ) Allocator.Error!String {
        try buffer.appendSlice(allocator, value);
        const appended = buffer.items[buffer.items.len - value.len ..];
        return init(buffer.items, appended);
    }

    pub fn eql(self: String, other: String, self_buffer: string, other_buffer: string) bool {
        if (self.isInline() and other.isInline()) {
            return @as(u64, @bitCast(self.bytes)) == @as(u64, @bitCast(other.bytes));
        }
        if (self.isInline() != other.isInline()) return false;
        const lhs = self.ptr();
        const rhs = other.ptr();
        return std.mem.eql(
            u8,
            self_buffer[lhs.off..][0..lhs.len],
            other_buffer[rhs.off..][0..rhs.len],
        );
    }

    pub inline fn isEmpty(self: String) bool {
        return @as(u64, @bitCast(self.bytes)) == 0;
    }

    pub fn len(self: String) usize {
        if (!self.isInline()) return self.ptr().len;
        if (self.bytes[0] == 0) return 0;
        inline for (0..max_inline_len) |index| {
            if (self.bytes[index] == 0) return index;
        }
        return max_inline_len;
    }

    pub const Pointer = extern struct {
        off: u32 = 0,
        len: u32 = 0,

        pub fn init(buffer: string, value: string) Pointer {
            if (support.Environment.allow_assert) {
                std.debug.assert(support.isSliceInBuffer(value, buffer));
            }
            return .{
                .off = @truncate(@intFromPtr(value.ptr) - @intFromPtr(buffer.ptr)),
                .len = @truncate(value.len),
            };
        }
    };

    pub inline fn ptr(self: String) Pointer {
        return @bitCast(@as(u64, @as(u63, @truncate(@as(u64, @bitCast(self))))));
    }

    /// Must receive a pointer because inline values are sliced from their own storage.
    pub fn slice(self: *const String, buffer: string) string {
        if (!self.isInline()) {
            const pointer = self.ptr();
            return buffer[pointer.off..][0..pointer.len];
        }
        if (self.bytes[0] == 0) return "";
        inline for (0..max_inline_len) |index| {
            if (self.bytes[index] == 0) return self.bytes[0..index];
        }
        return &self.bytes;
    }

    pub const Builder = struct {
        len: usize = 0,
        cap: usize = 0,
        ptr: ?[*]u8 = null,
        string_pool: StringPool = undefined,

        pub const StringPool = std.HashMap(u64, String, support.IdentityContext(u64), 80);

        pub inline fn stringHash(value: string) u64 {
            return Wyhash11.hash(0, value);
        }

        pub inline fn count(self: *Builder, value: string) void {
            self.countWithHash(
                value,
                if (value.len >= String.max_inline_len) stringHash(value) else std.math.maxInt(u64),
            );
        }

        pub inline fn countWithHash(self: *Builder, value: string, hash: u64) void {
            if (value.len <= String.max_inline_len) return;
            if (!self.string_pool.contains(hash)) self.cap += value.len;
        }

        pub inline fn allocatedSlice(self: *Builder) []u8 {
            return if (self.cap == 0) &.{} else self.ptr.?[0..self.cap];
        }

        pub fn allocate(self: *Builder, allocator: Allocator) Allocator.Error!void {
            const allocation = try allocator.alloc(u8, self.cap);
            self.ptr = allocation.ptr;
        }

        pub fn append(self: *Builder, comptime Type: type, value: string) Type {
            return self.appendWithHash(Type, value, stringHash(value));
        }

        pub fn appendUTF8WithoutPool(
            self: *Builder,
            comptime Type: type,
            value: string,
            hash: u64,
        ) Type {
            if (value.len <= String.max_inline_len and support.strings.isAllASCII(value)) {
                return make(Type, self.allocatedSlice(), value, hash);
            }
            return self.appendWithoutPool(Type, value, hash);
        }

        pub fn appendWithoutPool(
            self: *Builder,
            comptime Type: type,
            value: string,
            hash: u64,
        ) Type {
            if (String.canInline(value)) return make(Type, self.allocatedSlice(), value, hash);

            std.debug.assert(self.len + value.len <= self.cap);
            @memcpy(self.ptr.?[self.len..][0..value.len], value);
            const final_value = self.ptr.?[self.len..][0..value.len];
            self.len += value.len;
            return make(Type, self.allocatedSlice(), final_value, hash);
        }

        pub fn appendWithHash(
            self: *Builder,
            comptime Type: type,
            value: string,
            hash: u64,
        ) Type {
            if (String.canInline(value)) return make(Type, self.allocatedSlice(), value, hash);

            std.debug.assert(self.len <= self.cap);
            const entry = self.string_pool.getOrPut(hash) catch unreachable;
            if (!entry.found_existing) {
                std.debug.assert(self.len + value.len <= self.cap);
                @memcpy(self.ptr.?[self.len..][0..value.len], value);
                const final_value = self.ptr.?[self.len..][0..value.len];
                self.len += value.len;
                entry.value_ptr.* = String.init(self.allocatedSlice(), final_value);
            }

            return switch (Type) {
                String => entry.value_ptr.*,
                ExternalString => .{ .value = entry.value_ptr.*, .hash = hash },
                else => @compileError("invalid semver string builder output type"),
            };
        }

        fn make(comptime Type: type, buffer: string, value: string, hash: u64) Type {
            return switch (Type) {
                String => String.init(buffer, value),
                ExternalString => ExternalString.init(buffer, value, hash),
                else => @compileError("invalid semver string builder output type"),
            };
        }
    };

    comptime {
        if (@sizeOf(String) != @sizeOf(Pointer)) {
            @compileError("semver string and pointer representations must match");
        }
    }
};

pub const ExternalString = extern struct {
    value: String = .{},
    hash: u64 = 0,

    pub inline fn fmt(self: *const ExternalString, buffer: string) String.Formatter {
        return self.value.fmt(buffer);
    }

    pub fn order(
        lhs: *const ExternalString,
        rhs: *const ExternalString,
        lhs_buffer: string,
        rhs_buffer: string,
    ) std.math.Order {
        if (lhs.hash == rhs.hash and lhs.hash > 0) return .eq;
        return lhs.value.order(&rhs.value, lhs_buffer, rhs_buffer);
    }

    pub inline fn from(value: string) ExternalString {
        return .{
            .value = String.init(value, value),
            .hash = std.hash.Wyhash.hash(0, value),
        };
    }

    pub inline fn isInline(self: ExternalString) bool {
        return self.value.isInline();
    }

    pub inline fn isEmpty(self: ExternalString) bool {
        return self.value.isEmpty();
    }

    pub inline fn len(self: ExternalString) usize {
        return self.value.len();
    }

    pub inline fn init(buffer: string, value: string, hash: u64) ExternalString {
        return .{ .value = String.init(buffer, value), .hash = hash };
    }

    pub inline fn slice(self: *const ExternalString, buffer: string) string {
        return self.value.slice(buffer);
    }
};

pub const SlicedString = struct {
    buf: string,
    slice: string,

    pub inline fn init(buffer: string, input: string) SlicedString {
        if (support.Environment.allow_assert and !@inComptime()) {
            std.debug.assert(@intFromPtr(buffer.ptr) <= @intFromPtr(input.ptr));
        }
        return .{ .buf = buffer, .slice = input };
    }

    pub inline fn external(self: SlicedString) ExternalString {
        if (support.Environment.allow_assert) {
            std.debug.assert(support.isSliceInBuffer(self.slice, self.buf));
        }
        return ExternalString.init(self.buf, self.slice, Wyhash11.hash(0, self.slice));
    }

    pub inline fn value(self: SlicedString) String {
        if (support.Environment.allow_assert) {
            std.debug.assert(support.isSliceInBuffer(self.slice, self.buf));
        }
        return String.init(self.buf, self.slice);
    }

    pub inline fn sub(self: SlicedString, value_: string) SlicedString {
        if (support.Environment.allow_assert) {
            std.debug.assert(support.isSliceInBuffer(value_, self.buf));
        }
        return .{ .buf = self.buf, .slice = value_ };
    }
};
