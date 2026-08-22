import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  mkdtempSync,
  readFileSync,
  rmSync,
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

function versionConstant(name) {
  const source = readFileSync(join(hutchRoot, "src", "version.zig"), "utf8");
  const match = source.match(new RegExp(`pub const ${name} = "([^"]+)";`));
  assert.ok(match, `missing ${name} in src/version.zig`);
  return match[1];
}

function resolveCottontail(hutch) {
  const configured = process.env.COTTONTAIL_BINARY ?? process.env.DASH_COTTONTAIL;
  if (configured) return resolve(configured);
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

test("electrobun update rewrites the nearest parent pin to stable and syncs", { timeout: 120_000 }, async () => {
  const fixture = mkdtempSync(join(os.tmpdir(), "hutch-electrobun-update-"));
  const workspace = join(fixture, "workspace");
  const project = join(workspace, "apps", "desktop");
  const coreFiles = join(fixture, "core-files");
  const coreArchive = join(fixture, "electrobun-core.tar.gz");
  const hutchHome = join(fixture, "hutch-home");
  const stableVersion = "2.0.1";
  const oldVersion = "2.0.1-beta.29";
  const host = hostContract();
  const hutch = join(hutchRoot, "zig-out", "bin", executableName("hutch"));
  const engine = join(hutchRoot, "zig-out", "bin", executableName("hutch-engine"));
  const cottontail = resolveCottontail(hutch);

  try {
    createCoreFixture(coreFiles, stableVersion, host);
    const packed = spawnSync("tar", ["-czf", coreArchive, "-C", coreFiles, "."], {
      encoding: "utf8",
      env: { ...process.env, COPYFILE_DISABLE: "1" },
    });
    assert.equal(packed.status, 0, packed.stderr || packed.stdout);
    const archive = readFileSync(coreArchive);
    const archiveSha256 = createHash("sha256").update(archive).digest("hex");

    const configPath = join(workspace, "hutch.config.ts");
    writeFixtureFile(configPath, `// parent workspace config\nexport default {\n  scripts: { version: "unchanged" },\n  electrobun: { version: "${oldVersion}" },\n};\n`);
    writeFixtureFile(join(project, "src", "index.ts"), "console.log('updated');\n");
    writeFixtureFile(join(project, "electrobun.config.ts"), `
import type { ElectrobunConfig } from "electrobun";
export default {
  app: { name: "Updated", identifier: "dev.electrobun.updated", version: "1.0.0" },
  build: {
    mainProcess: "cottontail",
    cottontail: { entrypoint: "src/index.ts" },
    mac: { icons: null, codesign: false, notarize: false, bundleCEF: false, bundleWGPU: false },
    win: { bundleCEF: false, bundleWGPU: false },
    linux: { bundleCEF: false, bundleWGPU: false },
  },
} satisfies ElectrobunConfig;
`);

    let baseUrl;
    let catalogRequests = 0;
    let releaseRequests = 0;
    const server = createServer((request, response) => {
      if (request.url === "/templates/channels/stable.json") {
        catalogRequests += 1;
        response.writeHead(200, { "content-type": "application/json" });
        response.end(`${JSON.stringify({
          schema: 1,
          kind: "electrobun-template-channel",
          channel: "stable",
          version: stableVersion,
          revision: "a".repeat(40),
          tools: {
            hutch: versionConstant("version"),
            cottontail: versionConstant("paired_cottontail_version"),
          },
          templates: [{
            id: "unused",
            name: "Unused",
            description: "Catalog contract fixture",
            mainProcess: "cottontail",
            archive: {
              url: `${baseUrl}/templates/artifacts/${"0".repeat(64)}.tar.gz`,
              sha256: "0".repeat(64),
              size: 1,
            },
          }],
        })}\n`);
        return;
      }
      const releasePrefix = `/releases/download/v${stableVersion}`;
      if (request.url === `${releasePrefix}/electrobun-artifacts.json`) {
        releaseRequests += 1;
        response.writeHead(200, { "content-type": "application/json" });
        response.end(`${JSON.stringify({
          schemaVersion: 1,
          product: { name: "electrobun", version: stableVersion },
          devkit: { manifest: "native-devkit.json", schemaVersion: 1 },
          abi: {
            core: { name: "electrobun-core", version: 1 },
            sdk: { name: "electrobun-sdk", version: 1 },
          },
          platforms: {
            [host.key]: {
              target: { os: host.os, arch: host.arch },
              core: {
                url: `${baseUrl}${releasePrefix}/electrobun-core-${host.asset}.tar.gz`,
                size: archive.length,
                sha256: archiveSha256,
              },
            },
          },
        })}\n`);
        return;
      }
      if (request.url === `${releasePrefix}/electrobun-core-${host.asset}.tar.gz`) {
        releaseRequests += 1;
        response.writeHead(200, { "content-type": "application/gzip" });
        response.end(archive);
        return;
      }
      response.writeHead(404);
      response.end();
    });
    await new Promise((resolveListen, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", resolveListen);
    });
    const address = server.address();
    assert.ok(address && typeof address === "object");
    baseUrl = `http://127.0.0.1:${address.port}`;

    try {
      const result = await run(hutch, ["electrobun", "update"], {
        cwd: project,
        env: {
          ...process.env,
          COTTONTAIL_BINARY: cottontail,
          DASH_COTTONTAIL: cottontail,
          DASH_HOME: hutchHome,
          HUTCH_ENGINE_BINARY: engine,
          HUTCH_ACTIVE_CHANNEL: "canary",
          HUTCH_NO_UPDATE_CHECK: "1",
          ELECTROBUN_TEMPLATES_BASE_URL: `${baseUrl}/templates`,
          ELECTROBUN_RELEASES_BASE_URL: `${baseUrl}/releases/download`,
        },
        stdio: ["ignore", "pipe", "pipe"],
      });
      assert.equal(result.status, 0, result.stderr || result.stdout);
      assert.match(result.stdout, /electrobun\.version=2\.0\.1 \(was 2\.0\.1-beta\.29\)/);
      assert.match(result.stdout, /electrobun sync complete/);
      assert.equal(catalogRequests, 1, "update must resolve stable even when the active channel is canary");
      assert.equal(releaseRequests, 2, "sync must fetch the selected release index and core archive");

      const updatedConfig = readFileSync(configPath, "utf8");
      assert.match(updatedConfig, /\/\/ parent workspace config/);
      assert.match(updatedConfig, /scripts: \{ version: "unchanged" \}/);
      assert.match(updatedConfig, /electrobun: \{ version: "2\.0\.1" \}/);
      const projection = JSON.parse(
        readFileSync(join(project, ".hutch", "devkit", "projection.json"), "utf8"),
      );
      assert.equal(projection.product.version, stableVersion);
    } finally {
      server.close();
    }
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
});
