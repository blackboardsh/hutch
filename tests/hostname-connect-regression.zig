const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const IpAddress = Io.net.IpAddress;
const Socket = Io.net.Socket;
const Stream = Io.net.Stream;

fn durationMilliseconds(from: Io.Clock.Timestamp, to: Io.Clock.Timestamp) i64 {
    return from.durationTo(to).raw.toMilliseconds();
}

fn connectAndClose(address: IpAddress, io: Io) IpAddress.ConnectError!void {
    const stream = try address.connect(io, .{ .mode = .stream });
    stream.close(io);
}

fn openFdCount(io: Io) !usize {
    var directory = try Io.Dir.openDirAbsolute(io, "/proc/self/fd", .{ .iterate = true });
    defer directory.close(io);
    var iterator = directory.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |_| count += 1;
    return count;
}

var fake_lookup_addresses: [2]IpAddress = undefined;
var fake_lookup_repetitions: usize = 1;
var fake_lookup_delay: Io.Clock.Duration = .{ .raw = .zero, .clock = .awake };
var fake_connect_started: std.atomic.Value(usize) = .init(0);
var fake_connect_active: std.atomic.Value(usize) = .init(0);
var fake_connect_peak: std.atomic.Value(usize) = .init(0);

fn fakeNetLookup(
    userdata: ?*anyopaque,
    host_name: Io.net.HostName,
    resolved: *Io.Queue(Io.net.HostName.LookupResult),
    options: Io.net.HostName.LookupOptions,
) Io.net.HostName.LookupError!void {
    const threaded: *Io.Threaded = @ptrCast(@alignCast(userdata));
    const io = threaded.io();
    defer resolved.close(io);

    for (0..fake_lookup_repetitions) |_| {
        for (fake_lookup_addresses) |template| {
            var address = template;
            address.setPort(options.port);
            resolved.putOne(io, .{ .address = address }) catch |err| switch (err) {
                error.Canceled => |e| return e,
                error.Closed => unreachable,
            };
        }
    }
    try fake_lookup_delay.sleep(io);
    if (options.canonical_name_buffer) |buffer| {
        const canonical_bytes = buffer[0..host_name.bytes.len];
        @memcpy(canonical_bytes, host_name.bytes);
        resolved.putOne(io, .{ .canonical_name = .{ .bytes = canonical_bytes } }) catch |err| switch (err) {
            error.Canceled => |e| return e,
            error.Closed => unreachable,
        };
    }
}

fn fakeNetConnectIp(
    userdata: ?*anyopaque,
    address: *const IpAddress,
    options: IpAddress.ConnectOptions,
) IpAddress.ConnectError!Socket {
    _ = address;
    _ = options;
    const threaded: *Io.Threaded = @ptrCast(@alignCast(userdata));
    const io = threaded.io();
    _ = fake_connect_started.fetchAdd(1, .monotonic);
    const active = fake_connect_active.fetchAdd(1, .monotonic) + 1;
    defer _ = fake_connect_active.fetchSub(1, .monotonic);

    var peak = fake_connect_peak.load(.monotonic);
    while (active > peak) {
        if (fake_connect_peak.cmpxchgWeak(peak, active, .monotonic, .monotonic)) |actual| {
            peak = actual;
        } else break;
    }

    try Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(10), .clock = .awake }, io);
    return error.ConnectionRefused;
}

