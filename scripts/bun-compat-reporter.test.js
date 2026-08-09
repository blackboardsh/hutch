import assert from "node:assert/strict";
import {
  closeSync,
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
  writeSync,
} from "node:fs";
import os from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  HutchCompatReporter,
  writeDurably,
} from "./bun-compat-reporter.js";

function temporaryRoot(t, prefix) {
  const root = mkdtempSync(join(os.tmpdir(), prefix));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return root;
}

function reporterOptions(root, overrides = {}) {
  return {
    heartbeatMs: 60_000,
    identity: {
      inventory: { canonicalRunnableFiles: 1_445, ownedRunnableFiles: 103 },
      selection: ["test/example.test.ts"],
    },
    maxOutputBytes: 8,
    onError() {},
    planned: 1,
    reportDir: join(root, "run"),
    reportsRoot: join(root, "unused-default-root"),
    ...overrides,
  };
}

test("persists checksummed live file progress, bounded output, and a final summary", t => {
  const root = temporaryRoot(t, "hutch-compat-reporter-");
  const reporter = new HutchCompatReporter(reporterOptions(root));
  reporter.recordHarnessDependencies({
    generationFingerprint: "a".repeat(64),
    nodeModules: { entries: 281, payloadFingerprint: "b".repeat(64) },
    payloadFingerprint: "c".repeat(64),
  });
  if (process.platform !== "win32") {
    assert.equal(statSync(join(root, "run")).mode & 0o777, 0o700);
    assert.equal(statSync(join(root, "run", "logs")).mode & 0o777, 0o700);
  }
  const entry = { path: "test/example.test.ts", status: "enabled" };
  const token = reporter.startEntry(entry, {
    started: 1,
    completed: 0,
    running: 1,
  });
  reporter.appendOutput(token, "stdout", Buffer.from("hello"));
  reporter.appendOutput(token, "stderr", Buffer.from(" world"));
  reporter.heartbeat();
  const reportLog = reporter.finishEntry(
    token,
    {
      ok: false,
      outcome: "unexpected-failure",
      message: "FAIL test/example.test.ts exited 1",
      execution: {
        code: 1,
        signal: null,
        timedOut: false,
        processDeathProven: true,
      },
    },
    {
      started: 1,
      completed: 1,
      running: 0,
      outcomeCounts: { "unexpected-failure": 1 },
    },
  );
  reporter.finish({
    files: 1,
    outcomeCounts: { "unexpected-failure": 1 },
  });

  const run = JSON.parse(readFileSync(join(root, "run", "run.json"), "utf8"));
  assert.equal(run.schema, 1);
  assert.equal(run.suite, "hutch-bun-package-manager-compat");
  assert.match(run.identityFingerprint, /^[0-9a-f]{64}$/);

  const events = readFileSync(join(root, "run", "events.jsonl"), "utf8")
    .trim()
    .split("\n")
    .map(line => JSON.parse(line));
  assert.deepEqual(
    events.map(event => event.kind),
    [
      "run-start",
      "harness-dependencies",
      "file-start",
      "heartbeat",
      "file-end",
      "run-end",
    ],
  );
  for (const event of events) assert.match(event.checksum, /^[0-9a-f]{64}$/);
  assert.equal(events[2].path, entry.path);
  assert.equal(events[4].outcome, "unexpected-failure");
  assert.equal(events[4].log, reportLog);

  const dependencies = JSON.parse(
    readFileSync(join(root, "run", "harness-dependencies.json"), "utf8"),
  );
  assert.equal(dependencies.generationFingerprint, "a".repeat(64));

  const log = readFileSync(join(root, "run", reportLog), "utf8");
  assert.match(log, /--- stdout ---\nhello/);
  assert.match(log, /--- stderr ---\n wo/);
  assert.match(log, /output truncated at configured log limit/);
  assert.match(log, /outcome: unexpected-failure/);

  const summary = JSON.parse(readFileSync(join(root, "run", "summary.json"), "utf8"));
  assert.equal(summary.planned, 1);
  assert.equal(summary.completed, 1);
  assert.equal(summary.unexpected, 1);
  assert.deepEqual(summary.outcomeCounts, { "unexpected-failure": 1 });
});

