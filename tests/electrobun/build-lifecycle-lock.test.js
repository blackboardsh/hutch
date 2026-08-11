import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  appendFileSync,
  chmodSync,
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
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

function trackedRun(command, args, options) {
  const child = spawn(command, args, options);
  const tracked = { child, stdout: "", stderr: "", closed: null, exited: null };
  child.stdout.on("data", (chunk) => { tracked.stdout += chunk; });
  child.stderr.on("data", (chunk) => { tracked.stderr += chunk; });
  tracked.exited = new Promise((resolveExit, reject) => {
    child.once("error", reject);
    child.once("exit", (status, signal) => resolveExit({ status, signal }));
  });
  tracked.closed = new Promise((resolveClose, reject) => {
    child.once("error", reject);
    child.once("close", (status, signal) => resolveClose({ status, signal }));
  });
  return tracked;
}

async function withTimeout(promise, timeoutMs, description) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(`timed out waiting for ${description}`)), timeoutMs);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

async function waitFor(check, description, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  while (!check()) {
    if (Date.now() >= deadline) throw new Error(`timed out waiting for ${description}`);
    await new Promise((resolveWait) => setTimeout(resolveWait, 20));
  }
}

async function waitForNewLauncher(eventsDirectory, seen) {
  let ready;
  await waitFor(() => {
    const candidates = readdirSync(eventsDirectory)
      .filter((name) => name.startsWith("ready-") && !seen.has(name));
    ready = candidates[0];
    return ready !== undefined;
  }, "the built launcher to report ready");
  seen.add(ready);
  return ready.slice("ready-".length);
}

function releaseLauncher(eventsDirectory, pid) {
  writeFileSync(join(eventsDirectory, `release-${pid}`), "");
}

function stopProcess(child, signal = "SIGKILL") {
  if (child.exitCode !== null || child.signalCode !== null) return;
  try {
    child.kill(signal);
  } catch {
    // The process may have exited between the state check and kill.
  }
}

function buildRoot(project) {
  const host = hostContract();
  const arch = process.arch === "arm64" ? "arm64" : "x64";
  return join(project, "build", `dev-${host.os}-${arch}`);
}

