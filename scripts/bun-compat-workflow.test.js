import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import {
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";
import test from "node:test";

import {
  startWindowsTaskkill,
  waitForChildCompletion,
} from "./bun-compat-child-lifecycle.js";
import {
  createTestInvocation,
  readGitHeadCommit,
} from "./bun-compat-runner-contract.js";

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
  assert.equal(
    workflow.match(/hashFiles\('scripts\/setup\.sh', 'scripts\/patch-zig-hostname-connect\.js', 'patches\/zig-0\.16\.0-hostname-connect\.patch'\)/g)?.length,
    2,
  );
  assert.match(
    workflow,
    /platform: macos-arm64\s+runner: macos-26\s+os: macos\s+target: ""/,
  );
  assert.match(
    workflow,
    /platform: linux-x64\s+runner: ubuntu-24\.04\s+os: linux\s+target: x86_64-linux-gnu\.2\.35/,
  );
  assert.match(
    workflow,
    /platform: linux-arm64\s+runner: ubuntu-24\.04-arm\s+os: linux\s+target: aarch64-linux-gnu\.2\.35/,
  );
  assert.match(
    workflow,
    /run: node --test scripts\/bun-compat-workflow\.test\.js scripts\/bun-harness-dependencies\.test\.js scripts\/bun-compat-reporter\.test\.js/,
  );
  assert.match(
    workflow,
    /if \[\[ -n "\$target" \]\]; then\s+target_arg=\("-Dtarget=\$target"\)/,
  );
  assert.match(
    workflow,
    /\.\/vendors\/zig\/zig build -Doptimize=ReleaseSmall -Dcpu=baseline "\$\{target_arg\[@\]\}"/,
  );
  assert.match(
    workflow,
    /if \[\[ '\$\{\{ matrix\.os \}\}' == 'linux' \]\]; then\s+node scripts\/verify-linux-glibc\.js zig-out\/bin\/hutch-engine 2\.35/,
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

test("rejects an oversized heartbeat before Node can clamp it to one millisecond", () => {
  assert.throws(
    () => execFileSync(
      process.execPath,
      ["scripts/run-bun-package-manager-tests.js", "--check"],
      {
        cwd: root,
        encoding: "utf8",
        env: { ...process.env, HUTCH_COMPAT_HEARTBEAT_MS: "2147483648" },
      },
    ),
    error => {
      assert.match(
        error.stderr ?? "",
        /HUTCH_COMPAT_HEARTBEAT_MS must be a positive safe integer no greater than 2147483647/,
      );
      return true;
    },
  );

  const configuredTimeoutCheck = execFileSync(
    process.execPath,
    ["scripts/run-bun-package-manager-tests.js", "--check"],
    {
      cwd: root,
      encoding: "utf8",
      env: { ...process.env, HUTCH_COMPAT_TEST_TIMEOUT_MS: "15001" },
    },
  );
  assert.match(configuredTimeoutCheck, /ownership and copied-inventory checks passed/);
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

test("reports live per-file progress durably and preserves failure diagnostics", () => {
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
    5,
    "cancellation, unsafe teardown, start errors, timeouts, and unexpected results retain diagnostics",
  );
  assert.match(compatRunner, /if \(result\.diagnostics\) console\.log\(result\.diagnostics\);/);
  assert.match(compatRunner, /reporter\.startEntry\(entry,/);
  assert.match(compatRunner, /reporter\.appendOutput\(reportToken, "stdout", chunk\)/);
  assert.match(compatRunner, /reporter\.finishEntry\(/);
  assert.match(compatRunner, /HUTCH_COMPAT_REPORTS_DIR/);
  assert.match(compatRunner, /HUTCH_COMPAT_REPORT_DIR/);
  assert.match(compatRunner, /activeReporter\.setPhase\("preflight"\)/);
  assert.match(compatRunner, /await preflight\(options, executionAbortController\.signal\)/);
  assert.match(compatRunner, /const harnessDependencies = await prepareHarnessDependencies\(/);
  assert.match(compatRunner, /signal: options\.signal/);
  assert.match(compatRunner, /onError\(error\) \{ executionAbortController\.abort\(error\); \}/);
  assert.doesNotMatch(compatRunner, /spawnSync/);
  assert.match(compatRunner, /const outcomeCounts = await runEntries\(/);
  assert.doesNotMatch(compatRunner, /const results = (?:new Array|await runEntries)/);
});

test("constructs one effective inner timeout with an independent outer margin", () => {
  const invocationOptions = {
    defaultInnerTimeoutMs: 15_000,
    defaultOuterTimeoutMs: 30_000,
    defaultOuterMarginMs: 15_000,
    overrideOuterMarginMs: 60_000,
  };
  for (const [path, status] of Object.entries(suiteStatus.tests)) {
    const invocation = createTestInvocation(
      { path, ...status },
      "/absolute/preload.ts",
      invocationOptions,
    );
    assert.equal(invocation.args.filter(arg => arg.startsWith("--timeout=")).length, 1);
    assert.ok(
      invocation.outerTimeoutMs - invocation.innerTimeoutMs >=
        (invocation.hasInnerOverride ? 60_000 : 15_000),
      path,
    );
  }

  const install = createTestInvocation(
    {
      path: "test/cli/install/bun-install.test.ts",
      ...suiteStatus.tests["test/cli/install/bun-install.test.ts"],
    },
    "/absolute/preload.ts",
    invocationOptions,
  );
  assert.equal(install.innerTimeoutMs, 300_000);
  assert.equal(install.outerTimeoutMs, 360_000);
  assert.deepEqual(
    install.args.filter(arg => arg.startsWith("--timeout=")),
    ["--timeout=300000"],
  );
  assert.throws(
    () => createTestInvocation(
      { path: "test/example.test.ts", args: ["--timeout=1000"], timeoutMs: 60_999 },
      "/absolute/preload.ts",
      invocationOptions,
    ),
    /must exceed its overridden inner timeout by at least 60000ms/,
  );
  assert.throws(
    () => createTestInvocation(
      {
        path: "test/example.test.ts",
        args: ["--timeout", "1000", "--timeout=2000"],
        timeoutMs: 100_000,
      },
      "/absolute/preload.ts",
      invocationOptions,
    ),
    /multiple test timeouts/,
  );
  assert.throws(
    () => createTestInvocation(
      { path: "test/example.test.ts", timeoutMs: 2_147_483_648 },
      "/absolute/preload.ts",
      invocationOptions,
    ),
    /outer timeout.*positive safe integer no greater than 2147483647/,
  );
  const raisedDefault = createTestInvocation(
    { path: "test/example.test.ts", timeoutMs: 30_000 },
    "/absolute/preload.ts",
    { ...invocationOptions, defaultInnerTimeoutMs: 15_001 },
  );
  assert.equal(raisedDefault.innerTimeoutMs, 15_001);
  assert.equal(raisedDefault.outerTimeoutMs, 30_001);

  assert.match(compatRunner, /const invocation = entryInvocation\(entry, preloadPath\);/);
  assert.match(compatRunner, /timeoutMs: invocation\.outerTimeoutMs/);
  assert.match(compatRunner, /spawn\(options\.runtime, invocation\.args,/);
});

test("reads a linked-worktree HEAD through its common Git directory", t => {
  const temporary = mkdtempSync(join(os.tmpdir(), "hutch-linked-worktree-head-"));
  t.after(() => rmSync(temporary, { recursive: true, force: true }));
  const repositoryRoot = join(temporary, "checkout");
  const commonGit = join(temporary, "common.git");
  const worktreeGit = join(commonGit, "worktrees", "checkout");
  mkdirSync(repositoryRoot, { recursive: true });
  mkdirSync(worktreeGit, { recursive: true });
  mkdirSync(join(commonGit, "refs", "heads"), { recursive: true });
  writeFileSync(join(repositoryRoot, ".git"), `gitdir: ${worktreeGit}\n`);
  writeFileSync(join(worktreeGit, "commondir"), "../..\n");
  writeFileSync(join(worktreeGit, "HEAD"), "ref: refs/heads/compat\n");
  writeFileSync(join(commonGit, "refs", "heads", "compat"), `${"a".repeat(40)}\n`);

  assert.equal(readGitHeadCommit(repositoryRoot), "a".repeat(40));
});

test("bounds process-tree cleanup and retries runner-owned removal", () => {
  assert.match(compatRunner, /maxRetries: 10/);
  assert.match(compatRunner, /retryDelay: 100/);
  assert.match(compatRunner, /startWindowsTaskkill\(child,/);
  assert.match(compatRunner, /spawnProcess: spawn/);
  assert.doesNotMatch(compatRunner, /spawnSync\("taskkill"/);
  assert.match(compatRunner, /hardSettleTimeoutMs: childHardSettleTimeoutMs/);
  assert.match(compatRunner, /requireTerminationProof: process\.platform === "win32"/);
  assert.match(compatRunner, /unprovenDeathTempRoots\.add\(tempRoot\)/);
  assert.match(compatRunner, /options\.keepTemp \|\| unprovenDeathTempRoots\.has\(tempRoot\)/);
  assert.match(compatRunner, /retained temp root because process death was not observed/);
  assert.match(compatRunner, /if \(result\.teardownIncomplete\)/);
  assert.match(compatRunner, /outcome: "unexpected-failure"/);
  assert.match(compatRunner, /if \(!options\.keepTemp\) removeRunnerOwnedPath\(runTemp\);/);
  assert.match(compatRunner, /removeRunnerOwnedPath\(tempRoot\);/);
  assert.match(compatRunner, /const executionAbortController = new AbortController\(\)/);
  assert.doesNotMatch(compatRunner, /async function runEntries[\s\S]*?const abortController = new AbortController/);
  assert.match(compatRunner, /unsafe process teardown for/);
  assert.match(compatRunner, /await Promise\.all\(/);
});

test("a failed asynchronous Windows taskkill cannot extend the outer deadline", async () => {
  const child = fakeChild();
  const taskkill = new EventEmitter();
  taskkill.unrefCalls = 0;
  taskkill.unref = () => { taskkill.unrefCalls += 1; };
  taskkill.kill = () => true;
  let taskkillInvocation = null;
  const started = Date.now();
  const completion = waitForChildCompletion(child, {
    timeoutMs: 5,
    hardSettleTimeoutMs: 10,
    requireTerminationProof: true,
    settleDelayMs: 1,
    terminate(target) {
      return startWindowsTaskkill(target, {
        timeoutMs: 1_000,
        spawnProcess(command, args, options) {
          taskkillInvocation = { command, args, options };
          queueMicrotask(() => taskkill.emit("error", new Error("taskkill failed")));
          return taskkill;
        },
      });
    },
  });
  const result = await completion;

  assert.deepEqual(taskkillInvocation, {
    command: "taskkill",
    args: ["/pid", "12345", "/t", "/f"],
    options: { stdio: "ignore", windowsHide: true },
  });
  assert.equal(taskkill.unrefCalls, 0);
  assert.equal(result.timedOut, true);
  assert.equal(result.teardownIncomplete, true);
  assert.match(result.teardownError?.message ?? "", /taskkill failed to start: taskkill failed/);
  assert.ok(Date.now() - started < 1_000, "taskkill failure must not delay hard settlement");
});

test("a hung taskkill helper is killed and unrefed by its own watchdog", async () => {
  const target = fakeChild();
  const taskkill = new EventEmitter();
  let killCalls = 0;
  let unrefCalls = 0;
  taskkill.kill = () => { killCalls += 1; return true; };
  taskkill.unref = () => { unrefCalls += 1; };
  const started = Date.now();
  await assert.rejects(
    startWindowsTaskkill(target, {
      timeoutMs: 10,
      spawnProcess() { return taskkill; },
    }),
    /taskkill did not settle within 10ms/,
  );

  assert.equal(killCalls, 1);
  assert.equal(unrefCalls, 1);
  assert.ok(Date.now() - started < 1_000);
});

test("Windows close waits for bounded taskkill proof before allowing cleanup", async () => {
  const child = fakeChild();
  const taskkill = new EventEmitter();
  taskkill.unref = () => {};
  taskkill.kill = () => true;
  const completion = waitForChildCompletion(child, {
    timeoutMs: 5,
    hardSettleTimeoutMs: 100,
    naturalCloseProvesTreeDeath: false,
    requireTerminationProof: true,
    settleDelayMs: 50,
    terminateOnExit: false,
    terminate(target) {
      return startWindowsTaskkill(target, {
        timeoutMs: 1_000,
        spawnProcess() { return taskkill; },
      });
    },
  });
  let completed = false;
  completion.then(() => { completed = true; });
  await new Promise(resolve => setTimeout(resolve, 10));
  child.emit("exit", 0, null);
  child.emit("close", 0, null);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(completed, false, "direct close alone must not prove the Windows tree died");
  taskkill.emit("close", 0);
  const result = await completion;
  assert.equal(result.processDeathProven, true);
  assert.equal(result.teardownIncomplete, false);
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

test("a natural Windows close retains temp state without falsely failing the file", async () => {
  const child = fakeChild();
  let terminateCalls = 0;
  const completion = waitForChildCompletion(child, {
    timeoutMs: 1_000,
    hardSettleTimeoutMs: 100,
    naturalCloseProvesTreeDeath: false,
    requireTerminationProof: true,
    settleDelayMs: 50,
    terminate() { terminateCalls += 1; },
    terminateOnExit: false,
  });
  child.emit("exit", 0, null);
  child.emit("close", 0, null);
  const result = await completion;

  assert.equal(result.code, 0);
  assert.equal(result.processDeathProven, false);
  assert.equal(result.teardownIncomplete, false);
  assert.equal(terminateCalls, 0);
  assert.equal(child.unrefCalls, 1);
});

test("cooperative abort starts bounded teardown immediately", async () => {
  const child = fakeChild();
  const controller = new AbortController();
  let terminateCalls = 0;
  const completion = waitForChildCompletion(child, {
    timeoutMs: 10_000,
    hardSettleTimeoutMs: 10,
    signal: controller.signal,
    settleDelayMs: 1,
    terminate() { terminateCalls += 1; },
  });
  controller.abort(new Error("peer failed"));
  const result = await completion;

  assert.equal(result.aborted, true);
  assert.equal(result.timedOut, false);
  assert.equal(result.teardownIncomplete, true);
  assert.equal(terminateCalls, 1);
});

test(
  "normal POSIX exit kills an independent-stdio descendant before cleanup",
  { skip: process.platform === "win32" },
  async t => {
    const source = `
      const { spawn } = require("node:child_process");
      const child = spawn(process.execPath, ["-e", "setTimeout(() => {}, 10000)"], {
        stdio: "ignore",
      });
      console.log(child.pid);
      child.unref();
    `;
    const child = spawn(process.execPath, ["-e", source], {
      detached: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    child.stdout.on("data", chunk => { stdout += chunk; });
    let terminateCalls = 0;
    const result = await waitForChildCompletion(child, {
      timeoutMs: 1_000,
      hardSettleTimeoutMs: 100,
      settleDelayMs: 50,
      terminate(target) {
        terminateCalls += 1;
        try { process.kill(-target.pid, "SIGKILL"); } catch {}
      },
    });
    const grandchildPid = Number(stdout.trim());
    t.after(() => {
      if (Number.isInteger(grandchildPid)) {
        try { process.kill(grandchildPid, "SIGKILL"); } catch {}
      }
    });

    assert.equal(result.processDeathProven, true);
    assert.ok(terminateCalls >= 1);
    assert.ok(Number.isInteger(grandchildPid));
    let alive = true;
    for (let attempt = 0; attempt < 50 && alive; attempt += 1) {
      try {
        process.kill(grandchildPid, 0);
        await new Promise(resolve => setTimeout(resolve, 10));
      } catch {
        alive = false;
      }
    }
    assert.equal(alive, false, `grandchild ${grandchildPid} survived process-group cleanup`);
  },
);

test("exit without close is bounded but cannot prove inherited handles closed", async () => {
  const child = fakeChild();
  const completion = waitForChildCompletion(child, {
    timeoutMs: 1_000,
    hardSettleTimeoutMs: 100,
    settleDelayMs: 5,
    terminate() {},
  });
  child.emit("exit", 0, null);
  const result = await completion;

  assert.equal(result.code, 0);
  assert.equal(result.timedOut, false);
  assert.equal(result.processDeathProven, false);
  assert.equal(result.teardownIncomplete, true);
  assert.equal(child.unrefCalls, 1);
  assert.equal(child.stdout.destroyed, true);
  assert.equal(child.stderr.destroyed, true);
});

test("a late exit cannot extend the original hard-settlement deadline", async () => {
  const child = fakeChild();
  const started = Date.now();
  const completion = waitForChildCompletion(child, {
    timeoutMs: 5,
    hardSettleTimeoutMs: 30,
    settleDelayMs: 2_000,
    terminate() {},
  });
  setTimeout(() => child.emit("exit", null, "SIGKILL"), 20);
  const result = await completion;

  assert.equal(result.timedOut, true);
  assert.equal(result.processDeathProven, false);
  assert.ok(
    Date.now() - started < 1_000,
    "an exit transition must not replace the original hard deadline",
  );
});

test("a failed normal-exit cleanup cannot be reported as proven", async () => {
  const child = fakeChild();
  const completion = waitForChildCompletion(child, {
    timeoutMs: 1_000,
    hardSettleTimeoutMs: 100,
    settleDelayMs: 50,
    terminate() { throw new Error("injected process-group cleanup failure"); },
  });
  child.emit("exit", 0, null);
  child.emit("close", 0, null);
  const result = await completion;

  assert.equal(result.code, 0);
  assert.equal(result.processDeathProven, false);
  assert.equal(result.teardownIncomplete, true);
  assert.match(result.teardownError?.message ?? "", /process-group cleanup failure/);
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
  assert.throws(
    () => waitForChildCompletion(fakeChild(), {
      timeoutMs: 2_147_483_648,
      hardSettleTimeoutMs: 10,
      settleDelayMs: 0,
      terminate() {},
    }),
    /timeoutMs must be positive safe integer no greater than 2147483647/,
  );
});
