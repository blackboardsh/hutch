const std = @import("std");
const Semver = @import("semver.zig");

pub const PackageId = u32;

pub const Behavior = packed struct(u8) {
    prod: bool = false,
    optional: bool = false,
    dev: bool = false,
    peer: bool = false,
    _padding: u4 = 0,

    fn order(lhs: Behavior, rhs: Behavior) std.math.Order {
        if (lhs.dev != rhs.dev) return if (lhs.dev) .lt else .gt;
        if (lhs.optional != rhs.optional) return if (lhs.optional) .lt else .gt;
        if (lhs.prod != rhs.prod) return if (lhs.prod) .lt else .gt;
        if (lhs.peer != rhs.peer) return if (lhs.peer) .lt else .gt;
        return .eq;
    }
};

pub const Dependency = struct {
    alias: []const u8,
    spec: []const u8,
    package_id: ?PackageId,
    behavior: Behavior,
};

pub const Package = struct {
    version: []const u8 = "",
    dependencies: []const Dependency = &.{},
    hoistable: bool = true,
    is_npm: bool = false,
};

pub const Placement = struct {
    key: []const u8,
    alias: []const u8,
    package_id: PackageId,
};

const PlacedDependency = struct {
    package_id: PackageId,
    behavior: Behavior,
    root_dependency: bool,
};

const Tree = struct {
    parent: ?usize,
    path: []const u8,
    dependencies: std.StringHashMap(PlacedDependency),
};

const PendingPackage = struct {
    destination_tree: usize,
    alias: []const u8,
    package_id: PackageId,
};

const Destination = union(enum) {
    deduplicated,
    skipped,
    place: usize,
};

const State = struct {
    allocator: std.mem.Allocator,
    packages: []const Package,
    trees: std.array_list.Managed(Tree),
    pending: std.array_list.Managed(PendingPackage),
    placements: std.array_list.Managed(Placement),

    fn deinit(state: *State) void {
        for (state.trees.items) |*tree| {
            if (tree.path.len > 0) state.allocator.free(tree.path);
            tree.dependencies.deinit();
        }
        state.trees.deinit();
        state.pending.deinit();
        state.placements.deinit();
    }

    fn processDependencies(
        state: *State,
        tree_id: usize,
        dependencies: []const Dependency,
    ) !void {
        const sorted = try state.allocator.dupe(Dependency, dependencies);
        defer state.allocator.free(sorted);
        std.mem.sort(Dependency, sorted, {}, dependencyLessThan);

        for (sorted) |dependency| {
            const package_id = dependency.package_id orelse continue;
            if (package_id >= state.packages.len) return error.InvalidPackageId;

            const destination = if (state.packages[package_id].hoistable)
                try state.findDestination(tree_id, dependency)
            else
                Destination{ .place = tree_id };

            const destination_tree = switch (destination) {
                .deduplicated, .skipped => continue,
                .place => |id| id,
            };
            const root_dependency = destination_tree == 0 and tree_id == 0;
            const placed = try state.trees.items[destination_tree].dependencies.getOrPut(dependency.alias);
            if (placed.found_existing) {
                // A non-hoistable dependency can arrive here without consulting
                // the ancestor walk. The existing placement is still the only
                // package that can occupy this node_modules slot.
                if (placed.value_ptr.package_id == package_id) continue;
                return error.DependencyLoop;
            }
            placed.value_ptr.* = .{
                .package_id = package_id,
                .behavior = dependency.behavior,
                .root_dependency = root_dependency,
            };

            const parent_path = state.trees.items[destination_tree].path;
            const key = if (parent_path.len == 0)
                try state.allocator.dupe(u8, dependency.alias)
            else
                try std.fmt.allocPrint(state.allocator, "{s}/{s}", .{ parent_path, dependency.alias });
            try state.placements.append(.{
                .key = key,
                .alias = dependency.alias,
                .package_id = package_id,
            });

            if (state.packages[package_id].dependencies.len > 0) {
                try state.pending.append(.{
                    .destination_tree = destination_tree,
                    .alias = dependency.alias,
                    .package_id = package_id,
                });
            }
        }
    }

    fn findDestination(
        state: *State,
        start_tree_id: usize,
        dependency: Dependency,
    ) !Destination {
        var tree_id = start_tree_id;
        var as_defined = true;

        while (true) {
            const tree = &state.trees.items[tree_id];
            if (tree.dependencies.get(dependency.alias)) |existing| {
                if (existing.package_id == dependency.package_id.?) return .deduplicated;

                // Bun treats a duplicate declaration split between dev and
                // non-dev sections as the already-defined package.
                if (as_defined and existing.behavior.dev != dependency.behavior.dev) {
                    return .deduplicated;
                }

                if (dependency.behavior.peer) {
                    if (existing.root_dependency or
                        state.peerSatisfied(existing.package_id, dependency.spec))
                    {
                        return .deduplicated;
                    }
                    return if (as_defined) .skipped else .{ .place = start_tree_id };
                }

                if (as_defined) return error.DependencyLoop;
                return .{ .place = start_tree_id };
            }

            tree_id = tree.parent orelse return .{ .place = tree_id };
            as_defined = false;
        }
    }

    fn peerSatisfied(state: *State, package_id: PackageId, spec: []const u8) bool {
        const package = state.packages[package_id];
        if (!package.is_npm) return false;
        return Semver.satisfies(package.version, spec);
    }
};

