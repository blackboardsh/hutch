import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { createCoreFixture, executableName, hostContract, writeFixtureFile } from "./v2-devkit-fixture.js";

const hutchRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

function resolveCottontail(hutch, engine) {
  const configured = process.env.COTTONTAIL_BINARY ?? process.env.DASH_COTTONTAIL;
  if (configured) return resolve(configured);
  const result = spawnSync(hutch, ["cottontail", "path"], {
    cwd: hutchRoot,
    encoding: "utf8",
    env: { ...process.env, HUTCH_ENGINE_BINARY: engine, HUTCH_NO_UPDATE_CHECK: "1" },
    timeout: 30_000,
  });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  return result.stdout.trim();
}

// Compiler and compressor fixtures isolate Hutch's cross-target orchestration:
// these assertions do not claim to validate actual compiler or zstd output.
// These POSIX fixtures require native Windows launchers before they can run
// on Windows; they do not establish Windows cross-build correctness.
test("cross architecture Zig and JavaScript builds package target payloads using host tools", {
  timeout: 120_000,
  skip: process.platform === "win32",
}, () => {
  const fixture = realpathSync(mkdtempSync(join(tmpdir(), "hutch-cross-architecture-")));
  const project = join(fixture, "project");
  const targetCore = join(fixture, "target-core");
  const hostCore = join(fixture, "host-core");
  const bin = join(fixture, "bin");
  const capture = join(fixture, "compiler.jsonl");
  const toolCapture = join(fixture, "host-tools.jsonl");
  const hooks = join(fixture, "hooks.jsonl");
  const hutch = join(hutchRoot, "zig-out", "bin", executableName("hutch"));
  const engine = join(hutchRoot, "zig-out", "bin", executableName("hutch-engine"));
  const host = hostContract();
  const arch = host.arch === "arm64" ? "x64" : "arm64";
  const target = {
    ...host,
    arch,
    key: host.key.replace(/-(arm64|x64)$/, `-${arch}`),
    asset: host.asset.replace(/-(arm64|x64)$/, `-${arch}`),
  };
  const targetKey = `${host.os}-${arch}`;
  const version = "2.0.0-test.cross-architecture";
  const targetPrefix = arch === "arm64" ? "aarch64" : "x86_64";

  try {
    assert.ok(existsSync(hutch), `Build Hutch before this test: ${hutch}`);
    assert.ok(existsSync(engine), `Build the Hutch engine before this test: ${engine}`);
    const cottontail = resolveCottontail(hutch, engine);
    createCoreFixture(targetCore, version, target);
    createCoreFixture(hostCore, version, host);
    writeFixtureFile(join(targetCore, host.core), `target-core-${arch}`);
    writeFixtureFile(join(hostCore, host.core), `host-core-${host.arch}`);
    const targetTool = "#!/bin/sh\necho 'target tool executed on build host' >&2\nexit 91\n";
    for (const tool of ["zig-zstd", "bsdiff"]) {
      writeFixtureFile(join(targetCore, tool), targetTool);
      chmodSync(join(targetCore, tool), 0o755);
    }

    writeFixtureFile(join(project, "hutch.config.ts"), `export default { electrobun: { version: "${version}" } };\n`);
    writeFixtureFile(join(project, "electrobun.config.ts"), `export default {
  app: { name: "CrossFixture", identifier: "dev.electrobun.cross-fixture", version: "1.2.3" },
  build: {
    mainProcess: "zig",
    mac: { icons: null, codesign: false, notarize: false, createDmg: false, bundleCEF: false, bundleWGPU: false },
    win: { bundleCEF: false, bundleWGPU: false },
    linux: { bundleCEF: false, bundleWGPU: false },
  },
  release: { generatePatch: false },
  scripts: { preBuild: "capture-hook.mjs" },
};\n`);
    writeFixtureFile(join(project, "capture-hook.mjs"), `import { appendFileSync } from "node:fs";
appendFileSync(process.env.HUTCH_CROSS_HOOK_CAPTURE, JSON.stringify({
  target: process.env.ELECTROBUN_ARCH,
  host: process.env.ELECTROBUN_HOST_ARCH,
  build: process.env.ELECTROBUN_BUILD_DIR,
}) + "\\n");\n`);
    writeFixtureFile(join(project, "build.zig"), "// Owned compiler fixture.\n");
    const compiler = join(fixture, "compiler.cjs");
    writeFixtureFile(compiler, `const assert = require("node:assert/strict");
const { appendFileSync, mkdirSync, writeFileSync } = require("node:fs");
const { join } = require("node:path");
const args = process.argv.slice(2);
if (args.length === 1 && args[0] === "version") { console.log("0.16.0"); process.exit(0); }
assert.deepEqual(args.slice(0, 2), ["build", "install"]);
function option(name) { const index = args.indexOf(name); assert.ok(index >= 0); return args[index + 1]; }
const prefix = option("--prefix");
const cache = option("--cache-dir");
const target = args.find(arg => arg.startsWith("-Dtarget="));
appendFileSync(process.env.HUTCH_CROSS_COMPILER_CAPTURE, JSON.stringify({ prefix, cache, target }) + "\\n");
mkdirSync(join(prefix, "bin"), { recursive: true });
writeFileSync(join(prefix, "bin", "main"), "target-main:" + target);\n`);
    writeFixtureFile(join(bin, "zig"), '#!/bin/sh\nexec "$HUTCH_CROSS_NODE" "$HUTCH_CROSS_COMPILER" "$@"\n');
    chmodSync(join(bin, "zig"), 0o755);

    const compressor = join(fixture, "compressor.cjs");
    writeFixtureFile(compressor, `const assert = require("node:assert/strict");
const { appendFileSync, copyFileSync } = require("node:fs");
const args = process.argv.slice(2);
assert.equal(args[0], "compress");
appendFileSync(process.env.HUTCH_CROSS_TOOL_CAPTURE, JSON.stringify(args) + "\\n");
copyFileSync(args[args.indexOf("-i") + 1], args[args.indexOf("-o") + 1]);\n`);
    writeFixtureFile(join(hostCore, "zig-zstd"), '#!/bin/sh\nexec "$HUTCH_CROSS_NODE" "$HUTCH_CROSS_COMPRESSOR" "$@"\n');
    chmodSync(join(hostCore, "zig-zstd"), 0o755);

    const env = {
      ...process.env,
      COTTONTAIL_BINARY: cottontail,
      DASH_COTTONTAIL: cottontail,
      HUTCH_RUNTIME: "cottontail",
      HUTCH_ENGINE_BINARY: engine,
      HUTCH_ELECTROBUN_DEVKIT_ROOT: targetCore,
      HUTCH_ELECTROBUN_HOST_DEVKIT_ROOT: hostCore,
      HUTCH_HOME: join(fixture, "hutch-home"),
      DASH_HOME: join(fixture, "dash-home"),
      DASH_RELEASE_OFFLINE: "1",
      HUTCH_NO_UPDATE_CHECK: "1",
      HUTCH_CROSS_NODE: process.execPath,
      HUTCH_CROSS_COMPILER: compiler,
      HUTCH_CROSS_COMPRESSOR: compressor,
      HUTCH_CROSS_COMPILER_CAPTURE: capture,
      HUTCH_CROSS_TOOL_CAPTURE: toolCapture,
      HUTCH_CROSS_HOOK_CAPTURE: hooks,
      PATH: `${bin}${delimiter}${process.env.PATH ?? ""}`,
    };
    delete env.COTTONTAIL_ELECTROBUN_PACKAGE;
    delete env.HUTCH_ELECTROBUN_BUILD_LOCK;
    delete env.HUTCH_ELECTROBUN_COTTONTAIL_BINARY;
    delete env.DASH_USE_LOCAL_COTTONTAIL;

    function run(args, expectedStatus = 0) {
      const result = spawnSync(hutch, ["electrobun", ...args], {
        cwd: project, encoding: "utf8", env, timeout: 45_000,
      });
      assert.equal(result.status, expectedStatus, result.stderr || result.stdout || String(result.error));
      return result;
    }
    run(["sync", "--arch", arch]);
    const projection = JSON.parse(readFileSync(join(project, ".hutch", "devkit", "projection.json"), "utf8"));
    assert.deepEqual(projection.target, { os: host.os, arch });
    // Both targets share a version. A native preparation between cross builds
    // must not make the next build reuse an incompatible projected devkit.
    env.HUTCH_ELECTROBUN_DEVKIT_ROOT = hostCore;
    run(["sync", `--arch=${host.arch}`]);
    assert.deepEqual(JSON.parse(readFileSync(join(project, ".hutch", "devkit", "projection.json"), "utf8")).target,
      { os: host.os, arch: host.arch });
    env.HUTCH_ELECTROBUN_DEVKIT_ROOT = targetCore;
    run(["build", "--env=dev", `--arch=${arch}`]);
    assert.deepEqual(JSON.parse(readFileSync(join(project, ".hutch", "devkit", "projection.json"), "utf8")).target,
      { os: host.os, arch });
    const buildRoot = join(project, "build", `dev-${targetKey}`);
    const execDir = process.platform === "darwin"
      ? join(buildRoot, "CrossFixture-dev.app", "Contents", "MacOS")
      : join(buildRoot, "CrossFixture-dev", "bin");
    assert.equal(readFileSync(join(execDir, host.core), "utf8"), `target-core-${arch}`);
    assert.match(readFileSync(join(execDir, "main"), "utf8"), new RegExp(`target-main:-Dtarget=${targetPrefix}-`));
    assert.equal(existsSync(join(project, "build", `dev-${host.os}-${host.arch}`)), false);
    const first = JSON.parse(readFileSync(capture, "utf8").trim());
    assert.equal(first.cache, join(project, ".hutch", "cache", "zig", targetKey));
    assert.match(first.target, new RegExp(`^-Dtarget=${targetPrefix}-`));
    assert.deepEqual(JSON.parse(readFileSync(hooks, "utf8").trim()), { target: arch, host: host.arch, build: buildRoot });

    run(["build", "--env=canary", `--arch=${arch}`]);
    assert.equal(readFileSync(toolCapture, "utf8").trim().split("\n").length, 1,
      "release compression must execute the host devkit tool exactly once");
    const update = JSON.parse(readFileSync(join(project, "artifacts", `canary-${targetKey}-update.json`), "utf8"));
    assert.equal(update.platform, host.os);
    assert.equal(update.arch, arch);
    assert.equal(update.version, "1.2.3");
    assert.equal(existsSync(join(project, "artifacts", `canary-${host.os}-${host.arch}-update.json`)), false);
    const archive = join(project, "artifacts", `canary-${targetKey}-CrossFixture-canary${process.platform === "darwin" ? ".app" : ""}.tar.zst`);
    // The compressor fixture deliberately preserves the tar bytes, making the
    // target payload inspectable without relying on zstd in the test host.
    const unpacked = join(fixture, "unpacked");
    writeFixtureFile(join(unpacked, "placeholder"));
    const extraction = spawnSync("tar", ["-xf", archive, "-C", unpacked], { encoding: "utf8" });
    assert.equal(extraction.status, 0, extraction.stderr || extraction.stdout);
    const releasedExec = process.platform === "darwin"
      ? join(unpacked, "CrossFixture-canary.app", "Contents", "MacOS")
      : join(unpacked, "CrossFixture-canary", "bin");
    assert.equal(readFileSync(join(releasedExec, host.core), "utf8"), `target-core-${arch}`);
    assert.equal(readFileSync(join(releasedExec, "zig-zstd"), "utf8"), targetTool,
      "target runtime helper must remain target-selected even though compression used a host tool");

    for (const command of ["run", "dev"]) {
      const unsupported = spawnSync(hutch, ["electrobun", command, `--arch=${arch}`], {
        cwd: project, encoding: "utf8", env, timeout: 10_000,
      });
      assert.notEqual(unsupported.status, 0);
      assert.match(unsupported.stderr, /CrossArchitectureExecutionUnsupported|run\/dev\/init require the native architecture/);
    }
    const configPath = join(project, "electrobun.config.ts");
    const zigConfig = readFileSync(configPath, "utf8");
    writeFixtureFile(configPath, zigConfig.replace('mainProcess: "zig"', 'mainProcess: "rust"'));
    const unsupportedMain = spawnSync(hutch, ["electrobun", "build", `--arch=${arch}`], {
      cwd: project, encoding: "utf8", env, timeout: 10_000,
    });
    assert.notEqual(unsupportedMain.status, 0);
    assert.match(unsupportedMain.stderr, /UnsupportedCrossArchitectureMainProcess|other main processes need target toolchain support/);
    assert.equal(readFileSync(capture, "utf8").trim().split("\n").length, 2,
      "unsupported execution or runtime selection must not invoke the compiler");

    // A legacy devkit's embedded Bun is a target payload. It must never be
    // invoked to load configuration, execute hooks, or bundle JavaScript.
    const targetBun = "#!/bin/sh\necho 'target Bun executed on build host' >&2\nexit 92\n";
    const manifestPath = join(targetCore, "native-devkit.json");
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    delete manifest.toolchains.bun;
    manifest.runtimes = { bun: { version: "1.3.13" } };
    manifest.layout.runtime.bun = "bun";
    writeFixtureFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
    writeFixtureFile(join(targetCore, "bun"), targetBun);
    chmodSync(join(targetCore, "bun"), 0o755);
    writeFixtureFile(join(project, "src", "bun", "index.ts"),
      "import { devkitMarker } from 'electrobun/main';\nconsole.log('CROSS_JAVASCRIPT_MAIN', devkitMarker);\n");
    writeFixtureFile(configPath, zigConfig.replace('mainProcess: "zig"', 'mainProcess: "bun"'));

    const helperCapture = join(fixture, "host-helper.jsonl");
    const helper = join(fixture, "helper.cjs");
    writeFixtureFile(helper, `const { appendFileSync } = require("node:fs");
const { spawnSync } = require("node:child_process");
const args = process.argv.slice(2);
appendFileSync(process.env.HUTCH_CROSS_HELPER_CAPTURE, JSON.stringify(args) + "\\n");
const result = spawnSync(process.env.HUTCH_CROSS_HOST_COTTONTAIL, args, { stdio: "inherit" });
if (result.error) throw result.error;
process.exit(result.status ?? 1);\n`);
    const hostHelper = join(bin, "cottontail");
    writeFixtureFile(hostHelper, '#!/bin/sh\nexec "$HUTCH_CROSS_NODE" "$HUTCH_CROSS_HELPER" "$@"\n');
    chmodSync(hostHelper, 0o755);
    env.COTTONTAIL_BINARY = hostHelper;
    env.DASH_COTTONTAIL = hostHelper;
    env.HUTCH_CROSS_HELPER = helper;
    env.HUTCH_CROSS_HELPER_CAPTURE = helperCapture;
    env.HUTCH_CROSS_HOST_COTTONTAIL = cottontail;

    run(["build", "--env=canary", `--arch=${arch}`]);
    function extractRelease() {
      rmSync(unpacked, { recursive: true, force: true });
      writeFixtureFile(join(unpacked, "placeholder"));
      const result = spawnSync("tar", ["-xf", archive, "-C", unpacked], { encoding: "utf8" });
      assert.equal(result.status, 0, result.stderr || result.stdout);
    }
    extractRelease();
    const canaryBundle = join(unpacked,
      `CrossFixture-canary${process.platform === "darwin" ? ".app" : ""}`);
    const canaryExec = process.platform === "darwin"
      ? join(canaryBundle, "Contents", "MacOS") : join(canaryBundle, "bin");
    const canaryResources = process.platform === "darwin"
      ? join(canaryBundle, "Contents", "Resources") : join(canaryBundle, "Resources");
    assert.equal(readFileSync(join(canaryExec, "bun"), "utf8"), targetBun,
      "the release archive must ship the embedded target Bun unchanged");
    assert.equal(readFileSync(join(canaryExec, host.core), "utf8"), `target-core-${arch}`);
    const bundledMain = join(canaryResources, "app", "bun", "index.js");
    assert.match(readFileSync(bundledMain, "utf8"), /CROSS_JAVASCRIPT_MAIN/);
    assert.match(readFileSync(bundledMain, "utf8"), /V2_DEVKIT_ALIAS/);
    const helperCalls = readFileSync(helperCapture, "utf8").trim().split("\n").map(JSON.parse);
    assert.equal(helperCalls.filter(args => args.some(arg => arg.endsWith("javascript-build-helper.mjs"))).length, 1,
      "JavaScript bundling must execute the native helper runtime");
    assert.equal(readFileSync(toolCapture, "utf8").trim().split("\n").length, 2);
    const bunUpdate = JSON.parse(readFileSync(join(project, "artifacts", `canary-${targetKey}-update.json`), "utf8"));
    assert.equal(bunUpdate.arch, arch);
    assert.equal(bunUpdate.platform, host.os);
    const bunMetadata = JSON.parse(readFileSync(join(canaryResources, "build.json"), "utf8"));
    assert.equal(bunMetadata.mainProcess, "bun");
    assert.equal(bunMetadata.runtimeVersions.bun, "1.3.13");

    // Seed both architectures at the same exact Cottontail release. Its
    // binary and optional capabilities must all come from the target store.
    const cottontailVersion = "9.8.7";
    const revision = "b".repeat(40);
    for (const selected of [host, target]) {
      const root = join(env.HUTCH_HOME, "releases", "cottontail", cottontailVersion, revision, selected.key);
      const executable = join(root, "bin", "cottontail");
      writeFixtureFile(executable, `#!/bin/sh\necho '${selected.arch} app runtime executed on build host' >&2\nexit 93\n`);
      chmodSync(executable, 0o755);
      writeFixtureFile(join(root, "bin", "cottontail-core", "capability-namespace.jsc"), `core-${selected.arch}`);
      writeFixtureFile(join(root, "bin", "cottontail-stdlib", "compression", "main.jsc"), `compression-${selected.arch}`);
      writeFixtureFile(join(root, ".dash-installed"), "a".repeat(64));
      writeFixtureFile(join(root, "cottontail-release.json"), JSON.stringify({
        schema: 1, kind: "archive", product: "cottontail", version: cottontailVersion, revision, platform: selected.key,
      }));
      writeFixtureFile(`${root}.lock`, "");
    }
    manifest.toolchains.cottontail = { defaultVersion: cottontailVersion };
    writeFixtureFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
    writeFixtureFile(configPath, zigConfig.replace('mainProcess: "zig"',
      'mainProcess: "cottontail", cottontail: { entrypoint: "src/bun/index.ts", capabilities: ["compression"] }'));
    run(["build", "--env=canary", `--arch=${arch}`]);
    extractRelease();
    assert.equal(readFileSync(join(canaryExec, "cottontail"), "utf8"),
      readFileSync(join(env.HUTCH_HOME, "releases", "cottontail", cottontailVersion, revision, target.key, "bin", "cottontail"), "utf8"));
    assert.equal(readFileSync(join(canaryExec, "cottontail-core", "capability-namespace.jsc"), "utf8"), `core-${arch}`);
    assert.equal(readFileSync(join(canaryExec, "cottontail-stdlib", "compression", "main.jsc"), "utf8"), `compression-${arch}`);
    assert.match(readFileSync(bundledMain, "utf8"), /CROSS_JAVASCRIPT_MAIN/);
    const cottontailMetadata = JSON.parse(readFileSync(join(canaryResources, "build.json"), "utf8"));
    assert.equal(cottontailMetadata.mainProcess, "cottontail");
    assert.equal(cottontailMetadata.runtimeVersions.cottontail, cottontailVersion);
    const cottontailUpdate = JSON.parse(readFileSync(join(project, "artifacts", `canary-${targetKey}-update.json`), "utf8"));
    assert.equal(cottontailUpdate.arch, arch);
    assert.equal(cottontailUpdate.platform, host.os);
    assert.equal(readFileSync(toolCapture, "utf8").trim().split("\n").length, 3);
    assert.equal(readFileSync(helperCapture, "utf8").trim().split("\n").map(JSON.parse)
      .filter(args => args.some(arg => arg.endsWith("javascript-build-helper.mjs"))).length, 2);
    assert.ok(readFileSync(join(project, ".hutch", "dependencies.lock"), "utf8")
      .includes(`releases/cottontail/${cottontailVersion}/${revision}/${target.key}`));

    env.HUTCH_ELECTROBUN_COTTONTAIL_BINARY = cottontail;
    const localOverride = spawnSync(hutch, ["electrobun", "build", "--env=dev", `--arch=${arch}`], {
      cwd: project, encoding: "utf8", env, timeout: 10_000,
    });
    assert.notEqual(localOverride.status, 0);
    assert.match(localOverride.stderr, /CrossArchitectureCottontailRequiresPin|cross-architecture Cottontail builds require an exact runtime pin/);
    delete env.HUTCH_ELECTROBUN_COTTONTAIL_BINARY;

    delete manifest.toolchains.cottontail;
    writeFixtureFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
    const legacyFallback = spawnSync(hutch, ["electrobun", "build", "--env=dev", `--arch=${arch}`], {
      cwd: project, encoding: "utf8", env, timeout: 10_000,
    });
    assert.notEqual(legacyFallback.status, 0);
    assert.match(legacyFallback.stderr, /CrossArchitectureCottontailRequiresPin|cross-architecture Cottontail builds require an exact runtime pin/);
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
});
