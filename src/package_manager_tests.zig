// Root the package-manager tests explicitly: the production main entry point
// does not reference its installer while compiling the CLI's own unit tests.
comptime {
    _ = @import("package_manager/root.zig").cli;
}
