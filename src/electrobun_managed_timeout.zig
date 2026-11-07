//! Bounds native Managed Deploys requests, including connection setup, body
//! transfer and response parsing, without running a JavaScript runtime.
const std = @import("std");

pub const request_timeout: std.Io.Duration = .fromSeconds(120);

fn Result(comptime function: anytype) type {
    return @typeInfo(@TypeOf(function)).@"fn".return_type.?;
}

fn Payload(comptime function: anytype) type {
    const Return = Result(function);
    return switch (@typeInfo(Return)) {
        .error_union => |info| info.payload,
        else => Return,
    };
}

/// Runs one request with a 120-second deadline. The function must cooperate with
/// std.Io cancellation and clean up request/connection handles in defer blocks.
/// Result allocations must belong to the command arena: a result that races the
/// timeout can be discarded. The caller's thread performs no allocations while
/// the function runs, so the request may safely use that same arena.
pub fn run(io: std.Io, comptime function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) anyerror!Payload(function) {
    return runWithTimeout(io, request_timeout, function, args);
}

pub fn runWithTimeout(io: std.Io, duration: std.Io.Duration, comptime function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) anyerror!Payload(function) {
    const Completion = union(enum) {
        operation: Result(function),
        timer: std.Io.Cancelable!void,
    };
    var completions: [2]Completion = undefined;
    var select: std.Io.Select(Completion) = .init(io, &completions);
    // Always join before args or the select's stack storage go out of scope.
    // This also guarantees HTTP defers have released the connection before the
    // caller touches or destroys its client/arena again.
    defer select.cancelDiscard();
    // async is insufficient here: a backend may run the operation inline,
    // preventing us from observing the timer until the request has completed.
    try select.concurrent(.timer, waitForDeadline, .{ io, duration });
    try select.concurrent(.operation, function, args);
    return switch (try select.await()) {
        .operation => |result| result,
        .timer => |result| blk: {
            try result;
            break :blk error.ManagedRequestTimedOut;
        },
    };
}

fn waitForDeadline(io: std.Io, duration: std.Io.Duration) std.Io.Cancelable!void {
    try io.sleep(duration, .boot);
}

test "successful request cancels its timer and preserves an arena-owned result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Operation = struct {
        fn call(allocator: std.mem.Allocator) ![]const u8 {
            return allocator.dupe(u8, "response");
        }
    };
    const result = try run(std.testing.io, Operation.call, .{arena.allocator()});
    try std.testing.expectEqualStrings("response", result);
}

test "request failure is returned without waiting for its timer" {
    const Operation = struct {
        fn call() error{RequestFailed}!void {
            return error.RequestFailed;
        }
    };
    try std.testing.expectError(error.RequestFailed, run(std.testing.io, Operation.call, .{}));
}

test "timeout cancels a blocked operation and waits for cleanup" {
    const Operation = struct {
        fn call(io: std.Io, cleaned_up: *std.atomic.Value(bool)) !void {
            defer cleaned_up.store(true, .release);
            try io.sleep(.fromSeconds(60), .boot);
        }
    };
    var cleaned_up: std.atomic.Value(bool) = .init(false);
    const started = std.Io.Clock.boot.now(std.testing.io);
    try std.testing.expectError(error.ManagedRequestTimedOut, runWithTimeout(std.testing.io, .fromMilliseconds(25), Operation.call, .{ std.testing.io, &cleaned_up }));
    try std.testing.expect(cleaned_up.load(.acquire));
    const elapsed = started.durationTo(std.Io.Clock.boot.now(std.testing.io));
    try std.testing.expect(elapsed.toMilliseconds() < 5_000);
}

test "plain value operations are also supported" {
    const Operation = struct {
        fn call(value: u32) u32 {
            return value + 1;
        }
    };
    try std.testing.expectEqual(@as(u32, 42), try run(std.testing.io, Operation.call, .{41}));
}
