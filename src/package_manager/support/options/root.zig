//! Package-manager configuration without compiler, AST, or JavaScript runtime
//! dependencies.

pub const Environment = @import("environment.zig").Environment;

const types = @import("types.zig");
pub const default_registry_url = types.default_registry_url;
pub const CertificateAuthorities = types.CertificateAuthorities;
pub const InstallOptions = types.InstallOptions;
pub const NodeLinker = types.NodeLinker;
pub const NpmRegistry = types.NpmRegistry;
pub const RegistryCredential = types.RegistryCredential;
pub const RegistryCredentialOption = types.RegistryCredentialOption;

pub const parseBunfig = @import("bunfig.zig").parse;
const npmrc = @import("npmrc.zig");
pub const NpmrcParseOptions = npmrc.ParseOptions;
pub const parseNpmrc = npmrc.parse;

test {
    _ = @import("environment.zig");
    _ = @import("types.zig");
    _ = @import("toml.zig");
    _ = @import("bunfig.zig");
    _ = @import("npmrc.zig");
}
