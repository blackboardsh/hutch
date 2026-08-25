import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { createServer } from "node:http";
import {
	chmodSync,
	cpSync,
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

function run(command, args, options) {
  return new Promise((resolveRun, reject) => {
    const child = spawn(command, args, {
      ...options,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.once("error", reject);
    child.once("close", (status, signal) => {
      resolveRun({ status, signal, stdout, stderr });
    });
  });
}

function resolveCottontail() {
  const configured = process.env.COTTONTAIL_BINARY ?? process.env.DASH_COTTONTAIL;
  if (configured) return resolve(configured);

  const hutch = join(hutchRoot, "zig-out", "bin", executableName("hutch"));
  assert.ok(existsSync(hutch), `Hutch must be built before this test: ${hutch}`);

	const result = spawnSync(hutch, ["cottontail", "path"], {
		cwd: hutchRoot,
		encoding: "utf8",
		env: { ...process.env, HUTCH_ENGINE_BINARY: join(hutchRoot, "zig-out", "bin", executableName("hutch-engine")), HUTCH_NO_UPDATE_CHECK: "1" },
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
  cpSync(join(dirname(cottontail), "cottontail-core"), join(root, "cottontail-core"), { recursive: true });
  chmodSync(executable, 0o755);
  writeFixtureFile(join(root, ".hutch-toolchain"), version);
  return executable;
}

function installManagedCottontail(home, { version, revision, source }) {
  const root = join(
    home,
    "releases",
    "cottontail",
    version,
    revision,
    toolchainPlatformKey(),
  );
  const executable = join(root, "bin", executableName("cottontail"));
  mkdirSync(dirname(executable), { recursive: true });
  if (source) copyFileSync(source, executable);
  else writeFixtureFile(executable, "devkit-pinned cottontail runtime fixture\n");
  const core = join(dirname(executable), "cottontail-core");
  if (source) {
    cpSync(join(dirname(source), "cottontail-core"), core, { recursive: true });
    cpSync(join(dirname(source), "cottontail-stdlib"), join(dirname(executable), "cottontail-stdlib"), { recursive: true });
  } else {
    writeFixtureFile(join(core, "capability-namespace.jsc"), "fixture core bytecode\n");
  }
  chmodSync(executable, 0o755);
  writeFixtureFile(join(root, ".dash-installed"), "a".repeat(64));
  writeFixtureFile(join(root, "cottontail-release.json"), `${JSON.stringify({
    schema: 1,
    kind: "archive",
    product: "cottontail",
    version,
    revision,
    platform: toolchainPlatformKey(),
  })}\n`);
  writeFixtureFile(`${root}.lock`, "");
  return { executable, root };
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

function prepareLegacyBunDevkit(root, version, pinnedBunVersion, cottontail) {
  const host = hostContract();
  const manifest = createCoreFixture(root, version, host);
  delete manifest.toolchains.bun;
  delete manifest.toolchains.cottontail;
  manifest.runtimes = { bun: { version: pinnedBunVersion } };
  manifest.layout.runtime.bun = executableName("bun");
  copyFileSync(cottontail, join(root, manifest.layout.runtime.bun));
  chmodSync(join(root, manifest.layout.runtime.bun), 0o755);
  writeFixtureFile(
    join(root, "native-devkit.json"),
    `${JSON.stringify(manifest, null, 2)}\n`,
  );
  writeFixtureFile(join(root, manifest.layout.runtime.main), 'import "./app/bun/index.js";\n');

  const launcher = join(root, manifest.layout.runtime.launcher);
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
    writeFixtureFile(
      join(project, ".hutch", "devkit", "projection.json"),
      `${JSON.stringify({ product: { version: "8.8.8" } })}\n`,
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
      // The exact config pin must win over both the npm shim default above a
      // project and a stale projection below it.
      HUTCH_DEFAULT_ELECTROBUN: "latest",
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

    // This fixture uses Cottontail as a Bun-compatible stand-in. A real Bun
    // binary is monolithic, whereas current Cottontail releases keep their
    // bootstrap bytecode adjacent to the executable.
    cpSync(join(dirname(cottontail), "cottontail-core"), join(execDir, "cottontail-core"), { recursive: true });

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

test("Electrobun 2.0.1-beta.18 keeps its exact embedded Bun runtime", { timeout: 120_000 }, () => {
  mkdirSync(scratchRoot, { recursive: true });
  const fixture = mkdtempSync(join(scratchRoot, "beta-18-embedded-bun-"));
  const project = join(fixture, "project");
  const coreRoot = join(fixture, "electrobun-core");
  const home = join(fixture, "hutch-home");
  const version = "2.0.1-beta.18";
  const hutch = join(hutchRoot, "zig-out", "bin", executableName("hutch"));
  const engine = join(hutchRoot, "zig-out", "bin", executableName("hutch-engine"));
  const cottontail = resolveCottontail();

  try {
    const pinnedBunVersion = bunToolchainVersion(cottontail);
    const { manifest } = prepareLegacyBunDevkit(
      coreRoot,
      version,
      pinnedBunVersion,
      cottontail,
    );
    const embeddedBun = join(coreRoot, manifest.layout.runtime.bun);
    writeFixtureFile(
      join(project, "src", "bun", "electrobun-main.ts"),
      `console.log("${marker}", Bun.version);\n`,
    );
    writeFixtureFile(join(project, "electrobun.config.ts"), `
export default {
  app: {
    name: "NonIndexEntrypoint",
    identifier: "dev.electrobun.beta-18-embedded-bun",
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
      DASH_RELEASE_OFFLINE: "1",
      HUTCH_ELECTROBUN_DEVKIT_ROOT: coreRoot,
      HUTCH_ENGINE_BINARY: engine,
      HUTCH_HOME: home,
      HUTCH_NO_UPDATE_CHECK: "1",
    };
    delete env.COTTONTAIL_ELECTROBUN_PACKAGE;

    const packageManager = spawnSync(hutch, ["pm", "--version"], {
      cwd: project,
      encoding: "utf8",
      env,
    });
    assert.equal(
      packageManager.status,
      0,
      packageManager.stderr || packageManager.stdout,
    );
    assert.equal(packageManager.stdout.trim(), pinnedBunVersion);
    assert.equal(
      existsSync(join(home, "toolchains", "bun")),
      false,
      "beta.18 package-manager execution must use its embedded Bun",
    );

    const build = spawnSync(hutch, ["electrobun", "build", "--env=dev"], {
      cwd: project,
      encoding: "utf8",
      env,
    });
    assert.equal(build.status, 0, build.stderr || build.stdout);

    const { execDir, resourcesDir } = bundlePaths(project);
    const stagedBun = join(execDir, executableName("bun"));
    assert.equal(sha256(stagedBun), sha256(embeddedBun));
    const dependencyLock = readFileSync(join(project, ".hutch", "dependencies.lock"), "utf8");
    assert.doesNotMatch(
      dependencyLock,
      /toolchains\/bun\//,
      "the embedded runtime is reachable through the Electrobun core, not a replacement toolchain",
    );
    const buildMetadata = JSON.parse(readFileSync(join(resourcesDir, "build.json"), "utf8"));
    assert.equal(buildMetadata.electrobunVersion, version);
    assert.equal(buildMetadata.runtimeVersions.bun, pinnedBunVersion);
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
});

test("floating Electrobun packageManager bun follows npm default, projection, then channel", { timeout: 120_000 }, async () => {
  mkdirSync(scratchRoot, { recursive: true });
  const fixture = mkdtempSync(join(scratchRoot, "floating-package-manager-bun-"));
  const coreRoot = join(fixture, "electrobun-core");
  const home = join(fixture, "hutch-home");
  const version = "2.0.0-test.floating-pm.1";
  const hutch = join(hutchRoot, "zig-out", "bin", executableName("hutch"));
  const engine = join(hutchRoot, "zig-out", "bin", executableName("hutch-engine"));
  const cottontail = resolveCottontail();
  const pinnedBunVersion = bunToolchainVersion(cottontail);
  prepareBunDevkit(coreRoot, version, pinnedBunVersion, cottontail);
  installManagedBun(home, pinnedBunVersion, cottontail);
  const externalBun = prepareExternalBun(fixture);

  let baseUrl;
  let channelRequests = 0;
  const checksum = "b".repeat(64);
  const server = createServer((request, response) => {
    if (request.url !== "/channels/stable.json") {
      response.writeHead(404);
      response.end();
      return;
    }
    channelRequests += 1;
    response.writeHead(200, { "content-type": "application/json" });
    response.end(`${JSON.stringify({
      schema: 1,
      kind: "electrobun-template-channel",
      channel: "stable",
      version,
      revision: "a".repeat(40),
      tools: { hutch: "0.23.0", cottontail: "0.5.0" },
      templates: [{
        id: "fixture",
        name: "Fixture",
        description: "Local channel fixture",
        mainProcess: "bun",
        archive: {
          url: `${baseUrl}/artifacts/${checksum}.tar.gz`,
          sha256: checksum,
          size: 1,
        },
      }],
    })}\n`);
  });
  await new Promise((resolveListen, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolveListen);
  });
  const address = server.address();
  assert.equal(typeof address, "object");
  baseUrl = `http://127.0.0.1:${address.port}`;

  const commonEnv = {
    ...process.env,
    COTTONTAIL_BINARY: cottontail,
    DASH_COTTONTAIL: cottontail,
    ELECTROBUN_TEMPLATES_BASE_URL: baseUrl,
    HUTCH_ACTIVE_CHANNEL: "stable",
    HUTCH_ELECTROBUN_DEVKIT_ROOT: coreRoot,
    HUTCH_ENGINE_BINARY: engine,
    HUTCH_HOME: home,
    HUTCH_NO_UPDATE_CHECK: "1",
  };
  delete commonEnv.COTTONTAIL_ELECTROBUN_PACKAGE;
  delete commonEnv.DASH_RELEASE_OFFLINE;
  delete commonEnv.HUTCH_DEFAULT_ELECTROBUN;
  prependExecutablePath(commonEnv, externalBun.bin);

  const makeProject = (name) => {
    const project = join(fixture, name);
    writeFixtureFile(
      join(project, "hutch.config.ts"),
      'export default { packageManager: "bun", scripts: {} };\n',
    );
    writeFixtureFile(join(project, "electrobun.config.ts"), "export default {};\n");
    return project;
  };

  try {
    const npmDefaultProject = makeProject("npm-default");
    const npmDefault = spawnSync(hutch, ["pm", "--version"], {
      cwd: npmDefaultProject,
      encoding: "utf8",
      env: {
        ...commonEnv,
        DASH_RELEASE_OFFLINE: "1",
        HUTCH_DEFAULT_ELECTROBUN: version,
      },
    });
    assert.equal(npmDefault.status, 0, npmDefault.stderr || npmDefault.stdout);
    assert.equal(npmDefault.stdout.trim(), pinnedBunVersion);
    assert.equal(channelRequests, 0, "the npm default must avoid channel resolution");

    const projectionProject = makeProject("projection");
    writeFixtureFile(
      join(projectionProject, ".hutch", "devkit", "projection.json"),
      `${JSON.stringify({
        schemaVersion: 1,
        kind: "electrobun-devkit-projection",
        product: { name: "electrobun", version },
      })}\n`,
    );
    const projection = spawnSync(hutch, ["pm", "--version"], {
      cwd: projectionProject,
      encoding: "utf8",
      env: { ...commonEnv, DASH_RELEASE_OFFLINE: "1" },
    });
    assert.equal(projection.status, 0, projection.stderr || projection.stdout);
    assert.equal(projection.stdout.trim(), pinnedBunVersion);
    assert.equal(channelRequests, 0, "an existing projection must avoid channel resolution");

    const channelProject = makeProject("channel");
    const channel = await run(hutch, ["pm", "--version"], {
      cwd: channelProject,
      env: commonEnv,
    });
    assert.equal(channel.status, 0, channel.stderr || channel.stdout);
    assert.equal(channel.stdout.trim(), pinnedBunVersion);
    assert.equal(channelRequests, 1, "a fully floating project must resolve the active channel");

    const genericProject = join(fixture, "generic-bun");
    const genericHome = join(fixture, "generic-home");
    writeFixtureFile(
      join(genericProject, "hutch.config.ts"),
      'export default { packageManager: "bun", scripts: {} };\n',
    );
    const generic = spawnSync(hutch, ["pm", "--version"], {
      cwd: genericProject,
      encoding: "utf8",
      env: {
        ...commonEnv,
        DASH_RELEASE_OFFLINE: "1",
        HUTCH_HOME: genericHome,
      },
    });
    assert.equal(generic.status, 1, generic.stderr || generic.stdout);
    assert.match(
      generic.stderr,
      /bun 1\.4\.0 is not installed/,
      "a generic Bun project must retain Hutch's default instead of loading an Electrobun devkit",
    );
    assert.equal(channelRequests, 1, "generic Bun projects must not query Electrobun channels");
  } finally {
    await new Promise((resolveClose) => server.close(resolveClose));
    rmSync(fixture, { recursive: true, force: true });
  }
});

test("devkit-pinned Cottontail is registered and provenanced separately from Hutch's build runtime", { timeout: 120_000 }, () => {
  mkdirSync(scratchRoot, { recursive: true });
  const fixture = mkdtempSync(join(scratchRoot, "pinned-cottontail-runtime-"));
  const project = join(fixture, "project");
  const coreRoot = join(fixture, "electrobun-core");
  const home = join(fixture, "hutch-home");
  const version = "2.0.0-test.cottontail-runtime.1";
  const pairedVersion = "9.7.6";
  const pinnedVersion = "9.8.7";
  const hutch = join(hutchRoot, "zig-out", "bin", executableName("hutch"));
  const engine = join(hutchRoot, "zig-out", "bin", executableName("hutch-engine"));
  const localCottontail = resolveCottontail();

  try {
    const paired = installManagedCottontail(home, {
      version: pairedVersion,
      revision: "a".repeat(40),
      source: localCottontail,
    });
    const pinned = installManagedCottontail(home, {
      version: pinnedVersion,
      revision: "b".repeat(40),
    });
    const manifest = createCoreFixture(coreRoot, version, hostContract());
    manifest.toolchains.cottontail = { defaultVersion: pinnedVersion };
    writeFixtureFile(
      join(coreRoot, "native-devkit.json"),
      `${JSON.stringify(manifest, null, 2)}\n`,
    );
    writeFixtureFile(
      join(project, "src", "bun", "electrobun-main.ts"),
      `console.log("${marker}");\n`,
    );
    writeFixtureFile(join(project, "electrobun.config.ts"), `
export default {
  app: {
    name: "NonIndexEntrypoint",
    identifier: "dev.electrobun.pinned-cottontail-runtime",
    version: "0.0.0",
  },
  build: {
    mainProcess: "cottontail",
    cottontail: { entrypoint: "src/bun/electrobun-main.ts" },
    mac: { icons: null, codesign: false, notarize: false, bundleCEF: false, bundleWGPU: false },
    win: { bundleCEF: false, bundleWGPU: false },
    linux: { bundleCEF: false, bundleWGPU: false },
  },
};
`);
    writeFixtureFile(
      join(project, "hutch.config.ts"),
      `export default { electrobun: { version: "${version}" }, scripts: {} };\n`,
    );

    const env = {
      ...process.env,
      COTTONTAIL_BINARY: paired.executable,
      DASH_COTTONTAIL: paired.executable,
      DASH_RELEASE_OFFLINE: "1",
      HUTCH_ELECTROBUN_DEVKIT_ROOT: coreRoot,
      HUTCH_ENGINE_BINARY: engine,
      HUTCH_HOME: home,
      HUTCH_NO_UPDATE_CHECK: "1",
    };
    delete env.COTTONTAIL_ELECTROBUN_PACKAGE;

    const build = spawnSync(hutch, ["electrobun", "build", "--env=dev"], {
      cwd: project,
      encoding: "utf8",
      env,
    });
    assert.equal(build.status, 0, build.stderr || build.stdout);

    const dependencyLock = readFileSync(join(project, ".hutch", "dependencies.lock"), "utf8");
    const pairedRelative = `releases/cottontail/${pairedVersion}/${"a".repeat(40)}/${toolchainPlatformKey()}`;
    const pinnedRelative = `releases/cottontail/${pinnedVersion}/${"b".repeat(40)}/${toolchainPlatformKey()}`;
    assert.match(dependencyLock, new RegExp(pairedRelative));
    assert.match(dependencyLock, new RegExp(pinnedRelative));

    const { execDir, resourcesDir } = bundlePaths(project);
    const stagedCottontail = join(execDir, executableName("cottontail"));
    assert.equal(sha256(stagedCottontail), sha256(pinned.executable));
    assert.notEqual(sha256(stagedCottontail), sha256(paired.executable));
    const buildMetadata = JSON.parse(readFileSync(join(resourcesDir, "build.json"), "utf8"));
    assert.equal(buildMetadata.mainProcess, "cottontail");
    assert.equal(buildMetadata.runtimeVersions.cottontail, pinnedVersion);
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
});
