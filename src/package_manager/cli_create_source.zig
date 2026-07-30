const std = @import("std");

const Bunx = @import("package_manager_bunx.zig");
const CreateSourceSupport = @import("support/create_source/root.zig");
const Host = @import("package_manager_host.zig");
const PackageManager = @import("package_manager_cli.zig");

const Allocator = std.mem.Allocator;

const max_source_bytes = 16 * 1024 * 1024;

const shared_build_ts = CreateSourceSupport.assets.shared_build_ts;
const shared_client_tsx = CreateSourceSupport.assets.shared_client_tsx;
const shared_html = CreateSourceSupport.assets.shared_html;
const shared_package_json = CreateSourceSupport.assets.shared_package_json;
const shared_bunfig_toml = CreateSourceSupport.assets.shared_bunfig_toml;

const TemplateKind = enum {
    react,
    react_tailwind,
    react_shadcn,

    fn label(self: TemplateKind) []const u8 {
        return switch (self) {
            .react => "React",
            .react_tailwind => "React + Tailwind",
            .react_shadcn => "React + shadcn/ui + Tailwind",
        };
    }
};

const Reason = enum {
    shadcn,
    bun,
    css,
    tsc,
    build,
    html,
    npm,
};

const TemplateFile = struct {
    path: []const u8,
    contents: []const u8,
    reason: Reason,
    overwrite: bool = true,
};

const react_files = [_]TemplateFile{
    .{ .path = "REPLACE_ME_WITH_YOUR_APP_FILE_NAME.build.ts", .contents = shared_build_ts, .reason = .build },
    .{
        .path = "REPLACE_ME_WITH_YOUR_APP_FILE_NAME.css",
        .contents = CreateSourceSupport.assets.react_css,
        .reason = .css,
        .overwrite = false,
    },
    .{ .path = "REPLACE_ME_WITH_YOUR_APP_FILE_NAME.html", .contents = shared_html, .reason = .html },
    .{ .path = "REPLACE_ME_WITH_YOUR_APP_FILE_NAME.client.tsx", .contents = shared_client_tsx, .reason = .bun },
    .{
        .path = "package.json",
        .contents = CreateSourceSupport.assets.react_package_json,
        .reason = .npm,
        .overwrite = false,
    },
};

const react_tailwind_files = [_]TemplateFile{
    .{ .path = "REPLACE_ME_WITH_YOUR_APP_FILE_NAME.build.ts", .contents = shared_build_ts, .reason = .build },
    .{
        .path = "REPLACE_ME_WITH_YOUR_APP_FILE_NAME.css",
        .contents = CreateSourceSupport.assets.react_tailwind_css,
        .reason = .css,
    },
    .{ .path = "REPLACE_ME_WITH_YOUR_APP_FILE_NAME.html", .contents = shared_html, .reason = .html },
    .{ .path = "REPLACE_ME_WITH_YOUR_APP_FILE_NAME.client.tsx", .contents = shared_client_tsx, .reason = .bun },
    .{ .path = "bunfig.toml", .contents = shared_bunfig_toml, .reason = .bun, .overwrite = false },
    .{ .path = "package.json", .contents = shared_package_json, .reason = .npm, .overwrite = false },
};

const react_shadcn_files = [_]TemplateFile{
    .{
        .path = "lib/utils.ts",
        .contents = CreateSourceSupport.assets.shadcn_utils,
        .reason = .shadcn,
    },
    .{
        .path = "index.css",
        .contents = CreateSourceSupport.assets.shadcn_index_css,
        .reason = .shadcn,
    },
    .{ .path = "REPLACE_ME_WITH_YOUR_APP_FILE_NAME.build.ts", .contents = shared_build_ts, .reason = .bun },
    .{ .path = "REPLACE_ME_WITH_YOUR_APP_FILE_NAME.client.tsx", .contents = shared_client_tsx, .reason = .bun },
    .{
        .path = "REPLACE_ME_WITH_YOUR_APP_FILE_NAME.css",
        .contents = CreateSourceSupport.assets.shadcn_app_css,
        .reason = .css,
    },
    .{ .path = "REPLACE_ME_WITH_YOUR_APP_FILE_NAME.html", .contents = shared_html, .reason = .html },
    .{
        .path = "styles/globals.css",
        .contents = CreateSourceSupport.assets.shadcn_globals_css,
        .reason = .shadcn,
    },
    .{ .path = "bunfig.toml", .contents = shared_bunfig_toml, .reason = .bun, .overwrite = false },
    .{ .path = "package.json", .contents = shared_package_json, .reason = .npm, .overwrite = false },
    .{
        .path = "tsconfig.json",
        .contents = CreateSourceSupport.assets.shadcn_tsconfig,
        .reason = .tsc,
        .overwrite = false,
    },
    .{
        .path = "components.json",
        .contents = CreateSourceSupport.assets.shadcn_components,
        .reason = .shadcn,
        .overwrite = false,
    },
};