test "HostName.connect races localhost addresses and returns a usable winner" {
    // Force Io.async's eager fallback. HostName.connect must still use real
    // concurrency so a nested package-manager fetch can consume the first
    // successful address without waiting for every loser.
    var threaded: Io.Threaded = .init(std.testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    const io = threaded.io();

    var listen_address: IpAddress = .{ .ip4 = .loopback(0) };
    var server = try listen_address.listen(io, .{ .kernel_backlog = 64 });
    defer server.deinit(io);

    const host_name: Io.net.HostName = try .init("localhost");
    const fd_count_before = if (builtin.os.tag == .linux) try openFdCount(io) else 0;
    for (0..8) |_| {
        const stream = try host_name.connect(io, server.socket.address.getPort(), .{ .mode = .stream });
        stream.close(io);
    }
    if (builtin.os.tag == .linux) {
        try std.testing.expectEqual(fd_count_before, try openFdCount(io));
    }
}

test "HostName.connect returns before a blackholed loser and closes it" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var threaded: Io.Threaded = .init(std.testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    const threaded_io = threaded.io();
    var fake_vtable: Io.VTable = threaded_io.vtable.*;
    fake_vtable.netLookup = fakeNetLookup;
    const io: Io = .{ .userdata = threaded_io.userdata, .vtable = &fake_vtable };

    var loser_address: IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 2 }, .port = 0 } };
    var loser_server = try loser_address.listen(io, .{ .kernel_backlog = 1 });
    defer loser_server.deinit(io);
    const port = loser_server.socket.address.getPort();

    var winner_address: IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } };
    var winner_server = try winner_address.listen(io, .{ .kernel_backlog = 8 });
    defer winner_server.deinit(io);

    fake_lookup_addresses = .{
        loser_server.socket.address,
        winner_server.socket.address,
    };
    fake_lookup_repetitions = 1;
    fake_lookup_delay = .{ .raw = .fromSeconds(5), .clock = .awake };

    var fillers: [2]Stream = undefined;
    var fillers_len: usize = 0;
    defer for (fillers[0..fillers_len]) |stream| stream.close(io);
    while (fillers_len < fillers.len) : (fillers_len += 1) {
        fillers[fillers_len] = try loser_server.socket.address.connect(io, .{
            .mode = .stream,
            .timeout = .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } },
        });
    }

    const fd_count_before = try openFdCount(io);
    const start = Io.Clock.Timestamp.now(io, .awake);
    const host_name: Io.net.HostName = try .init("blackhole.test");
    const winner = try host_name.connect(io, port, .{ .mode = .stream });
    winner.close(io);
    const elapsed = durationMilliseconds(start, Io.Clock.Timestamp.now(io, .awake));

    try std.testing.expect(elapsed < 2_000);
    try std.testing.expectEqual(fd_count_before, try openFdCount(io));
}

test "HostName.connect caps address attempts and worker concurrency" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    const threaded_io = threaded.io();
    var fake_vtable: Io.VTable = threaded_io.vtable.*;
    fake_vtable.netLookup = fakeNetLookup;
    fake_vtable.netConnectIp = fakeNetConnectIp;
    const io: Io = .{ .userdata = threaded_io.userdata, .vtable = &fake_vtable };

    fake_lookup_addresses = .{
        .{ .ip4 = .loopback(0) },
        .{ .ip4 = .loopback(0) },
    };
    fake_lookup_repetitions = 32;
    fake_lookup_delay = .{ .raw = .zero, .clock = .awake };
    fake_connect_started.store(0, .monotonic);
    fake_connect_active.store(0, .monotonic);
    fake_connect_peak.store(0, .monotonic);

    const host_name: Io.net.HostName = try .init("bounded.test");
    try std.testing.expectError(error.ConnectionRefused, host_name.connect(io, 443, .{ .mode = .stream }));
    try std.testing.expectEqual(@as(usize, 32), fake_connect_started.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), fake_connect_active.load(.monotonic));
    try std.testing.expect(fake_connect_peak.load(.monotonic) > 1);
    try std.testing.expect(fake_connect_peak.load(.monotonic) <= 4);
}

test "Threaded POSIX connect timeout and cancellation settle blackholed sockets" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A listening socket with backlog 1 queues two loopback handshakes on
    // Linux without accept(). Further connects remain pending, giving this
    // test a local and deterministic blackhole with no firewall privileges.
    var listen_address: IpAddress = .{ .ip4 = .loopback(0) };
    var server = try listen_address.listen(io, .{ .kernel_backlog = 1 });
    defer server.deinit(io);
    const target = server.socket.address;

    var fillers: [2]Stream = undefined;
    var fillers_len: usize = 0;
    defer for (fillers[0..fillers_len]) |stream| stream.close(io);
    while (fillers_len < fillers.len) : (fillers_len += 1) {
        fillers[fillers_len] = try target.connect(io, .{
            .mode = .stream,
            .timeout = .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } },
        });
    }
    const fd_count_before = try openFdCount(io);

    const timeout_start = Io.Clock.Timestamp.now(io, .awake);
    try std.testing.expectError(error.Timeout, target.connect(io, .{
        .mode = .stream,
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(150), .clock = .awake } },
    }));
    const timeout_elapsed = durationMilliseconds(timeout_start, Io.Clock.Timestamp.now(io, .awake));
    try std.testing.expect(timeout_elapsed >= 50);
    try std.testing.expect(timeout_elapsed < 2_000);

    var pending = try io.concurrent(connectAndClose, .{ target, io });
    try Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(100), .clock = .awake }, io);
    const cancel_start = Io.Clock.Timestamp.now(io, .awake);
    try std.testing.expectError(error.Canceled, pending.cancel(io));
    const cancel_elapsed = durationMilliseconds(cancel_start, Io.Clock.Timestamp.now(io, .awake));
    try std.testing.expect(cancel_elapsed < 2_000);

    try std.testing.expectEqual(fd_count_before, try openFdCount(io));
}
