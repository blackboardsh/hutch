import { randomUUID } from "node:crypto";

const windowsJobMetadata = new WeakMap();

function abandonChildHandles(child) {
  for (const stream of [child.stdin, child.stdout, child.stderr]) {
    try {
      stream?.destroy();
    } catch {}
  }
  try {
    child.unref();
  } catch {}
}

function validateDuration(name, value, allowZero = false) {
  if (
    !Number.isSafeInteger(value) ||
    value > 2_147_483_647 ||
    (allowZero ? value < 0 : value <= 0)
  ) {
    throw new TypeError(
      `${name} must be ${allowZero ? "non-negative" : "positive"} ` +
      "safe integer no greater than 2147483647",
    );
  }
}

export function startWindowsJobChild(command, args, options) {
  const {
    jobLauncher,
    parentPid = process.pid,
    spawnOptions,
    spawnProcess,
  } = options;
  if (typeof command !== "string" || command.length === 0) {
    throw new TypeError("Windows job command must be a non-empty string");
  }
  if (!Array.isArray(args)) throw new TypeError("Windows job args must be an array");
  if (typeof jobLauncher !== "string" || jobLauncher.length === 0) {
    throw new TypeError("jobLauncher must be a non-empty string");
  }
  if (!Number.isSafeInteger(parentPid) || parentPid < 1 || parentPid > 0xffff_ffff) {
    throw new TypeError("parentPid must be a positive 32-bit integer");
  }
  if (typeof spawnProcess !== "function") {
    throw new TypeError("spawnProcess must be a function");
  }
  const jobName = `Local\\HutchBunCompat-${randomUUID()}`;
  const child = spawnProcess(
    jobLauncher,
    ["run", jobName, String(parentPid), command, ...args.map(String)],
    spawnOptions,
  );
  windowsJobMetadata.set(child, { jobLauncher, jobName });
  return child;
}

export function startWindowsJobTermination(child, options) {
  const { spawnProcess, timeoutMs, watchdogMs } = options;
  validateDuration("Windows job timeoutMs", timeoutMs);
  validateDuration("Windows job watchdogMs", watchdogMs);
  if (watchdogMs <= timeoutMs) {
    throw new TypeError("Windows job watchdogMs must exceed timeoutMs");
  }
  if (typeof spawnProcess !== "function") {
    throw new TypeError("spawnProcess must be a function");
  }
  const metadata = windowsJobMetadata.get(child);
  if (metadata == null) {
    throw new TypeError("child was not started by the Windows Job Object launcher");
  }

  return new Promise((resolve, reject) => {
    let settled = false;
    let retryTimer = null;
    let terminator = null;
    let watchdog = null;
    let lastStatus = null;
    const deadline = Date.now() + watchdogMs;
    const finish = error => {
      if (settled) return;
      settled = true;
      if (watchdog != null) clearTimeout(watchdog);
      if (retryTimer != null) clearTimeout(retryTimer);
      watchdog = null;
      retryTimer = null;
      if (error) reject(error);
      else resolve(true);
    };
    const startAttempt = () => {
      if (settled) return;
      try {
        terminator = spawnProcess(
          metadata.jobLauncher,
          ["terminate", metadata.jobName, String(timeoutMs)],
          { stdio: "ignore", windowsHide: true },
        );
      } catch (error) {
        finish(new Error(
          `Windows Job Object terminator failed to start: ${error?.message ?? String(error)}`,
          { cause: error },
        ));
        return;
      }
      terminator.once("error", error => {
        finish(new Error(
          `Windows Job Object terminator failed to start: ${error?.message ?? String(error)}`,
          { cause: error },
        ));
      });
      terminator.once("close", code => {
        if (settled) return;
        if (code === 0) {
          finish(null);
          return;
        }
        lastStatus = code;
        // An interrupt can arrive after the launcher process is spawned but
        // before it creates its named Job. OpenJobObject then fails quickly;
        // retry inside the same overall watchdog instead of caching that
        // startup race as a permanent failed proof.
        if (Date.now() + 25 < deadline) {
          retryTimer = setTimeout(startAttempt, 25);
          return;
        }
        finish(new Error(
          `Windows Job Object terminator exited with status ${lastStatus ?? "unknown"}`,
        ));
      });
    };
    watchdog = setTimeout(() => {
      try {
        terminator?.kill("SIGKILL");
      } catch {}
      terminator?.unref?.();
      finish(new Error(
        `Windows Job Object terminator did not settle within ${watchdogMs}ms` +
        (lastStatus == null ? "" : ` (last status ${lastStatus})`),
      ));
    }, watchdogMs);
    startAttempt();
  });
}

