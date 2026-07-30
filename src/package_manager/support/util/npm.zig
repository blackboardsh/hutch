const std = @import("std");
const builtin = @import("builtin");

pub fn Negatable(comptime T: type) type {
    return struct {
        added: T = T.none,
        removed: T = T.none,
        had_wildcard: bool = false,
        had_unrecognized_values: bool = false,

        pub fn combine(self: @This()) T {
            const added = if (self.had_wildcard) T.all_value else @intFromEnum(self.added);
            const removed = @intFromEnum(self.removed);

            if (added == 0 and removed == 0) {
                if (self.had_unrecognized_values) return T.none;
                return T.all;
            }
            if (added == 0) return @enumFromInt(T.all_value & ~removed);
            if (removed == 0) return @enumFromInt(added);
            return @enumFromInt(added & ~removed);
        }

        pub fn apply(self: *@This(), value: []const u8) void {
            if (value.len == 0) return;

            if (std.mem.eql(u8, value, "any")) {
                self.had_wildcard = true;
                return;
            }
            if (std.mem.eql(u8, value, "none")) {
                self.had_unrecognized_values = true;
                return;
            }

            const negated = value[0] == '!';
            const offset: usize = @intFromBool(negated);
            const field = T.NameMap.get(value[offset..]) orelse {
                if (!negated) self.had_unrecognized_values = true;
                return;
            };

            if (negated) {
                self.* = .{
                    .added = self.added,
                    .removed = @enumFromInt(@intFromEnum(self.removed) | field),
                };
            } else {
                self.* = .{
                    .added = @enumFromInt(@intFromEnum(self.added) | field),
                    .removed = self.removed,
                };
            }
        }
    };
}

pub const OperatingSystem = enum(u16) {
    none = 0,
    all = all_value,
    _,

    pub const aix: u16 = 1 << 1;
    pub const darwin: u16 = 1 << 2;
    pub const freebsd: u16 = 1 << 3;
    pub const linux: u16 = 1 << 4;
    pub const openbsd: u16 = 1 << 5;
    pub const sunos: u16 = 1 << 6;
    pub const win32: u16 = 1 << 7;
    pub const android: u16 = 1 << 8;
    pub const all_value: u16 = aix | darwin | freebsd | linux | openbsd | sunos | win32 | android;

    pub const NameMap = std.StaticStringMap(u16).initComptime(.{
        .{ "aix", aix },
        .{ "darwin", darwin },
        .{ "freebsd", freebsd },
        .{ "linux", linux },
        .{ "openbsd", openbsd },
        .{ "sunos", sunos },
        .{ "win32", win32 },
        .{ "android", android },
    });

    pub const current: OperatingSystem = switch (builtin.os.tag) {
        .linux => @enumFromInt(if (builtin.target.abi.isAndroid()) android else linux),
        .macos => @enumFromInt(darwin),
        .windows => @enumFromInt(win32),
        .freebsd => @enumFromInt(freebsd),
        else => @compileError("unsupported npm operating system: " ++ @tagName(builtin.os.tag)),
    };

    pub const current_name = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "darwin",
        .windows => "win32",
        .freebsd => "freebsd",
        else => @compileError("unsupported npm operating system: " ++ @tagName(builtin.os.tag)),
    };

    pub fn isMatch(self: OperatingSystem, target: OperatingSystem) bool {
        return (@intFromEnum(self) & @intFromEnum(target)) != 0;
    }

    pub inline fn has(self: OperatingSystem, other: u16) bool {
        return (@intFromEnum(self) & other) != 0;
    }

    pub fn negatable(self: OperatingSystem) Negatable(OperatingSystem) {
        return .{ .added = self };
    }
};

pub const Libc = enum(u8) {
    none = 0,
    all = all_value,
    _,

    pub const glibc: u8 = 1 << 1;
    pub const musl: u8 = 1 << 2;
    pub const all_value: u8 = glibc | musl;

    pub const NameMap = std.StaticStringMap(u8).initComptime(.{
        .{ "glibc", glibc },
        .{ "musl", musl },
    });

    pub const current: Libc = if (builtin.os.tag == .linux) @enumFromInt(glibc) else .none;

    pub fn isMatch(self: Libc, target: Libc) bool {
        return (@intFromEnum(self) & @intFromEnum(target)) != 0;
    }

    pub inline fn has(self: Libc, other: u8) bool {
        return (@intFromEnum(self) & other) != 0;
    }

    pub fn negatable(self: Libc) Negatable(Libc) {
        return .{ .added = self };
    }
};

