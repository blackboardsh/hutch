import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import {
  chmodSync,
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

const hutchRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

function executableName(name) {
  return process.platform === "win32" ? `${name}.exe` : name;
}

function write(path, contents = "") {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, contents);
}

function platformNames() {
  if (process.platform === "darwin") {
    return {
      key: `macos-${process.arch === "arm64" ? "arm64" : "x64"}`,
      core: "libElectrobunCore.dylib",
      native: "libNativeWrapper.dylib",
      asar: "libasar.dylib",
    };
  }
  if (process.platform === "win32") {
    return {
      key: "windows-x64",
      core: "ElectrobunCore.dll",
      native: "libNativeWrapper.dll",
      asar: "libasar.dll",
    };
  }
  return {
    key: `linux-${process.arch === "arm64" ? "arm64" : "x64"}`,
    core: "libElectrobunCore.so",
    native: "libNativeWrapper.so",
    asar: "libasar.so",
  };
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

test("published npm packages download and reuse native Electrobun artifacts", { timeout: 120_000 }, async () => {
  const fixture = mkdtempSync(join(os.tmpdir(), "hutch-published-electrobun-"));
  const project = join(fixture, "project");
  const packageRoot = join(fixture, "electrobun-package");
  const dist = join(packageRoot, "dist");
  const coreFiles = join(fixture, "core-files");
  const archive = join(fixture, "electrobun-core.tar.gz");
  const dashHome = join(fixture, "dash-home");
  const names = platformNames();
  const version = "9.8.7-test.1";
  const hutch = join(hutchRoot, "zig-out", "bin", executableName("hutch"));
  const engine = join(hutchRoot, "zig-out", "bin", executableName("hutch-engine"));
  const cottontail = resolveCottontail();

  try {
    write(join(packageRoot, "package.json"), JSON.stringify({ name: "electrobun", version, type: "module" }));
    write(join(dist, "main.js"));
    write(join(dist, "preload-full.js"));
    write(join(dist, "preload-sandboxed.js"));

    for (const file of [executableName("launcher"), names.core, names.native, names.asar]) {
      write(join(coreFiles, file), file);
      if (process.platform !== "win32") chmodSync(join(coreFiles, file), 0o755);
    }
    const packed = spawnSync("tar", ["-czf", archive, "-C", coreFiles, "."], { encoding: "utf8" });
    assert.equal(packed.status, 0, packed.stderr || packed.stdout);

    write(join(project, "src", "bun", "index.ts"), "console.log('published artifact fixture');\n");
    write(join(project, "electrobun.config.ts"), `
export default {
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

    let requests = 0;
    const server = createServer((_request, response) => {
      requests += 1;
      response.writeHead(200, { "content-type": "application/gzip" });
      response.end(readFileSync(archive));
    });
    await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
    const address = server.address();
    assert.ok(address && typeof address === "object");

    try {
      const env = {
        ...process.env,
        COTTONTAIL_BINARY: cottontail,
        COTTONTAIL_ELECTROBUN_PACKAGE: packageRoot,
        DASH_HOME: dashHome,
        ELECTROBUN_RELEASES_BASE_URL: `http://127.0.0.1:${address.port}/releases/download`,
        HUTCH_ENGINE_BINARY: engine,
        HUTCH_NO_UPDATE_CHECK: "1",
      };
      const first = await run(hutch, ["electrobun", "build", "--env=dev"], {
        cwd: project,
        env,
        stdio: ["ignore", "pipe", "pipe"],
      });
      assert.equal(first.status, 0, first.stderr || first.stdout);
      assert.equal(requests, 1, "the first build should download one core archive");
      assert.match(first.stderr, /downloading Electrobun 9\.8\.7-test\.1 core/);

      const cacheRoot = join(dashHome, "products", "electrobun", version, names.key);
      assert.ok(existsSync(join(cacheRoot, executableName("launcher"))));
      assert.ok(existsSync(join(cacheRoot, ".core-complete")));

      rmSync(join(project, "build"), { recursive: true, force: true });
      const second = await run(hutch, ["electrobun", "build", "--env=dev"], {
        cwd: project,
        env,
        stdio: ["ignore", "pipe", "pipe"],
      });
      assert.equal(second.status, 0, second.stderr || second.stdout);
      assert.equal(requests, 1, "subsequent projects should reuse the shared artifact cache");
    } finally {
      await new Promise((resolveClose, reject) => server.close((error) => error ? reject(error) : resolveClose()));
    }
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
});