test("records an interrupted run even when no file reaches a terminal result", t => {
  const root = temporaryRoot(t, "hutch-compat-reporter-interrupt-");
  const reporter = new HutchCompatReporter(reporterOptions(root));
  reporter.startEntry(
    { path: "test/example.test.ts", status: "enabled" },
    { started: 1, completed: 0, running: 1 },
  );
  reporter.interrupt("SIGTERM");

  const summary = JSON.parse(readFileSync(join(root, "run", "summary.json"), "utf8"));
  assert.equal(summary.completed, 0);
  assert.match(summary.fatal, /SIGTERM/);
  assert.deepEqual(summary.running, ["test/example.test.ts"]);
  assert.equal(existsSync(join(root, "run", "events.jsonl")), true);
});

test("refuses to overwrite an existing explicit report directory", t => {
  const root = temporaryRoot(t, "hutch-compat-reporter-existing-");
  mkdirSync(join(root, "run"));
  assert.throws(
    () => new HutchCompatReporter(reporterOptions(root)),
    /new report directory already exists/,
  );
});

test("refuses report paths that overlap runner-owned cleanup roots", t => {
  const root = temporaryRoot(t, "hutch-compat-reporter-overlap-");
  const suiteRoot = join(root, "suite");
  mkdirSync(suiteRoot);
  assert.throws(
    () => new HutchCompatReporter(reporterOptions(root, {
      forbiddenRoots: [suiteRoot],
      reportDir: join(suiteRoot, ".cottontail-tmp", "report"),
    })),
    /report path overlaps runner-owned input or cleanup root/,
  );
  assert.equal(existsSync(join(suiteRoot, ".cottontail-tmp")), false);
});

test("resolves parent symlinks before checking runner-owned cleanup roots", t => {
  const root = temporaryRoot(t, "hutch-compat-reporter-symlink-overlap-");
  const suiteRoot = join(root, "suite");
  const alias = join(root, "suite-alias");
  mkdirSync(suiteRoot);
  symlinkSync(suiteRoot, alias, process.platform === "win32" ? "junction" : "dir");

  assert.throws(
    () => new HutchCompatReporter(reporterOptions(root, {
      forbiddenRoots: [suiteRoot],
      reportDir: join(alias, ".cottontail-tmp", "report"),
    })),
    /report path overlaps runner-owned input or cleanup root/,
  );
  assert.equal(existsSync(join(suiteRoot, ".cottontail-tmp")), false);
});

test("routes heartbeat write failures through the runner error boundary", t => {
  const root = temporaryRoot(t, "hutch-compat-reporter-heartbeat-error-");
  let heartbeatError = null;
  const reporter = new HutchCompatReporter(reporterOptions(root, {
    onError(error) { heartbeatError = error; },
  }));
  const appendEvent = reporter.appendEvent.bind(reporter);
  reporter.appendEvent = () => { throw new Error("injected heartbeat write failure"); };

  assert.doesNotThrow(() => reporter.runHeartbeat());
  assert.match(heartbeatError?.message ?? "", /injected heartbeat write failure/);

  reporter.appendEvent = appendEvent;
  reporter.fatal(heartbeatError);
  const summary = JSON.parse(readFileSync(join(root, "run", "summary.json"), "utf8"));
  assert.match(summary.fatal, /injected heartbeat write failure/);
});

test("refuses later files when the report directory pathname is rebound", t => {
  const root = temporaryRoot(t, "hutch-compat-reporter-rebind-");
  const reporter = new HutchCompatReporter(reporterOptions(root));
  const movedRun = join(root, "moved-run");
  const replacement = join(root, "replacement");
  renameSync(join(root, "run"), movedRun);
  mkdirSync(replacement);
  symlinkSync(replacement, join(root, "run"), process.platform === "win32" ? "junction" : "dir");

  assert.throws(
    () => reporter.startEntry(
      { path: "test/example.test.ts", status: "enabled" },
      { started: 1, completed: 0, running: 1 },
    ),
    /report directory path was replaced while the run was active/,
  );
  assert.throws(
    () => reporter.fatal(new Error("report path rebound")),
    /report directory path was replaced while the run was active/,
  );
  assert.deepEqual(readdirSync(replacement), []);
});

