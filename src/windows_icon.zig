const std = @import("std");
const builtin = @import("builtin");

const max_icon_images = 256;

const IconImage = struct {
    width: u8,
    height: u8,
    color_count: u8,
    reserved: u8,
    planes: u16,
    bit_count: u16,
    data: []const u8,
};

const windows_api = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;

    extern "kernel32" fn BeginUpdateResourceW(
        file_name: windows.LPCWSTR,
        delete_existing_resources: windows.BOOL,
    ) callconv(.winapi) ?windows.HANDLE;

    extern "kernel32" fn UpdateResourceW(
        update: windows.HANDLE,
        resource_type: ?*const anyopaque,
        resource_name: ?*const anyopaque,
        language: windows.LANGID,
        data: ?*const anyopaque,
        data_size: windows.DWORD,
    ) callconv(.winapi) windows.BOOL;

    extern "kernel32" fn EndUpdateResourceW(
        update: windows.HANDLE,
        discard: windows.BOOL,
    ) callconv(.winapi) windows.BOOL;

    extern "kernel32" fn LoadLibraryExW(
        file_name: windows.LPCWSTR,
        file: ?windows.HANDLE,
        flags: windows.DWORD,
    ) callconv(.winapi) ?windows.HMODULE;

    extern "kernel32" fn FreeLibrary(module: windows.HMODULE) callconv(.winapi) windows.BOOL;

    extern "kernel32" fn FindResourceExW(
        module: windows.HMODULE,
        resource_type: ?*const anyopaque,
        resource_name: ?*const anyopaque,
        language: windows.WORD,
    ) callconv(.winapi) ?*anyopaque;

    extern "kernel32" fn LoadResource(
        module: windows.HMODULE,
        resource: *anyopaque,
    ) callconv(.winapi) ?*anyopaque;

    extern "kernel32" fn LockResource(resource: *anyopaque) callconv(.winapi) ?*const anyopaque;

    extern "kernel32" fn SizeofResource(
        module: windows.HMODULE,
        resource: *anyopaque,
    ) callconv(.winapi) windows.DWORD;

    const rt_icon = 3;
    const rt_group_icon = 14;
    const app_icon_group = 1;
    const default_icon_language = 1033;
    const load_library_as_datafile = 0x00000002;

    // MAKEINTRESOURCEW encodes an integer ID as a deliberately small pointer.
    // Model it as opaque so Zig does not impose wchar_t's two-byte alignment
    // and panic on valid odd IDs such as RT_ICON (3).
    fn intResource(id: u16) ?*const anyopaque {
        if (id == 0) return null;
        return @ptrFromInt(@as(usize, id));
    }
} else struct {};

pub fn embed(allocator: std.mem.Allocator, executable_path: []const u8, ico: []const u8) !void {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;

    const images = try parse(allocator, ico);
    defer allocator.free(images);
    const group = try makeGroupResource(allocator, images);
    defer allocator.free(group);
    const path_utf16 = try std.unicode.utf8ToUtf16LeAllocZ(allocator, executable_path);
    defer allocator.free(path_utf16);

    const update = windows_api.BeginUpdateResourceW(path_utf16.ptr, .FALSE) orelse
        return error.BeginResourceUpdateFailed;
    var update_ended = false;
    defer if (!update_ended) {
        _ = windows_api.EndUpdateResourceW(update, .TRUE);
    };

    for (images, 1..) |image, id| {
        if (!windows_api.UpdateResourceW(
            update,
            windows_api.intResource(windows_api.rt_icon),
            windows_api.intResource(@intCast(id)),
            windows_api.default_icon_language,
            image.data.ptr,
            @intCast(image.data.len),
        ).toBool()) return error.IconResourceUpdateFailed;
    }

    if (!windows_api.UpdateResourceW(
        update,
        windows_api.intResource(windows_api.rt_group_icon),
        windows_api.intResource(windows_api.app_icon_group),
        windows_api.default_icon_language,
        group.ptr,
        @intCast(group.len),
    ).toBool()) return error.IconGroupResourceUpdateFailed;

    const committed = windows_api.EndUpdateResourceW(update, .FALSE).toBool();
    update_ended = true;
    if (!committed) return error.EndResourceUpdateFailed;
}

