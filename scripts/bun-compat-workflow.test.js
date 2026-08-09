import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { EventEmitter } from "node:events";
import { readFileSync } from "node:fs";
import { PassThrough } from "node:stream";
import test from "node:test";

import { waitForChildCompletion } from "./bun-compat-child-lifecycle.js";

const root = new URL("..", import.meta.url);
const workflowPath = new URL("../.github/workflows/bun-compat.yml", import.meta.url);
const cottontailManifestPath = new URL(
  "../compat/upstream/cottontail.json",
  import.meta.url,
);
const cottontailSetupPath = new URL("./setup-upstream-cottontail.js", import.meta.url);
const suiteManifestPath = new URL(
  "../compat/upstream/bun/v1.3.10/manifest.json",
  import.meta.url,
);
const suiteStatusPath = new URL(
  "../compat/upstream/bun/v1.3.10/status.json",
  import.meta.url,
);
const ownershipPath = new URL(
  "../compat/bun-v1.3.10-ownership.json",
  import.meta.url,
);
const compatRunnerPath = new URL("./run-bun-package-manager-tests.js", import.meta.url);
const workflow = readFileSync(workflowPath, "utf8").replace(/\r\n/g, "\n");
const cottontailManifest = JSON.parse(readFileSync(cottontailManifestPath, "utf8"));
const cottontailSetup = readFileSync(cottontailSetupPath, "utf8").replace(/\r\n/g, "\n");
const compatRunner = readFileSync(compatRunnerPath, "utf8").replace(/\r\n/g, "\n");
const suiteManifest = JSON.parse(readFileSync(suiteManifestPath, "utf8"));
const suiteStatus = JSON.parse(readFileSync(suiteStatusPath, "utf8"));
const ownership = JSON.parse(readFileSync(ownershipPath, "utf8"));

function workflowTriggers(source) {
  const end = source.indexOf("\npermissions:");
  assert.notEqual(end, -1, "workflow must declare permissions after its triggers");
  return source.slice(0, end);
}

test("runs only for compat branches and manual dispatch", () => {
  const triggers = workflowTriggers(workflow);
  assert.match(
    triggers,
    /^on:\n  push:\n    branches:\n      - "compat\/\*\*"\n  workflow_dispatch:\s*$/m,
  );
  assert.doesNotMatch(triggers, /\btags:|\bpull_request:|\bschedule:/);
});

test("builds Hutch and runs the complete owned JavaScript compatibility suite without publishing", () => {
  for (const platform of ["macos-arm64", "linux-x64", "linux-arm64", "windows-x64"]) {
    assert.match(workflow, new RegExp(`platform: ${platform}`));
  }
  assert.match(workflow, /runner: macos-26/);
  assert.match(workflow, /runner: ubuntu-24\.04/);
  assert.match(workflow, /runner: ubuntu-24\.04-arm/);
  assert.match(workflow, /runner: windows-2025/);
  assert.match(workflow, /fail-fast: false/);
  assert.match(
    workflow,
    /run: node --test scripts\/bun-compat-workflow\.test\.js scripts\/bun-harness-dependencies\.test\.js/,
  );
  assert.match(
    workflow,
    /run: \.\/vendors\/zig\/zig build -Doptimize=ReleaseSmall -Dcpu=baseline/,
  );
  assert.match(
    workflow,
    /zig\.exe build -Doptimize=ReleaseSmall -Dtarget=x86_64-windows-msvc -Dcpu=baseline/,
  );
  assert.match(workflow, /HUTCH_COMPAT_COTTONTAIL: \$\{\{ steps\.cottontail\.outputs\.binary \}\}/);
  assert.match(workflow, /run: node scripts\/run-bun-package-manager-tests\.js --all/);
  assert.match(workflow, /run: node scripts\/run-bun-package-manager-tests\.js --check/);
  assert.doesNotMatch(
    workflow,
    /continue-on-error:|upload-artifact|upload-release-r2|publish|secrets\.|pull_request:/i,
  );

  const checkOutput = execFileSync(
    process.execPath,
    ["scripts/run-bun-package-manager-tests.js", "--check"],
    { cwd: root, encoding: "utf8" },
  );
  assert.match(
    checkOutput,
    new RegExp(
      `Hutch Bun package-manager compatibility: ${suiteManifest.ownedRunnableFiles}/` +
        `${suiteManifest.canonicalRunnableFiles} canonical files owned by Hutch`,
    ),
  );
  assert.match(checkOutput, /ownership and copied-inventory checks passed/);
});

