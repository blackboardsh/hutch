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
  readdirSync,
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
const dashHome = join(temporary, "home");

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
let requestCount = 0;

const server = createServer((request, response) => {
  requestCount += 1;
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
  if (request.url in bodies) {
    setTimeout(() => {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(`${JSON.stringify(bodies[request.url], null, 2)}\n`);
    }, 75);
  } else if (request.url?.endsWith("/cottontail.tar.gz")) {
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
    DASH_HOME: dashHome,
    HUTCH_ACTIVE_CHANNEL: "canary",
    DASH_ARTIFACTS_BASE_URL: `http://127.0.0.1:${server.address().port}`,
  };
  const coldResolvers = await Promise.all(
    Array.from({ length: 12 }, () =>
      runAsync(engine, ["cottontail", "path", "canary"], environment)),
  );
  const installed = coldResolvers[0].stdout.trim();
  for (const resolution of coldResolvers) {
    assert.equal(resolution.stdout.trim(), installed);
  }
  assert(installed.endsWith(`bin${process.platform === "win32" ? "\\" : "/"}${executableName}`));
  assert(existsSync(installed));
  assert.equal(
    requestCount,
    3,
    "concurrent cold resolvers must share one channel manifest, release manifest, and archive download",
  );
  const channelCache = join(dashHome, "cache", "cottontail", "channels");
  const releaseCache = join(dashHome, "cache", "cottontail", "releases");
  assert.deepEqual(
    readdirSync(channelCache).sort(),
    ["canary.json", "canary.json.lock"],
    "the channel cache must retain only its manifest and persistent lock",
  );
  assert.deepEqual(
    readdirSync(releaseCache).sort(),
    [`${version}.json`, `${version}.json.lock`],
    "the release cache must retain only its manifest and persistent lock",
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
  console.log(`Hutch native release store smoke passed for ${platform}`);
} finally {
  if (server.listening) await new Promise((resolve) => server.close(resolve));
  rmSync(temporary, { recursive: true, force: true });
}