export function waitForChildCompletion(child, options) {
  const {
    timeoutMs,
    hardSettleTimeoutMs,
    naturalCloseProvesTreeDeath = true,
    requireTerminationProof = false,
    signal: abortSignal = null,
    settleDelayMs,
    terminate,
    terminateOnExit = true,
  } = options;
  validateDuration("timeoutMs", timeoutMs);
  validateDuration("hardSettleTimeoutMs", hardSettleTimeoutMs);
  validateDuration("settleDelayMs", settleDelayMs, true);
  if (typeof requireTerminationProof !== "boolean") {
    throw new TypeError("requireTerminationProof must be a boolean");
  }
  if (typeof naturalCloseProvesTreeDeath !== "boolean") {
    throw new TypeError("naturalCloseProvesTreeDeath must be a boolean");
  }
  if (typeof terminateOnExit !== "boolean") {
    throw new TypeError("terminateOnExit must be a boolean");
  }
  if (
    abortSignal != null &&
    (typeof abortSignal.addEventListener !== "function" ||
      typeof abortSignal.removeEventListener !== "function")
  ) {
    throw new TypeError("signal must be an AbortSignal");
  }
  if (typeof terminate !== "function") throw new TypeError("terminate must be a function");

  return new Promise(resolve => {
    let hardSettleTimer = null;
    let settleTimer = null;
    let settled = false;
    let teardownError = null;
    let terminationProof = requireTerminationProof ? null : true;
    let terminationStarted = false;
    let timedOut = false;
    let aborted = false;
    let closed = null;
    let exited = null;

    const clearTimers = () => {
      clearTimeout(timeoutTimer);
      if (hardSettleTimer != null) clearTimeout(hardSettleTimer);
      if (settleTimer != null) clearTimeout(settleTimer);
      abortSignal?.removeEventListener("abort", onAbort);
    };
    const finish = ({
      code = null,
      signal = null,
      error,
      processDeathProven,
      teardownIncomplete = !processDeathProven,
    }) => {
      if (settled) return;
      settled = true;
      clearTimers();
      if (!processDeathProven) abandonChildHandles(child);
      resolve({
        code,
        signal,
        ...(error ? { error } : {}),
        aborted,
        timedOut,
        processDeathProven,
        teardownIncomplete,
        ...(teardownError ? { teardownError } : {}),
      });
    };
    const finishClosedIfProven = () => {
      if (settled || closed == null) return;
      if (!terminationStarted) {
        finish({
          code: closed.code,
          signal: closed.signal,
          processDeathProven: naturalCloseProvesTreeDeath,
          teardownIncomplete: false,
        });
        return;
      }
      if (terminationProof == null) return;
      finish({
        code: closed.code,
        signal: closed.signal,
        processDeathProven: terminationProof,
      });
    };
    const recordTerminationProof = proven => {
      if (settled) return;
      if (!requireTerminationProof && proven !== false) return;
      terminationProof = proven === true;
      finishClosedIfProven();
      if (terminationProof === false && closed == null) {
        finish({
          code: exited?.code,
          signal: exited?.signal,
          processDeathProven: false,
        });
      }
    };
    const terminateBoundedly = () => {
      if (terminationStarted) return;
      terminationStarted = true;
      try {
        const result = terminate(child);
        if (requireTerminationProof) {
          if (result && typeof result.then === "function") {
            Promise.resolve(result).then(
              recordTerminationProof,
              error => {
                teardownError ??= error;
                recordTerminationProof(false);
              },
            );
          } else {
            recordTerminationProof(result === true);
          }
        } else if (result && typeof result.then === "function") {
          Promise.resolve(result).catch(error => {
            teardownError ??= error;
            recordTerminationProof(false);
          });
        }
      } catch (error) {
        teardownError ??= error;
        recordTerminationProof(false);
      }
    };
    const startHardSettlement = () => {
      if (hardSettleTimer != null) return;
      hardSettleTimer = setTimeout(() => {
        finish({ processDeathProven: false });
      }, hardSettleTimeoutMs);
    };
    const onAbort = () => {
      if (settled || aborted) return;
      aborted = true;
      clearTimeout(timeoutTimer);
      startHardSettlement();
      terminateBoundedly();
    };
    const timeoutTimer = setTimeout(() => {
      timedOut = true;
      startHardSettlement();
      terminateBoundedly();
    }, timeoutMs);

    child.once("exit", (code, signal) => {
      if (settled) return;
      exited = { code, signal };
      clearTimeout(timeoutTimer);
      if (!terminationStarted) {
        settleTimer = setTimeout(() => {
          // `exit` proves only that the direct child exited. `close` is the
          // evidence that its stdio handles closed as well. A descendant can
          // inherit those handles, so bound this state but retain temp data and
          // classify teardown as incomplete rather than claiming the tree died.
          finish({ code, signal, processDeathProven: false });
        }, settleDelayMs);
      }
      if (terminateOnExit) terminateBoundedly();
    });
    child.once("close", (code, signal) => {
      closed = { code, signal };
      if (terminateOnExit) terminateBoundedly();
      finishClosedIfProven();
    });
    child.once("error", error => {
      if (child.pid == null) {
        finish({ error, processDeathProven: true });
        return;
      }
      terminateBoundedly();
      finish({ error, processDeathProven: false });
    });
    abortSignal?.addEventListener("abort", onAbort, { once: true });
    if (abortSignal?.aborted) onAbort();
  });
}