pub fn icoFromPng(allocator: std.mem.Allocator, png: []const u8) ![]u8 {
    const signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };
    if (png.len < 33 or !std.mem.eql(u8, png[0..signature.len], &signature)) return error.InvalidPng;
    if (readU32Big(png, 8) != 13 or !std.mem.eql(u8, png[12..16], "IHDR")) return error.InvalidPng;

    const width = readU32Big(png, 16);
    const height = readU32Big(png, 20);
    if (width == 0 or height == 0 or width != height) return error.PngMustBeSquare;
    if (width > 256) return error.PngTooLarge;
    if (png.len > std.math.maxInt(u32)) return error.IconImageTooLarge;

    const header_size = 6 + 16;
    const output = try allocator.alloc(u8, header_size + png.len);
    @memset(output, 0);
    writeU16Little(output, 2, 1);
    writeU16Little(output, 4, 1);
    output[6] = if (width == 256) 0 else @intCast(width);
    output[7] = if (height == 256) 0 else @intCast(height);
    writeU16Little(output, 10, 1);
    writeU16Little(output, 12, 32);
    writeU32Little(output, 14, @intCast(png.len));
    writeU32Little(output, 18, header_size);
    @memcpy(output[header_size..], png);
    return output;
}

fn parse(allocator: std.mem.Allocator, ico: []const u8) ![]IconImage {
    if (ico.len < 6) return error.InvalidIcon;
    if (readU16Little(ico, 0) != 0 or readU16Little(ico, 2) != 1) return error.InvalidIcon;

    const count = readU16Little(ico, 4);
    if (count == 0 or count > max_icon_images) return error.InvalidIcon;
    const directory_size = 6 + @as(usize, count) * 16;
    if (directory_size > ico.len) return error.InvalidIcon;

    const images = try allocator.alloc(IconImage, count);
    errdefer allocator.free(images);
    for (images, 0..) |*image, index| {
        const entry_offset = 6 + index * 16;
        const data_size = readU32Little(ico, entry_offset + 8);
        const data_offset = readU32Little(ico, entry_offset + 12);
        if (data_size == 0 or data_offset < directory_size) return error.InvalidIcon;
        const data_end = std.math.add(usize, data_offset, data_size) catch return error.InvalidIcon;
        if (data_end > ico.len) return error.InvalidIcon;

        image.* = .{
            .width = ico[entry_offset],
            .height = ico[entry_offset + 1],
            .color_count = ico[entry_offset + 2],
            .reserved = ico[entry_offset + 3],
            .planes = readU16Little(ico, entry_offset + 4),
            .bit_count = readU16Little(ico, entry_offset + 6),
            .data = ico[data_offset..data_end],
        };
    }
    return images;
}

fn makeGroupResource(allocator: std.mem.Allocator, images: []const IconImage) ![]u8 {
    if (images.len == 0 or images.len > max_icon_images) return error.InvalidIcon;
    const group = try allocator.alloc(u8, 6 + images.len * 14);
    @memset(group, 0);
    writeU16Little(group, 2, 1);
    writeU16Little(group, 4, @intCast(images.len));

    for (images, 0..) |image, index| {
        const offset = 6 + index * 14;
        group[offset] = image.width;
        group[offset + 1] = image.height;
        group[offset + 2] = image.color_count;
        group[offset + 3] = image.reserved;
        writeU16Little(group, offset + 4, image.planes);
        writeU16Little(group, offset + 6, image.bit_count);
        writeU32Little(group, offset + 8, @intCast(image.data.len));
        writeU16Little(group, offset + 12, @intCast(index + 1));
    }
    return group;
}

fn readU16Little(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) |
        (@as(u16, bytes[offset + 1]) << 8);
}

fn readU32Little(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}

fn readU32Big(bytes: []const u8, offset: usize) u32 {
    return (@as(u32, bytes[offset]) << 24) |
        (@as(u32, bytes[offset + 1]) << 16) |
        (@as(u32, bytes[offset + 2]) << 8) |
        @as(u32, bytes[offset + 3]);
}

fn writeU16Little(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
}

fn writeU32Little(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
    bytes[offset + 2] = @truncate(value >> 16);
    bytes[offset + 3] = @truncate(value >> 24);
}

