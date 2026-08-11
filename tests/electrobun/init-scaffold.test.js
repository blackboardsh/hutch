import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  readdirSync,
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
  const nativeTemplateRoot = join(archiveSource, "native-basic");
  const archivePath = join(fixture, "hello-world.tar.gz");
  const nativeArchivePath = join(fixture, "native-basic.tar.gz");
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
  writeFileSync(
    join(templateRoot, "hutch.config.ts"),
    'export default { scripts: { install: [process.execPath, "install.cjs"] } };\n',
  );
  writeFileSync(
    join(templateRoot, "install.cjs"),
    'require("node:fs").writeFileSync(".configured-install-ran", process.cwd());\n',
  );
  writeFileSync(join(templateRoot, "src", "index.ts"), 'console.log("hello");\n');
  mkdirSync(join(nativeTemplateRoot, "src"), { recursive: true });
  writeFileSync(join(nativeTemplateRoot, "electrobun.config.ts"), `
export default {
  electrobun: { version: "${version}" },
  app: { name: "NativeBasic", identifier: "dev.electrobun.native-basic", version: "0.0.0" },
  build: {
    mainProcess: "cottontail",
    cottontail: { entrypoint: "src/index.ts" },
    mac: { icons: null, codesign: false, notarize: false, bundleCEF: false, bundleWGPU: false },
    win: { bundleCEF: false, bundleWGPU: false },
    linux: { bundleCEF: false, bundleWGPU: false },
  },
};
`);
  writeFileSync(
    join(nativeTemplateRoot, "hutch.config.ts"),
    'export default { scripts: { dev: ["hutch", "electrobun", "dev"] } };\n',
  );
  writeFileSync(join(nativeTemplateRoot, "src", "index.ts"), "console.log('native package-free');\n");
  const tar = spawnSync("tar", ["-czf", archivePath, "-C", archiveSource, "hello-world"], {
    encoding: "utf8",
    env: { ...process.env, COPYFILE_DISABLE: "1" },
  });
  assert.equal(tar.status, 0, tar.stderr || tar.stdout);
  const nativeTar = spawnSync("tar", ["-czf", nativeArchivePath, "-C", archiveSource, "native-basic"], {
    encoding: "utf8",
    env: { ...process.env, COPYFILE_DISABLE: "1" },
  });
  assert.equal(nativeTar.status, 0, nativeTar.stderr || nativeTar.stdout);
  const archive = readFileSync(archivePath);
  const checksum = createHash("sha256").update(archive).digest("hex");
  const nativeArchive = readFileSync(nativeArchivePath);
  const nativeChecksum = createHash("sha256").update(nativeArchive).digest("hex");
  const requestCounts = {
    channel: 0,
    helloArchive: 0,
    nativeArchive: 0,
  };

  let baseUrl;
  const server = createServer((request, response) => {
    if (request.url === "/channels/stable.json") {
      requestCounts.channel += 1;
      const catalog = {
        schema: 1,
        kind: "electrobun-template-channel",
        channel: "stable",
        version: "2.0.0",
        revision: "a".repeat(40),
        tools: { hutch: "0.5.0", cottontail: "0.2.3" },
        templates: [
          {
            id: "hello-world",
            name: "Hello World",
            description: "A remote starter",
            mainProcess: "cottontail",
            archive: {
              url: `${baseUrl}/artifacts/${checksum}.tar.gz`,
              sha256: checksum,
              size: archive.length,
            },
          },
          {
            id: "native-basic",
            name: "Native Basic",
            description: "A package-free starter",
            mainProcess: "cottontail",
            archive: {
              url: `${baseUrl}/artifacts/${nativeChecksum}.tar.gz`,
              sha256: nativeChecksum,
              size: nativeArchive.length,
            },
          },
        ],
      };
      setTimeout(() => {
        response.writeHead(200, { "content-type": "application/json" });
        response.end(`${JSON.stringify(catalog)}\n`);
      }, 75);
      return;
    }
    if (request.url === `/artifacts/${checksum}.tar.gz`) {
      requestCounts.helloArchive += 1;
      response.writeHead(200, { "content-type": "application/gzip" });
      response.end(archive);
      return;
    }
    if (request.url === `/artifacts/${nativeChecksum}.tar.gz`) {
      requestCounts.nativeArchive += 1;
      response.writeHead(200, { "content-type": "application/gzip" });
      response.end(nativeArchive);
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

  const dashHome = join(fixture, "dash-home");
  const env = {
    ...process.env,
    COTTONTAIL_BINARY: cottontail,
    DASH_COTTONTAIL: cottontail,
    DASH_HOME: dashHome,
    ELECTROBUN_TEMPLATES_BASE_URL: baseUrl,
    HUTCH_ELECTROBUN_DEVKIT_ROOT: coreRoot,
    HUTCH_ENGINE_BINARY: engine,
    HUTCH_NO_UPDATE_CHECK: "1",
  };

  try {
    const racedProjectName = "raced-app";
    const racedProjectRoot = join(realpathSync(workspace), racedProjectName);
    const raced = await Promise.all([
      run(
        hutch,
        ["electrobun", "init", racedProjectName, "--template=native-basic", "--skip-install"],
        { cwd: workspace, env },
      ),
      run(
        hutch,
        ["electrobun", "init", racedProjectName, "--template=native-basic", "--skip-install"],
        { cwd: workspace, env },
      ),
    ]);
    assert.deepEqual(
      raced.map((result) => result.status).sort(),
      [0, 1],
      raced.map((result) => result.stderr || result.stdout).join("\n"),
    );
    const rejectedRace = raced.find((result) => result.status === 1);
    assert.match(rejectedRace.stderr, /ProjectAlreadyExists/);
    assert.equal(
      readFileSync(join(racedProjectRoot, "src", "index.ts"), "utf8"),
      "console.log('native package-free');\n",
    );
    assert.ok(existsSync(join(racedProjectRoot, ".hutch", "devkit", "projection.json")));
    assert.ok(existsSync(join(workspace, `.${racedProjectName}.hutch-template.lock`)));
    assert.deepEqual(
      readdirSync(workspace).filter((name) => name.startsWith(`.${racedProjectName}.hutch-template-tmp-`)),
      [],
    );
    assert.equal(requestCounts.channel, 1, "contending cold init must reuse the published catalog");
    assert.equal(requestCounts.nativeArchive, 1, "contending cold init must download one template archive");
    const templateCache = join(dashHome, "cache", "electrobun", "templates");
    assert.ok(existsSync(join(templateCache, "channels", "stable.json.lock")));
    assert.ok(existsSync(join(templateCache, "archives", `${nativeChecksum}.tar.gz.lock`)));
    assert.deepEqual(
      readFileSync(join(templateCache, "archives", `${nativeChecksum}.tar.gz`)),
      nativeArchive,
      "the winning initializer must publish the complete verified template archive",
    );

    const listed = await run(hutch, ["electrobun", "init"], { cwd: workspace, env });
    assert.equal(listed.status, 0, listed.stderr || listed.stdout);
    assert.match(listed.stdout, /Electrobun 2\.0\.0 templates \(stable\):/);
    assert.match(listed.stdout, /hello-world - A remote starter/);
    assert.match(listed.stdout, /native-basic - A package-free starter/);

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
        "Running hutch.config.ts install task if configured...\n" +
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
    assert.equal(readFileSync(join(projectRoot, ".configured-install-ran"), "utf8"), projectRoot);

    const nativeProjectName = "native-app";
    const nativeProjectRoot = join(realpathSync(workspace), nativeProjectName);
    const nativeResult = await run(
      hutch,
      ["electrobun", "init", nativeProjectName, "--template=native-basic"],
      { cwd: workspace, env },
    );
    assert.equal(nativeResult.status, 0, nativeResult.stderr || nativeResult.stdout);
    assert.equal(nativeResult.stderr, "");
    assert.match(nativeResult.stdout, /Preparing the Electrobun devkit and required toolchain/);
    assert.match(nativeResult.stdout, /Running hutch\.config\.ts install task if configured/);
    assert.ok(existsSync(join(nativeProjectRoot, "src", "index.ts")));
    assert.equal(existsSync(join(nativeProjectRoot, "package.json")), false);
    assert.equal(existsSync(join(nativeProjectRoot, ".configured-install-ran")), false);
    assert.ok(existsSync(join(nativeProjectRoot, ".hutch", "devkit", "projection.json")));

    const skipped = await run(
      hutch,
      ["electrobun", "init", "skipped-app", "--template=hello-world", "--skip-install"],
      { cwd: workspace, env },
    );
    assert.equal(skipped.status, 0, skipped.stderr || skipped.stdout);
    assert.match(skipped.stdout, /Skipped configured install task \(--skip-install\)\./);
    assert.match(skipped.stdout, /hutch run --if-configured install/);
    assert.equal(existsSync(join(workspace, "skipped-app", ".configured-install-ran")), false);
    assert.ok(existsSync(join(workspace, "skipped-app", ".hutch", "devkit", "projection.json")));

    const requestsBeforeEnvironmentOffline = { ...requestCounts };
    const cached = await run(
      hutch,
      [
        "electrobun",
        "init",
        "cached-app",
        "--template=hello-world",
      ],
      { cwd: workspace, env: { ...env, DASH_RELEASE_OFFLINE: "1" } },
    );
    assert.equal(cached.status, 0, cached.stderr || cached.stdout);
    assert.ok(existsSync(join(workspace, "cached-app", ".hutch", "devkit", "projection.json")));
    assert.match(cached.stdout, /Running hutch\.config\.ts install task if configured/);
    assert.doesNotMatch(cached.stdout, /Skipped configured install task/);
    assert.doesNotMatch(cached.stdout, /hutch run --if-configured install/);
    assert.equal(
      readFileSync(join(workspace, "cached-app", ".configured-install-ran"), "utf8"),
      join(realpathSync(workspace), "cached-app"),
    );
    assert.deepEqual(
      requestCounts,
      requestsBeforeEnvironmentOffline,
      "DASH_RELEASE_OFFLINE must prevent Dash-managed HTTP without suppressing install",
    );

    const requestsBeforeCliOffline = { ...requestCounts };
    const cliOffline = await run(
      hutch,
      [
        "electrobun",
        "init",
        "cli-offline-app",
        "--template=hello-world",
        "--offline",
      ],
      { cwd: workspace, env },
    );
    assert.equal(cliOffline.status, 0, cliOffline.stderr || cliOffline.stdout);
    assert.match(cliOffline.stdout, /Running hutch\.config\.ts install task if configured/);
    assert.equal(
      readFileSync(join(workspace, "cli-offline-app", ".configured-install-ran"), "utf8"),
      join(realpathSync(workspace), "cli-offline-app"),
    );
    assert.deepEqual(
      requestCounts,
      requestsBeforeCliOffline,
      "--offline must prevent Dash-managed HTTP without suppressing install",
    );
  } finally {
    await new Promise((resolveClose) => server.close(resolveClose));
    rmSync(fixture, { recursive: true, force: true });
  }
});
