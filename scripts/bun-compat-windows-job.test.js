import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import {
  mkdtempSync,
  readFileSync,
  rmSync,
} from "node:fs";
import os from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import test from "node:test";

import {
  startWindowsJobChild,
  startWindowsJobTermination,
  waitForChildCompletion,
} from "./bun-compat-child-lifecycle.js";

const hutchRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const jobLauncher = join(hutchRoot, "zig-out", "bin", "hutch-bun-compat-job.exe");
const lifecycleModuleUrl = pathToFileURL(
  join(hutchRoot, "scripts", "bun-compat-child-lifecycle.js"),
).href;
const windowsOnly = { skip: process.platform !== "win32" };

function startTarget(args, spawnOptions = {}) {
  return startWindowsJobChild(process.execPath, args, {
    jobLauncher,
    spawnOptions,
    spawnProcess: spawn,
  });
}

function capture(child) {
  let stdout = "";
  let stderr = "";
  child.stdout?.setEncoding("utf8");
  child.stderr?.setEncoding("utf8");
  child.stdout?.on("data", chunk => { stdout += chunk; });
  child.stderr?.on("data", chunk => { stderr += chunk; });
  return {
    read() { return { stdout, stderr }; },
  };
}

function completion(child, options = {}) {
  return waitForChildCompletion(child, {
    timeoutMs: options.timeoutMs ?? 5_000,
    hardSettleTimeoutMs: options.hardSettleTimeoutMs ?? 5_000,
    naturalCloseProvesTreeDeath: true,
    requireTerminationProof: options.requireTerminationProof ?? false,
    signal: options.signal,
    settleDelayMs: 250,
    terminate(target) {
      return startWindowsJobTermination(target, {
        spawnProcess: spawn,
        timeoutMs: 2_000,
        watchdogMs: 2_500,
      });
    },
    terminateOnExit: false,
  });
}

function processIsAlive(pid) {
  if (!Number.isInteger(pid) || pid < 1) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function waitForProcessDeath(pid, label) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (!processIsAlive(pid)) return;
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  assert.fail(`${label} ${pid} survived Windows Job Object teardown`);
}

function forceKill(pid) {
  if (!processIsAlive(pid)) return;
  try { process.kill(pid, "SIGKILL"); } catch {}
}

function detachedGrandchildSource({ stayAlive = false } = {}) {
  return `
    const { spawn } = require("node:child_process");
    const grandchild = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], {
      detached: true,
      stdio: "ignore",
    });
    console.log("GRANDCHILD:" + grandchild.pid);
    grandchild.unref();
    ${stayAlive ? "setInterval(() => {}, 1000);" : ""}
  `;
}

function pidFromOutput(output, label) {
  const match = output.match(new RegExp(`${label}:(\\d+)`));
  assert.ok(match, `missing ${label} PID in output: ${output}`);
  return Number(match[1]);
}

async function waitForCapturedPid(output, label, timeoutMs = 5_000) {
  const deadline = Date.now() + timeoutMs;
  do {
    const match = output.read().stdout.match(new RegExp(`${label}:(\\d+)`));
    if (match) return Number(match[1]);
    await new Promise(resolve => setTimeout(resolve, 25));
  } while (Date.now() < deadline);
  assert.fail(`missing ${label} PID in output: ${output.read().stdout}`);
}

