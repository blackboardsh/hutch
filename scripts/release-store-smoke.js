#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const hutchRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const platform = {
  "darwin-arm64": "macos-arm64",
  "linux-x64": "linux-x64",
  "linux-arm64": "linux-arm64",
  "win32-x64": "windows-x64",
}[`${process.platform}-${process.arch}`];
assert(platform, `unsupported release-store smoke platform: ${process.platform}-${process.arch}`);

const version = "9.8.7-canary.6";
const revision = "0123456789abcdef0123456789abcdef01234567";
const executableName = process.platform === "win32" ? "cottontail.exe" : "cottontail";
const engineName = process.platform === "win32" ? "hutch-engine.exe" : "hutch-engine";
const engine = join(hutchRoot, "zig-out", "bin", engineName);
const temporary = mkdtempSync(join(tmpdir(), "hutch-release-store-smoke-"));
const packageName = `cottontail-v${version}-${platform}`;
const packageRoot = join(temporary, packageName);
const binRoot = join(packageRoot, "bin");
const archivePath = join(temporary, "cottontail.tar.gz");
const hutchHome = join(temporary, "home");

mkdirSync(binRoot, { recursive: true });
writeFileSync(join(binRoot, executableName), "release store fixture\n");
if (process.platform !== "win32") chmodSync(join(binRoot, executableName), 0o755);
writeFileSync(
  join(packageRoot, "cottontail-release.json"),
  `${JSON.stringify({
    schema: 1,
    kind: "archive",
    product: "cottontail",
    channel: "canary",
    version,
    platform,
    revision,
    executable: `bin/${executableName}`,
  }, null, 2)}\n`,
);
const tar = spawnSync(
  "tar",
  ["-czf", archivePath, "-C", temporary, packageName],
  { encoding: "utf8" },
);
assert.equal(tar.status, 0, tar.stderr || tar.stdout);
const archive = readFileSync(archivePath);
const checksum = createHash("sha256").update(archive).digest("hex");
// Windows is the platform where the exclusive installer lock hands off to a
// shared object lease while other exclusive installers are still queued. Use
// extra processes there so every release exercises that native lock sequence.
const concurrentResolverCount = process.platform === "win32" ? 24 : 12;
const requestCounts = { channel: 0, release: 0, archive: 0 };
const pendingMetadataResponses = { channel: [], release: [] };

function respondToMetadataBarrier(kind, response, body) {
  requestCounts[kind] += 1;
  pendingMetadataResponses[kind].push({ response, body });
  if (pendingMetadataResponses[kind].length !== concurrentResolverCount) return;
  setTimeout(() => {
    for (const pending of pendingMetadataResponses[kind]) {
      pending.response.writeHead(200, { "content-type": "application/json" });
      pending.response.end(`${JSON.stringify(pending.body, null, 2)}\n`);
    }
  }, 75);
}

const server = createServer((request, response) => {
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  const bodies = {
    "/cottontail/channels/canary.json": {
      schema: 1,
      kind: "channel",
      product: "cottontail",
      channel: "canary",
      version,
      revision,
      release: {
        url: `${baseUrl}/cottontail/releases/${version}/manifest.json`,
      },
    },
    [`/cottontail/releases/${version}/manifest.json`]: {
      schema: 1,
      kind: "release",
      product: "cottontail",
      channel: "canary",
      version,
      revision,
      platforms: {
        [platform]: {
          archive: {
            url: `${baseUrl}/cottontail/builds/${revision}/${platform}/cottontail.tar.gz`,
            sha256: checksum,
            size: statSync(archivePath).size,
          },
        },
      },
    },
  };
  if (request.url === "/cottontail/channels/canary.json") {
    respondToMetadataBarrier("channel", response, bodies[request.url]);
  } else if (request.url === `/cottontail/releases/${version}/manifest.json`) {
    respondToMetadataBarrier("release", response, bodies[request.url]);
  } else if (request.url?.endsWith("/cottontail.tar.gz")) {
    requestCounts.archive += 1;
    response.writeHead(200, {
      "content-type": "application/gzip",
      "content-length": archive.length,
    });
    response.end(archive);
  } else {
    response.writeHead(404);
    response.end("not found");
  }
});

function runAsync(command, args, env) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8").on("data", (chunk) => { stdout += chunk; });
    child.stderr.setEncoding("utf8").on("data", (chunk) => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", (code, signal) => {
      if (code === 0) resolve({ stdout, stderr });
      else reject(new Error(`hutch exited ${code ?? signal}\n${stderr || stdout}`));
    });
  });
}

try {
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const environment = {
    ...process.env,
    HUTCH_HOME: hutchHome,
    HUTCH_ACTIVE_CHANNEL: "canary",
    DASH_ARTIFACTS_BASE_URL: `http://127.0.0.1:${server.address().port}`,
  };
  const coldSettled = await Promise.allSettled(
    Array.from({ length: concurrentResolverCount }, () =>
      runAsync(engine, ["cottontail", "path", "canary"], environment)),
  );
  const coldFailures = coldSettled.flatMap((result, index) =>
    result.status === "rejected" ? [`resolver ${index + 1}: ${result.reason?.stack ?? result.reason}`] : []);
  if (coldFailures.length > 0) {
    throw new Error(
      `${coldFailures.length}/${concurrentResolverCount} concurrent release resolvers failed\n` +
        coldFailures.join("\n\n"),
    );
  }
  const coldResolvers = coldSettled.map((result) => result.value);
  const installed = coldResolvers[0].stdout.trim();
  for (const resolution of coldResolvers) {
    assert.equal(resolution.stdout.trim(), installed);
  }
  const installedRoot = join(
    hutchHome,
    "releases",
    "cottontail",
    version,
    revision,
    platform,
  );
  assert.equal(installed, join(installedRoot, "bin", executableName));
  assert(existsSync(installed));
  assert.deepEqual(
    requestCounts,
    {
      channel: concurrentResolverCount,
      release: concurrentResolverCount,
      archive: 1,
    },
    "each invocation must fetch fresh metadata while concurrent installation shares one archive download",
  );
  assert.equal(existsSync(join(hutchHome, "cache")), false);
  assert.equal(existsSync(join(hutchHome, "channels")), false);
  assert.ok(existsSync(`${installedRoot}.lock`));
  const selections = JSON.parse(
    readFileSync(join(hutchHome, "state", "selections.json"), "utf8"),
  );
  assert.deepEqual(
    selections,
    {
      schemaVersion: 1,
      kind: "hutch-selections",
      products: {
        hutch: {},
        cottontail: {
          canary: { version, revision, platform },
        },
      },
    },
    "the exact active release must be persisted as local selection state",
  );

  await new Promise((resolve) => server.close(resolve));
  const offline = spawnSync(engine, ["cottontail", "path", "canary"], {
    env: {
      ...environment,
      DASH_RELEASE_OFFLINE: "1",
    },
    encoding: "utf8",
  });
  assert.equal(offline.status, 0, offline.stderr || offline.stdout);
  assert.equal(offline.stdout.trim(), installed);
  assert.deepEqual(requestCounts, {
    channel: concurrentResolverCount,
    release: concurrentResolverCount,
    archive: 1,
  });
  console.log(`Hutch native release store smoke passed for ${platform}`);
} finally {
  if (server.listening) await new Promise((resolve) => server.close(resolve));
  rmSync(temporary, { recursive: true, force: true });
}
