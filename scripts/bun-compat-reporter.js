import { createHash, randomUUID } from "node:crypto";
import {
  closeSync,
  existsSync,
  fsyncSync,
  linkSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  realpathSync,
  rmSync,
  statSync,
  writeSync,
} from "node:fs";
import {
  basename,
  dirname,
  isAbsolute,
  join,
  relative,
  resolve,
  sep,
} from "node:path";

const maxTimerDelayMs = 2_147_483_647;

function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map(key => [key, canonicalize(value[key])]),
    );
  }
  return value;
}

function canonicalJson(value) {
  return `${JSON.stringify(canonicalize(value), null, 2)}\n`;
}

function fingerprint(value) {
  return createHash("sha256").update(canonicalJson(value)).digest("hex");
}

function writeAll(descriptor, bytes, writeChunk = writeSync) {
  let offset = 0;
  while (offset < bytes.length) {
    const written = writeChunk(descriptor, bytes, offset, bytes.length - offset);
    if (!Number.isInteger(written) || written < 1) {
      throw new Error(`durable write made no progress at byte ${offset}`);
    }
    offset += written;
  }
}

function directoryFsyncUnsupported(error) {
  return (
    process.platform === "win32" &&
    ["EACCES", "EBADF", "EINVAL", "EISDIR", "ENOSYS", "ENOTSUP", "EPERM"]
      .includes(error?.code)
  );
}

function fsyncDirectory(path) {
  let descriptor = null;
  try {
    descriptor = openSync(path, "r");
    fsyncSync(descriptor);
  } catch (error) {
    if (!directoryFsyncUnsupported(error)) throw error;
  } finally {
    if (descriptor != null) {
      try {
        closeSync(descriptor);
      } catch (error) {
        if (!directoryFsyncUnsupported(error)) throw error;
      }
    }
  }
}

function fsyncParentDirectory(path) {
  fsyncDirectory(dirname(path));
}

function mkdirDurably(path) {
  const missing = [];
  let cursor = resolve(path);
  while (!existsSync(cursor)) {
    missing.push(cursor);
    const parent = dirname(cursor);
    if (parent === cursor) break;
    cursor = parent;
  }
  mkdirSync(path, { recursive: true, mode: 0o700 });
  for (const created of missing.reverse()) {
    fsyncDirectory(created);
    fsyncParentDirectory(created);
  }
}

function writeDescriptorDurably(descriptor, data) {
  const bytes = Buffer.isBuffer(data) ? data : Buffer.from(String(data));
  writeAll(descriptor, bytes);
  fsyncSync(descriptor);
}

export function writeDurably(path, data, { writeChunk = writeSync } = {}) {
  const bytes = Buffer.isBuffer(data) ? data : Buffer.from(String(data));
  if (existsSync(path)) throw new Error(`durable output already exists: ${path}`);
  const temporaryPath = join(
    dirname(path),
    `.${basename(path)}.${process.pid}.${randomUUID()}.tmp`,
  );
  let descriptor = null;
  try {
    descriptor = openSync(temporaryPath, "wx", 0o600);
    writeAll(descriptor, bytes, writeChunk);
    fsyncSync(descriptor);
    closeSync(descriptor);
    descriptor = null;
    linkSync(temporaryPath, path);
    fsyncParentDirectory(path);
    rmSync(temporaryPath);
    fsyncParentDirectory(path);
  } finally {
    if (descriptor != null) closeSync(descriptor);
    if (existsSync(temporaryPath)) rmSync(temporaryPath, { force: true });
  }
}

function durationLabel(milliseconds) {
  if (milliseconds < 1_000) return `${milliseconds}ms`;
  const seconds = Math.round(milliseconds / 1_000);
  if (seconds < 60) return `${seconds}s`;
  return `${Math.floor(seconds / 60)}m${String(seconds % 60).padStart(2, "0")}s`;
}

