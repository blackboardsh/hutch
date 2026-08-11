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
import { dirname, join, resolve } from "node:path";
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

test("v2 Electrobun stages and launches a non-index Bun entrypoint from its exact devkit", { timeout: 120_000 }, () => {
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
    assert.match(manifest.runtimes.bun.version, /^\d+\.\d+\.\d+/);
    const devkitBunSha256 = sha256(devkitBun);
    const devkitManifestSha256 = sha256(join(coreRoot, "native-devkit.json"));

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

    const env = {
      ...process.env,
      COTTONTAIL_BINARY: cottontail,
      DASH_COTTONTAIL: cottontail,
      HUTCH_ELECTROBUN_DEVKIT_ROOT: coreRoot,
      HUTCH_ENGINE_BINARY: engine,
      HUTCH_NO_UPDATE_CHECK: "1",
    };
    delete env.COTTONTAIL_ELECTROBUN_PACKAGE;
    assert.equal(existsSync(join(project, "package.json")), false);
    assert.equal(existsSync(join(project, "node_modules")), false);
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
