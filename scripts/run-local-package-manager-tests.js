#!/usr/bin/env node

import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { spawnSync } from "node:child_process";
import os from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const hutchRoot = resolve(scriptDir, "..");
const testRoot = join(hutchRoot, "tests", "package-manager");
const executableSuffix = process.platform === "win32" ? ".exe" : "";
const hutch = resolve(
  process.env.HUTCH_LOCAL_TEST_BINARY ??
    join(hutchRoot, "zig-out", "bin", `hutch${executableSuffix}`),
);
const engine = resolve(
  process.env.HUTCH_LOCAL_TEST_ENGINE ??
    join(hutchRoot, "zig-out", "bin", `hutch-engine${executableSuffix}`),
);
const cottontail = resolve(
  process.env.HUTCH_LOCAL_TEST_COTTONTAIL ??
    join(hutchRoot, "..", "..", "cottontail", "zig-out", "bin", `cottontail${executableSuffix}`),
);

const tests = [
  { name: "cli-init", file: "cli-init.test.ts", mode: "test", marker: "5 pass" },
  {
    name: "cli-run-package-scripts",
    file: "cli-run-package-scripts.test.ts",
    mode: "test",
    marker: "3 pass",
  },
  {
    name: "bun-package-manager-link",
    file: "bun-package-manager-link.ts",
    marker: "bun package manager link passed",
  },
  {
    name: "external-file-dependencies",
    file: "package-manager-external-file-dependencies.ts",
    marker: "package manager external file dependencies passed",
  },
  {
    name: "install-edges",
    file: "package-manager-install-edges.cjs",
    passHutch: true,
    marker: "package-manager install edges: pass",
  },
  {
    name: "bunx",
    file: "package-manager-bunx.cjs",
    passHutch: true,
    marker: "package-manager bunx: pass",
    expectedFailure: "Pre-split gap: installed JavaScript bins launch through the system Node shebang instead of the selected runtime.",
  },
  {
    name: "cache-concurrency",
    file: "package-manager-cache-concurrency.cjs",
    passHutch: true,
    marker: "package-manager cache concurrency: pass",
  },
  {
    name: "create",
    file: "package-manager-create.cjs",
    passHutch: true,
    marker: "package-manager create: pass",
    expectedFailure: "Pre-split gap: GitHub template requests do not include the expected bearer authorization header.",
  },
  {
    name: "dist-tag",
    file: "package-manager-dist-tag-native.mjs",
    marker: "package manager native dist-tag test passed",
  },
  {
    name: "isolated-graph",
    file: "package-manager-isolated-graph.cjs",
    passHutch: true,
    marker: "package-manager isolated graph: pass",
    expectedFailure: "Pre-split gap: isolated installs do not create the two expected optional-peer context variants.",
  },
  {
    name: "lockfiles",
    file: "package-manager-lockfiles.cjs",
    passHutch: true,
    marker: "package-manager lockfiles: pass",
  },
  {
    name: "peer-conflict",
    file: "package-manager-peer-conflict.cjs",
    passHutch: true,
    marker: "package-manager peer conflict diagnostics: pass",
  },
  {
    name: "publish",
    file: "package-manager-publish-native.mjs",
    marker: "package manager native publish test passed",
  },
  {
    name: "update-native",
    file: "package-manager-update-native.mjs",
    marker: "package manager native update test passed",
    expectedFailure: "Pre-split gap: adding an npm alias during update preserves a tilde range where Bun normalizes it to a caret.",
  },
  {
    name: "update",
    file: "package-manager-update.cjs",
    passHutch: true,
    marker: "package-manager update: pass",
  },
  {
    name: "workspaces",
    file: "package-manager-workspaces.cjs",
    passHutch: true,
    marker: "package-manager workspaces: pass",
  },
];

function fail(message) {
  console.error(`hutch-local-package-manager-tests: ${message}`);
  process.exit(1);
}

function usage() {
  console.log([
    "Usage: node scripts/run-local-package-manager-tests.js [--all | --test <name>...]",
    "       node scripts/run-local-package-manager-tests.js --list",
    "",
    "Environment:",
    "  HUTCH_LOCAL_TEST_BINARY",
    "  HUTCH_LOCAL_TEST_ENGINE",
    "  HUTCH_LOCAL_TEST_COTTONTAIL",
    "  HUTCH_LOCAL_TEST_TIMEOUT_MS",
  ].join("\n"));
}