test("builds an exact Cottontail source revision", () => {
  assert.equal(cottontailManifest.schema, 1);
  assert.equal(cottontailManifest.bunCompatibilityVersion, suiteManifest.version);
  assert.match(
    cottontailManifest.repository,
    /^https:\/\/github\.com\/[^/]+\/cottontail\.git$/,
  );
  assert.match(cottontailManifest.commit, /^[0-9a-f]{40}$/);

  assert.match(
    workflow,
    /cottontail="\$\(node scripts\/setup-upstream-cottontail\.js\)"/,
  );
  assert.match(
    workflow,
    /hashFiles\('compat\/upstream\/cottontail\.json', 'scripts\/setup-upstream-cottontail\.js'\)/,
  );
  assert.match(cottontailSetup, /git", \["fetch", "--quiet", "--depth", "1", "origin", manifest\.commit\]/);
  assert.match(cottontailSetup, /checkedOutCommit !== manifest\.commit/);
  assert.match(cottontailSetup, /"scripts\/setup\.js"/);
  assert.match(cottontailSetup, /"scripts\/setup-zig-html-rewriter\.js"/);
  assert.match(cottontailSetup, /"scripts\/setup-jsc\.js"/);
  assert.match(cottontailSetup, /"-Doptimize=ReleaseSmall"/);
  assert.match(cottontailSetup, /process\.platform === "win32" \? \["-Dtarget=x86_64-windows-msvc"\] : \[\]/);
  assert.match(cottontailSetup, /"-Dcpu=baseline"/);
  assert.doesNotMatch(cottontailSetup, /command -v|which\(|["']PATH["']/);
});

test("owns the complete canonical Next Pages fixture without generated state", () => {
  const nextPagesTests = [
    "test/integration/next-pages/test/dev-server-ssr-100.test.ts",
    "test/integration/next-pages/test/dev-server.test.ts",
    "test/integration/next-pages/test/next-build.test.ts",
  ];

  assert.equal(suiteManifest.canonicalRunnableFiles, 1_445);
  assert.equal(suiteManifest.ownedRunnableFiles, 103);
  assert.equal(suiteManifest.testFiles.length, 103);
  assert.deepEqual(ownership.ownerCounts, {
    "cottontail-runtime": 1_342,
    "hutch-package-manager": 103,
  });
  assert.equal(Object.values(ownership.ownerCounts).reduce((sum, count) => sum + count, 0), 1_445);

  const ownerByPath = new Map(ownership.tests.map(entry => [entry.path, entry.owner]));
  for (const path of nextPagesTests) {
    const entry = suiteStatus.tests[path];
    assert.equal(ownerByPath.get(path), "hutch-package-manager");
    assert.equal(entry.owner, "hutch-package-manager");
    assert.equal(entry.status, "enabled");
    assert.equal(entry.serial, true);
    const timeoutArgs = entry.args.filter(arg => String(arg).startsWith("--timeout="));
    assert.equal(timeoutArgs.length, 1);
    const innerTimeoutMs = Number(timeoutArgs[0].slice("--timeout=".length));
    assert.ok(entry.timeoutMs - innerTimeoutMs >= 60_000);
  }

  const [fixture] = suiteManifest.fixtureTrees;
  assert.equal(fixture.path, "test/integration/next-pages");
  assert.equal(fixture.copiedFiles, 28);
  assert.equal(fixture.files.length, 28);
  assert.deepEqual(fixture.generatedAtRuntime, [
    { path: "src/Counter.tsx", source: "src/Counter1.txt" },
  ]);
  assert.equal(fixture.files.some(entry => entry.path === "src/Counter.tsx"), false);
});

test("reports live per-file progress and preserves failure diagnostics", () => {
  assert.match(
    compatRunner,
    /`START \[\$\{started\}\/\$\{entries\.length\}; running \$\{started - completed\}\] \$\{entry\.path\}`/,
  );
  assert.match(
    compatRunner,
    /`DONE \[\$\{completed\}\/\$\{entries\.length\}; running \$\{started - completed\}\] \$\{result\.message\}`/,
  );
  assert.match(compatRunner, /`  progress: passed \$\{outcomeCounts\.passed\}; `/);
  assert.equal(
    [...compatRunner.matchAll(/diagnostics: capturedDiagnostics\(result\),/g)].length,
    4,
    "unsafe teardown, start errors, timeouts, and unexpected results retain diagnostics",
  );
  assert.match(compatRunner, /if \(result\.diagnostics\) console\.log\(result\.diagnostics\);/);
  assert.match(compatRunner, /const outcomeCounts = await runEntries\(/);
  assert.doesNotMatch(compatRunner, /const results = (?:new Array|await runEntries)/);
});

test("constructs one effective inner timeout for each test invocation", () => {
  assert.match(compatRunner, /function testInvocationArgs\(entry, preloadPath\)/);
  assert.match(compatRunner, /if \(arg === "--timeout"\)/);
  assert.match(compatRunner, /else if \(arg\.startsWith\("--timeout="\)\)/);
  assert.match(compatRunner, /multiple test timeouts configured for \$\{entry\.path\}/);
  assert.match(compatRunner, /`--timeout=\$\{timeoutMs \?\? perTestTimeoutMs\}`/);

  const runEntrySource = compatRunner.slice(
    compatRunner.indexOf("function runEntry("),
    compatRunner.indexOf("function capturedDiagnostics("),
  );
  assert.match(runEntrySource, /const args = testInvocationArgs\(entry, preloadPath\);/);
  assert.doesNotMatch(runEntrySource, /entry\.args|`--timeout=/);
});

test("bounds process-tree cleanup and retries runner-owned removal", () => {
  assert.match(compatRunner, /maxRetries: 10/);
  assert.match(compatRunner, /retryDelay: 100/);
  assert.match(compatRunner, /timeout: windowsTaskkillTimeoutMs/);
  assert.match(compatRunner, /hardSettleTimeoutMs: childHardSettleTimeoutMs/);
  assert.match(compatRunner, /unprovenDeathTempRoots\.add\(tempRoot\)/);
  assert.match(compatRunner, /options\.keepTemp \|\| unprovenDeathTempRoots\.has\(tempRoot\)/);
  assert.match(compatRunner, /retained temp root because process death was not observed/);
  assert.match(compatRunner, /if \(result\.teardownIncomplete\)/);
  assert.match(compatRunner, /outcome: "unexpected-failure"/);
  assert.match(compatRunner, /if \(!options\.keepTemp\) removeRunnerOwnedPath\(runTemp\);/);
  assert.match(compatRunner, /removeRunnerOwnedPath\(tempRoot\);/);
});

function fakeChild(pid = 12_345) {
  const child = new EventEmitter();
  child.pid = pid;
  child.stdin = new PassThrough();
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  child.unrefCalls = 0;
  child.unref = () => {
    child.unrefCalls += 1;
  };
  return child;
}

test("hard-settles a timed-out child whose exit and close events never arrive", async () => {
  const child = fakeChild();
  let terminateCalls = 0;
  const started = Date.now();
  const result = await waitForChildCompletion(child, {
    timeoutMs: 5,
    hardSettleTimeoutMs: 10,
    settleDelayMs: 1,
    terminate() {
      terminateCalls += 1;
    },
  });

  assert.equal(result.timedOut, true);
  assert.equal(result.processDeathProven, false);
  assert.equal(result.teardownIncomplete, true);
  assert.equal(terminateCalls, 1);
  assert.equal(child.unrefCalls, 1);
  assert.equal(child.stdout.destroyed, true);
  assert.equal(child.stderr.destroyed, true);
  assert.ok(Date.now() - started < 1_000, "hard settlement must remain bounded");
});

test("an observed child exit remains safe when close follows", async () => {
  const child = fakeChild();
  let terminateCalls = 0;
  const completion = waitForChildCompletion(child, {
    timeoutMs: 1_000,
    hardSettleTimeoutMs: 100,
    settleDelayMs: 50,
    terminate() {
      terminateCalls += 1;
    },
  });
  child.emit("exit", 0, null);
  child.emit("close", 0, null);
  const result = await completion;

  assert.equal(result.code, 0);
  assert.equal(result.timedOut, false);
  assert.equal(result.processDeathProven, true);
  assert.equal(result.teardownIncomplete, false);
  assert.equal(terminateCalls, 1);
  assert.equal(child.unrefCalls, 0);
});

test("rejects invalid outer timeout values before starting lifecycle timers", () => {
  assert.throws(
    () => waitForChildCompletion(fakeChild(), {
      timeoutMs: Number.POSITIVE_INFINITY,
      hardSettleTimeoutMs: 10,
      settleDelayMs: 0,
      terminate() {},
    }),
    /timeoutMs must be positive/,
  );
});
