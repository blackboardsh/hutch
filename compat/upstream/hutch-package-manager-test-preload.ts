import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { setDefaultTimeout } from "bun:test";

const hutchPath = process.env.HUTCH_COMPAT_CLI;
const cottontailPath = process.env.HUTCH_COMPAT_COTTONTAIL ?? process.env.COTTONTAIL_BINARY;

if (!hutchPath) {
  throw new Error("HUTCH_COMPAT_CLI is required by the Hutch package-manager test preload");
}
if (!cottontailPath) {
  throw new Error("HUTCH_COMPAT_COTTONTAIL is required by the Hutch package-manager test preload");
}

const hutchExecutable = realpathSync.native(resolve(hutchPath));
const cottontailExecutable = realpathSync.native(resolve(cottontailPath));
if (hutchExecutable === cottontailExecutable) {
  throw new Error("Hutch child CLI and Cottontail test runtime must be different executables");
}

const preloadKey = Symbol.for("hutch.bunPackageManagerCompatPreload");
const previous = (globalThis as any)[preloadKey];
if (previous && previous !== hutchExecutable) {
  throw new Error(`Hutch package-manager preload already selected a different CLI: ${previous}`);
}

Object.defineProperty(globalThis, preloadKey, {
  configurable: false,
  enumerable: false,
  value: hutchExecutable,
});

// Bun's harness implements bunExe() with process.execPath. Only the outer
// Cottontail test process is rewritten; Hutch receives the original runtime
// path through COTTONTAIL_BINARY and forwards runtime commands to it.
Object.defineProperty(process, "execPath", {
  configurable: true,
  enumerable: true,
  value: hutchExecutable,
  writable: true,
});

process.env.COTTONTAIL_BINARY = cottontailExecutable;
process.env.DASH_COTTONTAIL = cottontailExecutable;

const testTimeout = Number(process.env.HUTCH_COMPAT_TEST_TIMEOUT_MS);
if (Number.isFinite(testTimeout) && testTimeout > 0) {
  setDefaultTimeout(testTimeout);
}