function logName(path) {
  const prefix = createHash("sha256").update(path).digest("hex").slice(0, 16);
  const label = basename(path).replace(/[^a-zA-Z0-9._-]+/g, "_").slice(-100);
  return `${prefix}-${label}.log`;
}

function pathIsInside(root, path) {
  const relativePath = relative(root, path);
  return (
    relativePath === "" ||
    (!isAbsolute(relativePath) && relativePath !== ".." && !relativePath.startsWith(`..${sep}`))
  );
}

function pathsOverlap(left, right) {
  return pathIsInside(left, right) || pathIsInside(right, left);
}

function canonicalTarget(path) {
  const suffix = [];
  let cursor = resolve(path);
  while (!existsSync(cursor)) {
    suffix.unshift(basename(cursor));
    const parent = dirname(cursor);
    if (parent === cursor) break;
    cursor = parent;
  }
  return resolve(realpathSync(cursor), ...suffix);
}

function assertAllowedReportPath(requestedRoot, forbiddenRoots) {
  for (const root of forbiddenRoots) {
    if (pathsOverlap(requestedRoot, root)) {
      throw new Error(`report path overlaps runner-owned input or cleanup root: ${root}`);
    }
  }
}

export class HutchCompatReporter {
  constructor({
    heartbeatMs,
    identity,
    forbiddenRoots = [],
    maxOutputBytes,
    onError,
    planned,
    reportDir = null,
    reportsRoot,
  }) {
    if (!Number.isInteger(planned) || planned < 1) {
      throw new TypeError("planned report entries must be a positive integer");
    }
    if (!Number.isInteger(maxOutputBytes) || maxOutputBytes < 1) {
      throw new TypeError("maxOutputBytes must be a positive integer");
    }
    if (
      !Number.isSafeInteger(heartbeatMs) ||
      heartbeatMs < 1 ||
      heartbeatMs > maxTimerDelayMs
    ) {
      throw new TypeError(
        `heartbeatMs must be a positive safe integer no greater than ${maxTimerDelayMs}`,
      );
    }
    if (typeof onError !== "function") throw new TypeError("onError must be a function");

    this.startedAtMs = Date.now();
    this.planned = planned;
    this.completed = 0;
    this.unexpected = 0;
    this.maxOutputBytes = maxOutputBytes;
    this.running = new Map();
    this.finished = false;
    this.harnessDependencies = null;
    this.heartbeatError = null;
    this.phase = "initializing";
    this.onError = onError;

    const lexicalRequestedRoot = resolve(reportDir ?? reportsRoot);
    const lexicalForbiddenRoots = forbiddenRoots.map(root => resolve(root));
    assertAllowedReportPath(lexicalRequestedRoot, lexicalForbiddenRoots);
    const requestedRoot = canonicalTarget(lexicalRequestedRoot);
    const canonicalForbiddenRoots = lexicalForbiddenRoots.map(canonicalTarget);
    assertAllowedReportPath(requestedRoot, canonicalForbiddenRoots);

    if (reportDir != null) {
      this.reportDir = requestedRoot;
      if (existsSync(this.reportDir)) {
        throw new Error(`new report directory already exists: ${this.reportDir}`);
      }
      mkdirDurably(dirname(this.reportDir));
      mkdirSync(this.reportDir, { mode: 0o700 });
      fsyncDirectory(this.reportDir);
      fsyncParentDirectory(this.reportDir);
    } else {
      const parent = requestedRoot;
      mkdirDurably(parent);
      const stamp = new Date().toISOString().replace(/[:.]/g, "-");
      this.reportDir = mkdtempSync(join(parent, `${stamp}-`));
      fsyncDirectory(this.reportDir);
      fsyncParentDirectory(this.reportDir);
    }
    const reportDirectoryStat = lstatSync(this.reportDir);
    if (reportDirectoryStat.isSymbolicLink() || !reportDirectoryStat.isDirectory()) {
      throw new Error(`report directory must be a real directory: ${this.reportDir}`);
    }
    this.reportDir = realpathSync(this.reportDir);
    assertAllowedReportPath(this.reportDir, canonicalForbiddenRoots);
    const physicalReportDirectoryStat = lstatSync(this.reportDir);
    this.reportDirectoryIdentity = {
      dev: physicalReportDirectoryStat.dev,
      ino: physicalReportDirectoryStat.ino,
    };

    this.eventsPath = join(this.reportDir, "events.jsonl");
    this.logsDir = join(this.reportDir, "logs");
    mkdirSync(this.logsDir, { mode: 0o700 });
    fsyncDirectory(this.logsDir);
    fsyncParentDirectory(this.logsDir);
    const logsDirectoryStat = lstatSync(this.logsDir);
    this.logsDirectoryIdentity = {
      dev: logsDirectoryStat.dev,
      ino: logsDirectoryStat.ino,
    };
    const identityRecord = {
      schema: 1,
      suite: "hutch-bun-package-manager-compat",
      createdAt: new Date().toISOString(),
      identity,
      identityFingerprint: fingerprint(identity),
    };
    writeDurably(join(this.reportDir, "run.json"), canonicalJson(identityRecord));
    this.eventsDescriptor = openSync(this.eventsPath, "wx", 0o600);
    try {
      this.appendEvent({
        kind: "run-start",
        identityFingerprint: identityRecord.identityFingerprint,
        planned,
      });
      fsyncParentDirectory(this.eventsPath);
    } catch (error) {
      try { closeSync(this.eventsDescriptor); } catch {}
      this.eventsDescriptor = null;
      throw error;
    }
    console.log(`Hutch compatibility report: ${this.reportDir}`);

    this.heartbeatTimer = setInterval(() => this.runHeartbeat(), heartbeatMs);
    this.heartbeatTimer.unref();
  }

