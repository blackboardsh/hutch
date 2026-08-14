import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { createServer } from "node:http";
import os from "node:os";
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

function resolveCottontail() {
  const configured = process.env.COTTONTAIL_BINARY ?? process.env.DASH_COTTONTAIL;
  if (configured) return resolve(configured);
  const hutch = join(hutchRoot, "zig-out", "bin", executableName("hutch"));
  const result = spawnSync(hutch, ["cottontail", "path", "production"], {
    cwd: hutchRoot,
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  return result.stdout.trim();
}

function run(command, args, options) {
  return new Promise((resolveRun, reject) => {
    const child = spawn(command, args, options);
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", (status) => resolveRun({ status, stdout, stderr }));
  });
}

function startRun(command, args, options) {
  const child = spawn(command, args, options);
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  const result = new Promise((resolveRun, reject) => {
    child.on("error", reject);
    child.on("close", (status, signal) => resolveRun({ status, signal, stdout, stderr }));
  });
  return { child, result };
}

function waitFor(promise, timeoutMilliseconds, message) {
  let timer;
  return Promise.race([
    promise,
    new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(message)), timeoutMilliseconds);
    }),
  ]).finally(() => clearTimeout(timer));
}

test("v2 sync and build use only the installed devkit, without an npm package", { timeout: 120_000 }, async () => {
  const fixture = mkdtempSync(join(os.tmpdir(), "hutch-v2-devkit-"));
  const project = join(fixture, "project");
  const coreFiles = join(fixture, "core-files");
  const archive = join(fixture, "electrobun-core.tar.gz");
  const dashHome = join(fixture, "dash-home");
  const host = hostContract();
  const version = "2.0.0-test.1";
  const hutch = join(hutchRoot, "zig-out", "bin", executableName("hutch"));
  const engine = join(hutchRoot, "zig-out", "bin", executableName("hutch-engine"));
  const cottontail = resolveCottontail();

  try {
    createCoreFixture(coreFiles, version, host);
    const packed = spawnSync("tar", ["-czf", archive, "-C", coreFiles, "."], { encoding: "utf8" });
    assert.equal(packed.status, 0, packed.stderr || packed.stdout);
    const archiveBytes = readFileSync(archive);
    const archiveSha256 = createHash("sha256").update(archiveBytes).digest("hex");

    writeFixtureFile(join(project, "src", "bun", "index.ts"), "import { devkitMarker } from 'electrobun/main';\nconsole.log(devkitMarker);\n");
    writeFixtureFile(join(project, "electrobun.config.ts"), `
import type { ElectrobunConfig } from "electrobun";
export default {
  app: { name: "V2Devkit", identifier: "dev.electrobun.v2-devkit", version: "0.0.0" },
  build: {
    mainProcess: "cottontail",
    cottontail: { entrypoint: "src/bun/index.ts" },
    mac: { icons: null, codesign: false, notarize: false, bundleCEF: false, bundleWGPU: false },
    win: { bundleCEF: false, bundleWGPU: false },
    linux: { bundleCEF: false, bundleWGPU: false },
  },
} satisfies ElectrobunConfig;
`);
    writeFixtureFile(
      join(project, "hutch.config.ts"),
      `export default { electrobun: { version: "${version}" } };\n`,
    );
    assert.equal(existsSync(join(project, "package.json")), false);
    assert.equal(existsSync(join(project, "node_modules")), false);

    let requests = 0;
    const server = createServer((request, response) => {
      requests += 1;
      const basePath = `/releases/download/v${version}`;
      if (request.url === `${basePath}/electrobun-artifacts.json`) {
        const origin = `http://127.0.0.1:${server.address().port}/releases/download`;
        const body = JSON.stringify({
          schemaVersion: 1,
          product: { name: "electrobun", version },
          devkit: { manifest: "native-devkit.json", schemaVersion: 1 },
          abi: {
            core: { name: "electrobun-core", version: 1 },
            sdk: { name: "electrobun-sdk", version: 1 },
          },
          platforms: {
            [host.key]: {
              target: { os: host.os, arch: host.arch },
              core: {
                url: `${origin}/v${version}/electrobun-core-${host.asset}.tar.gz`,
                size: archiveBytes.length,
                sha256: archiveSha256,
              },
            },
          },
        });
        setTimeout(() => {
          response.writeHead(200, { "content-type": "application/json" });
          response.end(body);
        }, 75);
        return;
      }
      if (request.url === `${basePath}/electrobun-core-${host.asset}.tar.gz`) {
        setTimeout(() => {
          response.writeHead(200, { "content-type": "application/gzip" });
          response.end(archiveBytes);
        }, 75);
        return;
      }
      response.writeHead(404);
      response.end();
    });
    await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
    const address = server.address();
    assert.ok(address && typeof address === "object");

    try {
      const env = {
        ...process.env,
        COTTONTAIL_BINARY: cottontail,
        DASH_COTTONTAIL: cottontail,
        DASH_HOME: dashHome,
        ELECTROBUN_RELEASES_BASE_URL: `http://127.0.0.1:${address.port}/releases/download`,
        HUTCH_ENGINE_BINARY: engine,
        HUTCH_NO_UPDATE_CHECK: "1",
      };
      const coldSyncs = await Promise.all(
        Array.from({ length: 8 }, () => run(hutch, ["electrobun", "sync"], {
          cwd: project,
          env,
          stdio: ["ignore", "pipe", "pipe"],
        })),
      );
      for (const sync of coldSyncs) {
        assert.equal(sync.status, 0, sync.stderr || sync.stdout);
        assert.match(sync.stdout, /electrobun sync complete/);
      }
      assert.equal(
        requests,
        2,
        "concurrent cold syncs must share one artifact index and one core archive download",
      );

      const releaseRoot = join(dashHome, "releases", "electrobun", version, host.key);
      assert.equal(existsSync(join(dashHome, "cache")), false, "artifact metadata must not persist");
      assert.ok(existsSync(`${releaseRoot}.lock`));
      assert.ok(existsSync(join(project, ".hutch", "devkit.lock")));
      assert.deepEqual(
        readdirSync(join(project, ".hutch")).filter((name) =>
          name.startsWith(".devkit-tmp-") || name.startsWith(".devkit-old-")),
        [],
      );
      assert.ok(existsSync(join(releaseRoot, "native-devkit.json")));
      assert.ok(existsSync(join(project, ".hutch", "devkit", "api", "sdks", "main", "index.ts")));
      assert.ok(existsSync(join(project, ".hutch", "devkit", "go-sdk", "go.mod")));
      assert.match(readFileSync(join(project, ".hutch", "devkit", "tsconfig.json"), "utf8"), /electrobun\/main/);
      const dependencyLock = readFileSync(join(project, ".hutch", "dependencies.lock"), "utf8");
      assert.match(dependencyLock, /hutch-project-dependencies/);
      assert.match(dependencyLock, new RegExp(`releases/electrobun/${version}/${host.key}`));
      assert.match(dependencyLock, new RegExp(archiveSha256));
      const registrations = readdirSync(join(dashHome, "state", "projects"))
        .filter((name) => name.endsWith(".json"));
      assert.equal(registrations.length, 1);
      const registration = readFileSync(
        join(dashHome, "state", "projects", registrations[0]),
        "utf8",
      );
      assert.match(registration, /hutch-project-registration/);
      assert.match(registration, new RegExp(`releases/electrobun/${version}/${host.key}`));

      assert.ok(existsSync(releaseRoot), "a registered exact devkit must remain installed");

      const projectedMainSdk = join(project, ".hutch", "devkit", "api", "sdks", "main", "index.ts");
      writeFixtureFile(
        projectedMainSdk,
        "export const devkitMarker = 'PROJECT_SDK_EDIT';\nexport type { ElectrobunConfig } from '../../config/ElectrobunConfig';\n",
      );
      assert.match(
        readFileSync(join(releaseRoot, "api", "sdks", "main", "index.ts"), "utf8"),
        /V2_DEVKIT_ALIAS/,
        "editing the project SDK must not mutate the installed core",
      );

      const build = await run(hutch, ["electrobun", "build", "--env=dev"], {
        cwd: project,
        env,
        stdio: ["ignore", "pipe", "pipe"],
      });
      assert.equal(build.status, 0, build.stderr || build.stdout);
      assert.equal(requests, 2, "build should reuse the installed core and projected devkit");
      const bundledMain = process.platform === "darwin"
        ? join(project, "build", `dev-${host.os}-${host.arch}`, "V2Devkit-dev.app", "Contents", "Resources", "app", "bun", "index.js")
        : join(project, "build", `dev-${host.os}-${host.arch}`, "V2Devkit-dev", "Resources", "app", "bun", "index.js");
      assert.match(readFileSync(bundledMain, "utf8"), /PROJECT_SDK_EDIT/);
      assert.doesNotMatch(readFileSync(bundledMain, "utf8"), /V2_DEVKIT_ALIAS/);
      assert.match(readFileSync(projectedMainSdk, "utf8"), /PROJECT_SDK_EDIT/);
      assert.equal(existsSync(join(project, "node_modules")), false);

      rmSync(releaseRoot, { recursive: true, force: true });
      rmSync(join(project, ".hutch", "devkit"), { recursive: true, force: true });
      const configPath = join(project, "electrobun.config.ts");
      writeFileSync(
        configPath,
        readFileSync(configPath, "utf8").replaceAll("bundleCEF: false", "bundleCEF: true"),
      );
      const missingLocalCef = await run(hutch, ["electrobun", "sync"], {
        cwd: project,
        env: { ...env, HUTCH_ELECTROBUN_DEVKIT_ROOT: coreFiles },
        stdio: ["ignore", "pipe", "pipe"],
      });
      assert.equal(missingLocalCef.status, 1);
      assert.match(missingLocalCef.stderr, /ElectrobunLocalDevkitCefNotFound/);

      writeFixtureFile(join(coreFiles, "cef", "icudtl.dat"), "cef");
      const localSync = await run(hutch, ["electrobun", "sync"], {
        cwd: project,
        env: { ...env, HUTCH_ELECTROBUN_DEVKIT_ROOT: coreFiles },
        stdio: ["ignore", "pipe", "pipe"],
      });
      assert.equal(localSync.status, 0, localSync.stderr || localSync.stdout);
      assert.equal(requests, 2, "an explicit local devkit root must bypass release downloads");
      assert.ok(existsSync(join(project, ".hutch", "devkit", "projection.json")));

      writeFixtureFile(
        join(coreFiles, "api", "sdks", "main", "index.ts"),
        "export const devkitMarker = 'LOCAL_SDK_EDIT';\n",
      );
      const refreshedLocalSync = await run(hutch, ["electrobun", "sync"], {
        cwd: project,
        env: { ...env, HUTCH_ELECTROBUN_DEVKIT_ROOT: coreFiles },
        stdio: ["ignore", "pipe", "pipe"],
      });
      assert.equal(refreshedLocalSync.status, 0, refreshedLocalSync.stderr || refreshedLocalSync.stdout);
      assert.match(
        readFileSync(join(project, ".hutch", "devkit", "api", "sdks", "main", "index.ts"), "utf8"),
        /LOCAL_SDK_EDIT/,
      );
    } finally {
      await new Promise((resolveClose, reject) => server.close((error) => error ? reject(error) : resolveClose()));
    }
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
});

test(
  "concurrent cold native toolchain resolution survives a crashed publisher",
  { timeout: 120_000, skip: process.platform === "win32" },
  async () => {
    const fixture = mkdtempSync(join(os.tmpdir(), "hutch-v2-toolchain-race-"));
    const project = join(fixture, "project");
    const coreFiles = join(fixture, "core-files");
    const dashHome = join(fixture, "dash-home");
    const host = hostContract();
    const electrobunVersion = "2.0.0-test.toolchain-race.1";
    const odinVersion = "dev-2099-01a";
    const hutch = join(hutchRoot, "zig-out", "bin", executableName("hutch"));
    const engine = join(hutchRoot, "zig-out", "bin", executableName("hutch-engine"));
    const cottontail = resolveCottontail();
    const proxySockets = new Set();
    let proxyRequests = 0;
    let resolveProxyRequest;
    const firstProxyRequest = new Promise((resolveRequest) => { resolveProxyRequest = resolveRequest; });
    const proxy = createServer((_request, _response) => {
      proxyRequests += 1;
      resolveProxyRequest();
    });
    proxy.on("connect", (_request, socket) => {
      proxyRequests += 1;
      proxySockets.add(socket);
      socket.on("close", () => proxySockets.delete(socket));
      resolveProxyRequest();
      // Deliberately leave the tunnel unanswered. The first resolver remains
      // inside the download while holding the persistent toolchain root lock.
    });

    let holder;
    try {
      createCoreFixture(coreFiles, electrobunVersion, host);
      writeFixtureFile(join(project, "src", "odin", "main.odin"), "package main\n");
      writeFixtureFile(join(project, "electrobun.config.ts"), `
export default {
  app: { name: "ToolchainRace", identifier: "dev.electrobun.toolchain-race", version: "0.0.0" },
  build: {
    mainProcess: "odin",
    odin: { entrypoint: "src/odin/main.odin", version: "${odinVersion}" },
    mac: { icons: null, codesign: false, notarize: false, bundleCEF: false, bundleWGPU: false },
    win: { bundleCEF: false, bundleWGPU: false },
    linux: { bundleCEF: false, bundleWGPU: false },
  },
};
`);
      writeFixtureFile(
        join(project, "hutch.config.ts"),
        `export default { electrobun: { version: "${electrobunVersion}" } };\n`,
      );

      await new Promise((resolveListen) => proxy.listen(0, "127.0.0.1", resolveListen));
      const proxyAddress = proxy.address();
      assert.ok(proxyAddress && typeof proxyAddress === "object");
      const proxyUrl = `http://127.0.0.1:${proxyAddress.port}`;
      const env = {
        ...process.env,
        COTTONTAIL_BINARY: cottontail,
        DASH_COTTONTAIL: cottontail,
        DASH_HOME: dashHome,
        HUTCH_ELECTROBUN_DEVKIT_ROOT: coreFiles,
        HUTCH_ENGINE_BINARY: engine,
        HUTCH_NO_UPDATE_CHECK: "1",
        HTTPS_PROXY: proxyUrl,
        https_proxy: proxyUrl,
        NO_PROXY: "",
        no_proxy: "",
      };

      holder = startRun(hutch, ["electrobun", "sync"], {
        cwd: project,
        env,
        stdio: ["ignore", "pipe", "pipe"],
      });
      await waitFor(
        firstProxyRequest,
        15_000,
        "the first cold toolchain resolver did not reach the blocking proxy",
      );
      assert.equal(holder.child.kill("SIGSTOP"), true);

      let completedWaiters = 0;
      const waiters = Array.from({ length: 8 }, () =>
        run(hutch, ["electrobun", "sync"], {
          cwd: project,
          env,
          stdio: ["ignore", "pipe", "pipe"],
        }).then((result) => {
          completedWaiters += 1;
          return result;
        }));
      await new Promise((resolveDelay) => setTimeout(resolveDelay, 1_000));
      assert.equal(completedWaiters, 0, "cold waiters must remain behind the held toolchain lock");
      assert.equal(proxyRequests, 1, "blocked waiters must not start duplicate downloads");

      const toolchainRoot = join(dashHome, "toolchains", "odin", odinVersion, host.key);
      mkdirSync(toolchainRoot, { recursive: true });
      const odin = join(toolchainRoot, "odin");
      writeFileSync(odin, "#!/bin/sh\nprintf 'dev-2099-01\\n'\n");
      chmodSync(odin, 0o755);
      writeFileSync(join(toolchainRoot, ".hutch-toolchain"), `${odinVersion}\n`);

      assert.equal(holder.child.kill("SIGKILL"), true);
      const crashed = await holder.result;
      assert.equal(crashed.signal, "SIGKILL");
      const results = await Promise.all(waiters);
      for (const result of results) {
        assert.equal(result.status, 0, result.stderr || result.stdout);
        assert.match(result.stdout, /electrobun sync complete/);
      }
      assert.equal(proxyRequests, 1, "waiters must recheck the installed toolchain instead of downloading");
      assert.ok(existsSync(`${toolchainRoot}.lock`));
      assert.equal(
        readFileSync(join(toolchainRoot, ".hutch-toolchain"), "utf8").trim(),
        odinVersion,
      );
      assert.ok(existsSync(join(project, ".hutch", "devkit", "projection.json")));
      assert.match(
        readFileSync(join(project, ".hutch", "dependencies.lock"), "utf8"),
        new RegExp(`toolchains/odin/${odinVersion}/${host.key}`),
      );
    } finally {
      if (holder?.child.exitCode == null && holder?.child.signalCode == null) {
        holder.child.kill("SIGKILL");
        await holder.result.catch(() => {});
      }
      for (const socket of proxySockets) socket.destroy();
      if (proxy.listening) {
        await new Promise((resolveClose) => proxy.close(resolveClose));
      }
      rmSync(fixture, { recursive: true, force: true });
    }
  },
);

test("v2 Rust builds use the project Cargo manifest and lock without npm", { timeout: 120_000 }, async () => {
  const rustc = spawnSync("rustc", ["--version"], { encoding: "utf8" });
  const cargo = spawnSync("cargo", ["--version"], { encoding: "utf8" });
  assert.equal(rustc.status, 0, rustc.stderr || "rustc is required for this integration");
  assert.equal(cargo.status, 0, cargo.stderr || "cargo is required for this integration");
  const rustVersion = /^rustc (\d+\.\d+\.\d+)\b/.exec(rustc.stdout)?.[1];
  const cargoVersion = /^cargo (\d+\.\d+\.\d+)\b/.exec(cargo.stdout)?.[1];
  assert.ok(rustVersion, `unexpected rustc version: ${rustc.stdout}`);
  assert.equal(cargoVersion, rustVersion, "cargo and rustc must come from the same exact toolchain");

  const fixture = mkdtempSync(join(os.tmpdir(), "hutch-v2-rust-cargo-"));
  const project = join(fixture, "project");
  const coreFiles = join(fixture, "core-files");
  const dashHome = join(fixture, "dash-home");
  const host = hostContract();
  const version = "2.0.0-test.rust.1";
  const hutch = join(hutchRoot, "zig-out", "bin", executableName("hutch"));
  const engine = join(hutchRoot, "zig-out", "bin", executableName("hutch-engine"));
  const cottontail = resolveCottontail();

  try {
    createCoreFixture(coreFiles, version, host);
    const cargoManifest = `[package]
name = "rust-cargo-fixture"
version = "0.0.0"
edition = "2021"
publish = false

[[bin]]
name = "main"
path = "src/main.rs"

[dependencies]
electrobun = { path = ".hutch/devkit/rust-sdk" }
`;
    writeFixtureFile(join(project, "Cargo.toml"), cargoManifest);
    const lockContents = `# This file is automatically @generated by Cargo.
# It is not intended for manual editing.
version = 4

[[package]]
name = "electrobun"
version = "2.0.0"

[[package]]
name = "rust-cargo-fixture"
version = "0.0.0"
dependencies = [
 "electrobun",
]
`;
    writeFixtureFile(join(project, "Cargo.lock"), lockContents);
    writeFixtureFile(join(project, "src", "main.rs"), `use electrobun::MARKER;

fn main() {
    assert!(MARKER);
}
`);
    writeFixtureFile(join(project, "electrobun.config.ts"), `
import type { ElectrobunConfig } from "electrobun";
export default {
  app: { name: "RustCargo", identifier: "dev.electrobun.rust-cargo", version: "0.0.0" },
  build: {
    mainProcess: "rust",
    rust: { version: "${rustVersion}", manifest: "Cargo.toml", binary: "main" },
    mac: { icons: null, codesign: false, notarize: false, bundleCEF: false, bundleWGPU: false },
    win: { bundleCEF: false, bundleWGPU: false },
    linux: { bundleCEF: false, bundleWGPU: false },
  },
} satisfies ElectrobunConfig;
`);
    writeFixtureFile(
      join(project, "hutch.config.ts"),
      `export default { electrobun: { version: "${version}" } };\n`,
    );
    assert.equal(existsSync(join(project, "package.json")), false);
    assert.equal(existsSync(join(project, "node_modules")), false);

    const env = {
      ...process.env,
      COTTONTAIL_BINARY: cottontail,
      DASH_COTTONTAIL: cottontail,
      DASH_HOME: dashHome,
      HUTCH_ELECTROBUN_DEVKIT_ROOT: coreFiles,
      HUTCH_ENGINE_BINARY: engine,
      HUTCH_NO_UPDATE_CHECK: "1",
      RUSTC_WRAPPER: join(fixture, "poisoned-rustc-wrapper"),
      RUSTC_WORKSPACE_WRAPPER: join(fixture, "poisoned-workspace-wrapper"),
    };
    const build = await run(hutch, ["electrobun", "build", "--env=dev"], {
      cwd: project,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    assert.equal(build.status, 0, build.stderr || build.stdout);

    const buildRoot = join(project, "build", `dev-${host.os}-${host.arch}`);
    const stagedMain = process.platform === "darwin"
      ? join(buildRoot, "RustCargo-dev.app", "Contents", "MacOS", executableName("main"))
      : join(buildRoot, "RustCargo-dev", "bin", executableName("main"));
    assert.ok(existsSync(stagedMain), `missing staged Rust main binary at ${stagedMain}`);
    assert.ok(existsSync(join(project, ".hutch", "devkit", "rust-sdk", "Cargo.toml")));
    assert.equal(readFileSync(join(project, "Cargo.lock"), "utf8"), lockContents);
    assert.equal(existsSync(join(project, "node_modules")), false);
    assert.equal(
      existsSync(join(buildRoot, ".electrobun-rust-main", `${host.os}-${host.arch}`, "main.rs")),
      false,
      "Hutch must not synthesize a Rust wrapper",
    );
    assert.equal(existsSync(join(dirname(stagedMain), "Cargo.toml")), false);
    assert.equal(existsSync(join(dirname(stagedMain), "deps")), false);

    writeFixtureFile(join(project, "stale-sdk", "Cargo.toml"), `[package]
name = "electrobun"
version = "2.0.0"
edition = "2021"
[lib]
path = "electrobun.rs"
`);
    writeFixtureFile(join(project, "stale-sdk", "electrobun.rs"), "pub const MARKER: bool = true;\n");
    writeFixtureFile(
      join(project, "Cargo.toml"),
      cargoManifest.replace('.hutch/devkit/rust-sdk', 'stale-sdk'),
    );
    const staleSdk = await run(hutch, ["electrobun", "build", "--env=dev"], {
      cwd: project,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    assert.equal(staleSdk.status, 1, "Cargo must use the SDK from the selected projected devkit");
    assert.match(staleSdk.stderr, /RustSdkDependencyMismatch|expected projected SDK/i);
    writeFixtureFile(join(project, "Cargo.toml"), cargoManifest);

    rmSync(join(project, "Cargo.lock"));
    const unlocked = await run(hutch, ["electrobun", "build", "--env=dev"], {
      cwd: project,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    assert.equal(unlocked.status, 1, "a missing project lock must fail the Cargo build");
    assert.match(unlocked.stderr, /RustBuildFailed|--locked|lock file/i);
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
});
