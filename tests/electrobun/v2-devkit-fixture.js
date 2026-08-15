import { chmodSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

export function executableName(name) {
  return process.platform === "win32" ? `${name}.exe` : name;
}

export function writeFixtureFile(path, contents = "") {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, contents);
}

export function hostContract() {
  if (process.platform === "darwin") {
    return {
      os: "macos",
      arch: process.arch === "arm64" ? "arm64" : "x64",
      key: `macos-${process.arch === "arm64" ? "arm64" : "x64"}`,
      asset: `darwin-${process.arch === "arm64" ? "arm64" : "x64"}`,
      core: "libElectrobunCore.dylib",
      native: "libNativeWrapper.dylib",
      nativeCef: "libNativeWrapper.dylib",
      asar: "libasar.dylib",
      wgpu: "libwebgpu_dawn.dylib",
    };
  }
  if (process.platform === "win32") {
    return {
      os: "win",
      arch: "x64",
      key: "windows-x64",
      asset: "win-x64",
      core: "ElectrobunCore.dll",
      native: "libNativeWrapper.dll",
      nativeCef: "libNativeWrapper.dll",
      asar: "libasar.dll",
      wgpu: "webgpu_dawn.dll",
      wgpuAuxiliaryLibraries: ["d3dcompiler_47.dll"],
    };
  }
  return {
    os: "linux",
    arch: process.arch === "arm64" ? "arm64" : "x64",
    key: `linux-${process.arch === "arm64" ? "arm64" : "x64"}`,
    asset: `linux-${process.arch === "arm64" ? "arm64" : "x64"}`,
    core: "libElectrobunCore.so",
    native: "libNativeWrapper.so",
    nativeCef: "libNativeWrapper_cef.so",
    asar: "libasar.so",
    wgpu: "libwebgpu_dawn.so",
  };
}

export function createCoreFixture(root, version, host = hostContract()) {
  const runtime = {
    main: "main.js",
    preloadFull: "preload-full.js",
    preloadSandboxed: "preload-sandboxed.js",
    bun: executableName("bun"),
    launcher: executableName("launcher"),
    extractor: executableName("extractor"),
    coreLibrary: host.core,
    nativeWrapper: host.native,
    nativeWrapperCef: host.nativeCef,
    asarLibrary: host.asar,
    wgpuLibrary: host.wgpu,
    wgpuAuxiliaryLibraries: host.wgpuAuxiliaryLibraries || [],
    processHelper: executableName("process_helper"),
    bsdiff: executableName("bsdiff"),
    bspatch: executableName("bspatch"),
    zigAsar: executableName("zig-asar"),
    zigZstd: executableName("zig-zstd"),
  };
  const manifest = {
    schemaVersion: 1,
    product: { name: "electrobun", version },
    target: { os: host.os, arch: host.arch },
    abi: {
      core: { name: "electrobun-core", version: 1 },
      sdk: { name: "electrobun-sdk", version: 1 },
    },
    toolchains: {
      zig: { defaultVersion: "0.16.0" },
      rust: { defaultVersion: "1.88.0" },
      go: { defaultVersion: "1.26.4" },
      odin: { defaultVersion: "dev-2026-07a" },
    },
    runtimes: {
      bun: { version: "1.3.13" },
    },
    layout: {
      runtime,
      sdks: {
        javascript: {
          root: "api",
          main: "api/sdks/main/index.ts",
          browser: "api/browser/index.ts",
          config: "api/config/ElectrobunConfig.ts",
          preload: "api/preload",
          exports: {
            ".": "api/sdks/main/index.ts",
            "./main": "api/sdks/main/index.ts",
            "./view": "api/browser/index.ts",
          },
        },
        zig: { root: "zig-sdk", entrypoint: "zig-sdk/electrobun.zig" },
        rust: { root: "rust-sdk", manifest: "rust-sdk/Cargo.toml" },
        go: { root: "go-sdk", manifest: "go-sdk/go.mod", module: "electrobun" },
        odin: {
          root: "odin-sdk/electrobun",
          entrypoint: "odin-sdk/electrobun/electrobun.odin",
          collection: "odin-sdk",
          collectionName: "electrobun_sdk",
        },
      },
    },
  };

  const { wgpuAuxiliaryLibraries, ...runtimeFiles } = runtime;
  for (const file of new Set([
    ...Object.values(runtimeFiles),
    ...wgpuAuxiliaryLibraries,
  ])) {
    writeFixtureFile(join(root, file), file);
    if (process.platform !== "win32") chmodSync(join(root, file), 0o755);
  }
  writeFixtureFile(join(root, "api", "sdks", "main", "index.ts"), "export const devkitMarker = 'V2_DEVKIT_ALIAS';\nexport type { ElectrobunConfig } from '../../config/ElectrobunConfig';\n");
  writeFixtureFile(join(root, "api", "browser", "index.ts"), "export const viewMarker = 'V2_VIEW_ALIAS';\n");
  writeFixtureFile(join(root, "api", "config", "ElectrobunConfig.ts"), "export interface ElectrobunConfig { app?: unknown; build?: unknown }\n");
  writeFixtureFile(join(root, "api", "preload", "index.ts"), "export {};\n");
  writeFixtureFile(join(root, "zig-sdk", "electrobun.zig"), "pub const marker = true;\n");
  writeFixtureFile(join(root, "rust-sdk", "Cargo.toml"), "[package]\nname = \"electrobun\"\nversion = \"2.0.0\"\nedition = \"2021\"\n[lib]\npath = \"electrobun.rs\"\n");
  writeFixtureFile(join(root, "rust-sdk", "electrobun.rs"), "pub const MARKER: bool = true;\n");
  writeFixtureFile(join(root, "go-sdk", "go.mod"), "module electrobun\n\ngo 1.26\n");
  writeFixtureFile(join(root, "go-sdk", "electrobun.go"), "package electrobun\n");
  writeFixtureFile(join(root, "odin-sdk", "electrobun", "electrobun.odin"), "package electrobun\n");
  writeFixtureFile(join(root, "native-devkit.json"), `${JSON.stringify(manifest, null, 2)}\n`);
  return manifest;
}
