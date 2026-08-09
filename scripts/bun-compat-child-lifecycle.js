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

export function startWindowsTaskkill(child, options) {
  const { spawnProcess, timeoutMs } = options;
  validateDuration("taskkill timeoutMs", timeoutMs);
  if (typeof spawnProcess !== "function") {
    throw new TypeError("spawnProcess must be a function");
  }
  if (!Number.isInteger(child.pid) || child.pid < 1) return null;

  // Do not synchronously wait for taskkill. It is only a best-effort Windows
  // process-tree signal; the child lifecycle's independent hard-settlement
  // timer is the authority that bounds the outer test deadline.
  const taskkill = spawnProcess(
    "taskkill",
    ["/pid", String(child.pid), "/t", "/f"],
    { stdio: "ignore", windowsHide: true },
  );
  return new Promise((resolve, reject) => {
    let settled = false;
    let taskkillTimer = setTimeout(() => {
      taskkillTimer = null;
      try {
        taskkill.kill("SIGKILL");
      } catch {}
      // The watchdog has made its best-effort kill. Do not let a broken helper
      // outlive the runner indefinitely if Windows refuses that final signal.
      taskkill.unref?.();
      finish(new Error(`taskkill did not settle within ${timeoutMs}ms`));
    }, timeoutMs);
    const finish = error => {
      if (settled) return;
      settled = true;
      if (taskkillTimer != null) clearTimeout(taskkillTimer);
      taskkillTimer = null;
      if (error) reject(error);
      else resolve(true);
    };
    taskkill.once("error", error => {
      finish(new Error(
        `taskkill failed to start: ${error?.message ?? String(error)}`,
        { cause: error },
      ));
    });
    taskkill.once("close", code => {
      finish(code === 0 ? null : new Error(`taskkill exited with status ${code ?? "unknown"}`));
    });
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
