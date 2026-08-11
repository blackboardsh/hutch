import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
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

async function waitForPath(path, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  while (!existsSync(path)) {
    if (Date.now() >= deadline) throw new Error(`timed out waiting for ${path}`);
    await new Promise((resolveWait) => setTimeout(resolveWait, 20));
  }
}

test("exact Electrobun artifacts are cached and same-project builds serialize", { timeout: 120_000 }, async () => {
  const fixture = mkdtempSync(join(os.tmpdir(), "hutch-published-electrobun-"));
  const project = join(fixture, "project");
  const coreFiles = join(fixture, "core-files");
  const archive = join(fixture, "electrobun-core.tar.gz");
  const dashHome = join(fixture, "dash-home");
  const names = hostContract();
  const version = "9.8.7-test.1";
  const hutch = join(hutchRoot, "zig-out", "bin", executableName("hutch"));
  const engine = join(hutchRoot, "zig-out", "bin", executableName("hutch-engine"));
  const cottontail = resolveCottontail();

  try {
    createCoreFixture(coreFiles, version, names);
    const packed = spawnSync("tar", ["-czf", archive, "-C", coreFiles, "."], { encoding: "utf8" });
    assert.equal(packed.status, 0, packed.stderr || packed.stdout);
    const archiveBytes = readFileSync(archive);
    const archiveSha256 = createHash("sha256").update(archiveBytes).digest("hex");

    writeFixtureFile(join(project, "src", "bun", "index.ts"), "console.log('published artifact fixture');\n");
    writeFixtureFile(join(project, "claim-build-window.mjs"), `
import { closeSync, existsSync, openSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const sentinel = process.env.HUTCH_BUILD_SENTINEL;
if (sentinel) {
  const descriptor = openSync(sentinel, "wx");
  closeSync(descriptor);
  if (process.env.HUTCH_BUILD_LEADER === "1") {
    const canary = join(process.env.ELECTROBUN_BUILD_DIR, ".serialization-canary");
    writeFileSync(canary, "");
    writeFileSync(process.env.HUTCH_BUILD_LEADER_READY, "");
    await new Promise((resolveWait) => setTimeout(resolveWait, 5_000));
    if (!existsSync(canary)) throw new Error("a concurrent build deleted the active build directory");
  } else {
    await new Promise((resolveWait) => setTimeout(resolveWait, 250));
  }
}
`);
    writeFixtureFile(join(project, "release-build-window.mjs"), `
import { unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const sentinel = process.env.HUTCH_BUILD_SENTINEL;
if (sentinel) unlinkSync(sentinel);
const completionDirectory = process.env.HUTCH_BUILD_COMPLETION_DIR;
const runId = process.env.HUTCH_BUILD_RUN_ID;
if (completionDirectory && runId) writeFileSync(join(completionDirectory, runId), "");
`);
    writeFixtureFile(join(project, "electrobun.config.ts"), `
export default {
  electrobun: { version: "${version}" },
  app: { name: "PublishedArtifact", identifier: "dev.electrobun.published-artifact", version: "0.0.0" },
  build: {
    mainProcess: "cottontail",
    cottontail: { entrypoint: "src/bun/index.ts" },
    mac: { icons: null, codesign: false, notarize: false, bundleCEF: false, bundleWGPU: false },
    win: { bundleCEF: false, bundleWGPU: false },
    linux: { bundleCEF: false, bundleWGPU: false },
  },
  scripts: {
    preBuild: "claim-build-window.mjs",
    postPackage: "release-build-window.mjs",
  },
};
`);
    assert.equal(existsSync(join(project, "package.json")), false);

    let indexRequests = 0;
    let coreRequests = 0;
    let serveOversizedIndex = false;
    let serveCoreUnavailable = false;
    const server = createServer((request, response) => {
      const basePath = `/releases/download/v${version}`;
      if (request.url === `${basePath}/electrobun-artifacts.json`) {
        indexRequests += 1;
        if (serveOversizedIndex) {
          response.writeHead(200, { "content-type": "application/json" });
          for (let chunk = 0; chunk < 17; chunk += 1) {
            response.write(Buffer.alloc(64 * 1024, 0x20));
          }
          response.end();
          return;
        }
        const origin = `http://127.0.0.1:${server.address().port}/releases/download`;
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({
          schemaVersion: 1,
          product: { name: "electrobun", version },
          devkit: { manifest: "native-devkit.json", schemaVersion: 1 },
          abi: {
            core: { name: "electrobun-core", version: 1 },
            sdk: { name: "electrobun-sdk", version: 1 },
          },
          platforms: {
            [names.key]: {
              target: { os: names.os, arch: names.arch },
              core: {
                url: `${origin}/v${version}/electrobun-core-${names.asset}.tar.gz`,
                size: archiveBytes.length,
                sha256: archiveSha256,
              },
            },
          },
        }));
        return;
      }
      if (request.url === `${basePath}/electrobun-core-${names.asset}.tar.gz`) {
        coreRequests += 1;
        if (serveCoreUnavailable) {
          response.writeHead(503);
          response.end();
          return;
        }
        response.writeHead(200, { "content-type": "application/gzip" });
        response.end(archiveBytes);
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
      for (const name of [
        "HUTCH_BUILD_SENTINEL",
        "HUTCH_BUILD_COMPLETION_DIR",
        "HUTCH_BUILD_RUN_ID",
        "HUTCH_BUILD_LEADER",
        "HUTCH_BUILD_LEADER_READY",
        "HUTCH_ELECTROBUN_BUILD_LOCK",
      ]) delete env[name];
      const cacheRoot = join(dashHome, "products", "electrobun", version, names.key);
      const indexCache = join(
        dashHome,
        "cache",
        "electrobun",
        "releases",
        version,
        "electrobun-artifacts.json",
      );

      const offlineMiss = await run(hutch, ["electrobun", "build", "--env=dev"], {
        cwd: project,
        env: { ...env, DASH_RELEASE_OFFLINE: "1" },
        stdio: ["ignore", "pipe", "pipe"],
      });
      assert.notEqual(offlineMiss.status, 0);
      assert.match(offlineMiss.stderr, /ElectrobunArtifactIndexNotCached/);
      assert.equal(indexRequests, 0, "offline cache misses must not perform HTTP requests");
      assert.equal(coreRequests, 0);

      serveOversizedIndex = true;
      const oversized = await run(hutch, ["electrobun", "build", "--env=dev"], {
        cwd: project,
        env,
        stdio: ["ignore", "pipe", "pipe"],
      });
      assert.notEqual(oversized.status, 0);
      assert.match(oversized.stderr, /ReleaseDownloadTooLarge/);
      assert.equal(indexRequests, 1);
      assert.equal(coreRequests, 0, "an oversized index must fail before an artifact request");
      assert.equal(existsSync(indexCache), false, "an oversized index must not enter the cache");

      serveOversizedIndex = false;
      serveCoreUnavailable = true;
      const indexOnly = await run(hutch, ["electrobun", "build", "--env=dev"], {
        cwd: project,
        env,
        stdio: ["ignore", "pipe", "pipe"],
      });
      assert.notEqual(indexOnly.status, 0);
      assert.match(indexOnly.stderr, /ReleaseDownloadFailed/);
      assert.equal(indexRequests, 2);
      assert.equal(coreRequests, 1);
      assert.ok(existsSync(indexCache), "a valid immutable index is cached before artifact download");

      const offlineArtifactMiss = await run(hutch, ["electrobun", "build", "--env=dev"], {
        cwd: project,
        env: { ...env, DASH_RELEASE_OFFLINE: "1" },
        stdio: ["ignore", "pipe", "pipe"],
      });
      assert.notEqual(offlineArtifactMiss.status, 0);
      assert.match(offlineArtifactMiss.stderr, /ElectrobunArtifactNotCached/);
      assert.equal(indexRequests, 2, "offline artifact misses must not refresh the index");
      assert.equal(coreRequests, 1, "offline artifact misses must not perform HTTP requests");

      serveCoreUnavailable = false;
      const first = await run(hutch, ["electrobun", "build", "--env=dev"], {
        cwd: project,
        env,
        stdio: ["ignore", "pipe", "pipe"],
      });
      assert.equal(first.status, 0, first.stderr || first.stdout);
      assert.equal(indexRequests, 2, "the first online build should reuse the valid artifact index");
      assert.equal(coreRequests, 2, "the first build should download one verified core archive");
      assert.match(first.stderr, /downloading Electrobun 9\.8\.7-test\.1 core/);

      assert.ok(existsSync(join(cacheRoot, executableName("launcher"))));
      assert.ok(existsSync(join(cacheRoot, ".core-complete")));
      assert.equal(readFileSync(join(cacheRoot, ".core-complete"), "utf8").trim(), archiveSha256);
      assert.ok(existsSync(indexCache));

      writeFileSync(indexCache, "{truncated");
      rmSync(join(project, "build"), { recursive: true, force: true });
      const recovered = await run(hutch, ["electrobun", "build", "--env=dev"], {
        cwd: project,
        env,
        stdio: ["ignore", "pipe", "pipe"],
      });
      assert.equal(recovered.status, 0, recovered.stderr || recovered.stdout);
      assert.equal(indexRequests, 3, "online mode should replace one corrupt cached index");
      assert.equal(coreRequests, 2, "index recovery must preserve the verified core install");
      assert.ok(existsSync(`${indexCache}.invalid`));

      rmSync(join(project, "build"), { recursive: true, force: true });
      const second = await run(hutch, ["electrobun", "build", "--env=dev"], {
        cwd: project,
        env: { ...env, DASH_RELEASE_OFFLINE: "1" },
        stdio: ["ignore", "pipe", "pipe"],
      });
      assert.equal(second.status, 0, second.stderr || second.stdout);
      assert.equal(indexRequests, 3, "offline cache hits must not refresh the artifact index");
      assert.equal(coreRequests, 2, "offline cache hits must reuse the verified core cache");

      rmSync(join(project, "build"), { recursive: true, force: true });
      rmSync(join(project, ".hutch", "locks"), { recursive: true, force: true });
      const sentinel = join(fixture, "build-active");
      const leaderReady = join(fixture, "build-leader-ready");
      const completionDir = join(fixture, "build-completions");
      mkdirSync(completionDir);
      const concurrentEnv = {
        ...env,
        HUTCH_BUILD_SENTINEL: sentinel,
        HUTCH_BUILD_COMPLETION_DIR: completionDir,
        HUTCH_ELECTROBUN_DEVKIT_ROOT: coreFiles,
      };
      const buildRun = (runId, extraEnv = {}) => run(
        hutch,
        ["electrobun", "build", "--env=dev"],
        {
          cwd: project,
          env: {
            ...concurrentEnv,
            DASH_HOME: join(fixture, `concurrent-dash-home-${runId}`),
            HUTCH_BUILD_RUN_ID: runId,
            ...extraEnv,
          },
          stdio: ["ignore", "pipe", "pipe"],
        },
      );
      const leader = buildRun("0", {
        HUTCH_BUILD_LEADER: "1",
        HUTCH_BUILD_LEADER_READY: leaderReady,
      });
      await waitForPath(leaderReady);
      const followers = Array.from({ length: 3 }, (_, index) => buildRun(String(index + 1)));
      const settled = await Promise.allSettled([leader, ...followers]);
      for (const result of settled) {
        assert.equal(result.status, "fulfilled", String(result.reason));
      }
      const concurrent = settled.map((result) => result.value);
      for (const result of concurrent) {
        assert.equal(result.status, 0, result.stderr || result.stdout);
      }
      assert.equal(indexRequests, 3, "local concurrent builds must not refresh the artifact index");
      assert.equal(coreRequests, 2, "local concurrent builds must not download artifacts");
      assert.equal(existsSync(sentinel), false, "the final build must release its serialization sentinel");
      assert.ok(existsSync(join(project, ".hutch", "locks", "electrobun-build.lock")));
      for (let index = 0; index < concurrent.length; index += 1) {
        assert.ok(existsSync(join(completionDir, String(index))), `missing completion for build ${index}`);
      }
    } finally {
      await new Promise((resolveClose, reject) => server.close((error) => error ? reject(error) : resolveClose()));
    }
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
});
