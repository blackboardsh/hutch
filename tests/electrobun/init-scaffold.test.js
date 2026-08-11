import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import {
  createCoreFixture,
  executableName,
} from "./v2-devkit-fixture.js";

const hutchRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

function run(command, args, options) {
  return new Promise((resolveResult, reject) => {
    const child = spawn(command, args, { ...options, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", (status) => resolveResult({ status, stdout, stderr }));
  });
}

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

test("hutch electrobun init lists and downloads the active remote template channel", async () => {
  const hutch = join(hutchRoot, "zig-out", "bin", executableName("hutch"));
  const engine = join(hutchRoot, "zig-out", "bin", executableName("hutch-engine"));
  assert.ok(existsSync(hutch), `Hutch must be built before this test: ${hutch}`);
  assert.ok(existsSync(engine), `Hutch engine must be built before this test: ${engine}`);

  const fixture = mkdtempSync(join(tmpdir(), "hutch-electrobun-init-"));
  const archiveSource = join(fixture, "archive-source");
  const templateRoot = join(archiveSource, "hello-world");
  const archivePath = join(fixture, "hello-world.tar.gz");
  const workspace = join(fixture, "workspace");
  const coreRoot = join(fixture, "core");
  const projectName = "sample-app";
  const version = "2.0.0";
  const cottontail = resolveCottontail();

  mkdirSync(join(templateRoot, "src"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  const projectRoot = join(realpathSync(workspace), projectName);
  createCoreFixture(coreRoot, version);
  writeFileSync(join(templateRoot, "electrobun.config.ts"), `
export default {
  electrobun: { version: "${version}" },
  app: { name: "HelloWorld", identifier: "dev.electrobun.hello-world", version: "0.0.0" },
  build: {
    mainProcess: "cottontail",
    cottontail: { entrypoint: "src/index.ts" },
    mac: { icons: null, codesign: false, notarize: false, bundleCEF: false, bundleWGPU: false },
    win: { bundleCEF: false, bundleWGPU: false },
    linux: { bundleCEF: false, bundleWGPU: false },
  },
};
`);
  writeFileSync(join(templateRoot, "src", "index.ts"), 'console.log("hello");\n');
  const tar = spawnSync("tar", ["-czf", archivePath, "-C", archiveSource, "hello-world"], {
    encoding: "utf8",
    env: { ...process.env, COPYFILE_DISABLE: "1" },
  });
  assert.equal(tar.status, 0, tar.stderr || tar.stdout);
  const archive = readFileSync(archivePath);
  const checksum = createHash("sha256").update(archive).digest("hex");

  let baseUrl;
  const server = createServer((request, response) => {
    if (request.url === "/channels/stable.json") {
      const catalog = {
        schema: 1,
        kind: "electrobun-template-channel",
        channel: "stable",
        version: "2.0.0",
        revision: "a".repeat(40),
        tools: { hutch: "0.5.0", cottontail: "0.2.3" },
        templates: [{
          id: "hello-world",
          name: "Hello World",
          description: "A remote starter",
          mainProcess: "cottontail",
          archive: {
            url: `${baseUrl}/artifacts/${checksum}.tar.gz`,
            sha256: checksum,
            size: archive.length,
          },
        }],
      };
      response.writeHead(200, { "content-type": "application/json" });
      response.end(`${JSON.stringify(catalog)}\n`);
      return;
    }
    if (request.url === `/artifacts/${checksum}.tar.gz`) {
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
  assert.equal(typeof address, "object");
  baseUrl = `http://127.0.0.1:${address.port}`;

  const env = {
    ...process.env,
    COTTONTAIL_BINARY: cottontail,
    DASH_COTTONTAIL: cottontail,
    DASH_HOME: join(fixture, "dash-home"),
    ELECTROBUN_TEMPLATES_BASE_URL: baseUrl,
    HUTCH_ELECTROBUN_DEVKIT_ROOT: coreRoot,
    HUTCH_ENGINE_BINARY: engine,
    HUTCH_NO_UPDATE_CHECK: "1",
  };

  try {
    const listed = await run(hutch, ["electrobun", "init"], { cwd: workspace, env });
    assert.equal(listed.status, 0, listed.stderr || listed.stdout);
    assert.match(listed.stdout, /Electrobun 2\.0\.0 templates \(stable\):/);
    assert.match(listed.stdout, /hello-world - A remote starter/);

    const result = await run(
      hutch,
      ["electrobun", "init", projectName, "--template=hello-world"],
      { cwd: workspace, env },
    );

    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.equal(result.stderr, "");
    assert.equal(
      result.stdout,
      "Downloading hello-world from Electrobun 2.0.0 (stable)...\n" +
        "Preparing the Electrobun devkit and required toolchain...\n" +
        `Created Electrobun project at ${projectRoot}\n` +
        "Next steps:\n" +
        `  cd ${projectName}\n` +
        "  hutch run dev\n",
    );
    assert.equal(existsSync(join(projectRoot, "package.json")), false);
    assert.equal(
      readFileSync(join(projectRoot, "src", "index.ts"), "utf8"),
      'console.log("hello");\n',
    );
    assert.match(readFileSync(join(projectRoot, "electrobun.config.ts"), "utf8"), /electrobun: \{ version: "2\.0\.0" \}/);
    assert.ok(existsSync(join(projectRoot, ".hutch", "devkit", "projection.json")));

    const cached = await run(
      hutch,
      [
        "electrobun",
        "init",
        "cached-app",
        "--template=hello-world",
        "--offline",
      ],
      { cwd: workspace, env },
    );
    assert.equal(cached.status, 0, cached.stderr || cached.stdout);
    assert.ok(existsSync(join(workspace, "cached-app", ".hutch", "devkit", "projection.json")));
  } finally {
    await new Promise((resolveClose) => server.close(resolveClose));
    rmSync(fixture, { recursive: true, force: true });
  }
});
