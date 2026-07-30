const std = @import("std");

fn parseDigits(value: []const u8, start: usize, count: usize) !i64 {
    if (start + count > value.len) return error.InvalidDate;
    var result: i64 = 0;
    for (value[start .. start + count]) |character| {
        if (character < '0' or character > '9') return error.InvalidDate;
        result = result * 10 + character - '0';
    }
    return result;
}

fn daysFromCivil(year_input: i64, month: i64, day: i64) i64 {
    const year = year_input - @intFromBool(month <= 2);
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const shifted_month = month + (if (month > 2) @as(i64, -3) else 9);
    const day_of_year = @divFloor(153 * shifted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

/// Parses the ISO-form timestamps consumed from npm registry publication
/// metadata, returning milliseconds since the Unix epoch.
pub fn parseES5Date(value: []const u8) !f64 {
    if (value.len < 20 or value[4] != '-' or value[7] != '-' or
        (value[10] != 'T' and value[10] != 't' and value[10] != ' ') or
        value[13] != ':' or value[16] != ':')
    {
        return error.InvalidDate;
    }

    const year = try parseDigits(value, 0, 4);
    const month = try parseDigits(value, 5, 2);
    const day = try parseDigits(value, 8, 2);
    const hour = try parseDigits(value, 11, 2);
    const minute = try parseDigits(value, 14, 2);
    const second = try parseDigits(value, 17, 2);
    if (month < 1 or month > 12 or day < 1 or day > 31 or
        hour > 23 or minute > 59 or second > 59)
    {
        return error.InvalidDate;
    }

    var index: usize = 19;
    var milliseconds: i64 = 0;
    if (index < value.len and value[index] == '.') {
        index += 1;
        var digits: usize = 0;
        while (index < value.len and value[index] >= '0' and value[index] <= '9') : (index += 1) {
            if (digits < 3) milliseconds = milliseconds * 10 + value[index] - '0';
            digits += 1;
        }
        if (digits == 0) return error.InvalidDate;
        while (digits < 3) : (digits += 1) milliseconds *= 10;
    }

    var timezone_offset_minutes: i64 = 0;
    if (index >= value.len) return error.InvalidDate;
    if (value[index] == 'Z' or value[index] == 'z') {
        index += 1;
    } else if (value[index] == '+' or value[index] == '-') {
        const sign: i64 = if (value[index] == '+') 1 else -1;
        index += 1;
        const timezone_hour = try parseDigits(value, index, 2);
        index += 2;
        if (index < value.len and value[index] == ':') index += 1;
        const timezone_minute = try parseDigits(value, index, 2);
        index += 2;
        if (timezone_hour > 23 or timezone_minute > 59) return error.InvalidDate;
        timezone_offset_minutes = sign * (timezone_hour * 60 + timezone_minute);
    } else {
        return error.InvalidDate;
    }
    if (index != value.len) return error.InvalidDate;

    const seconds_since_epoch = daysFromCivil(year, month, day) * std.time.s_per_day +
        hour * std.time.s_per_hour + minute * std.time.s_per_min + second -
        timezone_offset_minutes * std.time.s_per_min;
    return @floatFromInt(seconds_since_epoch * std.time.ms_per_s + milliseconds);
}

test "parseES5Date parses npm ISO timestamps and fractional seconds" {
    try std.testing.expectEqual(@as(f64, 0), try parseES5Date("1970-01-01T00:00:00.000Z"));
    try std.testing.expectEqual(@as(f64, 946684800000), try parseES5Date("2000-01-01T00:00:00.000Z"));
    try std.testing.expectEqual(@as(f64, 123), try parseES5Date("1970-01-01T00:00:00.1239Z"));
    try std.testing.expectEqual(@as(f64, 120), try parseES5Date("1970-01-01 00:00:00.12z"));
}

test "parseES5Date applies timezone offsets" {
    try std.testing.expectEqual(@as(f64, 0), try parseES5Date("1970-01-01T01:30:00+01:30"));
    try std.testing.expectEqual(@as(f64, 0), try parseES5Date("1969-12-31T19:00:00-0500"));
}

test "parseES5Date rejects malformed timestamps" {
    const invalid = [_][]const u8{
        "",
        "2026-01-01",
        "2026-13-01T00:00:00Z",
        "2026-01-01T24:00:00Z",
        "2026-01-01T00:00:00",
        "2026-01-01T00:00:00.Z",
        "2026-01-01T00:00:00+25:00",
        "2026-01-01T00:00:00Z trailing",
    };
    for (invalid) |value| {
        try std.testing.expectError(error.InvalidDate, parseES5Date(value));
    }
}
