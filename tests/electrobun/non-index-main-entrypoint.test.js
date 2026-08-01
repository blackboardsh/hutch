import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const hutchRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const scratchRoot = join(hutchRoot, ".cottontail-tmp", "tests");
const marker = "NON_INDEX_MAIN_ENTRYPOINT_EXECUTED";

function executableName(name) {
  return process.platform === "win32" ? `${name}.exe` : name;
}

function resolveCottontail() {
  const configured = process.env.COTTONTAIL_BINARY ?? process.env.DASH_COTTONTAIL;
  if (configured) return resolve(configured);

  const hutch = join(hutchRoot, "zig-out", "bin", executableName("hutch"));
  assert.ok(existsSync(hutch), `Hutch must be built before this test: ${hutch}`);

  const result = spawnSync(hutch, ["cottontail", "path", "production"], {
    cwd: hutchRoot,
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  return result.stdout.trim();
}

function write(path, contents = "") {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, contents);
}

function platformNames() {
  if (process.platform === "darwin") {
    return {
      os: "macos",
      core: "libElectrobunCore.dylib",
      native: "libNativeWrapper.dylib",
      asar: "libasar.dylib",
    };
  }
  if (process.platform === "win32") {
    return {
      os: "win",
      core: "ElectrobunCore.dll",
      native: "libNativeWrapper.dll",
      asar: "libasar.dll",
    };
  }
  return {
    os: "linux",
    core: "libElectrobunCore.so",
    native: "libNativeWrapper.so",
    asar: "libasar.so",
  };
}

function createPackageFixture(root, cottontail) {
  const dist = join(root, "dist");
  const names = platformNames();
  const launcher = join(dist, executableName("launcher"));
  const runtime = join(dist, executableName("bun"));

  write(join(root, "package.json"), JSON.stringify({ name: "electrobun-test-fixture", type: "module" }));
  write(join(dist, "main.js"), 'import "./app/bun/index.js";\n');
  write(join(dist, "preload-full.js"));
  write(join(dist, "preload-sandboxed.js"));
  write(join(dist, names.core));
  write(join(dist, names.native));
  write(join(dist, names.asar));
  write(join(dist, "api", "sdks", "bun", "index.ts"), "export {};\n");
  write(join(dist, "api", "browser", "index.ts"), "export {};\n");
  copyFileSync(cottontail, runtime);
  chmodSync(runtime, 0o755);

  if (process.platform === "win32") {
    copyFileSync(cottontail, launcher);
  } else {
    write(
      launcher,
      '#!/bin/sh\nset -eu\nHERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)\nexec "$HERE/bun" "$HERE/../Resources/main.js"\n',
    );
  }
  chmodSync(launcher, 0o755);
}

function bundlePaths(project) {
  const names = platformNames();
  const arch = process.arch === "arm64" ? "arm64" : "x64";
  const buildRoot = join(project, "build", `dev-${names.os}-${arch}`);
  const bundleRoot = process.platform === "darwin"
    ? join(buildRoot, "NonIndexEntrypoint-dev.app")
    : join(buildRoot, "NonIndexEntrypoint-dev");
  const execDir = process.platform === "darwin"
    ? join(bundleRoot, "Contents", "MacOS")
    : join(bundleRoot, "bin");
  const resourcesDir = process.platform === "darwin"
    ? join(bundleRoot, "Contents", "Resources")
    : join(bundleRoot, "Resources");
  return { execDir, resourcesDir };
}

test("Electrobun launches a non-index Bun entrypoint from the canonical artifact", { timeout: 120_000 }, () => {
  mkdirSync(scratchRoot, { recursive: true });
  const fixture = mkdtempSync(join(scratchRoot, "non-index-main-entrypoint-"));
  const project = join(fixture, "project");
  const packageRoot = join(fixture, "electrobun-package");
  const hutch = join(hutchRoot, "zig-out", "bin", executableName("hutch"));
  const engine = join(hutchRoot, "zig-out", "bin", executableName("hutch-engine"));
  const cottontail = resolveCottontail();

  try {
    assert.ok(existsSync(hutch), `Hutch must be built before this test: ${hutch}`);
    assert.ok(existsSync(engine), `Hutch engine must be built before this test: ${engine}`);
    createPackageFixture(packageRoot, cottontail);

    write(join(project, "src", "bun", "electrobun-main.ts"), `console.log("${marker}");\n`);
    write(join(project, "electrobun.config.ts"), `
export default {
  app: {
    name: "NonIndexEntrypoint",
    identifier: "dev.electrobun.non-index-entrypoint",
    version: "0.0.0",
  },
  build: {
    mainProcess: "bun",
    bun: { entrypoint: "src/bun/electrobun-main.ts" },
    mac: { icons: null, codesign: false, notarize: false, bundleCEF: false, bundleWGPU: false },
    win: { bundleCEF: false, bundleWGPU: false },
    linux: { bundleCEF: false, bundleWGPU: false },
  },
};
`);

    const env = {
      ...process.env,
      COTTONTAIL_BINARY: cottontail,
      DASH_COTTONTAIL: cottontail,
      COTTONTAIL_ELECTROBUN_PACKAGE: packageRoot,
      HUTCH_ENGINE_BINARY: engine,
      HUTCH_NO_UPDATE_CHECK: "1",
    };
    const build = spawnSync(hutch, ["electrobun", "build", "--env=dev"], {
      cwd: project,
      encoding: "utf8",
      env,
    });
    assert.equal(build.status, 0, build.stderr || build.stdout);

    const { execDir, resourcesDir } = bundlePaths(project);
    const canonicalMain = join(resourcesDir, "app", "bun", "index.js");
    const sourceNamedOutput = join(resourcesDir, "app", "bun", "electrobun-main.js");
    const launchBridge = join(resourcesDir, "main.js");

    assert.ok(existsSync(canonicalMain), `Expected canonical main artifact: ${canonicalMain}`);
    assert.equal(existsSync(sourceNamedOutput), false, "The source basename must not leak into the launcher contract");
    assert.match(readFileSync(canonicalMain, "utf8"), new RegExp(marker));
    assert.match(readFileSync(launchBridge, "utf8"), /\.\/app\/bun\/index\.js/);

    const launch = process.platform === "win32"
      ? spawnSync(join(execDir, executableName("bun")), [launchBridge], { cwd: execDir, encoding: "utf8", env })
      : spawnSync(hutch, ["electrobun", "run", "--env=dev"], { cwd: project, encoding: "utf8", env });
    assert.equal(launch.status, 0, launch.stderr || launch.stdout);
    assert.match(launch.stdout, new RegExp(marker));
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
});