pub fn place(
    allocator: std.mem.Allocator,
    packages: []const Package,
) ![]const Placement {
    if (packages.len == 0 or packages.len > std.math.maxInt(PackageId)) {
        return error.InvalidPackageId;
    }

    var state = State{
        .allocator = allocator,
        .packages = packages,
        .trees = std.array_list.Managed(Tree).init(allocator),
        .pending = std.array_list.Managed(PendingPackage).init(allocator),
        .placements = std.array_list.Managed(Placement).init(allocator),
    };
    defer state.deinit();

    try state.trees.append(.{
        .parent = null,
        .path = "",
        .dependencies = std.StringHashMap(PlacedDependency).init(allocator),
    });
    try state.processDependencies(0, packages[0].dependencies);

    var pending_index: usize = 0;
    while (pending_index < state.pending.items.len) : (pending_index += 1) {
        const pending = state.pending.items[pending_index];
        const parent_path = state.trees.items[pending.destination_tree].path;
        const path = if (parent_path.len == 0)
            try allocator.dupe(u8, pending.alias)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent_path, pending.alias });
        const tree_id = state.trees.items.len;
        try state.trees.append(.{
            .parent = pending.destination_tree,
            .path = path,
            .dependencies = std.StringHashMap(PlacedDependency).init(allocator),
        });
        try state.processDependencies(tree_id, state.packages[pending.package_id].dependencies);
    }

    return allocator.dupe(Placement, state.placements.items);
}

fn dependencyLessThan(_: void, lhs: Dependency, rhs: Dependency) bool {
    return switch (lhs.behavior.order(rhs.behavior)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.order(u8, lhs.alias, rhs.alias) == .lt,
    };
}

test "hoists breadth first and nests version conflicts" {
    const allocator = std.testing.allocator;
    const packages = [_]Package{
        .{ .dependencies = &.{
            .{ .alias = "b", .spec = "^1", .package_id = 2, .behavior = .{ .prod = true } },
            .{ .alias = "a", .spec = "^1", .package_id = 1, .behavior = .{ .prod = true } },
        } },
        .{
            .version = "1.0.0",
            .is_npm = true,
            .dependencies = &.{
                .{ .alias = "shared", .spec = "^1", .package_id = 3, .behavior = .{ .prod = true } },
            },
        },
        .{
            .version = "1.0.0",
            .is_npm = true,
            .dependencies = &.{
                .{ .alias = "shared", .spec = "^2", .package_id = 4, .behavior = .{ .prod = true } },
            },
        },
        .{ .version = "1.5.0", .is_npm = true },
        .{ .version = "2.0.0", .is_npm = true },
    };

    const placements = try place(allocator, &packages);
    defer {
        for (placements) |placement| allocator.free(placement.key);
        allocator.free(placements);
    }

    try std.testing.expectEqual(@as(usize, 4), placements.len);
    try std.testing.expectEqualStrings("a", placements[0].key);
    try std.testing.expectEqualStrings("b", placements[1].key);
    try std.testing.expectEqualStrings("shared", placements[2].key);
    try std.testing.expectEqualStrings("b/shared", placements[3].key);
}

test "compatible peers use an existing ancestor placement" {
    const allocator = std.testing.allocator;
    const packages = [_]Package{
        .{ .dependencies = &.{
            .{ .alias = "parent", .spec = "^1", .package_id = 1, .behavior = .{ .prod = true } },
            .{ .alias = "plugin", .spec = "^1", .package_id = 2, .behavior = .{ .prod = true } },
        } },
        .{
            .version = "1.0.0",
            .is_npm = true,
            .dependencies = &.{
                .{ .alias = "host", .spec = "^1", .package_id = 3, .behavior = .{ .prod = true } },
            },
        },
        .{
            .version = "1.0.0",
            .is_npm = true,
            .dependencies = &.{
                .{ .alias = "host", .spec = "^1.2.0", .package_id = 4, .behavior = .{ .peer = true } },
            },
        },
        .{ .version = "1.4.0", .is_npm = true },
        .{ .version = "1.8.0", .is_npm = true },
    };

    const placements = try place(allocator, &packages);
    defer {
        for (placements) |placement| allocator.free(placement.key);
        allocator.free(placements);
    }

    try std.testing.expectEqual(@as(usize, 3), placements.len);
    try std.testing.expectEqualStrings("parent", placements[0].key);
    try std.testing.expectEqualStrings("plugin", placements[1].key);
    try std.testing.expectEqualStrings("host", placements[2].key);
}
