const std = @import("std");

const assert = std.debug.assert;
const mem = std.mem;

const primes = [_]u64{
    0xa0761d6478bd642f,
    0xe7037ed1a0b428db,
    0x8ebc6af09c88c6e3,
    0x589965cc75374cc3,
    0x1d8e4e27c47d124f,
};

fn readBytes(comptime bytes: u8, data: []const u8) u64 {
    const T = std.meta.Int(.unsigned, 8 * bytes);
    return mem.readInt(T, data[0..bytes], .little);
}

fn read8BytesSwapped(data: []const u8) u64 {
    return (readBytes(4, data) << 32) | readBytes(4, data[4..]);
}

fn mum(a: u64, b: u64) u64 {
    var result = std.math.mulWide(u64, a, b);
    result = (result >> 64) ^ result;
    return @as(u64, @truncate(result));
}

fn mix0(a: u64, b: u64, seed: u64) u64 {
    return mum(a ^ seed ^ primes[0], b ^ seed ^ primes[1]);
}

fn mix1(a: u64, b: u64, seed: u64) u64 {
    return mum(a ^ seed ^ primes[2], b ^ seed ^ primes[3]);
}

const WyhashStateless = struct {
    seed: u64,
    msg_len: usize,

    fn init(seed: u64) WyhashStateless {
        return .{
            .seed = seed,
            .msg_len = 0,
        };
    }

    inline fn round(self: *WyhashStateless, bytes: []const u8) void {
        assert(bytes.len == 32);
        self.seed = mix0(
            readBytes(8, bytes[0..]),
            readBytes(8, bytes[8..]),
            self.seed,
        ) ^ mix1(
            readBytes(8, bytes[16..]),
            readBytes(8, bytes[24..]),
            self.seed,
        );
    }

    inline fn update(self: *WyhashStateless, bytes: []const u8) void {
        assert(bytes.len % 32 == 0);

        var offset: usize = 0;
        while (offset < bytes.len) : (offset += 32) {
            self.round(bytes[offset .. offset + 32]);
        }
        self.msg_len += bytes.len;
    }

    inline fn final(self: *WyhashStateless, bytes: []const u8) u64 {
        assert(bytes.len < 32);

        const seed = self.seed;
        const remaining_length = @as(u5, @intCast(bytes.len));
        const remaining = bytes[0..remaining_length];

        self.seed = switch (remaining_length) {
            0 => seed,
            1 => mix0(readBytes(1, remaining), primes[4], seed),
            2 => mix0(readBytes(2, remaining), primes[4], seed),
            3 => mix0((readBytes(2, remaining) << 8) | readBytes(1, remaining[2..]), primes[4], seed),
            4 => mix0(readBytes(4, remaining), primes[4], seed),
            5 => mix0((readBytes(4, remaining) << 8) | readBytes(1, remaining[4..]), primes[4], seed),
            6 => mix0((readBytes(4, remaining) << 16) | readBytes(2, remaining[4..]), primes[4], seed),
            7 => mix0((readBytes(4, remaining) << 24) | (readBytes(2, remaining[4..]) << 8) | readBytes(1, remaining[6..]), primes[4], seed),
            8 => mix0(read8BytesSwapped(remaining), primes[4], seed),
            9 => mix0(read8BytesSwapped(remaining), readBytes(1, remaining[8..]), seed),
            10 => mix0(read8BytesSwapped(remaining), readBytes(2, remaining[8..]), seed),
            11 => mix0(read8BytesSwapped(remaining), (readBytes(2, remaining[8..]) << 8) | readBytes(1, remaining[10..]), seed),
            12 => mix0(read8BytesSwapped(remaining), readBytes(4, remaining[8..]), seed),
            13 => mix0(read8BytesSwapped(remaining), (readBytes(4, remaining[8..]) << 8) | readBytes(1, remaining[12..]), seed),
            14 => mix0(read8BytesSwapped(remaining), (readBytes(4, remaining[8..]) << 16) | readBytes(2, remaining[12..]), seed),
            15 => mix0(read8BytesSwapped(remaining), (readBytes(4, remaining[8..]) << 24) | (readBytes(2, remaining[12..]) << 8) | readBytes(1, remaining[14..]), seed),
            16 => mix0(read8BytesSwapped(remaining), read8BytesSwapped(remaining[8..]), seed),
            17 => mix0(read8BytesSwapped(remaining), read8BytesSwapped(remaining[8..]), seed) ^ mix1(readBytes(1, remaining[16..]), primes[4], seed),
            18 => mix0(read8BytesSwapped(remaining), read8BytesSwapped(remaining[8..]), seed) ^ mix1(readBytes(2, remaining[16..]), primes[4], seed),
            19 => mix0(read8BytesSwapped(remaining), read8BytesSwapped(remaining[8..]), seed) ^ mix1((readBytes(2, remaining[16..]) << 8) | readBytes(1, remaining[18..]), primes[4], seed),
            20 => mix0(read8BytesSwapped(remaining), read8BytesSwapped(remaining[8..]), seed) ^ mix1(readBytes(4, remaining[16..]), primes[4], seed),
            21 => mix0(read8BytesSwapped(remaining), read8BytesSwapped(remaining[8..]), seed) ^ mix1((readBytes(4, remaining[16..]) << 8) | readBytes(1, remaining[20..]), primes[4], seed),
            22 => mix0(read8BytesSwapped(remaining), read8BytesSwapped(remaining[8..]), seed) ^ mix1((readBytes(4, remaining[16..]) << 16) | readBytes(2, remaining[20..]), primes[4], seed),
            23 => mix0(read8BytesSwapped(remaining), read8BytesSwapped(remaining[8..]), seed) ^ mix1((readBytes(4, remaining[16..]) << 24) | (readBytes(2, remaining[20..]) << 8) | readBytes(1, remaining[22..]), primes[4], seed),
            24 => mix0(read8BytesSwapped(remaining), read8BytesSwapped(remaining[8..]), seed) ^ mix1(read8BytesSwapped(remaining[16..]), primes[4], seed),
            25 => mix0(read8BytesSwapped(remaining), read8BytesSwapped(remaining[8..]), seed) ^ mix1(read8BytesSwapped(remaining[16..]), readBytes(1, remaining[24..]), seed),
            26 => mix0(read8BytesSwapped(remaining), read8BytesSwapped(remaining[8..]), seed) ^ mix1(read8BytesSwapped(remaining[16..]), readBytes(2, remaining[24..]), seed),
            27 => mix0(read8BytesSwapped(remaining), read8BytesSwapped(remaining[8..]), seed) ^ mix1(read8BytesSwapped(remaining[16..]), (readBytes(2, remaining[24..]) << 8) | readBytes(1, remaining[26..]), seed),
            28 => mix0(read8BytesSwapped(remaining), read8BytesSwapped(remaining[8..]), seed) ^ mix1(read8BytesSwapped(remaining[16..]), readBytes(4, remaining[24..]), seed),
            29 => mix0(read8BytesSwapped(remaining), read8BytesSwapped(remaining[8..]), seed) ^ mix1(read8BytesSwapped(remaining[16..]), (readBytes(4, remaining[24..]) << 8) | readBytes(1, remaining[28..]), seed),
            30 => mix0(read8BytesSwapped(remaining), read8BytesSwapped(remaining[8..]), seed) ^ mix1(read8BytesSwapped(remaining[16..]), (readBytes(4, remaining[24..]) << 16) | readBytes(2, remaining[28..]), seed),
            31 => mix0(read8BytesSwapped(remaining), read8BytesSwapped(remaining[8..]), seed) ^ mix1(read8BytesSwapped(remaining[16..]), (readBytes(4, remaining[24..]) << 24) | (readBytes(2, remaining[28..]) << 8) | readBytes(1, remaining[30..]), seed),
        };

        self.msg_len += bytes.len;
        return mum(self.seed ^ self.msg_len, primes[4]);
    }

    fn hash(seed: u64, input: []const u8) u64 {
        const aligned_length = input.len - (input.len % 32);
        var hasher = WyhashStateless.init(seed);
        hasher.update(input[0..aligned_length]);
        return hasher.final(input[aligned_length..]);
    }
};

