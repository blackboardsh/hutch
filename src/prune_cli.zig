const std = @import("std");
const managed_store = @import("managed_store.zig");

const help_text =
    "Usage:\n" ++
    "  hutch prune [--dry-run]\n" ++
    "\n" ++
    "Remove Hutch-managed releases and toolchains that are not in use.\n" ++
    "Manual pruning has no retention period; --dry-run only reports what\n" ++
    "would be removed.\n";

pub fn run(
    init: std.process.Init,
    args: []const [:0]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var dry_run = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (isHelp(arg)) {
            try stdout.writeAll(help_text);
            return 0;
        } else {
            try stderr.print("hutch prune: unknown option: {s}\n", .{arg});
            try stderr.writeAll(help_text);
            return 1;
        }
    }

    const result = managed_store.prune(init, init.arena.allocator(), .{
        .dry_run = dry_run,
    }) catch |err| {
        try stderr.print("hutch prune: {s}\n", .{@errorName(err)});
        return 1;
    };

    for (result.actions) |action| {
        try stdout.print("{s}: {s}\n", .{
            if (dry_run) "would prune" else "pruned",
            action.relative_root,
        });
    }
    try stdout.print(
        "prune {s}: scanned {d}, in use {d}, eligible {d}, pruned {d}, stale registrations {d}\n",
        .{
            if (dry_run) "preview" else "complete",
            result.scanned,
            result.reachable,
            result.eligible,
            result.pruned,
            result.expired_registrations,
        },
    );
    return 0;
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

test "prune is a top-level command with immediate manual cleanup" {
    try std.testing.expect(std.mem.indexOf(u8, help_text, "hutch prune [--dry-run]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "hutch cache") == null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "no retention period") != null);
}
