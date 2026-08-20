"use strict";

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { performance } = require("node:perf_hooks");
const { spawn, spawnSync } = require("node:child_process");
const { gzipSync } = require("node:zlib");

const cottontail = path.resolve(process.argv[2] || "zig-out/bin/cottontail");
const nodeProbe = spawnSync("node", ["-p", "process.execPath"], { encoding: "utf8" });
assert.equal(nodeProbe.status, 0, `failed to resolve host Node executable: ${nodeProbe.stderr}`);
const nodeRuntime = path.resolve(nodeProbe.stdout.trim());
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "cottontail-cache-concurrency-"));
const registryRoot = path.join(scratch, "registry");
const projectRoot = path.join(scratch, "project");
const home = path.join(scratch, "home");
const portFile = path.join(registryRoot, "port");
const statsFile = path.join(registryRoot, "stats.json");
const packageCount = 8;
const responseDelayMs = 220;

function writeTarField(header, offset, width, value) {
  header.write(`${value.toString(8).padStart(width - 1, "0")}\0`, offset, width, "ascii");
}

function packageArchive(packageJson) {
  const body = Buffer.from(`${JSON.stringify(packageJson)}\n`);
  const header = Buffer.alloc(512);
  header.write("package/package.json", 0, 100, "utf8");
  writeTarField(header, 100, 8, 0o644);
  writeTarField(header, 108, 8, 0);
  writeTarField(header, 116, 8, 0);
  writeTarField(header, 124, 12, body.length);
  writeTarField(header, 136, 12, 0);
  header.fill(0x20, 148, 156);
  header[156] = "0".charCodeAt(0);
  header.write("ustar\0", 257, 6, "ascii");
  header.write("00", 263, 2, "ascii");
  const checksum = header.reduce((sum, byte) => sum + byte, 0);
  header.write(checksum.toString(8).padStart(6, "0"), 148, 6, "ascii");
  header[154] = 0;
  header[155] = 0x20;
  const padding = Buffer.alloc((512 - (body.length % 512)) % 512);
  return gzipSync(Buffer.concat([header, body, padding, Buffer.alloc(1024)]));
}

function waitForFile(filename) {
  const signal = new Int32Array(new SharedArrayBuffer(4));
  for (let attempt = 0; attempt < 500; attempt += 1) {
    if (fs.existsSync(filename)) return;
    Atomics.wait(signal, 0, 0, 10);
  }
  throw new Error(`timed out waiting for ${filename}`);
}

function readStats() {
  return JSON.parse(fs.readFileSync(statsFile, "utf8"));
}

function runInstall(args = []) {
  const env = { ...process.env, HOME: home };
  delete env.BUN_INSTALL_CACHE_DIR;
  delete env.HUTCH_INSTALL_CACHE_DIR;
  delete env.HUTCH_HOME;
  delete env.DASH_HOME;
  delete env.XDG_CACHE_HOME;
  delete env.npm_config_cache;
  delete env.NPM_CONFIG_CACHE;
  const started = performance.now();
  const result = spawnSync(cottontail, ["install", "--ignore-scripts", "--silent", ...args], {
    cwd: projectRoot,
    env,
    encoding: "utf8",
    timeout: 15_000,
  });
  return { result, elapsedMs: performance.now() - started };
}

function expectSuccess(run) {
  assert.equal(
    run.result.status,
    0,
    `install failed\nstdout:\n${run.result.stdout}\nstderr:\n${run.result.stderr}`,
  );
}

function removeInstall({ lockfile }) {
  fs.rmSync(path.join(projectRoot, "node_modules"), { recursive: true, force: true });
  if (lockfile) {
    fs.rmSync(path.join(projectRoot, "hutch.lock"), { force: true });
    fs.rmSync(path.join(projectRoot, "bun.lockb"), { force: true });
  }
}

function countCacheFiles(root, extension) {
  let count = 0;
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const filename = path.join(root, entry.name);
    if (entry.isDirectory()) count += countCacheFiles(filename, extension);
    else if (entry.name.endsWith(extension)) count += 1;
  }
  return count;
}

function findCacheFiles(root, predicate, matches = []) {
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const filename = path.join(root, entry.name);
    if (entry.isDirectory()) findCacheFiles(filename, predicate, matches);
    else if (predicate(filename, entry.name)) matches.push(filename);
  }
  return matches;
}

fs.mkdirSync(registryRoot, { recursive: true });
fs.mkdirSync(projectRoot, { recursive: true });
fs.mkdirSync(home, { recursive: true });