fn testIco(allocator: std.mem.Allocator) ![]u8 {
    const png = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x04, 0x00, 0x00, 0x00, 0xb5, 0x1c, 0x0c, 0x02, 0x00, 0x00, 0x00,
        0x0b, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x64, 0xf8, 0x0f, 0x00,
        0x01, 0x05, 0x01, 0x01, 0x27, 0x18, 0xe3, 0x66, 0x00, 0x00, 0x00, 0x00,
        0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
    };
    return icoFromPng(allocator, &png);
}

test "PNG icons are wrapped as self-contained ICO files" {
    const allocator = std.testing.allocator;
    const ico = try testIco(allocator);
    defer allocator.free(ico);

    const images = try parse(allocator, ico);
    defer allocator.free(images);
    try std.testing.expectEqual(@as(usize, 1), images.len);
    try std.testing.expectEqual(@as(u8, 1), images[0].width);
    try std.testing.expectEqual(@as(u8, 1), images[0].height);
    try std.testing.expectEqual(@as(u16, 32), images[0].bit_count);
    try std.testing.expectEqualSlices(u8, ico[22..], images[0].data);
}

test "ICO parsing rejects an image outside the file" {
    const malformed = [_]u8{
        0,  0,  1, 0, 1, 0,
        16, 16, 0, 0, 1, 0,
        32, 0,  4, 0, 0, 0,
        22, 0,  0, 0,
    };
    try std.testing.expectError(error.InvalidIcon, parse(std.testing.allocator, &malformed));
}

test "group icon resources reference each embedded image" {
    const allocator = std.testing.allocator;
    const ico = try testIco(allocator);
    defer allocator.free(ico);
    const images = try parse(allocator, ico);
    defer allocator.free(images);
    const group = try makeGroupResource(allocator, images);
    defer allocator.free(group);

    try std.testing.expectEqual(@as(usize, 20), group.len);
    try std.testing.expectEqual(@as(u16, 1), readU16Little(group, 4));
    try std.testing.expectEqual(@as(u32, @intCast(images[0].data.len)), readU32Little(group, 14));
    try std.testing.expectEqual(@as(u16, 1), readU16Little(group, 18));
}

test "Windows resource writer embeds icons into a PE fixture" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const self_path = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_path);
    const executable = try std.Io.Dir.cwd().readFileAlloc(
        io,
        self_path,
        allocator,
        .limited(512 * 1024 * 1024),
    );
    defer allocator.free(executable);
    try tmp.dir.writeFile(io, .{ .sub_path = "fixture.exe", .data = executable });
    const fixture_path = try tmp.dir.realPathFileAlloc(io, "fixture.exe", allocator);
    defer allocator.free(fixture_path);

    const ico = try testIco(allocator);
    defer allocator.free(ico);
    try embed(allocator, fixture_path, ico);

    const fixture_utf16 = try std.unicode.utf8ToUtf16LeAllocZ(allocator, fixture_path);
    defer allocator.free(fixture_utf16);
    const module = windows_api.LoadLibraryExW(
        fixture_utf16.ptr,
        null,
        windows_api.load_library_as_datafile,
    ) orelse return error.LoadPeFixtureFailed;
    defer _ = windows_api.FreeLibrary(module);

    const icon_resource = windows_api.FindResourceExW(
        module,
        windows_api.intResource(windows_api.rt_icon),
        windows_api.intResource(1),
        windows_api.default_icon_language,
    ) orelse return error.IconResourceNotFound;
    const loaded_icon = windows_api.LoadResource(module, icon_resource) orelse return error.IconResourceLoadFailed;
    const icon_data = windows_api.LockResource(loaded_icon) orelse return error.IconResourceLockFailed;
    const icon_size = windows_api.SizeofResource(module, icon_resource);
    const icon_bytes: [*]const u8 = @ptrCast(icon_data);
    try std.testing.expectEqualSlices(u8, ico[22..], icon_bytes[0..icon_size]);

    const group_resource = windows_api.FindResourceExW(
        module,
        windows_api.intResource(windows_api.rt_group_icon),
        windows_api.intResource(windows_api.app_icon_group),
        windows_api.default_icon_language,
    ) orelse return error.IconGroupResourceNotFound;
    try std.testing.expectEqual(@as(u32, 20), windows_api.SizeofResource(module, group_resource));
}
