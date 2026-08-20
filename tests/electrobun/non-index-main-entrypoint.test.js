import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import {
  createCoreFixture,
  executableName,
  hostContract,
  writeFixtureFile,
} from "./v2-devkit-fixture.js";

const hutchRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const scratchRoot = join(hutchRoot, ".cottontail-tmp", "tests");
const marker = "NON_INDEX_MAIN_ENTRYPOINT_EXECUTED";

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

function sha256(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function prepareExternalBun(root) {
  const bin = join(root, "external-package-manager");
  const executable = join(bin, executableName("bun"));
  const probe = join(root, "external-bun-probe.cjs");
  const capture = join(root, "external-bun-invocation.json");
  mkdirSync(bin, { recursive: true });
  copyFileSync(process.execPath, executable);
  chmodSync(executable, 0o755);
  writeFixtureFile(
    probe,
    `const { createHash } = require("node:crypto");
const { readFileSync, writeFileSync } = require("node:fs");
writeFileSync(process.env.HUTCH_PM_CAPTURE, JSON.stringify({
  args: process.argv.slice(2),
  executableSha256: createHash("sha256").update(readFileSync(process.execPath)).digest("hex"),
}));
`,
  );
  return { bin, capture, executable, probe };
}

function prependExecutablePath(environment, directory) {
  const pathKey = Object.keys(environment).find((key) => key.toLowerCase() === "path") ?? "PATH";
  const current = environment[pathKey];
  environment[pathKey] = current ? `${directory}${delimiter}${current}` : directory;
}

function bunCompatibilityVersion(cottontail) {
  const result = spawnSync(
    cottontail,
    ["-e", "process.stdout.write(Bun.version)"],
    { encoding: "utf8" },
  );
  assert.equal(result.status, 0, result.stderr || result.stdout);
  const version = result.stdout.trim();
  assert.match(version, /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/);
  return version;
}

// The exact string the fixture bun answers to `--version`, which is what the
// toolchain store validates a pinned install against.
function bunToolchainVersion(cottontail) {
  const result = spawnSync(cottontail, ["--version"], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  const version = result.stdout.trim();
  assert.match(version, /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/);
  return version;
}

function toolchainPlatformKey() {
  if (process.platform === "darwin") {
    return process.arch === "arm64" ? "macos-arm64" : "macos-x64";
  }
  if (process.platform === "linux") {
    return process.arch === "arm64" ? "linux-arm64" : "linux-x64";
  }
  return "windows-x64";
}

// Pre-installs the fixture bun into a Hutch home's toolchain store the way a
// completed upstream download would land there.
function installManagedBun(home, version, cottontail) {
  const root = join(home, "toolchains", "bun", version, toolchainPlatformKey());
  const executable = join(root, executableName("bun"));
  mkdirSync(root, { recursive: true });
  copyFileSync(cottontail, executable);
  chmodSync(executable, 0o755);
  writeFixtureFile(join(root, ".hutch-toolchain"), version);
  return executable;
}

function prepareBunDevkit(root, version, pinnedBunVersion, cottontail) {
  const host = hostContract();
  const manifest = createCoreFixture(root, version, host);
  const launcher = join(root, manifest.layout.runtime.launcher);

  // The devkit no longer distributes a bun binary; it only pins the default
  // bun toolchain version the way it pins zig/rust/go/odin defaults.
  manifest.toolchains.bun.defaultVersion = pinnedBunVersion;
  writeFixtureFile(
    join(root, "native-devkit.json"),
    `${JSON.stringify(manifest, null, 2)}\n`,
  );
  writeFixtureFile(join(root, manifest.layout.runtime.main), 'import "./app/bun/index.js";\n');

  if (process.platform === "win32") {
    copyFileSync(cottontail, launcher);
  } else {
    writeFixtureFile(
      launcher,
      '#!/bin/sh\nset -eu\nHERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)\nexec "$HERE/bun" "$HERE/../Resources/main.js"\n',
    );
  }
  chmodSync(launcher, 0o755);
  return { host, manifest };
}

function bundlePaths(project) {
  const host = hostContract();
  const arch = process.arch === "arm64" ? "arm64" : "x64";
  const buildRoot = join(project, "build", `dev-${host.os}-${arch}`);
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

test("v2 Electrobun rejects invalid main processes without falling back to Bun", { timeout: 60_000 }, () => {
  mkdirSync(scratchRoot, { recursive: true });
  const fixture = mkdtempSync(join(scratchRoot, "invalid-main-process-"));
  const hutch = join(hutchRoot, "zig-out", "bin", executableName("hutch"));
  const engine = join(hutchRoot, "zig-out", "bin", executableName("hutch-engine"));
  const cottontail = resolveCottontail();
  const coreRoot = join(fixture, "core");
  createCoreFixture(coreRoot, "2.0.0-test.1");
  const diagnostic = "hutch electrobun: build.mainProcess must be bun, cottontail, zig, rust, go, or odin\n";

  try {
    for (const value of ['"bnu"', "42"]) {
      writeFixtureFile(
        join(fixture, "hutch.config.ts"),
        'export default { electrobun: { version: "2.0.0-test.1" } };\n',
      );
      writeFixtureFile(
        join(fixture, "electrobun.config.ts"),
        `export default { build: { mainProcess: ${value} } };\n`,
      );
      const env = {
        ...process.env,
        COTTONTAIL_BINARY: cottontail,
        DASH_COTTONTAIL: cottontail,
        HUTCH_ELECTROBUN_DEVKIT_ROOT: coreRoot,
        HUTCH_ENGINE_BINARY: engine,
        HUTCH_NO_UPDATE_CHECK: "1",
      };
      delete env.COTTONTAIL_ELECTROBUN_PACKAGE;
      const result = spawnSync(hutch, ["electrobun", "config"], {
        cwd: fixture,
        encoding: "utf8",
        env,
      });
      assert.equal(result.status, 1, result.stderr || result.stdout);
      assert.equal(result.stdout, "");
      assert.equal(result.stderr, diagnostic);
    }
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
});

test("v2 Electrobun product versions are exact Hutch config pins", { timeout: 60_000 }, () => {
  const fixture = mkdtempSync(join(tmpdir(), "hutch-electrobun-product-version-"));
  const hutch = join(hutchRoot, "zig-out", "bin", executableName("hutch"));
  const engine = join(hutchRoot, "zig-out", "bin", executableName("hutch-engine"));
  const cottontail = resolveCottontail();
  const coreRoot = join(fixture, "core");
  createCoreFixture(coreRoot, "2.0.0-test.1");
  const env = {
    ...process.env,
    COTTONTAIL_BINARY: cottontail,
    DASH_COTTONTAIL: cottontail,
    // Floating resolution must never reach the real channel in this test.
    ELECTROBUN_TEMPLATES_BASE_URL: "https://127.0.0.1:1/electrobun/templates",
    HUTCH_ELECTROBUN_DEVKIT_ROOT: coreRoot,
    HUTCH_ENGINE_BINARY: engine,
    HUTCH_NO_UPDATE_CHECK: "1",
  };
  delete env.COTTONTAIL_ELECTROBUN_PACKAGE;
  delete env.HUTCH_DEFAULT_ELECTROBUN;
  writeFixtureFile(join(fixture, "electrobun.config.ts"), "export default {};\n");

  const runConfig = (extraEnv = {}) => spawnSync(hutch, ["electrobun", "config"], {
    cwd: fixture,
    encoding: "utf8",
    env: { ...env, ...extraEnv },
  });

  try {
    // Unpinned projects float on the release channel; with the channel
    // unreachable the failure names the pin escape hatch.
    const missingConfig = runConfig();
    assert.equal(missingConfig.status, 1, missingConfig.stderr || missingConfig.stdout);
    assert.match(missingConfig.stderr, /no electrobun\.version is pinned/);

    for (const source of [
      "export default {};\n",
      "export default { electrobun: {} };\n",
    ]) {
      writeFixtureFile(join(fixture, "hutch.config.ts"), source);
      const floating = runConfig();
      assert.equal(floating.status, 1, floating.stderr || floating.stdout);
      assert.match(floating.stderr, /no electrobun\.version is pinned/);
    }

    // A shim-supplied default resolves without a config pin...
    rmSync(join(fixture, "hutch.config.ts"), { force: true });
    const viaDefault = runConfig({ HUTCH_DEFAULT_ELECTROBUN: "2.0.0-test.1" });
    assert.equal(viaDefault.status, 0, viaDefault.stderr || viaDefault.stdout);

    // ...but must itself be an exact version.
    const badDefault = runConfig({ HUTCH_DEFAULT_ELECTROBUN: "latest" });
    assert.equal(badDefault.status, 1, badDefault.stderr || badDefault.stdout);
    assert.match(badDefault.stderr, /HUTCH_DEFAULT_ELECTROBUN must be an exact semantic version/);

    for (const version of ["latest", "^2.0.0", "2.x", "not-semver"]) {
      writeFixtureFile(
        join(fixture, "hutch.config.ts"),
        `export default { electrobun: { version: "${version}" } };\n`,
      );
      const inexact = runConfig();
      assert.equal(inexact.status, 1, inexact.stderr || inexact.stdout);
      assert.match(inexact.stderr, /must be an exact semantic version/);
    }

    writeFixtureFile(
      join(fixture, "hutch.config.ts"),
      'export default { electrobun: { version: 2 } };\n',
    );
    const malformed = runConfig();
    assert.equal(malformed.status, 1, malformed.stderr || malformed.stdout);
    assert.match(malformed.stderr, /must be an object containing an exact string version/);

    writeFixtureFile(
      join(fixture, "hutch.config.ts"),
      'export default { electrobun: { version: "2.0.0-test.1" } };\n',
    );
    writeFixtureFile(
      join(fixture, "electrobun.config.ts"),
      'export default { electrobun: { version: "9.9.9" } };\n',
    );
    const appOwnedVersion = runConfig();
    assert.equal(appOwnedVersion.status, 1, appOwnedVersion.stderr || appOwnedVersion.stdout);
    assert.equal(
      appOwnedVersion.stderr,
      "hutch electrobun: electrobun.version belongs in hutch.config.ts; remove electrobun from electrobun.config.ts\n",
    );
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
});

test("v2 Electrobun rejects removed Bun version fields but permits unknown build fields", { timeout: 60_000 }, () => {
  mkdirSync(scratchRoot, { recursive: true });
  const fixture = mkdtempSync(join(scratchRoot, "legacy-bun-version-config-"));
  const hutch = join(hutchRoot, "zig-out", "bin", executableName("hutch"));
  const engine = join(hutchRoot, "zig-out", "bin", executableName("hutch-engine"));
  const cottontail = resolveCottontail();
  const coreRoot = join(fixture, "core");
  createCoreFixture(coreRoot, "2.0.0-test.1");
  const diagnostic = "hutch electrobun: build.bunVersion and build.bunnyBun were removed in v2; delete them because hutch.config.ts pins the exact Electrobun devkit and Bun runtime\n";
  const env = {
    ...process.env,
    COTTONTAIL_BINARY: cottontail,
    DASH_COTTONTAIL: cottontail,
    HUTCH_ELECTROBUN_DEVKIT_ROOT: coreRoot,
    HUTCH_ENGINE_BINARY: engine,
    HUTCH_NO_UPDATE_CHECK: "1",
  };
  delete env.COTTONTAIL_ELECTROBUN_PACKAGE;

  try {
    writeFixtureFile(
      join(fixture, "hutch.config.ts"),
      'export default { electrobun: { version: "2.0.0-test.1" } };\n',
    );
    for (const field of ["bunVersion", "bunnyBun"]) {
      writeFixtureFile(
        join(fixture, "electrobun.config.ts"),
        `export default { build: { mainProcess: "bun", ${field}: "1.3.8" } };\n`,
      );
      const result = spawnSync(hutch, ["electrobun", "config"], {
        cwd: fixture,
        encoding: "utf8",
        env,
      });
      assert.equal(result.status, 1, result.stderr || result.stdout);
      assert.equal(result.stdout, "");
      assert.equal(result.stderr, diagnostic);
    }

    writeFixtureFile(
      join(fixture, "electrobun.config.ts"),
      'export default { build: { mainProcess: "bun", futureBuildOption: true } };\n',
    );
    const forwardCompatible = spawnSync(hutch, ["electrobun", "config"], {
      cwd: fixture,
      encoding: "utf8",
      env,
    });
    assert.equal(
      forwardCompatible.status,
      0,
      forwardCompatible.stderr || forwardCompatible.stdout,
    );
    assert.equal(JSON.parse(forwardCompatible.stdout).build.futureBuildOption, true);
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
});

test("v2 mainProcess bun and the default package manager share the vendored bun toolchain", { timeout: 120_000 }, () => {
  mkdirSync(scratchRoot, { recursive: true });
  const fixture = mkdtempSync(join(scratchRoot, "non-index-main-entrypoint-"));
  const project = join(fixture, "project");
  const coreRoot = join(fixture, "electrobun-core");
  const home = join(fixture, "hutch-home");
  const version = "2.0.0-test.bun.1";
  const hutch = join(hutchRoot, "zig-out", "bin", executableName("hutch"));
  const engine = join(hutchRoot, "zig-out", "bin", executableName("hutch-engine"));
  const cottontail = resolveCottontail();

  try {
    assert.ok(existsSync(hutch), `Hutch must be built before this test: ${hutch}`);
    assert.ok(existsSync(engine), `Hutch engine must be built before this test: ${engine}`);
    const pinnedBunVersion = bunToolchainVersion(cottontail);
    const { manifest } = prepareBunDevkit(coreRoot, version, pinnedBunVersion, cottontail);
    const managedBun = installManagedBun(home, pinnedBunVersion, cottontail);
    const externalBun = prepareExternalBun(fixture);
    const managedBunSha256 = sha256(managedBun);
    const externalBunSha256 = sha256(externalBun.executable);
    const devkitManifestSha256 = sha256(join(coreRoot, "native-devkit.json"));
    assert.notEqual(
      externalBunSha256,
      managedBunSha256,
      "the PATH bun must be distinguishable from the managed toolchain bun",
    );

    writeFixtureFile(
      join(project, "src", "bun", "electrobun-main.ts"),
      `import { devkitMarker } from "electrobun/main";\nconsole.log("${marker}", devkitMarker, Bun.version);\n`,
    );
    writeFixtureFile(join(project, "electrobun.config.ts"), `
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
    writeFixtureFile(
      join(project, "hutch.config.ts"),
      `export default { electrobun: { version: "${version}" }, packageManager: "bun", scripts: {} };\n`,
    );

    const env = {
      ...process.env,
      COTTONTAIL_BINARY: cottontail,
      DASH_COTTONTAIL: cottontail,
      HUTCH_ELECTROBUN_DEVKIT_ROOT: coreRoot,
      HUTCH_ENGINE_BINARY: engine,
      HUTCH_HOME: home,
      HUTCH_NO_UPDATE_CHECK: "1",
      HUTCH_PM_CAPTURE: externalBun.capture,
    };
    delete env.COTTONTAIL_ELECTROBUN_PACKAGE;
    prependExecutablePath(env, externalBun.bin);
    assert.equal(existsSync(join(project, "package.json")), false);
    assert.equal(existsSync(join(project, "node_modules")), false);

    const packageManager = spawnSync(
      hutch,
      ["pm", externalBun.probe, "add", "left-pad", "--exact"],
      { cwd: project, encoding: "utf8", env },
    );
    assert.equal(packageManager.status, 0, packageManager.stderr || packageManager.stdout);
    const packageManagerInvocation = JSON.parse(readFileSync(externalBun.capture, "utf8"));
    assert.deepEqual(
      packageManagerInvocation.args,
      ["add", "left-pad", "--exact"],
      "packageManager: bun must preserve the manager's argv",
    );
    assert.equal(
      packageManagerInvocation.executableSha256,
      managedBunSha256,
      "packageManager: bun must execute the vendored toolchain bun, not the PATH bun",
    );
    assert.notEqual(packageManagerInvocation.executableSha256, externalBunSha256);

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
    const stagedBun = join(execDir, executableName("bun"));

    assert.ok(existsSync(canonicalMain), `Expected canonical main artifact: ${canonicalMain}`);
    assert.ok(existsSync(stagedBun), `Expected the vendored bun runtime: ${stagedBun}`);
    assert.equal(sha256(stagedBun), managedBunSha256, "the bundle must contain the exact managed toolchain bun");
    assert.equal(existsSync(sourceNamedOutput), false, "The source basename must not leak into the launcher contract");
    assert.match(readFileSync(canonicalMain, "utf8"), new RegExp(marker));
    assert.match(readFileSync(canonicalMain, "utf8"), /V2_DEVKIT_ALIAS/);
    assert.match(readFileSync(launchBridge, "utf8"), /\.\/app\/bun\/index\.js/);
    const buildMetadata = JSON.parse(readFileSync(join(resourcesDir, "build.json"), "utf8"));
    assert.equal(buildMetadata.mainProcess, "bun");
    assert.equal(buildMetadata.electrobunVersion, version);
    assert.equal(buildMetadata.runtimeVersions.bun, manifest.toolchains.bun.defaultVersion);
    assert.equal(existsSync(join(project, "node_modules")), false);
    const projectionMarker = readFileSync(join(project, ".hutch", "devkit", ".complete"), "utf8");
    assert.match(projectionMarker, new RegExp(`electrobun=${version.replaceAll(".", "\\.")}`));
    assert.match(projectionMarker, new RegExp(`source-manifest-sha256=${devkitManifestSha256}`));

    const launch = process.platform === "win32"
      ? spawnSync(stagedBun, [launchBridge], { cwd: execDir, encoding: "utf8", env })
      : spawnSync(hutch, ["electrobun", "run", "--env=dev"], { cwd: project, encoding: "utf8", env });
    assert.equal(launch.status, 0, launch.stderr || launch.stdout);
    assert.match(launch.stdout, new RegExp(marker));
    assert.match(launch.stdout, /V2_DEVKIT_ALIAS/);
    assert.match(launch.stdout, new RegExp(bunCompatibilityVersion(cottontail).replaceAll(".", "\\.")));
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
});
