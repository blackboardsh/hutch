import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, existsSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import {
  createCoreFixture,
  executableName,
  hostContract,
  writeFixtureFile,
} from "./v2-devkit-fixture.js";

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

// This tests Hutch's real build, cleanup, and packaging path. The compiler is
// deliberately a fixture: no downloaded compiler or native devkit is required,
// and the marker makes cache reuse deterministic rather than timing-dependent.
test(
  "Zig main builds preserve their project cache across output cleanup and source edits",
  { timeout: 120_000, skip: process.platform === "win32" },
  () => {
    // The fake compiler and emitted executable use POSIX shell launchers.
    const fixture = realpathSync(mkdtempSync(join(tmpdir(), "hutch-electrobun-zig-cache-")));
    const project = join(fixture, "project");
    const core = join(fixture, "core");
    const bin = join(fixture, "bin");
    const capture = join(fixture, "compiler-invocations.jsonl");
    const hutch = join(hutchRoot, "zig-out", "bin", executableName("hutch"));
    const engine = join(hutchRoot, "zig-out", "bin", executableName("hutch-engine"));
    const host = hostContract();
    const target = `${host.os}-${host.arch}`;
    const buildRoot = join(project, "build", `dev-${target}`);
    const expectedCache = join(project, ".hutch", "cache", "zig", target);
    const expectedInstall = join(buildRoot, ".electrobun-zig-main", target, "install");
    const executable = process.platform === "darwin"
      ? join(buildRoot, "ZigCache-dev.app", "Contents", "MacOS", "main")
      : join(buildRoot, "ZigCache-dev", "bin", "main");
    const source = join(project, "src", "main.zig");
    const version = "2.0.0-test.zig-cache";

    try {
      assert.ok(existsSync(hutch), `Build Hutch before this test: ${hutch}`);
      assert.ok(existsSync(engine), `Build the Hutch engine before this test: ${engine}`);
      const cottontail = resolveCottontail(hutch, engine);
      createCoreFixture(core, version, host);
      writeFixtureFile(join(project, "hutch.config.ts"),
        `export default { electrobun: { version: "${version}" } };\n`);
      writeFixtureFile(join(project, "electrobun.config.ts"), `export default {
  app: { name: "ZigCache", identifier: "dev.electrobun.zig-cache", version: "0.0.0" },
  build: {
    mainProcess: "zig",
    mac: { icons: null, codesign: false, notarize: false, bundleCEF: false, bundleWGPU: false },
    win: { bundleCEF: false, bundleWGPU: false },
    linux: { bundleCEF: false, bundleWGPU: false },
  },
};\n`);
      writeFixtureFile(join(project, "build.zig"), "// Project-owned compiler fixture.\n");
      writeFixtureFile(source, 'pub const generation = "first";\n');

      const compiler = join(fixture, "compiler.cjs");
      writeFixtureFile(compiler, `const assert = require("node:assert/strict");
const { createHash } = require("node:crypto");
const { appendFileSync, chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } = require("node:fs");
const { join } = require("node:path");
const args = process.argv.slice(2);
if (args.length === 1 && args[0] === "version") {
  process.stdout.write("0.16.0\\n");
  process.exit(0);
}
assert.deepEqual(args.slice(0, 2), ["build", "install"]);
function option(name) {
  const index = args.indexOf(name);
  assert.ok(index >= 0 && index + 1 < args.length, "missing " + name);
  return args[index + 1];
}
const cache = option("--cache-dir");
const prefix = option("--prefix");
const buildFile = option("--build-file");
assert.ok(existsSync(buildFile));
const markerPath = join(cache, "fixture-cache-entry");
const previousMarker = existsSync(markerPath) ? readFileSync(markerPath, "utf8") : null;
const sourceHash = createHash("sha256").update(readFileSync(join(process.cwd(), "src", "main.zig"))).digest("hex");
mkdirSync(cache, { recursive: true });
if (previousMarker === null) writeFileSync(markerPath, "first-build-cache-entry");
appendFileSync(process.env.HUTCH_ZIG_TEST_CAPTURE, JSON.stringify({ cache, prefix, buildFile, previousMarker, sourceHash }) + "\\n");
const output = join(prefix, "bin", "main");
mkdirSync(join(prefix, "bin"), { recursive: true });
writeFileSync(output, "#!/bin/sh\\nprintf '%s\\\\n' '" + sourceHash + "'\\n");
chmodSync(output, 0o755);
`);
      writeFixtureFile(join(bin, "zig"),
        '#!/bin/sh\nexec "$HUTCH_ZIG_TEST_NODE" "$HUTCH_ZIG_TEST_COMPILER" "$@"\n');
      chmodSync(join(bin, "zig"), 0o755);

      const env = {
        ...process.env,
        COTTONTAIL_BINARY: cottontail,
        DASH_COTTONTAIL: cottontail,
        HUTCH_ENGINE_BINARY: engine,
        HUTCH_ELECTROBUN_DEVKIT_ROOT: core,
        HUTCH_HOME: join(fixture, "hutch-home"),
        DASH_HOME: join(fixture, "dash-home"),
        DASH_RELEASE_OFFLINE: "1",
        HUTCH_NO_UPDATE_CHECK: "1",
        HUTCH_ZIG_TEST_NODE: process.execPath,
        HUTCH_ZIG_TEST_COMPILER: compiler,
        HUTCH_ZIG_TEST_CAPTURE: capture,
        PATH: `${bin}${delimiter}${process.env.PATH ?? ""}`,
      };
      delete env.COTTONTAIL_ELECTROBUN_PACKAGE;
      delete env.HUTCH_ELECTROBUN_BUILD_LOCK;

      function buildAndRun() {
        const result = spawnSync(hutch, ["electrobun", "build", "--env=dev"], {
          cwd: project, encoding: "utf8", env, timeout: 45_000,
        });
        assert.equal(result.status, 0, result.stderr || result.stdout || String(result.error));
        const output = spawnSync(executable, [], { encoding: "utf8", timeout: 5_000 });
        assert.equal(output.status, 0, output.stderr || String(output.error));
        const expectedHash = createHash("sha256").update(readFileSync(source)).digest("hex");
        assert.equal(output.stdout.trim(), expectedHash, "packaged main must reflect current source");
        return expectedHash;
      }

      const firstHash = buildAndRun();
      const first = JSON.parse(readFileSync(capture, "utf8").trim());
      assert.equal(first.cache, expectedCache);
      assert.equal(first.prefix, expectedInstall);
      assert.equal(first.buildFile, join(project, "build.zig"));
      assert.equal(first.previousMarker, null);

      rmSync(join(project, "build"), { recursive: true, force: true });
      assert.equal(existsSync(executable), false);
      assert.equal(readFileSync(join(expectedCache, "fixture-cache-entry"), "utf8"), "first-build-cache-entry");
      writeFixtureFile(source, 'pub const generation = "second";\n');
      const secondHash = buildAndRun();
      assert.notEqual(secondHash, firstHash);
      const invocations = readFileSync(capture, "utf8").trim().split("\n").map((line) => JSON.parse(line));
      assert.equal(invocations.length, 2, "each build must invoke the project compiler");
      assert.equal(invocations[1].cache, first.cache);
      assert.equal(invocations[1].prefix, expectedInstall);
      assert.equal(invocations[1].previousMarker, "first-build-cache-entry");
      assert.equal(invocations[1].sourceHash, secondHash);
      assert.equal(existsSync(join(expectedInstall, "bin", "main")), true);

      // A project cache must not be allowed to redirect compiler writes outside
      // the project through a symlink at any newly introduced path component.
      const outside = join(fixture, "outside-cache");
      writeFixtureFile(join(outside, "sentinel"), "leave outside state alone");
      rmSync(expectedCache, { recursive: true });
      symlinkSync(outside, expectedCache, "dir");
      const redirected = spawnSync(hutch, ["electrobun", "build", "--env=dev"], {
        cwd: project, encoding: "utf8", env, timeout: 45_000,
      });
      assert.notEqual(redirected.status, 0, redirected.stderr || redirected.stdout);
      assert.match(redirected.stderr, /InvalidProjectStatePath/);
      assert.equal(readFileSync(join(outside, "sentinel"), "utf8"), "leave outside state alone");
      assert.equal(existsSync(join(outside, "fixture-cache-entry")), false);
      assert.equal(readFileSync(capture, "utf8").trim().split("\n").length, 2,
        "the compiler must not run with a redirected cache");
    } finally {
      rmSync(fixture, { recursive: true, force: true });
    }
  },
);