  appendEvent(event) {
    if (this.eventsDescriptor == null) {
      throw new Error("report event stream is not open");
    }
    const record = JSON.parse(JSON.stringify({
      schema: 1,
      at: new Date().toISOString(),
      ...event,
    }));
    writeDescriptorDurably(
      this.eventsDescriptor,
      `${JSON.stringify({ ...record, checksum: fingerprint(record) })}\n`,
    );
  }

  assertReportDirectoryStable() {
    const current = lstatSync(this.reportDir);
    if (
      current.isSymbolicLink() ||
      !current.isDirectory() ||
      current.dev !== this.reportDirectoryIdentity.dev ||
      current.ino !== this.reportDirectoryIdentity.ino
    ) {
      throw new Error(`report directory path was replaced while the run was active: ${this.reportDir}`);
    }
  }

  assertLogsDirectoryStable() {
    this.assertReportDirectoryStable();
    const current = lstatSync(this.logsDir);
    if (
      current.isSymbolicLink() ||
      !current.isDirectory() ||
      current.dev !== this.logsDirectoryIdentity.dev ||
      current.ino !== this.logsDirectoryIdentity.ino
    ) {
      throw new Error(`report logs path was replaced while the run was active: ${this.logsDir}`);
    }
  }

  startEntry(entry, progress) {
    if (this.finished) throw new Error("cannot start a file after the report finished");
    if (this.running.has(entry.path)) {
      throw new Error(`report already has a running file: ${entry.path}`);
    }
    this.assertLogsDirectoryStable();
    const logPath = join(this.logsDir, logName(entry.path));
    const logDescriptor = openSync(logPath, "wx", 0o600);
    try {
      writeDescriptorDurably(
        logDescriptor,
        `=== ${entry.path} ${new Date().toISOString()} ===\n`,
      );
      fsyncParentDirectory(logPath);
    } catch (error) {
      try { closeSync(logDescriptor); } catch {}
      throw error;
    }
    const token = {
      bytes: 0,
      entry,
      lastStream: null,
      logDescriptor,
      logPath,
      startedAtMs: Date.now(),
      truncated: false,
    };
    this.running.set(entry.path, token);
    this.appendEvent({
      kind: "file-start",
      path: entry.path,
      status: entry.status,
      ...progress,
    });
    return token;
  }

