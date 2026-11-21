const std = @import("std");
const builtin = @import("builtin");

/// Electrobun builds stay on the host operating system. The selected CPU is
/// independent of the CPU running Hutch and its build-time tools.
pub const Target = struct {
    arch: std.Target.Cpu.Arch = builtin.cpu.arch,

    pub fn native() Target {
        return .{};
    }

    pub fn parse(value: []const u8) !Target {
        if (std.mem.eql(u8, value, "arm64")) return .{ .arch = .aarch64 };
        if (std.mem.eql(u8, value, "x64")) return .{ .arch = .x86_64 };
        return error.InvalidElectrobunTargetArchitecture;
    }

    pub fn isNative(self: Target) bool {
        return self.arch == builtin.cpu.arch;
    }

    pub fn archName(self: Target) []const u8 {
        return switch (self.arch) {
            .aarch64 => "arm64",
            .x86_64 => "x64",
            else => "unsupported",
        };
    }

    pub fn osName(_: Target) []const u8 {
        return switch (builtin.os.tag) {
            .macos => "macos",
            .linux => "linux",
            .windows => "win",
            else => "unsupported",
        };
    }

    pub fn releasePlatformName(_: Target) []const u8 {
        return switch (builtin.os.tag) {
            .macos => "darwin",
            .linux => "linux",
            .windows => "win",
            else => "unsupported",
        };
    }

    pub fn platformKey(self: Target) ![]const u8 {
        return switch (builtin.os.tag) {
            .macos => switch (self.arch) {
                .aarch64 => "macos-arm64",
                .x86_64 => "macos-x64",
                else => error.UnsupportedElectrobunPlatform,
            },
            .linux => switch (self.arch) {
                .aarch64 => "linux-arm64",
                .x86_64 => "linux-x64",
                else => error.UnsupportedElectrobunPlatform,
            },
            .windows => switch (self.arch) {
                .aarch64 => "windows-arm64",
                .x86_64 => "windows-x64",
                else => error.UnsupportedElectrobunPlatform,
            },
            else => error.UnsupportedElectrobunPlatform,
        };
    }
};

test "Electrobun targets select the CPU independently of the build host" {
    try std.testing.expectEqual(std.Target.Cpu.Arch.x86_64, (try Target.parse("x64")).arch);
    try std.testing.expectEqual(std.Target.Cpu.Arch.aarch64, (try Target.parse("arm64")).arch);
    try std.testing.expectError(error.InvalidElectrobunTargetArchitecture, Target.parse("x86"));
    try std.testing.expectError(error.InvalidElectrobunTargetArchitecture, Target.parse("linux-x64"));
    try std.testing.expect(Target.native().isNative());
}