test("native Job Object launcher source enforces the suspended assignment boundary", windowsOnly, () => {
  const source = readFileSync(
    join(hutchRoot, "src", "bun_compat_job_launcher.zig"),
    "utf8",
  );
  const suspended = source.indexOf(".start_suspended = true");
  const assigned = source.indexOf("AssignProcessToJobObject(job, child.id.?)");
  const resumed = source.indexOf("ResumeThread(child.thread_handle)");
  assert.ok(suspended !== -1 && assigned > suspended && resumed > assigned);
  assert.match(source, /job_object_limit_kill_on_job_close/);
  assert.match(source, /WaitForMultipleObjects\(handles\.len, &handles/);
  assert.match(source, /activeProcessCount\(job\) != 0/);
  assert.doesNotMatch(source, /taskkill/i);
});

test("bounded terminator retries the Job-creation startup race with the same name", async () => {
  const calls = [];
  const child = new EventEmitter();
  child.pid = 1234;
  startWindowsJobChild("runtime.exe", [], {
    jobLauncher: "launcher.exe",
    parentPid: 5678,
    spawnOptions: {},
    spawnProcess(command, args, options) {
      calls.push({ command, args, options });
      return child;
    },
  });

  const proof = startWindowsJobTermination(child, {
    timeoutMs: 200,
    watchdogMs: 500,
    spawnProcess(command, args, options) {
      calls.push({ command, args, options });
      const terminator = new EventEmitter();
      terminator.kill = () => {};
      const status = calls.length === 2 ? 1 : 0;
      queueMicrotask(() => terminator.emit("close", status));
      return terminator;
    },
  });
  assert.equal(await proof, true);
  assert.equal(calls.length, 3);
  assert.deepEqual(calls[2].args, calls[1].args);
});

test("native Job Object launcher preserves argv, environment, cwd, stdio, and exit code", windowsOnly, async t => {
  const cwd = mkdtempSync(join(os.tmpdir(), "hutch-job-contract-"));
  t.after(() => rmSync(cwd, { recursive: true, force: true }));
  const expectedArgs = ["", "space value", 'quote"value', "trailing\\", "rabbit-🐇"];
  const source = `
    process.stdin.setEncoding("utf8");
    let stdin = "";
    process.stdin.on("data", chunk => { stdin += chunk; });
    process.stdin.on("end", () => {
      console.log(JSON.stringify({
        argv: process.argv.slice(1),
        cwd: process.cwd(),
        marker: process.env.HUTCH_JOB_MARKER,
        stdin,
      }));
      console.error("STDERR-SENTINEL");
      process.exit(23);
    });
  `;
  const child = startTarget(["-e", source, ...expectedArgs], {
    cwd,
    env: { ...process.env, HUTCH_JOB_MARKER: "environment value" },
  });
  const output = capture(child);
  const completed = completion(child);
  child.stdin.end("STDIN-SENTINEL");
  const result = await completed;
  const captured = output.read();

  assert.equal(result.code, 23);
  assert.equal(result.processDeathProven, true);
  assert.equal(result.teardownIncomplete, false);
  assert.match(captured.stderr, /STDERR-SENTINEL/);
  const record = JSON.parse(captured.stdout.trim());
  assert.deepEqual(record.argv, expectedArgs);
  assert.equal(record.cwd.toLowerCase(), cwd.toLowerCase());
  assert.equal(record.marker, "environment value");
  assert.equal(record.stdin, "STDIN-SENTINEL");
});

test("a detached grandchild cannot survive normal child exit", windowsOnly, async t => {
  const child = startTarget(["-e", detachedGrandchildSource()]);
  const output = capture(child);
  const result = await completion(child);
  const grandchildPid = pidFromOutput(output.read().stdout, "GRANDCHILD");
  t.after(() => forceKill(grandchildPid));

  assert.equal(result.code, 0);
  assert.equal(result.processDeathProven, true);
  await waitForProcessDeath(grandchildPid, "detached grandchild after normal exit");
});

test("a detached grandchild cannot survive an outer timeout", windowsOnly, async t => {
  const child = startTarget(["-e", detachedGrandchildSource({ stayAlive: true })]);
  const output = capture(child);
  const grandchildPid = await waitForCapturedPid(output, "GRANDCHILD");
  t.after(() => forceKill(grandchildPid));
  const result = await completion(child, {
    timeoutMs: 150,
    requireTerminationProof: true,
  });

  assert.equal(result.timedOut, true);
  assert.equal(result.processDeathProven, true);
  assert.equal(result.teardownIncomplete, false);
  await waitForProcessDeath(grandchildPid, "detached grandchild after timeout");
});

test("a detached grandchild cannot survive cooperative runner cancellation", windowsOnly, async t => {
  const controller = new AbortController();
  const child = startTarget(["-e", detachedGrandchildSource({ stayAlive: true })]);
  const output = capture(child);
  child.stdout.once("data", () => controller.abort(new Error("injected reporter failure")));
  const result = await completion(child, {
    signal: controller.signal,
    requireTerminationProof: true,
  });
  const grandchildPid = pidFromOutput(output.read().stdout, "GRANDCHILD");
  t.after(() => forceKill(grandchildPid));

  assert.equal(result.aborted, true);
  assert.equal(result.processDeathProven, true);
  assert.equal(result.teardownIncomplete, false);
  await waitForProcessDeath(grandchildPid, "detached grandchild after cancellation");
});

test("a detached grandchild cannot survive abrupt runner death", windowsOnly, async t => {
  const targetSource = detachedGrandchildSource({ stayAlive: true });
  const runnerSource = `
    import { spawn } from "node:child_process";
    import { startWindowsJobChild } from ${JSON.stringify(lifecycleModuleUrl)};
    const child = startWindowsJobChild(process.execPath, ["-e", ${JSON.stringify(targetSource)}], {
      jobLauncher: ${JSON.stringify(jobLauncher)},
      spawnOptions: {},
      spawnProcess: spawn,
    });
    console.log("HELPER:" + child.pid);
    child.stdout.pipe(process.stdout);
    child.stderr.pipe(process.stderr);
    setInterval(() => {}, 1000);
  `;
  const runner = spawn(process.execPath, ["--input-type=module", "-e", runnerSource]);
  let stdout = "";
  let stderr = "";
  runner.stdout.setEncoding("utf8");
  runner.stderr.setEncoding("utf8");
  runner.stdout.on("data", chunk => { stdout += chunk; });
  runner.stderr.on("data", chunk => { stderr += chunk; });

  let helperPid;
  let grandchildPid;
  for (let attempt = 0; attempt < 200; attempt += 1) {
    helperPid = stdout.match(/HELPER:(\d+)/)?.[1];
    grandchildPid = stdout.match(/GRANDCHILD:(\d+)/)?.[1];
    if (helperPid && grandchildPid) break;
    if (runner.exitCode != null) assert.fail(`runner fixture exited early: ${stderr || stdout}`);
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  helperPid = Number(helperPid);
  grandchildPid = Number(grandchildPid);
  assert.ok(Number.isInteger(helperPid), `missing helper PID: ${stderr || stdout}`);
  assert.ok(Number.isInteger(grandchildPid), `missing grandchild PID: ${stderr || stdout}`);
  t.after(() => {
    forceKill(runner.pid);
    forceKill(helperPid);
    forceKill(grandchildPid);
  });

  runner.kill("SIGKILL");
  await new Promise(resolve => runner.once("close", resolve));
  await waitForProcessDeath(helperPid, "native launcher after runner death");
  await waitForProcessDeath(grandchildPid, "detached grandchild after runner death");
});