function selection(argv) {
  const names = new Set();
  let all = false;
  let list = false;
  const args = [...argv];
  while (args.length > 0) {
    const arg = args.shift();
    if (arg === "--all") all = true;
    else if (arg === "--list") list = true;
    else if (arg === "--test") {
      const name = args.shift();
      if (!name) fail("--test requires a name");
      names.add(name);
    } else if (arg === "--help" || arg === "-h") {
      usage();
      process.exit(0);
    } else {
      fail(`unknown argument: ${arg}`);
    }
  }
  if (!all && names.size === 0 && !list) fail("select --all or at least one --test");
  for (const name of names) {
    if (!tests.some(test => test.name === name)) fail(`unknown test: ${name}`);
  }
  return {
    list,
    tests: all || list ? tests : tests.filter(test => names.has(test.name)),
  };
}

const selected = selection(process.argv.slice(2));
if (selected.list) {
  for (const test of selected.tests) {
    console.log(`${test.expectedFailure ? "expected-failure" : "enabled"}\t${test.name}`);
  }
  process.exit(0);
}

for (const [label, path] of [
  ["Hutch launcher", hutch],
  ["Hutch engine", engine],
  ["Cottontail runtime", cottontail],
]) {
  if (!existsSync(path)) fail(`${label} not found: ${path}`);
}

const scratch = mkdtempSync(join(os.tmpdir(), "hutch-local-package-manager-"));
const timeout = Number(process.env.HUTCH_LOCAL_TEST_TIMEOUT_MS ?? 300_000);
if (!Number.isFinite(timeout) || timeout <= 0) fail("HUTCH_LOCAL_TEST_TIMEOUT_MS must be positive");

const outcomes = {
  passed: 0,
  "expected-failure": 0,
  unexpected: 0,
};
try {
  for (const test of selected.tests) {
    const file = join(testRoot, test.file);
    if (!existsSync(file)) fail(`missing test file: ${file}`);
    const args = test.mode === "test" ? ["test", file] : [file];
    if (test.passHutch) args.push(hutch);
    const result = spawnSync(cottontail, args, {
      cwd: hutchRoot,
      env: {
        ...process.env,
        COTTONTAIL_BIN: hutch,
        COTTONTAIL_BINARY: cottontail,
        COTTONTAIL_CLI_RUN_TEST_ROOT: scratch,
        COTTONTAIL_INIT_TEST_ROOT: scratch,
        COTTONTAIL_SPAWN_ARGV0: hutch,
        COTTONTAIL_SPAWN_EXEC_PATH: hutch,
        COTTONTAIL_TMP_DIR: scratch,
        DASH_COTTONTAIL: cottontail,
        HUTCH_ENGINE_BINARY: engine,
        HUTCH_NO_UPDATE_CHECK: "1",
        NO_COLOR: "1",
      },
      encoding: "utf8",
      timeout,
      maxBuffer: 64 * 1024 * 1024,
    });
    const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;
    const behaviorPassed = !result.error && result.status === 0 && output.includes(test.marker);
    if (behaviorPassed && !test.expectedFailure) {
      outcomes.passed += 1;
      console.log(`ok ${test.name}`);
      continue;
    }
    if (!behaviorPassed && test.expectedFailure) {
      outcomes["expected-failure"] += 1;
      console.log(`xfail ${test.name}: ${test.expectedFailure}`);
      continue;
    }

    outcomes.unexpected += 1;
    console.error(`${behaviorPassed ? "XPASS" : "FAIL"} ${test.name}`);
    if (result.error) console.error(result.error.stack ?? result.error.message);
    if (result.stdout) console.error(`stdout:\n${result.stdout}`);
    if (result.stderr) console.error(`stderr:\n${result.stderr}`);
  }
} finally {
  rmSync(scratch, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
}

console.log(
  `local package-manager files: ${selected.tests.length}; passed: ${outcomes.passed}; ` +
  `expected failures: ${outcomes["expected-failure"]}; unexpected: ${outcomes.unexpected}`,
);
if (outcomes.unexpected > 0) process.exitCode = 1;
