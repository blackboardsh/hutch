#!/usr/bin/env node

// Repository-local managed hosting checks. The cross-repository installed-app
// lifecycle runs in dash-cloud; these tests need no Cloudflare credentials or JS runner.
import { spawn } from "node:child_process";
import { constants, accessSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repository = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const suffix = process.platform === "win32" ? ".exe" : "";
const binary = resolve(process.env.HUTCH_BINARY || join(repository, "zig-out", "bin", `hutch${suffix}`));
const engine = resolve(process.env.HUTCH_ENGINE_BINARY || join(dirname(binary), `hutch-engine${suffix}`));
const zig = resolve(process.env.ZIG_BINARY || join(repository, "vendors", "zig", `zig${suffix}`));

// Fail before node:test can silently skip its optional native cases. Explicit
// paths also keep the launcher on this checkout's engine rather than a cached release.
for (const [label, path] of [["Hutch launcher", binary], ["Hutch engine", engine], ["Zig", zig]]) {
  try { accessSync(path, constants.X_OK); }
  catch { throw new Error(`${label} is missing or not executable: ${path}. Run bash scripts/build.sh first.`); }
}

const directory = mkdtempSync(join(tmpdir(), "hutch-managed-ci-"));
const env = { ...process.env, HUTCH_BINARY: binary, HUTCH_ENGINE_BINARY: engine,
  HUTCH_HOME: directory, HUTCH_NO_UPDATE_CHECK: "1" };

async function run(command, args) {
  console.log(`Managed hosting checks: ${command} ${args.join(" ")}`);
  const child = spawn(command, args, { cwd: repository, env, stdio: "inherit" });
  const timeout = setTimeout(() => child.kill("SIGKILL"), 10 * 60_000);
  try {
    await new Promise((done, reject) => {
      child.once("error", reject);
      child.once("close", (code, signal) => code === 0 ? done() : reject(new Error(`Managed hosting checks failed (${signal || code}).`)));
    });
  } finally { clearTimeout(timeout); }
}

try {
  await run(zig, ["build", "test:managed-deploys", "test:electrobun-config",
    ...(process.env.HUTCH_MANAGED_TEST_TARGET ? [`-Dtarget=${process.env.HUTCH_MANAGED_TEST_TARGET}`] : []),
    "--test-timeout", "120s", "--summary", "all"]);
  await run(process.execPath, ["--test", "--test-concurrency=1", "tests/electrobun/managed-build-config.test.js", "tests/electrobun/managed-deploy.test.js", "tests/electrobun/managed-native.test.js"]);
} finally {
  rmSync(directory, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
}