const Analysis = struct {
    dependencies: std.ArrayList([]const u8) = .empty,
    shadcn_components: std.ArrayList([]const u8) = .empty,
    component_export: ?[]const u8 = null,
    uses_tailwind: bool = false,
};

pub const Result = union(enum) {
    exit_code: u8,
    start_dev,
};

pub fn tryRun(
    init: std.process.Init,
    args: []const [:0]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !?Result {
    const entry_argument = sourceEntryArgument(args) orelse return null;
    const extension = std.fs.path.extension(entry_argument);
    if (!std.ascii.eqlIgnoreCase(extension, ".jsx") and !std.ascii.eqlIgnoreCase(extension, ".tsx")) return null;

    const stat = std.Io.Dir.cwd().statFile(init.io, entry_argument, .{}) catch return null;
    if (stat.kind != .file) return null;

    const code = run(init, args[0], entry_argument, stdout, stderr) catch |err| {
        if (err != error.CreateErrorReported) {
            try stderr.print("error: bun create failed: {s}\n", .{@errorName(err)});
        }
        try stderr.flush();
        return Result{ .exit_code = 1 };
    };
    return code;
}

fn sourceEntryArgument(args: []const [:0]const u8) ?[]const u8 {
    if (args.len <= 2) return null;
    var positional_mode = false;
    for (args[2..]) |arg_z| {
        const arg: []const u8 = arg_z;
        if (!positional_mode and std.mem.eql(u8, arg, "--")) {
            positional_mode = true;
            continue;
        }
        if (!positional_mode and std.mem.startsWith(u8, arg, "-")) continue;
        return arg;
    }
    return null;
}

fn run(
    init: std.process.Init,
    executable_arg: [:0]const u8,
    entry_argument: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !Result {
    const allocator = init.arena.allocator();
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(init.io, ".", allocator);
    const entry_absolute = try std.fs.path.resolve(allocator, &.{ cwd, entry_argument });
    var analysis = try analyze(init, entry_absolute, stderr);

    const component_export = analysis.component_export orelse {
        try stderr.print("error: No component export found in \"{s}\"\n", .{entry_argument});
        try stderr.writeAll(
            "Please add an export to your file. For example:\n\n" ++
                "   export default function MyApp() {\n" ++
                "     return <div>Hello World</div>;\n" ++
                "   }\n\n",
        );
        try stderr.flush();
        return .{ .exit_code = 1 };
    };

    const has_tailwind_dependency = containsDependency(analysis.dependencies.items, "tailwindcss") or
        containsDependency(analysis.dependencies.items, "bun-plugin-tailwind");
    const inject_tailwind = !has_tailwind_dependency and analysis.uses_tailwind;
    if (inject_tailwind) {
        try appendUnique(allocator, &analysis.dependencies, "tailwindcss");
        try appendUnique(allocator, &analysis.dependencies, "bun-plugin-tailwind");
    }

    const inject_shadcn = analysis.shadcn_components.items.len > 0;
    if (inject_shadcn) try addShadcnDependencies(allocator, &analysis.dependencies);

    try forceReact19Dependencies(allocator, &analysis.dependencies);

    const template: TemplateKind = if (inject_shadcn)
        .react_shadcn
    else if (has_tailwind_dependency or inject_tailwind)
        .react_tailwind
    else
        .react;

    const relative_entry = try relativeModulePath(allocator, cwd, entry_absolute);
    const extension = std.fs.path.extension(relative_entry);
    const relative_name = relative_entry[0 .. relative_entry.len - extension.len];
    const basename = std.fs.path.basename(relative_name);

    const generated_files = try generateFiles(init, template, basename, relative_name, component_export, stdout);
    if (analysis.dependencies.items.len > 0) {
        const install_code = try installDependencies(
            init,
            executable_arg,
            analysis.dependencies.items,
            stdout,
            stderr,
        );
        if (install_code != 0) return .{ .exit_code = install_code };
    }

    if (template == .react_shadcn and analysis.shadcn_components.items.len > 0) {
        const shadcn_code = try installShadcnComponents(
            init,
            executable_arg,
            relative_name,
            analysis.shadcn_components.items,
            stdout,
            stderr,
        );
        if (shadcn_code != 0) return .{ .exit_code = shadcn_code };
    }

    if (generated_files) try printConfigured(stdout, template);
    try stdout.flush();
    try stderr.flush();

    return .start_dev;
}

fn analyze(init: std.process.Init, entry_absolute: []const u8, stderr: *std.Io.Writer) !Analysis {
    const allocator = init.arena.allocator();
    const encoded = Host.runRuntimeService(
        init,
        allocator,
        "--cottontail-create-source-service",
        "analyze",
        entry_absolute,
        &.{},
    ) catch return error.CreateErrorReported;
    return decodeAnalysis(allocator, encoded) catch |err| {
        try stderr.print("error: invalid Cottontail create-source analysis: {s}\n", .{@errorName(err)});
        return error.CreateErrorReported;
    };
}

fn decodeAnalysis(allocator: Allocator, encoded: []const u8) !Analysis {
    const wire = try CreateSourceSupport.decodeAnalysis(allocator, encoded);
    var result: Analysis = .{
        .component_export = wire.component_export,
        .uses_tailwind = wire.uses_tailwind,
    };
    try result.dependencies.appendSlice(allocator, wire.dependencies);
    try result.shadcn_components.appendSlice(allocator, wire.shadcn_components);
    return result;
}

fn appendUnique(allocator: Allocator, list: *std.ArrayList([]const u8), value: []const u8) !void {
    for (list.items) |existing| if (std.mem.eql(u8, existing, value)) return;
    try list.append(allocator, try allocator.dupe(u8, value));
}

fn containsDependency(dependencies: []const []const u8, dependency: []const u8) bool {
    for (dependencies) |item| if (std.mem.eql(u8, item, dependency)) return true;
    return false;
}

fn addShadcnDependencies(allocator: Allocator, dependencies: *std.ArrayList([]const u8)) !void {
    try appendUnique(allocator, dependencies, "tailwindcss-animate");
    try appendUnique(allocator, dependencies, "class-variance-authority");
    try appendUnique(allocator, dependencies, "clsx");
    try appendUnique(allocator, dependencies, "tailwind-merge");
    try appendUnique(allocator, dependencies, "lucide-react");
}

fn forceReact19Dependencies(allocator: Allocator, dependencies: *std.ArrayList([]const u8)) !void {
    removeDependency(dependencies, "react");
    removeDependency(dependencies, "react-dom");
    try appendUnique(allocator, dependencies, "react-dom@19");
    try appendUnique(allocator, dependencies, "react@19");
}

fn removeDependency(dependencies: *std.ArrayList([]const u8), dependency: []const u8) void {
    var index: usize = 0;
    while (index < dependencies.items.len) {
        if (std.mem.eql(u8, dependencies.items[index], dependency)) {
            _ = dependencies.orderedRemove(index);
        } else {
            index += 1;
        }
    }
}

fn fileExists(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

fn relativeModulePath(allocator: Allocator, cwd: []const u8, absolute: []const u8) ![]const u8 {
    const native = try std.fs.path.relative(allocator, cwd, null, cwd, absolute);
    if (std.fs.path.sep == '/') return native;
    const portable = try allocator.dupe(u8, native);
    std.mem.replaceScalar(u8, portable, '\\', '/');
    return portable;
}

fn templateFiles(template: TemplateKind) []const TemplateFile {
    return switch (template) {
        .react => &react_files,
        .react_tailwind => &react_tailwind_files,
        .react_shadcn => &react_shadcn_files,
    };
}

fn generateFiles(
    init: std.process.Init,
    template: TemplateKind,
    basename: []const u8,
    relative_name: []const u8,
    component_export: []const u8,
    stdout: *std.Io.Writer,
) !bool {
    const allocator = init.arena.allocator();
    const files = templateFiles(template);
    var paths = try allocator.alloc([]const u8, files.len);
    var created = try allocator.alloc(bool, files.len);
    @memset(created, false);
    var max_path_len: usize = 0;
    for (files, 0..) |file, index| {
        paths[index] = try CreateSourceSupport.renderTemplate(
            allocator,
            file.path,
            basename,
            relative_name,
            component_export,
        );
    }

    for (files, paths, 0..) |file, path, index| {
        if (!file.overwrite and fileExists(init.io, path)) continue;
        const contents = try CreateSourceSupport.renderTemplate(
            allocator,
            file.contents,
            basename,
            relative_name,
            component_export,
        );
        if (try writeChangedFile(init, path, contents)) {
            created[index] = true;
            max_path_len = @max(max_path_len, path.len);
        }
    }

    var generated = false;
    for (files, paths, created) |file, path, was_created| {
        if (was_created) {
            generated = true;
            try stdout.print(" create  {s}", .{path});
            var padding = max_path_len - path.len;
            while (padding > 0) : (padding -= 1) try stdout.writeByte(' ');
            try stdout.print("   {s}\n", .{@tagName(file.reason)});
        }
    }
    return generated;
}

fn writeChangedFile(init: std.process.Init, path: []const u8, contents: []const u8) !bool {
    if (std.Io.Dir.cwd().readFileAlloc(
        init.io,
        path,
        init.arena.allocator(),
        .limited(max_source_bytes),
    ) catch null) |existing| {
        if (std.mem.eql(u8, existing, contents)) return false;
    }
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0 and !std.mem.eql(u8, parent, ".")) {
            try std.Io.Dir.cwd().createDirPath(init.io, parent);
        }
    }
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = contents });
    return true;
}

