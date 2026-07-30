const std = @import("std");

pub const assets = struct {
    pub const shared_build_ts = @embedFile("assets/react-shadcn-spa/REPLACE_ME_WITH_YOUR_APP_FILE_NAME.build.ts");
    pub const shared_client_tsx = @embedFile("assets/react-shadcn-spa/REPLACE_ME_WITH_YOUR_APP_FILE_NAME.client.tsx");
    pub const shared_html = @embedFile("assets/react-shadcn-spa/REPLACE_ME_WITH_YOUR_APP_FILE_NAME.html");
    pub const shared_package_json = @embedFile("assets/react-shadcn-spa/package.json");
    pub const shared_bunfig_toml = @embedFile("assets/react-shadcn-spa/bunfig.toml");
    pub const react_css = @embedFile("assets/react-spa/REPLACE_ME_WITH_YOUR_APP_FILE_NAME.css");
    pub const react_package_json = @embedFile("assets/react-spa/package.json");
    pub const react_tailwind_css = @embedFile("assets/react-tailwind-spa/REPLACE_ME_WITH_YOUR_APP_FILE_NAME.css");
    pub const shadcn_utils = @embedFile("assets/react-shadcn-spa/lib/utils.ts");
    pub const shadcn_index_css = @embedFile("assets/react-shadcn-spa/styles/index.css");
    pub const shadcn_app_css = @embedFile("assets/react-shadcn-spa/REPLACE_ME_WITH_YOUR_APP_FILE_NAME.css");
    pub const shadcn_globals_css = @embedFile("assets/react-shadcn-spa/styles/globals.css");
    pub const shadcn_tsconfig = @embedFile("assets/react-shadcn-spa/tsconfig.json");
    pub const shadcn_components = @embedFile("assets/react-shadcn-spa/components.json");
};

pub const WireAnalysis = struct {
    dependencies: []const []const u8 = &.{},
    shadcn_components: []const []const u8 = &.{},
    component_export: ?[]const u8 = null,
    uses_tailwind: bool = false,
};

pub fn decodeAnalysis(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) !WireAnalysis {
    return std.json.parseFromSliceLeaky(WireAnalysis, allocator, encoded, .{});
}

pub fn renderTemplate(
    allocator: std.mem.Allocator,
    input: []const u8,
    basename: []const u8,
    relative_name: []const u8,
    component_export: []const u8,
) ![]const u8 {
    var output = try std.mem.replaceOwned(
        u8,
        allocator,
        input,
        "REPLACE_ME_WITH_YOUR_REACT_COMPONENT_EXPORT",
        component_export,
    );
    output = try std.mem.replaceOwned(
        u8,
        allocator,
        output,
        "REPLACE_ME_WITH_YOUR_APP_BASE_NAME",
        basename,
    );
    output = try std.mem.replaceOwned(
        u8,
        allocator,
        output,
        "REPLACE_ME_WITH_YOUR_APP_FILE_NAME",
        relative_name,
    );
    return output;
}

test "decode source analysis service response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const analysis = try decodeAnalysis(arena.allocator(),
        \\{"dependencies":["zod"],"shadcn_components":["button"],"component_export":"App","uses_tailwind":true}
    );
    try std.testing.expectEqualStrings("zod", analysis.dependencies[0]);
    try std.testing.expectEqualStrings("button", analysis.shadcn_components[0]);
    try std.testing.expectEqualStrings("App", analysis.component_export.?);
    try std.testing.expect(analysis.uses_tailwind);
}

test "Hutch-owned source templates render without placeholders" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const rendered = try renderTemplate(
        arena.allocator(),
        assets.shared_client_tsx,
        "Example",
        "src/Example",
        "default",
    );
    try std.testing.expect(std.mem.indexOf(u8, rendered, "REPLACE_ME_WITH") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "from \"./Example\"") != null);
}