test("refuses later files when the report logs pathname is rebound", t => {
  const root = temporaryRoot(t, "hutch-compat-reporter-logs-rebind-");
  const reporter = new HutchCompatReporter(reporterOptions(root));
  const logs = join(root, "run", "logs");
  const movedLogs = join(root, "moved-logs");
  const replacement = join(root, "replacement");
  renameSync(logs, movedLogs);
  mkdirSync(replacement);
  symlinkSync(replacement, logs, process.platform === "win32" ? "junction" : "dir");

  assert.throws(
    () => reporter.startEntry(
      { path: "test/example.test.ts", status: "enabled" },
      { started: 1, completed: 0, running: 1 },
    ),
    /report logs path was replaced while the run was active/,
  );
  reporter.fatal(new Error("report logs path rebound"));
  assert.deepEqual(readdirSync(replacement), []);
});

test("records active-log flush failures before publishing a fatal summary", t => {
  const root = temporaryRoot(t, "hutch-compat-reporter-log-flush-");
  const reporter = new HutchCompatReporter(reporterOptions(root));
  const token = reporter.startEntry(
    { path: "test/example.test.ts", status: "enabled" },
    { started: 1, completed: 0, running: 1 },
  );
  closeSync(token.logDescriptor);

  assert.throws(() => reporter.fatal(new Error("runner failed")), /EBADF|bad file descriptor/i);
  const summary = JSON.parse(readFileSync(join(root, "run", "summary.json"), "utf8"));
  assert.match(summary.reportLogError, /EBADF|bad file descriptor/i);
  assert.equal(summary.fatal, "runner failed");
});

test("rejects heartbeat delays that Node would clamp to one millisecond", t => {
  const root = temporaryRoot(t, "hutch-compat-reporter-timer-bound-");
  assert.throws(
    () => new HutchCompatReporter(reporterOptions(root, {
      heartbeatMs: 2_147_483_648,
    })),
    /heartbeatMs must be a positive safe integer no greater than 2147483647/,
  );
  assert.equal(existsSync(join(root, "run")), false);
});

test("atomic durable writes handle short writes and hide interrupted output", t => {
  const root = temporaryRoot(t, "hutch-compat-atomic-write-");
  const completePath = join(root, "complete.json");
  writeDurably(completePath, "abcdef", {
    writeChunk(descriptor, bytes, offset, length) {
      return writeSync(descriptor, bytes, offset, Math.min(length, 2));
    },
  });
  assert.equal(readFileSync(completePath, "utf8"), "abcdef");

  const interruptedPath = join(root, "interrupted.json");
  let calls = 0;
  assert.throws(
    () => writeDurably(interruptedPath, "abcdef", {
      writeChunk(descriptor, bytes, offset, length) {
        calls += 1;
        if (calls > 1) throw new Error("injected write interruption");
        return writeSync(descriptor, bytes, offset, Math.min(length, 2));
      },
    }),
    /injected write interruption/,
  );
  assert.equal(existsSync(interruptedPath), false);
  assert.equal(
    readdirSync(root).some(name => name.includes("interrupted.json") && name.endsWith(".tmp")),
    false,
  );

  const contendedPath = join(root, "contended.json");
  assert.throws(
    () => writeDurably(contendedPath, "reporter", {
      writeChunk(descriptor, bytes, offset, length) {
        if (!existsSync(contendedPath)) writeFileSync(contendedPath, "competitor");
        return writeSync(descriptor, bytes, offset, length);
      },
    }),
    error => error?.code === "EEXIST",
  );
  assert.equal(readFileSync(contendedPath, "utf8"), "competitor");
});