function sha256(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

test(
  "Electrobun build, run, dev, and watch coordinate through project-lifetime leases",
  { timeout: 180_000, skip: process.platform === "win32" },
  async () => {
    const fixture = mkdtempSync(join(os.tmpdir(), "hutch-electrobun-build-lease-"));
    const project = join(fixture, "project");
    const coreRoot = join(fixture, "core");
    const alternateCoreRoot = join(fixture, "core-alternate");
    const hutch = join(hutchRoot, "zig-out", "bin", executableName("hutch"));
    const engine = join(hutchRoot, "zig-out", "bin", executableName("hutch-engine"));
    const cottontail = resolveCottontail();
    const version = "9.8.7-test.build-lease";
    const trackedChildren = [];
    const launcherPids = new Set();

    try {
      const manifest = createCoreFixture(coreRoot, version);
      cpSync(coreRoot, alternateCoreRoot, { recursive: true });
      appendFileSync(join(alternateCoreRoot, "native-devkit.json"), "\n");
      const coreManifestSha256 = sha256(join(coreRoot, "native-devkit.json"));
      const alternateManifestSha256 = sha256(join(alternateCoreRoot, "native-devkit.json"));
      assert.notEqual(coreManifestSha256, alternateManifestSha256);
      const launcher = join(coreRoot, manifest.layout.runtime.launcher);
      writeFixtureFile(launcher, `#!/bin/sh
set -eu
events="$HUTCH_APP_EVENTS_DIR"
cd /
ready="$events/ready-$$"
: > "$ready"
trap 'exit 0' TERM INT
while [ ! -f "$events/release-$$" ]; do sleep 0.05; done
if [ -n "\${HUTCH_APP_CANARY:-}" ] && [ ! -f "$HUTCH_APP_CANARY" ]; then
  exit 73
fi
`);
      chmodSync(launcher, 0o755);

      writeFixtureFile(join(project, "src", "bun", "index.ts"), "console.log('build lease fixture');\n");
      writeFixtureFile(join(project, "prebuild-probe.mjs"), `
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

function assertProjection() {
  const expected = process.env.HUTCH_EXPECTED_PROJECTION_MANIFEST;
  if (!expected) return;
  const projection = JSON.parse(readFileSync(join(process.cwd(), ".hutch", "devkit", "projection.json"), "utf8"));
  if (projection.sourceManifestSha256 !== expected) {
    throw new Error("another invocation replaced the active devkit projection");
  }
}

if (process.env.HUTCH_BUILD_STARTED_MARKER) {
  writeFileSync(process.env.HUTCH_BUILD_STARTED_MARKER, "");
}
assertProjection();
if (process.env.HUTCH_HANDOFF_LEADER_READY && process.env.HUTCH_HANDOFF_LEADER_RELEASE) {
  writeFileSync(process.env.HUTCH_HANDOFF_LEADER_READY, "");
  while (!existsSync(process.env.HUTCH_HANDOFF_LEADER_RELEASE)) {
    await new Promise((resolveWait) => setTimeout(resolveWait, 20));
  }
}
if (process.env.HUTCH_PROJECTION_LEADER_READY) {
  writeFileSync(process.env.HUTCH_PROJECTION_LEADER_READY, "");
  await new Promise((resolveWait) => setTimeout(resolveWait, 3_000));
  assertProjection();
}
if (process.env.HUTCH_RECURSIVE_HOOK === "1") {
  const nested = spawnSync(
    process.env.HUTCH_TEST_HUTCH,
    ["electrobun", "build", "--env=dev"],
    { cwd: process.cwd(), encoding: "utf8", env: process.env, timeout: 5_000 },
  );
  const diagnostic = nested.stderr || String(nested.error || "");
  if (nested.status === 0 || !diagnostic.includes("cannot recursively build or run")) {
    throw new Error("recursive same-project build did not fail immediately: " + diagnostic);
  }
  writeFileSync(process.env.HUTCH_RECURSIVE_RESULT, diagnostic);
}
`);
      writeFixtureFile(join(project, "electrobun.config.ts"), `
export default {
  electrobun: { version: "${version}" },
  app: { name: "BuildLease", identifier: "dev.electrobun.build-lease", version: "0.0.0" },
  build: {
    mainProcess: "cottontail",
    cottontail: { entrypoint: "src/bun/index.ts" },
    mac: { icons: null, codesign: false, notarize: false, bundleCEF: false, bundleWGPU: false },
    win: { bundleCEF: false, bundleWGPU: false },
    linux: { bundleCEF: false, bundleWGPU: false },
  },
  scripts: { preBuild: "prebuild-probe.mjs" },
};
`);

      const baseEnv = {
        ...process.env,
        COTTONTAIL_BINARY: cottontail,
        DASH_COTTONTAIL: cottontail,
        HUTCH_ELECTROBUN_DEVKIT_ROOT: coreRoot,
        HUTCH_ENGINE_BINARY: engine,
        HUTCH_NO_UPDATE_CHECK: "1",
        HUTCH_TEST_HUTCH: hutch,
      };
      for (const name of [
        "HUTCH_APP_CANARY",
        "HUTCH_APP_EVENTS_DIR",
        "HUTCH_BUILD_STARTED_MARKER",
        "HUTCH_ELECTROBUN_BUILD_LOCK",
        "HUTCH_EXPECTED_PROJECTION_MANIFEST",
        "HUTCH_HANDOFF_LEADER_READY",
        "HUTCH_HANDOFF_LEADER_RELEASE",
        "HUTCH_PROJECTION_LEADER_READY",
        "HUTCH_RECURSIVE_HOOK",
        "HUTCH_RECURSIVE_RESULT",
      ]) delete baseEnv[name];

      const start = (args, env, stdio = ["ignore", "pipe", "pipe"]) => {
        const tracked = trackedRun(hutch, args, { cwd: project, env, stdio });
        trackedChildren.push(tracked);
        return tracked;
      };
      const build = (dashName, extraEnv = {}) => start(
        ["electrobun", "build", "--env=dev"],
        { ...baseEnv, DASH_HOME: join(fixture, dashName), ...extraEnv },
      );

      const symlinkProject = join(fixture, "symlink-project");
      const outsideProjectState = join(fixture, "outside-project-state");
      const outsideSentinel = join(outsideProjectState, "sentinel");
      cpSync(project, symlinkProject, { recursive: true });
      mkdirSync(outsideProjectState);
      writeFileSync(outsideSentinel, "keep");
      symlinkSync(
        outsideProjectState,
        join(symlinkProject, ".hutch"),
        process.platform === "win32" ? "junction" : "dir",
      );
      const symlinkBuild = spawnSync(
        hutch,
        ["electrobun", "build", "--env=dev"],
        {
          cwd: symlinkProject,
          encoding: "utf8",
          env: { ...baseEnv, DASH_HOME: join(fixture, "dash-symlink") },
        },
      );
      assert.notEqual(symlinkBuild.status, 0, symlinkBuild.stderr || symlinkBuild.stdout);
      assert.ok(existsSync(outsideSentinel));
      assert.equal(existsSync(join(outsideProjectState, "locks")), false);
      assert.equal(existsSync(join(outsideProjectState, "dependencies.lock")), false);

      const initial = build("dash-initial");
      const initialResult = await withTimeout(initial.closed, 30_000, "the initial build");
      assert.equal(initialResult.status, 0, initial.stderr || initial.stdout);
      assert.ok(existsSync(join(project, ".hutch", "locks", "electrobun-build.lock")));

      const projectionLeaderReady = join(fixture, "projection-leader-ready");
      const projectionLeader = build("dash-projection-leader", {
        HUTCH_EXPECTED_PROJECTION_MANIFEST: coreManifestSha256,
        HUTCH_PROJECTION_LEADER_READY: projectionLeaderReady,
      });
      await waitFor(() => existsSync(projectionLeaderReady), "projection leader hook");
      const projectionFollower = build("dash-projection-follower", {
        HUTCH_ELECTROBUN_DEVKIT_ROOT: alternateCoreRoot,
        HUTCH_EXPECTED_PROJECTION_MANIFEST: alternateManifestSha256,
      });
      const projectionResults = await Promise.all([
        withTimeout(projectionLeader.closed, 30_000, "projection leader build"),
        withTimeout(projectionFollower.closed, 30_000, "projection follower build"),
      ]);
      assert.equal(projectionResults[0].status, 0, projectionLeader.stderr || projectionLeader.stdout);
      assert.equal(projectionResults[1].status, 0, projectionFollower.stderr || projectionFollower.stdout);

      // Queue a writer while dev still holds the exclusive gate in preBuild.
      // When dev publishes its read lease and releases the gate, the queued
      // writer must observe that lease rather than slipping into the build
      // tree during the build-to-running-app handoff.
      const handoffEvents = join(fixture, "events-handoff");
      const handoffLeaderReady = join(fixture, "handoff-leader-ready");
      const handoffLeaderRelease = join(fixture, "handoff-leader-release");
      const handoffWriterMarker = join(fixture, "handoff-writer-started");
      mkdirSync(handoffEvents);
      const handoffDev = start(
        ["electrobun", "dev", "--env=dev"],
        {
          ...baseEnv,
          DASH_HOME: join(fixture, "dash-handoff-dev"),
          HUTCH_APP_EVENTS_DIR: handoffEvents,
          HUTCH_HANDOFF_LEADER_READY: handoffLeaderReady,
          HUTCH_HANDOFF_LEADER_RELEASE: handoffLeaderRelease,
        },
      );
      await waitFor(() => existsSync(handoffLeaderReady), "handoff leader preBuild gate");
      const handoffWriter = build("dash-handoff-writer", {
        HUTCH_BUILD_STARTED_MARKER: handoffWriterMarker,
      });
      await waitFor(
        () => handoffWriter.stdout.includes("Waiting for the project build lock"),
        "handoff writer to queue on the exclusive gate",
      );
      writeFileSync(handoffLeaderRelease, "");
      const handoffPid = await waitForNewLauncher(handoffEvents, new Set());
      launcherPids.add(handoffPid);
      await new Promise((resolveWait) => setTimeout(resolveWait, 300));
      assert.equal(
        existsSync(handoffWriterMarker),
        false,
        "the queued writer entered preBuild during the build-to-app lease handoff",
      );
      releaseLauncher(handoffEvents, handoffPid);
      const handoffDevResult = await withTimeout(handoffDev.closed, 15_000, "handoff dev exit");
      launcherPids.delete(handoffPid);
      assert.equal(handoffDevResult.status, 0, handoffDev.stderr || handoffDev.stdout);
      const handoffWriterResult = await withTimeout(handoffWriter.closed, 30_000, "handoff queued writer");
      assert.equal(handoffWriterResult.status, 0, handoffWriter.stderr || handoffWriter.stdout);
      assert.ok(existsSync(handoffWriterMarker));

      const recursionResult = join(fixture, "recursive-result");
      const recursive = build("dash-recursive", {
        HUTCH_RECURSIVE_HOOK: "1",
        HUTCH_RECURSIVE_RESULT: recursionResult,
      });
      const recursiveStatus = await withTimeout(recursive.closed, 15_000, "recursive-hook rejection");
      assert.equal(recursiveStatus.status, 0, recursive.stderr || recursive.stdout);
      assert.match(readFileSync(recursionResult, "utf8"), /cannot recursively build or run/);

      const assertReaderBlocksBuild = async (command, label) => {
        const events = join(fixture, `events-${label}`);
        const canary = join(buildRoot(project), `.lifetime-canary-${label}`);
        const buildMarker = join(fixture, `build-started-${label}`);
        mkdirSync(events);
        const seen = new Set();
        const app = start(command, {
          ...baseEnv,
          DASH_HOME: join(fixture, `dash-${label}-app`),
          HUTCH_APP_CANARY: canary,
          HUTCH_APP_EVENTS_DIR: events,
        });
        const pid = await waitForNewLauncher(events, seen);
        launcherPids.add(pid);
        writeFileSync(canary, "");

        const competingBuild = build(`dash-${label}-build`, {
          HUTCH_BUILD_STARTED_MARKER: buildMarker,
        });
        await waitFor(
          () => competingBuild.stdout.includes("Waiting for the project build lock"),
          `${label}: competing build to reach the held project lock`,
        );
        assert.equal(competingBuild.child.exitCode, null, `${label}: competing build exited while the app was alive`);
        assert.equal(existsSync(buildMarker), false, `${label}: competing build entered preBuild before the app exited`);
        assert.ok(existsSync(canary), `${label}: the live app's build tree was deleted`);

        releaseLauncher(events, pid);
        const appResult = await withTimeout(app.closed, 15_000, `${label} app exit`);
        launcherPids.delete(pid);
        assert.equal(appResult.status, 0, app.stderr || app.stdout);
        const buildResult = await withTimeout(competingBuild.closed, 30_000, `${label} competing build`);
        assert.equal(buildResult.status, 0, competingBuild.stderr || competingBuild.stdout);
        assert.ok(existsSync(buildMarker), `${label}: queued build never ran`);
      };

      await assertReaderBlocksBuild(
        ["electrobun", "run", "--env=dev"],
        "run",
      );

      const multiReaderEvents = [
        join(fixture, "events-multi-reader-a"),
        join(fixture, "events-multi-reader-b"),
      ];
      for (const events of multiReaderEvents) mkdirSync(events);
      const multiReaders = multiReaderEvents.map((events, index) => start(
        ["electrobun", "run", "--env=dev"],
        {
          ...baseEnv,
          DASH_HOME: join(fixture, `dash-multi-reader-${index}`),
          HUTCH_APP_EVENTS_DIR: events,
        },
      ));
      const multiReaderPids = [];
      for (let index = 0; index < multiReaders.length; index += 1) {
        const pid = await waitForNewLauncher(multiReaderEvents[index], new Set());
        multiReaderPids.push(pid);
        launcherPids.add(pid);
      }
      const multiReaderBuildMarker = join(fixture, "build-started-multi-reader");
      const multiReaderBuild = build("dash-multi-reader-build", {
        HUTCH_BUILD_STARTED_MARKER: multiReaderBuildMarker,
      });
      await waitFor(
        () => multiReaderBuild.stdout.includes("Waiting for the project build lock"),
        "a writer to wait for both running apps",
      );
      releaseLauncher(multiReaderEvents[0], multiReaderPids[0]);
      const firstReaderResult = await withTimeout(multiReaders[0].closed, 10_000, "first shared reader exit");
      launcherPids.delete(multiReaderPids[0]);
      assert.equal(firstReaderResult.status, 0, multiReaders[0].stderr || multiReaders[0].stdout);
      await new Promise((resolveWait) => setTimeout(resolveWait, 300));
      assert.equal(
        existsSync(multiReaderBuildMarker),
        false,
        "the writer advanced while a second app still held a read lease",
      );
      releaseLauncher(multiReaderEvents[1], multiReaderPids[1]);
      const secondReaderResult = await withTimeout(multiReaders[1].closed, 10_000, "second shared reader exit");
      launcherPids.delete(multiReaderPids[1]);
      assert.equal(secondReaderResult.status, 0, multiReaders[1].stderr || multiReaders[1].stdout);
      const multiReaderBuildResult = await withTimeout(multiReaderBuild.closed, 30_000, "multi-reader queued build");
      assert.equal(multiReaderBuildResult.status, 0, multiReaderBuild.stderr || multiReaderBuild.stdout);
      assert.ok(existsSync(multiReaderBuildMarker));

      await assertReaderBlocksBuild(
        ["electrobun", "dev", "--env=dev"],
        "dev",
      );

      const watchEvents = join(fixture, "events-watch");
      mkdirSync(watchEvents);
      const watchSeen = new Set();
      const watch = start(
        ["electrobun", "dev", "--watch", "--env=dev"],
        {
          ...baseEnv,
          DASH_HOME: join(fixture, "dash-watch"),
          HUTCH_APP_EVENTS_DIR: watchEvents,
        },
      );
      const firstWatchPid = await waitForNewLauncher(watchEvents, watchSeen);
      launcherPids.add(firstWatchPid);
      await waitFor(() => watch.stdout.includes("Watching for changes"), "watch mode startup");
      appendFileSync(join(project, "src", "bun", "index.ts"), "// watch rebuild\n");
      let secondWatchPid;
      try {
        secondWatchPid = await withTimeout(
          waitForNewLauncher(watchEvents, watchSeen),
          30_000,
          "watch mode rebuild",
        );
      } catch (error) {
        throw new Error(`${error.message}\nwatch stdout:\n${watch.stdout}\nwatch stderr:\n${watch.stderr}`);
      }
      launcherPids.delete(firstWatchPid);
      launcherPids.add(secondWatchPid);
      assert.notEqual(firstWatchPid, secondWatchPid);
      assert.match(watch.stdout, /Change detected, rebuilding/);

      // A supervisor crash must release the OS-backed read lease. The test
      // deliberately leaves the outer launcher alive until after the queued
      // build proves it can acquire the project lock.
      stopProcess(watch.child, "SIGKILL");
      const watchExit = await withTimeout(watch.exited, 10_000, "watch supervisor crash");
      assert.equal(watchExit.signal, "SIGKILL");
      const afterCrashMarker = join(fixture, "build-started-after-crash");
      const afterCrash = build("dash-after-crash", {
        HUTCH_BUILD_STARTED_MARKER: afterCrashMarker,
      });
      const afterCrashResult = await withTimeout(afterCrash.closed, 30_000, "build after supervisor crash");
      assert.ok(existsSync(afterCrashMarker), "the crashed supervisor left its read lease locked");
      releaseLauncher(watchEvents, secondWatchPid);
      launcherPids.delete(secondWatchPid);
      await withTimeout(watch.closed, 10_000, "orphan launcher cleanup");
      if (afterCrashResult.status !== 0) {
        // macOS can refuse to replace a file in the still-running launcher's
        // bundle even though the advisory lease itself was released. Once the
        // orphan exits, the next build must recover normally.
        const recovered = build("dash-after-crash-recovery");
        const recoveredResult = await withTimeout(recovered.closed, 30_000, "build after orphan cleanup");
        assert.equal(recoveredResult.status, 0, recovered.stderr || recovered.stdout);
      }
      const readersDirectory = join(project, ".hutch", "locks", "electrobun-readers");
      assert.deepEqual(
        readdirSync(readersDirectory).filter((name) => name.endsWith(".lease")),
        [],
        "normal exits and crash recovery must leave no reader leases",
      );
    } finally {
      for (const tracked of trackedChildren) stopProcess(tracked.child);
      for (const pid of launcherPids) {
        try {
          process.kill(Number(pid), "SIGKILL");
        } catch {
          // Already gone.
        }
      }
      rmSync(fixture, { recursive: true, force: true });
    }
  },
);
