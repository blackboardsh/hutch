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
  if (!Number.isFinite(value) || (allowZero ? value < 0 : value <= 0)) {
    throw new TypeError(`${name} must be ${allowZero ? "non-negative" : "positive"}`);
  }
}

export function waitForChildCompletion(child, options) {
  const {
    timeoutMs,
    hardSettleTimeoutMs,
    settleDelayMs,
    terminate,
  } = options;
  validateDuration("timeoutMs", timeoutMs);
  validateDuration("hardSettleTimeoutMs", hardSettleTimeoutMs);
  validateDuration("settleDelayMs", settleDelayMs, true);
  if (typeof terminate !== "function") throw new TypeError("terminate must be a function");

  return new Promise(resolve => {
    let hardSettleTimer = null;
    let settleTimer = null;
    let settled = false;
    let teardownError = null;
    let timedOut = false;

    const clearTimers = () => {
      clearTimeout(timeoutTimer);
      if (hardSettleTimer != null) clearTimeout(hardSettleTimer);
      if (settleTimer != null) clearTimeout(settleTimer);
    };
    const finish = ({ code = null, signal = null, error, processDeathProven }) => {
      if (settled) return;
      settled = true;
      clearTimers();
      if (!processDeathProven) abandonChildHandles(child);
      resolve({
        code,
        signal,
        ...(error ? { error } : {}),
        timedOut,
        processDeathProven,
        teardownIncomplete: !processDeathProven,
        ...(teardownError ? { teardownError } : {}),
      });
    };
    const terminateBoundedly = () => {
      try {
        terminate(child);
      } catch (error) {
        teardownError ??= error;
      }
    };
    const timeoutTimer = setTimeout(() => {
      timedOut = true;
      terminateBoundedly();
      hardSettleTimer = setTimeout(() => {
        finish({ processDeathProven: false });
      }, hardSettleTimeoutMs);
    }, timeoutMs);

    child.once("exit", (code, signal) => {
      if (settled) return;
      clearTimeout(timeoutTimer);
      if (hardSettleTimer != null) clearTimeout(hardSettleTimer);
      terminateBoundedly();
      settleTimer = setTimeout(() => {
        finish({ code, signal, processDeathProven: true });
      }, settleDelayMs);
    });
    child.once("close", (code, signal) => {
      finish({ code, signal, processDeathProven: true });
    });
    child.once("error", error => {
      if (child.pid == null) {
        finish({ error, processDeathProven: true });
        return;
      }
      terminateBoundedly();
      finish({ error, processDeathProven: false });
    });
  });
}