  setPhase(phase) {
    if (this.finished) return;
    this.phase = String(phase);
    this.appendEvent({ kind: "phase", phase: this.phase });
  }

  recordHarnessDependencies(generation) {
    if (this.finished) throw new Error("cannot record dependencies after the report finished");
    if (this.harnessDependencies != null) {
      throw new Error("harness dependency generation was already recorded");
    }
    const record = JSON.parse(JSON.stringify(generation));
    this.assertReportDirectoryStable();
    writeDurably(
      join(this.reportDir, "harness-dependencies.json"),
      canonicalJson(record),
    );
    this.appendEvent({ kind: "harness-dependencies", generation: record });
    this.harnessDependencies = record;
  }

  appendOutput(token, stream, data) {
    if (this.finished) throw new Error("cannot append output after the report finished");
    if (token.truncated) return;
    const chunk = Buffer.isBuffer(data) ? data : Buffer.from(String(data));
    const remaining = Math.max(0, this.maxOutputBytes - token.bytes);
    if (remaining === 0) {
      writeDescriptorDurably(
        token.logDescriptor,
        "\n--- output truncated at configured log limit ---\n",
      );
      token.truncated = true;
      return;
    }
    if (token.lastStream !== stream) {
      writeAll(token.logDescriptor, Buffer.from(`--- ${stream} ---\n`));
      token.lastStream = stream;
    }
    const written = chunk.subarray(0, remaining);
    writeAll(token.logDescriptor, written);
    token.bytes += written.length;
    if (written.length < chunk.length) {
      writeDescriptorDurably(
        token.logDescriptor,
        "\n--- output truncated at configured log limit ---\n",
      );
      token.truncated = true;
    }
  }

  finishEntry(token, result, progress) {
    if (this.running.get(token.entry.path) !== token) {
      throw new Error(`report file was not running: ${token.entry.path}`);
    }
    const durationMs = Math.max(0, Date.now() - token.startedAtMs);
    writeDescriptorDurably(token.logDescriptor, [
      "",
      "--- result ---",
      `outcome: ${result.outcome}`,
      `durationMs: ${durationMs}`,
      `exitCode: ${result.execution?.code ?? ""}`,
      `signal: ${result.execution?.signal ?? ""}`,
      `timedOut: ${Boolean(result.execution?.timedOut)}`,
      `processDeathProven: ${Boolean(result.execution?.processDeathProven)}`,
      result.execution?.teardownError
        ? `teardownError: ${result.execution.teardownError}`
        : "",
      "",
    ].filter(Boolean).join("\n") + "\n");
    closeSync(token.logDescriptor);
    token.logDescriptor = null;
    const log = relative(this.reportDir, token.logPath).replaceAll("\\", "/");
    this.appendEvent({
      kind: "file-end",
      path: token.entry.path,
      status: token.entry.status,
      outcome: result.outcome,
      ok: result.ok,
      message: result.message,
      durationMs,
      log,
      execution: result.execution,
      ...progress,
    });
    this.running.delete(token.entry.path);
    this.completed += 1;
    if (!result.ok) this.unexpected += 1;
    return log;
  }

  heartbeat() {
    if (this.finished) return;
    const elapsedMs = Date.now() - this.startedAtMs;
    const running = [...this.running.values()].map(token => ({
      path: token.entry.path,
      elapsedMs: Date.now() - token.startedAtMs,
    }));
    for (const token of this.running.values()) {
      if (token.logDescriptor != null) fsyncSync(token.logDescriptor);
    }
    const message =
      `heartbeat Hutch compatibility: ${this.completed}/${this.planned} complete, ` +
      `${this.unexpected} unexpected, elapsed ${durationLabel(elapsedMs)}, ` +
      `phase ${this.phase}; running: ` +
      (running.map(entry => `${entry.path} (${durationLabel(entry.elapsedMs)})`).join(", ") || "none");
    console.log(message);
    this.appendEvent({
      kind: "heartbeat",
      completed: this.completed,
      planned: this.planned,
      unexpected: this.unexpected,
      elapsedMs,
      phase: this.phase,
      running,
    });
  }

