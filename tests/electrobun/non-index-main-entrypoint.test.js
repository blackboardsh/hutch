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

function prepareBunDevkit(root, version, cottontail) {
  const host = hostContract();
  const manifest = createCoreFixture(root, version, host);
  const runtime = join(root, manifest.layout.runtime.bun);
  const launcher = join(root, manifest.layout.runtime.launcher);

  // The fixture runtime is Cottontail's Bun-compatible executable. Keeping it
  // inside the devkit (rather than resolving `bun` from PATH) exercises the
  // same immutable runtime path used by a published Electrobun artifact.
  copyFileSync(cottontail, runtime);
  chmodSync(runtime, 0o755);
  manifest.runtimes.bun.version = bunCompatibilityVersion(cottontail);
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
  return { host, manifest, runtime };
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
  const diagnostic = "hutch electrobun: build.mainProcess must be bun, cottontail, zig, rust, go, or odin\n";

  try {
    for (const value of ['"bnu"', "42"]) {
      writeFixtureFile(
        join(fixture, "electrobun.config.ts"),
        `export default { build: { mainProcess: ${value} } };\n`,
      );
      const env = {
        ...process.env,
        COTTONTAIL_BINARY: cottontail,
        DASH_COTTONTAIL: cottontail,
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

test("v2 Electrobun keeps external package-manager Bun separate from its bundled Bun runtime", { timeout: 120_000 }, () => {
  mkdirSync(scratchRoot, { recursive: true });
  const fixture = mkdtempSync(join(scratchRoot, "non-index-main-entrypoint-"));
  const project = join(fixture, "project");
  const coreRoot = join(fixture, "electrobun-core");
  const version = "2.0.0-test.bun.1";
  const hutch = join(hutchRoot, "zig-out", "bin", executableName("hutch"));
  const engine = join(hutchRoot, "zig-out", "bin", executableName("hutch-engine"));
  const cottontail = resolveCottontail();

  try {
    assert.ok(existsSync(hutch), `Hutch must be built before this test: ${hutch}`);
    assert.ok(existsSync(engine), `Hutch engine must be built before this test: ${engine}`);
    const { manifest, runtime: devkitBun } = prepareBunDevkit(coreRoot, version, cottontail);
    const externalBun = prepareExternalBun(fixture);
    assert.match(manifest.runtimes.bun.version, /^\d+\.\d+\.\d+/);
    const devkitBunSha256 = sha256(devkitBun);
    const externalBunSha256 = sha256(externalBun.executable);
    const devkitManifestSha256 = sha256(join(coreRoot, "native-devkit.json"));
    assert.notEqual(
      externalBunSha256,
      devkitBunSha256,
      "the external package manager must be distinguishable from the devkit runtime",
    );

    writeFixtureFile(
      join(project, "src", "bun", "electrobun-main.ts"),
      `import { devkitMarker } from "electrobun/main";\nconsole.log("${marker}", devkitMarker, Bun.version);\n`,
    );
    writeFixtureFile(join(project, "electrobun.config.ts"), `
export default {
  electrobun: { version: "${version}" },
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
      'export default { packageManager: "bun", scripts: {} };\n',
    );

    const env = {
      ...process.env,
      COTTONTAIL_BINARY: cottontail,
      DASH_COTTONTAIL: cottontail,
      HUTCH_ELECTROBUN_DEVKIT_ROOT: coreRoot,
      HUTCH_ENGINE_BINARY: engine,
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
      "packageManager: bun must preserve the external manager's argv",
    );
    assert.equal(
      packageManagerInvocation.executableSha256,
      externalBunSha256,
      "packageManager: bun must execute the PATH Bun, not the devkit runtime",
    );
    assert.notEqual(packageManagerInvocation.executableSha256, devkitBunSha256);

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
    assert.ok(existsSync(stagedBun), `Expected the devkit Bun runtime: ${stagedBun}`);
    assert.equal(sha256(stagedBun), devkitBunSha256, "the bundle must contain the exact devkit runtime");
    assert.equal(existsSync(sourceNamedOutput), false, "The source basename must not leak into the launcher contract");
    assert.match(readFileSync(canonicalMain, "utf8"), new RegExp(marker));
    assert.match(readFileSync(canonicalMain, "utf8"), /V2_DEVKIT_ALIAS/);
    assert.match(readFileSync(launchBridge, "utf8"), /\.\/app\/bun\/index\.js/);
    const buildMetadata = JSON.parse(readFileSync(join(resourcesDir, "build.json"), "utf8"));
    assert.equal(buildMetadata.mainProcess, "bun");
    assert.equal(buildMetadata.electrobunVersion, version);
    assert.equal(buildMetadata.runtimeVersions.bun, manifest.runtimes.bun.version);
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
    assert.match(launch.stdout, new RegExp(manifest.runtimes.bun.version.replaceAll(".", "\\.")));
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
});
