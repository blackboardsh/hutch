const std = @import("std");
const cache_store = @import("cache_store.zig");

const help_text =
    "Usage:\n" ++
    "  hutch cache prune [--dry-run]\n" ++
    "  hutch cache clean --dry-run\n" ++
    "\n" ++
    "`prune` removes only unreachable Hutch-managed Electrobun and native\n" ++
    "toolchain objects after a 30-day grace period. `clean --dry-run` previews\n" ++
    "all unreachable managed objects without deleting them.\n";

pub fn run(
    init: std.process.Init,
    args: []const [:0]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    if (args.len == 0 or isHelp(args[0])) {
        try stdout.writeAll(help_text);
        return 0;
    }

    const operation = args[0];
    const prune = std.mem.eql(u8, operation, "prune");
    const clean = std.mem.eql(u8, operation, "clean");
    if (!prune and !clean) {
        try stderr.print("hutch cache: unknown command: {s}\n", .{operation});
        try stderr.writeAll(help_text);
        return 1;
    }

    var dry_run = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (isHelp(arg)) {
            try stdout.writeAll(help_text);
            return 0;
        } else {
            try stderr.print("hutch cache {s}: unknown option: {s}\n", .{ operation, arg });
            try stderr.writeAll(help_text);
            return 1;
        }
    }

    if (clean and !dry_run) {
        try stderr.writeAll("hutch cache clean is preview-only; pass --dry-run\n");
        return 1;
    }

    const result = cache_store.prune(init, init.arena.allocator(), .{
        .dry_run = dry_run,
        .grace_seconds = if (clean) 0 else cache_store.default_grace_seconds,
    }) catch |err| {
        try stderr.print("hutch cache {s}: {s}\n", .{ operation, @errorName(err) });
        return 1;
    };

    for (result.actions) |action| {
        try stdout.print("{s}: {s}\n", .{
            if (dry_run) "would prune" else "pruned",
            action.relative_root,
        });
    }
    try stdout.print(
        "cache {s}: scanned {d}, reachable {d}, grace-kept {d}, eligible {d}, pruned {d}, expired registrations {d}\n",
        .{
            if (dry_run) "preview" else "prune",
            result.scanned,
            result.reachable,
            result.grace_kept,
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

test "cache clean requires dry-run in the initial safety contract" {
    try std.testing.expect(std.mem.indexOf(u8, help_text, "cache clean --dry-run") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "30-day grace") != null);
}