const dependencies = {};
for (let index = 0; index < packageCount; index += 1) {
  const name = `delayed-package-${index}`;
  const metadata = { name, version: "1.0.0" };
  const archive = packageArchive(metadata);
  dependencies[name] = "1.0.0";
  fs.writeFileSync(path.join(registryRoot, `${name}.tgz`), archive);
  fs.writeFileSync(
    path.join(registryRoot, `${name}.json`),
    JSON.stringify({
      metadata,
      integrity: `sha512-${crypto.createHash("sha512").update(archive).digest("base64")}`,
    }),
  );
}

fs.writeFileSync(
  path.join(projectRoot, "package.json"),
  `${JSON.stringify({ name: "cache-concurrency", version: "1.0.0", dependencies }, null, 2)}\n`,
);

const serverFile = path.join(registryRoot, "server.cjs");
fs.writeFileSync(
  serverFile,
  `
"use strict";
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const [root, portFile, statsFile, delayText] = process.argv.slice(2);
const delay = Number(delayText);
const stats = { active: 0, maxActive: 0, requests: 0 };
function saveStats() { fs.writeFileSync(statsFile, JSON.stringify(stats)); }
const server = http.createServer((request, response) => {
  stats.active += 1;
  stats.requests += 1;
  stats.maxActive = Math.max(stats.maxActive, stats.active);
  saveStats();
  setTimeout(() => {
    const pathname = decodeURIComponent(new URL(request.url, "http://localhost").pathname);
    if (pathname.startsWith("/tarballs/")) {
      const filename = path.join(root, path.basename(pathname));
      if (fs.existsSync(filename)) {
        response.writeHead(200, { "content-type": "application/octet-stream" });
        response.end(fs.readFileSync(filename));
      } else {
        response.writeHead(404).end();
      }
    } else {
      const name = pathname.slice(1);
      const metadataFile = path.join(root, name + ".json");
      if (!fs.existsSync(metadataFile)) {
        response.writeHead(404).end();
      } else {
        const fixture = JSON.parse(fs.readFileSync(metadataFile, "utf8"));
        const metadata = {
          ...fixture.metadata,
          dist: {
            tarball: "http://127.0.0.1:" + server.address().port + "/tarballs/" + name + ".tgz",
            integrity: fixture.integrity,
          },
        };
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({
          name,
          "dist-tags": { latest: metadata.version },
          versions: { [metadata.version]: metadata },
        }));
      }
    }
    stats.active -= 1;
    saveStats();
  }, delay);
});
saveStats();
server.listen(0, "127.0.0.1", () => fs.writeFileSync(portFile, String(server.address().port)));
`,
);

const server = spawn(
  nodeRuntime,
  [serverFile, registryRoot, portFile, statsFile, String(responseDelayMs)],
  { stdio: ["ignore", "ignore", "inherit"] },
);