fn installDependencies(
    init: std.process.Init,
    executable_arg: [:0]const u8,
    dependencies: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const allocator = init.arena.allocator();
    try stdout.print("\n📦 Auto-installing {d} detected dependencies\n$ bun --only-missing install", .{dependencies.len});
    for (dependencies) |dependency| try stdout.print(" {s}", .{dependency});
    try stdout.writeByte('\n');
    try stdout.flush();

    const args = try allocator.alloc([:0]const u8, dependencies.len + 3);
    args[0] = executable_arg;
    args[1] = "install";
    args[2] = "--only-missing";
    for (dependencies, args[3..]) |dependency, *arg| arg.* = try allocator.dupeZ(u8, dependency);
    return PackageManager.run(init, args, stdout, stderr);
}

fn installShadcnComponents(
    init: std.process.Init,
    executable_arg: [:0]const u8,
    relative_name: []const u8,
    components: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const allocator = init.arena.allocator();
    const use_src_dir = std.mem.indexOf(u8, relative_name, "/src") != null;
    try stdout.writeAll("\n😎 Setting up shadcn/ui components\n$ bun x shadcn@canary add");
    if (use_src_dir) try stdout.writeAll(" --src-dir");
    try stdout.writeAll(" -y");
    for (components) |component| try stdout.print(" {s}", .{component});
    try stdout.writeByte('\n');
    try stdout.flush();

    var args: std.ArrayList([:0]const u8) = .empty;
    try args.append(allocator, executable_arg);
    try args.append(allocator, "x");
    try args.append(allocator, "shadcn@canary");
    try args.append(allocator, "add");
    if (use_src_dir) try args.append(allocator, "--src-dir");
    try args.append(allocator, "-y");
    for (components) |component| try args.append(allocator, try allocator.dupeZ(u8, component));
    const code = try Bunx.run(init, args.items, .{ .args_start = 2 }, stdout, stderr);
    if (code == 0) try stdout.writeByte('\n');
    return code;
}

fn printConfigured(stdout: *std.Io.Writer, template: TemplateKind) !void {
    try stdout.print(
        "--------------------------------\n" ++
            "✨ {s} project configured\n\n" ++
            "Development - frontend dev server with hot reload\n\n" ++
            "  bun dev\n\n" ++
            "Production - build optimized assets\n\n" ++
            "  bun run build\n\n" ++
            "Happy bunning! 🐇\n",
        .{template.label()},
    );
}