pub const Architecture = enum(u16) {
    none = 0,
    all = all_value,
    _,

    pub const arm: u16 = 1 << 1;
    pub const arm64: u16 = 1 << 2;
    pub const ia32: u16 = 1 << 3;
    pub const mips: u16 = 1 << 4;
    pub const mipsel: u16 = 1 << 5;
    pub const ppc: u16 = 1 << 6;
    pub const ppc64: u16 = 1 << 7;
    pub const s390: u16 = 1 << 8;
    pub const s390x: u16 = 1 << 9;
    pub const x32: u16 = 1 << 10;
    pub const x64: u16 = 1 << 11;
    pub const all_value: u16 = arm | arm64 | ia32 | mips | mipsel | ppc | ppc64 | s390 | s390x | x32 | x64;

    pub const NameMap = std.StaticStringMap(u16).initComptime(.{
        .{ "arm", arm },
        .{ "arm64", arm64 },
        .{ "ia32", ia32 },
        .{ "mips", mips },
        .{ "mipsel", mipsel },
        .{ "ppc", ppc },
        .{ "ppc64", ppc64 },
        .{ "s390", s390 },
        .{ "s390x", s390x },
        .{ "x32", x32 },
        .{ "x64", x64 },
    });

    pub const current: Architecture = switch (builtin.cpu.arch) {
        .aarch64 => @enumFromInt(arm64),
        .x86_64 => @enumFromInt(x64),
        else => @compileError("unsupported npm architecture: " ++ @tagName(builtin.cpu.arch)),
    };

    pub const current_name = switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x64",
        else => @compileError("unsupported npm architecture: " ++ @tagName(builtin.cpu.arch)),
    };

    pub fn isMatch(self: Architecture, target: Architecture) bool {
        return (@intFromEnum(self) & @intFromEnum(target)) != 0;
    }

    pub inline fn has(self: Architecture, other: u16) bool {
        return (@intFromEnum(self) & other) != 0;
    }

    pub fn negatable(self: Architecture) Negatable(Architecture) {
        return .{ .added = self };
    }
};

test "Negatable includes and excludes Bun npm platform sets" {
    var included = OperatingSystem.none.negatable();
    included.apply("linux");
    included.apply("darwin");
    const included_set = included.combine();
    try std.testing.expect(included_set.has(OperatingSystem.linux));
    try std.testing.expect(included_set.has(OperatingSystem.darwin));
    try std.testing.expect(!included_set.has(OperatingSystem.win32));

    var excluded = OperatingSystem.none.negatable();
    excluded.apply("!linux");
    const excluded_set = excluded.combine();
    try std.testing.expect(!excluded_set.has(OperatingSystem.linux));
    try std.testing.expect(excluded_set.has(OperatingSystem.darwin));
}

test "Negatable preserves Bun wildcard and unknown-value behavior" {
    var empty = Architecture.none.negatable();
    try std.testing.expectEqual(Architecture.all, empty.combine());

    var wildcard = Architecture.none.negatable();
    wildcard.apply("any");
    try std.testing.expectEqual(Architecture.all, wildcard.combine());

    var unknown = Architecture.none.negatable();
    unknown.apply("sparc");
    try std.testing.expectEqual(Architecture.none, unknown.combine());

    var unknown_exclusion = Architecture.none.negatable();
    unknown_exclusion.apply("!sparc");
    try std.testing.expectEqual(Architecture.all, unknown_exclusion.combine());
}

test "npm platform current values match the compilation target" {
    try std.testing.expect(OperatingSystem.current.isMatch(OperatingSystem.current));
    try std.testing.expect(Architecture.current.isMatch(Architecture.current));
    if (builtin.os.tag == .linux) {
        try std.testing.expectEqual(Libc.current, @as(Libc, @enumFromInt(Libc.glibc)));
    } else {
        try std.testing.expectEqual(Libc.none, Libc.current);
    }
}