/// Bun's Zig-era Wyhash implementation. This intentionally differs from
/// newer std.hash.Wyhash revisions and must remain stable for cache keys.
pub const Wyhash11 = struct {
    state: WyhashStateless,
    buffer: [32]u8,
    buffer_length: usize,

    pub fn init(seed: u64) Wyhash11 {
        return .{
            .state = WyhashStateless.init(seed),
            .buffer = undefined,
            .buffer_length = 0,
        };
    }

    pub fn update(self: *Wyhash11, bytes: []const u8) void {
        var offset: usize = 0;

        if (self.buffer_length != 0 and self.buffer_length + bytes.len >= 32) {
            offset += 32 - self.buffer_length;
            mem.copyForwards(u8, self.buffer[self.buffer_length..], bytes[0..offset]);
            self.state.update(self.buffer[0..]);
            self.buffer_length = 0;
        }

        const remaining_length = bytes.len - offset;
        const aligned_length = remaining_length - (remaining_length % 32);
        self.state.update(bytes[offset .. offset + aligned_length]);

        mem.copyForwards(u8, self.buffer[self.buffer_length..], bytes[offset + aligned_length ..]);
        self.buffer_length += @as(u8, @intCast(bytes[offset + aligned_length ..].len));
    }

    pub fn final(self: *Wyhash11) u64 {
        return self.state.final(self.buffer[0..self.buffer_length]);
    }

    pub fn hash(seed: u64, input: []const u8) u64 {
        return WyhashStateless.hash(seed, input);
    }
};

test "Wyhash11 one-shot and streaming APIs agree across block boundaries" {
    const input = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
    const expected = Wyhash11.hash(42, input);

    var byte_at_a_time = Wyhash11.init(42);
    for (input) |byte| byte_at_a_time.update(&.{byte});
    try std.testing.expectEqual(expected, byte_at_a_time.final());

    var uneven_chunks = Wyhash11.init(42);
    uneven_chunks.update(input[0..7]);
    uneven_chunks.update(input[7..39]);
    uneven_chunks.update(input[39..]);
    try std.testing.expectEqual(expected, uneven_chunks.final());
}

test "Wyhash11 reference vectors" {
    try std.testing.expectEqual(@as(u64, 0), Wyhash11.hash(0, ""));
    try std.testing.expectEqual(@as(u64, 0x69f6286685d0d6e0), Wyhash11.hash(0, "a"));
    try std.testing.expectEqual(@as(u64, 0x58cd09ec70c64344), Wyhash11.hash(0, "hello"));
    try std.testing.expectEqual(
        @as(u64, 0x4aa6b5022662f91a),
        Wyhash11.hash(42, "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"),
    );
}
