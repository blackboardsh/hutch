import * as loadedConfigModule from __MODULE_NAME__;

const loadedConfig = loadedConfigModule.default ?? loadedConfigModule ?? {};

const defaultConfig = {
  app: {
    name: "MyApp",
    identifier: "com.example.myapp",
    version: "0.1.0",
    description: undefined,
    urlSchemes: undefined,
    fileAssociations: undefined,
  },
  build: {
    buildFolder: "build",
    artifactFolder: "artifacts",
    mainProcess: "cottontail",
    useAsar: false,
    main: {
      entrypoint: "src/bun/index.ts",
    },
    bun: {
      entrypoint: "src/bun/index.ts",
    },
    cottontail: {
      entrypoint: "src/bun/index.ts",
    },
    zig: {
      entrypoint: "src/zig/main.zig",
    },
    rust: {
      entrypoint: "src/rust/main.rs",
    },
    go: {
      entrypoint: "src/go/main.go",
    },
    odin: {
      entrypoint: "src/odin/main.odin",
    },
    mac: {
      codesign: false,
      createDmg: true,
      notarize: false,
      bundleCEF: false,
      bundleWGPU: false,
      entitlements: {
        "com.apple.security.cs.allow-jit": true,
        "com.apple.security.cs.allow-unsigned-executable-memory": true,
        "com.apple.security.cs.disable-library-validation": true,
      },
      icons: "icon.iconset",
    },
    win: {
      bundleCEF: false,
      bundleWGPU: false,
    },
    linux: {
      bundleCEF: false,
      bundleWGPU: false,
      flatpak: {
        enabled: false,
        outputPath: "flatpak",
        runtime: "org.freedesktop.Platform",
        runtimeVersion: "25.08",
        sdk: "org.freedesktop.Sdk",
        finishArgs: [
          "--share=ipc",
          "--share=network",
          "--socket=wayland",
          "--socket=fallback-x11",
          "--socket=pulseaudio",
          "--device=dri",
        ],
      },
    },
    views: {},
    copy: {},
    watch: [],
    watchIgnore: [],
  },
  runtime: {},
  scripts: {
    preBuild: "",
    postBuild: "",
    postWrap: "",
    postPackage: "",
  },
  release: {
    baseUrl: "",
    generatePatch: true,
  },
};

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function mergeConfig(base, override) {
  if (Array.isArray(base)) {
    return Array.isArray(override) ? override.slice() : base.slice();
  }
  if (!isPlainObject(base)) {
    return override === undefined ? base : override;
  }
  const result = { ...base };
  if (!isPlainObject(override)) {
    return override === undefined ? result : override;
  }
  for (const [key, value] of Object.entries(override)) {
    if (value === undefined) continue;
    const existing = result[key];
    result[key] = isPlainObject(value) && isPlainObject(existing)
      ? mergeConfig(existing, value)
      : Array.isArray(value)
        ? value.slice()
        : value;
  }
  return result;
}

const merged = mergeConfig(defaultConfig, loadedConfig);

if (!merged.build.main && merged.build.bun) merged.build.main = { ...merged.build.bun };
if (!merged.build.bun && merged.build.main) merged.build.bun = { ...merged.build.main };

console.log(JSON.stringify(merged));
