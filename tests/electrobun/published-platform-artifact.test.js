import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  existsSync,
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

test("exact Electrobun config pins download and reuse verified native artifacts", { timeout: 120_000 }, async () => {
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
    } finally {
      await new Promise((resolveClose, reject) => server.close((error) => error ? reject(error) : resolveClose()));
    }
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
});