try {
  waitForFile(portFile);
  const port = fs.readFileSync(portFile, "utf8");
  fs.writeFileSync(
    path.join(projectRoot, "bunfig.toml"),
    `[install]\nregistry = "http://127.0.0.1:${port}/"\n`,
  );

  const cold = runInstall();
  expectSuccess(cold);
  const coldStats = readStats();
  assert.equal(coldStats.requests, packageCount * 2);
  assert.ok(coldStats.maxActive >= 4, `expected concurrent fetches, observed ${coldStats.maxActive}`);
  assert.ok(
    cold.elapsedMs < 2_500,
    `cold install took ${cold.elapsedMs.toFixed(2)}ms; delayed requests appear serialized`,
  );

  const cacheRoot = path.join(home, ".hutch", "cache", "npm");
  assert.equal(
    countCacheFiles(cacheRoot, ".npm"),
    0,
    "unauthenticated registry manifests must not be persisted as trusted cache entries",
  );
  assert.equal(countCacheFiles(cacheRoot, ".tgz"), packageCount);

  removeInstall({ lockfile: false });
  const warmLocked = runInstall();
  expectSuccess(warmLocked);
  assert.equal(readStats().requests, coldStats.requests, "lockfile reinstall contacted the registry");

  removeInstall({ lockfile: true });
  const warmUnlocked = runInstall();
  expectSuccess(warmUnlocked);
  const warmUnlockedStats = readStats();
  assert.equal(
    warmUnlockedStats.requests,
    coldStats.requests + packageCount,
    "a fresh resolution did not refetch every unauthenticated registry manifest",
  );

  const upgradedName = "delayed-package-0";
  const upgradedMetadata = { name: upgradedName, version: "2.0.0" };
  const upgradedArchive = packageArchive(upgradedMetadata);
  fs.writeFileSync(path.join(registryRoot, `${upgradedName}.tgz`), upgradedArchive);
  fs.writeFileSync(
    path.join(registryRoot, `${upgradedName}.json`),
    JSON.stringify({
      metadata: upgradedMetadata,
      integrity: `sha512-${crypto.createHash("sha512").update(upgradedArchive).digest("base64")}`,
    }),
  );
  dependencies[upgradedName] = "2.0.0";
  fs.writeFileSync(
    path.join(projectRoot, "package.json"),
    `${JSON.stringify({ name: "cache-concurrency", version: "1.0.0", dependencies }, null, 2)}\n`,
  );
  removeInstall({ lockfile: true });
  const staleExact = runInstall();
  expectSuccess(staleExact);
  const staleStats = readStats();
  assert.equal(
    staleStats.requests,
    warmUnlockedStats.requests + packageCount + 1,
    "an exact-version refresh did not fetch fresh manifests and the changed archive",
  );
  assert.equal(
    JSON.parse(fs.readFileSync(path.join(projectRoot, "node_modules", upgradedName, "package.json"), "utf8")).version,
    "2.0.0",
  );

  removeInstall({ lockfile: true });
  const noCache = runInstall(["--no-cache"]);
  expectSuccess(noCache);
  assert.equal(
    readStats().requests,
    staleStats.requests + packageCount * 2,
    "--no-cache reused registry artifacts",
  );

  const poisonVictim = "delayed-package-1";
  const archiveFiles = findCacheFiles(
    path.join(cacheRoot, poisonVictim),
    (_filename, basename) => basename.endsWith(".tgz"),
  );
  assert.equal(archiveFiles.length, 1, "expected one identity-bound archive cache entry");
  fs.writeFileSync(archiveFiles[0], packageArchive({ name: "swapped-package", version: "9.9.9" }));
  removeInstall({ lockfile: false });
  const beforeSwappedArchive = readStats().requests;
  const swappedArchive = runInstall(["--no-verify"]);
  expectSuccess(swappedArchive);
  assert.equal(
    readStats().requests,
    beforeSwappedArchive + 1,
    "a swapped archive cache entry was trusted instead of refetched",
  );
  assert.deepEqual(
    JSON.parse(fs.readFileSync(path.join(projectRoot, "node_modules", poisonVictim, "package.json"), "utf8")),
    { name: poisonVictim, version: "1.0.0" },
  );

  // Keep this sparse: the cache reader must reject it from its length without
  // allocating or reading the payload, reset the file, and fetch a replacement.
  const oversizedArchiveFd = fs.openSync(archiveFiles[0], "w");
  fs.ftruncateSync(oversizedArchiveFd, 512 * 1024 * 1024 + 1);
  fs.closeSync(oversizedArchiveFd);
  removeInstall({ lockfile: false });
  const beforeOversizedArchive = readStats().requests;
  const oversizedArchive = runInstall(["--no-verify"]);
  expectSuccess(oversizedArchive);
  assert.equal(
    readStats().requests,
    beforeOversizedArchive + 1,
    "an oversized archive cache entry did not reset and refetch",
  );

  const extractedDirectories = fs
    .readdirSync(cacheRoot, { withFileTypes: true })
    .filter(
      (entry) =>
        entry.isDirectory() &&
        entry.name.startsWith(`${poisonVictim}@`) &&
        entry.name.includes("@@source-"),
    );
  assert.equal(extractedDirectories.length, 1, "expected one source-bound extracted cache entry");
  const extractedDirectory = path.join(cacheRoot, extractedDirectories[0].name);
  fs.writeFileSync(path.join(extractedDirectory, "poison-marker"), "untrusted\n");
  removeInstall({ lockfile: false });
  const beforeExtractedPoison = readStats().requests;
  const extractedPoison = runInstall(["--no-verify"]);
  expectSuccess(extractedPoison);
  assert.equal(
    readStats().requests,
    beforeExtractedPoison,
    "rebuilding a poisoned extracted cache unexpectedly contacted the registry",
  );
  assert.equal(
    fs.existsSync(path.join(projectRoot, "node_modules", poisonVictim, "poison-marker")),
    false,
    "a poisoned extracted cache entry was copied into node_modules",
  );

  if (process.platform !== "win32") {
    const cacheWriteSentinel = path.join(scratch, "cache-write-sentinel");
    fs.writeFileSync(cacheWriteSentinel, "preserve\n");
    fs.rmSync(archiveFiles[0]);
    fs.symlinkSync(cacheWriteSentinel, archiveFiles[0]);
    removeInstall({ lockfile: false });
    const symlinkedArchive = runInstall(["--no-verify"]);
    assert.equal(symlinkedArchive.result.status, 1, "a symlinked archive cache entry was opened for writing");
    assert.match(symlinkedArchive.result.stderr, /InvalidPackageDestination/);
    assert.equal(fs.readFileSync(cacheWriteSentinel, "utf8"), "preserve\n");

    fs.rmSync(archiveFiles[0]);
    fs.copyFileSync(path.join(registryRoot, `${poisonVictim}.tgz`), archiveFiles[0]);

    const brokenVictim = "delayed-package-2";
    const brokenArchive = findCacheFiles(
      path.join(cacheRoot, brokenVictim),
      (_filename, basename) => basename.endsWith(".tgz"),
    );
    assert.equal(brokenArchive.length, 1);
    const brokenTarget = path.join(scratch, "missing-cache-target");
    fs.rmSync(brokenArchive[0]);
    fs.symlinkSync(brokenTarget, brokenArchive[0]);
    removeInstall({ lockfile: false });
    const brokenSymlinkArchive = runInstall(["--no-verify"]);
    assert.equal(brokenSymlinkArchive.result.status, 1, "prefetch followed a broken cache symlink");
    assert.match(brokenSymlinkArchive.result.stderr, /InvalidPackageDestination/);
    assert.equal(fs.existsSync(brokenTarget), false, "prefetch created a broken symlink target");

    fs.rmSync(brokenArchive[0]);
    fs.copyFileSync(path.join(registryRoot, `${brokenVictim}.tgz`), brokenArchive[0]);

    const oversizedTargetVictim = "delayed-package-3";
    const oversizedTargetArchive = findCacheFiles(
      path.join(cacheRoot, oversizedTargetVictim),
      (_filename, basename) => basename.endsWith(".tgz"),
    );
    assert.equal(oversizedTargetArchive.length, 1);
    const oversizedTarget = path.join(scratch, "oversized-cache-target");
    const oversizedTargetFd = fs.openSync(oversizedTarget, "w");
    fs.ftruncateSync(oversizedTargetFd, 512 * 1024 * 1024 + 1);
    fs.closeSync(oversizedTargetFd);
    fs.rmSync(oversizedTargetArchive[0]);
    fs.symlinkSync(oversizedTarget, oversizedTargetArchive[0]);
    removeInstall({ lockfile: false });
    const oversizedSymlinkArchive = runInstall(["--no-verify"]);
    assert.equal(oversizedSymlinkArchive.result.status, 1, "prefetch followed an oversized cache symlink target");
    assert.match(oversizedSymlinkArchive.result.stderr, /InvalidPackageDestination/);
    assert.equal(
      fs.statSync(oversizedTarget).size,
      512 * 1024 * 1024 + 1,
      "prefetch truncated an oversized cache symlink target",
    );

    fs.rmSync(oversizedTargetArchive[0]);
    fs.copyFileSync(path.join(registryRoot, `${oversizedTargetVictim}.tgz`), oversizedTargetArchive[0]);
  }

  const hardLinkVictim = "delayed-package-4";
  const hardLinkArchive = findCacheFiles(
    path.join(cacheRoot, hardLinkVictim),
    (_filename, basename) => basename.endsWith(".tgz"),
  );
  assert.equal(hardLinkArchive.length, 1);
  const hardLinkSentinel = path.join(scratch, "hard-link-cache-sentinel");
  fs.writeFileSync(hardLinkSentinel, "preserve\n");
  fs.rmSync(hardLinkArchive[0]);
  fs.linkSync(hardLinkSentinel, hardLinkArchive[0]);
  removeInstall({ lockfile: false });
  const hardLinkedArchive = runInstall(["--no-verify"]);
  assert.equal(hardLinkedArchive.result.status, 1, "prefetch wrote through a hard-linked cache entry");
  assert.match(hardLinkedArchive.result.stderr, /InvalidPackageDestination/);
  assert.equal(fs.readFileSync(hardLinkSentinel, "utf8"), "preserve\n");

  console.log(
    `package-manager cache concurrency: pass ` +
      `(cold=${cold.elapsedMs.toFixed(2)}ms, warm-lock=${warmLocked.elapsedMs.toFixed(2)}ms, ` +
      `warm-unlocked=${warmUnlocked.elapsedMs.toFixed(2)}ms, stale-exact=${staleExact.elapsedMs.toFixed(2)}ms, ` +
      `no-cache=${noCache.elapsedMs.toFixed(2)}ms, ` +
      `max-active=${coldStats.maxActive})`,
  );
} finally {
  server.kill();
  fs.rmSync(scratch, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
}