  runHeartbeat() {
    if (this.finished || this.heartbeatError != null) return;
    try {
      this.heartbeat();
    } catch (error) {
      this.heartbeatError = error;
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
      try {
        this.onError(error);
      } catch (callbackError) {
        console.error(
          `hutch-package-manager-compat: heartbeat error handler failed: ` +
          `${callbackError?.message ?? String(callbackError)}`,
        );
      }
    }
  }

  finish(summary) {
    if (this.finished) return;
    if (this.running.size !== 0 || this.completed !== this.planned) {
      throw new Error(
        `cannot finish report with ${this.running.size} running and ` +
        `${this.completed}/${this.planned} completed files`,
      );
    }
    clearInterval(this.heartbeatTimer);
    const record = {
      schema: 1,
      suite: "hutch-bun-package-manager-compat",
      finishedAt: new Date().toISOString(),
      elapsedMs: Date.now() - this.startedAtMs,
      planned: this.planned,
      completed: this.completed,
      unexpected: this.unexpected,
      ...summary,
    };
    this.appendEvent({ kind: "run-end", ...record });
    this.assertReportDirectoryStable();
    writeDurably(join(this.reportDir, "summary.json"), canonicalJson(record));
    try {
      closeSync(this.eventsDescriptor);
    } catch (error) {
      console.error(
        `hutch-package-manager-compat: warning: could not close report events: ` +
        `${error?.message ?? String(error)}`,
      );
    }
    this.eventsDescriptor = null;
    this.finished = true;
  }

  fatal(error) {
    if (this.finished) return;
    clearInterval(this.heartbeatTimer);
    const message = error?.message ?? String(error);
    let eventError = null;
    try {
      this.appendEvent({
        kind: "run-error",
        message,
        completed: this.completed,
        planned: this.planned,
        unexpected: this.unexpected,
        running: [...this.running.keys()],
      });
    } catch (error) {
      eventError = error;
    }
    let logError = null;
    for (const token of this.running.values()) {
      if (token.logDescriptor == null) continue;
      try {
        fsyncSync(token.logDescriptor);
      } catch (error) {
        logError ??= error;
      }
      try {
        closeSync(token.logDescriptor);
      } catch (error) {
        logError ??= error;
      }
      token.logDescriptor = null;
    }
    if (this.eventsDescriptor != null) {
      try {
        closeSync(this.eventsDescriptor);
      } catch (error) {
        eventError ??= error;
      }
      this.eventsDescriptor = null;
    }
    const summary = {
      schema: 1,
      suite: "hutch-bun-package-manager-compat",
      finishedAt: new Date().toISOString(),
      elapsedMs: Date.now() - this.startedAtMs,
      planned: this.planned,
      completed: this.completed,
      unexpected: this.unexpected,
      fatal: message,
      running: [...this.running.keys()],
      ...(eventError ? { reportEventError: eventError.message ?? String(eventError) } : {}),
      ...(logError ? { reportLogError: logError.message ?? String(logError) } : {}),
    };
    let summaryError = null;
    try {
      this.assertReportDirectoryStable();
      writeDurably(join(this.reportDir, "summary.json"), canonicalJson(summary));
    } catch (error) {
      summaryError = error;
    } finally {
      this.finished = true;
    }
    if (eventError || logError || summaryError) {
      throw eventError ?? logError ?? summaryError;
    }
  }

  interrupt(signal) {
    this.fatal(new Error(`runner interrupted by ${signal}`));
  }
}
