const std = @import("std");
const builtin = @import("builtin");

extern "kernel32" fn IsWow64Process2(
    process: std.os.windows.HANDLE,
    process_machine: *u16,
    native_machine: *u16,
) callconv(.winapi) std.os.windows.BOOL;

// Environment variables and os.machine report the emulated architecture in
// some x64 processes. Ask Windows about the physical host instead.
pub fn isX64OnArm64() bool {
    if (comptime builtin.os.tag != .windows or builtin.cpu.arch != .x86_64) return false;
    var process_machine: u16 = 0;
    var native_machine: u16 = 0;
    if (!IsWow64Process2(std.os.windows.GetCurrentProcess(), &process_machine, &native_machine).toBool()) return false;
    return native_machine == 0xaa64;
}

pub fn writeMigrationNotice(writer: anytype, emulated: bool, channel: []const u8, version: []const u8) !void {
    // The initial ARM64 release is canary-only. Do not suggest migrating a
    // production selection or an older exact release without ARM64 artifacts.
    if (!emulated or !std.mem.eql(u8, channel, "canary")) return;
    const selected = std.SemanticVersion.parse(version) catch return;
    const first_arm64 = std.SemanticVersion.parse("0.27.2-canary.1") catch unreachable;
    if (selected.order(first_arm64) == .lt) return;
    try writer.writeAll(
        "hutch: this x64 process is running on Windows ARM64. " ++
            "For the native canary, rerun the PowerShell installer with -Channel canary:\n" ++
            "  & ([scriptblock]::Create((irm https://hutch.blackboard.sh/hutch/install.ps1))) -Channel canary\n",
    );
}

test "migration notice requires an emulated process and an ARM64-capable canary" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeMigrationNotice(&output.writer, false, "canary", "0.27.2-canary.1");
    try writeMigrationNotice(&output.writer, true, "production", "0.27.2-canary.1");
    try writeMigrationNotice(&output.writer, true, "canary", "0.27.1");
    try writeMigrationNotice(&output.writer, true, "canary", "0.27.2-canary.0");
    try writeMigrationNotice(&output.writer, true, "canary", "invalid");
    try std.testing.expectEqualStrings("", output.written());
    try writeMigrationNotice(&output.writer, true, "canary", "0.27.2-canary.1");
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Windows ARM64") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "-Channel canary") != null);
}

test "native ARM64 does not need architecture migration" {
    if (comptime builtin.cpu.arch == .aarch64 or builtin.os.tag != .windows) {
        try std.testing.expect(!isX64OnArm64());
    }
}
