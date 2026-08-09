#!/usr/bin/env node

import {
  constants as fsConstants,
  cpSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import os from "node:os";
import { dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

import {
  createHarnessDependencyCacheIdentity,
  createHarnessDependencyStagingRoot,
  findValidHarnessDependencyGeneration,
  harnessDependencyInstallErrors,
  normalizeHarnessDependencyBinShims,
  publishHarnessDependencyGeneration,
  readHarnessDependencyPlan,
} from "./bun-harness-dependencies.js";
import { waitForChildCompletion } from "./bun-compat-child-lifecycle.js";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const hutchRoot = resolve(scriptDir, "..");
const suiteRoot = join(hutchRoot, "compat", "upstream", "bun", "v1.3.10");
const manifestPath = join(suiteRoot, "manifest.json");
const statusPath = join(suiteRoot, "status.json");
const ownershipPath = join(hutchRoot, "compat", "bun-v1.3.10-ownership.json");
const harnessDependencyCacheRoot = resolve(
  process.env.HUTCH_COMPAT_HARNESS_CACHE_DIR ??
  join(os.tmpdir(), "hutch-js-deps"),
);
const harnessDependencySourceRoot = join(
  hutchRoot,
  "compat",
  "harness-dependencies",
  "bun-v1.3.10",
);
const runnablePattern = /\.test\.(?:js|mjs|cjs|ts|tsx|mts|cts)$/i;
const canonicalRunnableCount = 1_445;
const expectedOwnedCount = 103;
const nextPagesFixtureRoot = "test/integration/next-pages";
const nextPagesGeneratedCounter = "src/Counter.tsx";
const executableSuffix = process.platform === "win32" ? ".exe" : "";
const defaultHutchBinary = join(hutchRoot, "zig-out", "bin", `hutch${executableSuffix}`);
const defaultHutchEngine = join(hutchRoot, "zig-out", "bin", `hutch-engine${executableSuffix}`);
const defaultCottontailBinary = resolve(
  hutchRoot,
  "..",
  "cottontail",
  "zig-out",
  "bin",
  `cottontail${executableSuffix}`,
);
const defaultJobs = Math.max(1, Math.min(4, os.availableParallelism?.() ?? os.cpus().length));
const maxOutputBytes = Number(process.env.HUTCH_COMPAT_MAX_OUTPUT_BYTES ?? 64 * 1024 * 1024);
const perTestTimeoutMs = Number(process.env.HUTCH_COMPAT_TEST_TIMEOUT_MS ?? 15_000);
const childTreeSettleDelayMs = process.platform === "win32" ? 1_000 : 250;
const childHardSettleTimeoutMs = 5_000;
const windowsTaskkillTimeoutMs = 10_000;
const cleanupOptions = {
  recursive: true,
  force: true,
  maxRetries: 10,
  retryDelay: 100,
};
const activeChildren = new Set();
const unprovenDeathTempRoots = new Set();

function fail(message) {
  console.error(`hutch-package-manager-compat: ${message}`);
  process.exit(1);
}

function removeRunnerOwnedPath(path) {
  try {
    rmSync(path, cleanupOptions);
    return true;
  } catch (error) {
    console.error(
      `hutch-package-manager-compat: warning: could not remove runner-owned ${path}: ` +
      `${error.message}`,
    );
    return false;
  }
}

if (!Number.isFinite(perTestTimeoutMs) || perTestTimeoutMs < 1) {
  fail("HUTCH_COMPAT_TEST_TIMEOUT_MS must be a positive number");
}

function usage() {
  console.log([
    "Usage: node scripts/run-bun-package-manager-tests.js [options]",
    "",
    "Selection (required for execution):",
    "  --test <path>       Run one owned canonical test path. May be repeated.",
    "  --match <regexp>    Run owned paths matching a regular expression.",
    "  --all               Run the complete Hutch-owned JavaScript compatibility suite.",
    "",
    "Inspection:",
    "  --list              List selected tests without running them.",
    "  --check             Validate copied files and the 1,445-file ownership index.",
    "",
    "Execution:",
    "  --hutch <path>      Hutch child CLI (default: zig-out/bin/hutch).",
    "  --engine <path>     Hutch engine used by copied launchers.",
    "  --runtime <path>    Cottontail JS test runtime (default: sibling checkout).",
    "  --jobs <n>          Parallel file workers (default: up to 4).",
    "  --max-tests <n>     Bound the selected file count.",
    "  --keep-temp         Preserve the runner-owned temporary directory.",
    "",
    "Environment equivalents:",
    "  HUTCH_COMPAT_BINARY, HUTCH_COMPAT_ENGINE, HUTCH_COMPAT_COTTONTAIL,",
    "  COTTONTAIL_BINARY, HUTCH_COMPAT_HARNESS_CACHE_DIR,",
    "  HUTCH_COMPAT_TEST_TIMEOUT_MS",
  ].join("\n"));
}

function parseArgs(argv) {
  const options = {
    all: false,
    check: false,
    engine: process.env.HUTCH_COMPAT_ENGINE ?? defaultHutchEngine,
    hutch: process.env.HUTCH_COMPAT_BINARY ?? defaultHutchBinary,
    jobs: defaultJobs,
    keepTemp: process.env.HUTCH_COMPAT_KEEP_TEMP === "1",
    list: false,
    match: null,
    maxTests: Infinity,
    runtime:
      process.env.HUTCH_COMPAT_COTTONTAIL ??
      process.env.COTTONTAIL_BINARY ??
      defaultCottontailBinary,
    tests: [],
  };
  const args = [...argv];
  while (args.length > 0) {
    const arg = args.shift();
    if (arg === "--all") {
      options.all = true;
    } else if (arg === "--check") {
      options.check = true;
    } else if (arg === "--hutch") {
      options.hutch = args.shift() ?? fail("--hutch requires a path");
    } else if (arg === "--engine") {
      options.engine = args.shift() ?? fail("--engine requires a path");
    } else if (arg === "--jobs") {
      const value = Number(args.shift() ?? fail("--jobs requires a number"));
      if (!Number.isInteger(value) || value < 1) fail("--jobs requires a positive integer");
      options.jobs = value;
    } else if (arg === "--keep-temp") {
      options.keepTemp = true;
    } else if (arg === "--list") {
      options.list = true;
    } else if (arg === "--match") {
      const value = args.shift() ?? fail("--match requires a regular expression");
      try {
        options.match = new RegExp(value);
      } catch (error) {
        fail(`invalid --match expression: ${error.message}`);
      }
    } else if (arg === "--max-tests") {
      const value = Number(args.shift() ?? fail("--max-tests requires a number"));
      if (!Number.isInteger(value) || value < 1) fail("--max-tests requires a positive integer");
      options.maxTests = value;
    } else if (arg === "--runtime") {
      options.runtime = args.shift() ?? fail("--runtime requires a path");
    } else if (arg === "--test") {
      options.tests.push(args.shift() ?? fail("--test requires a canonical path"));
    } else if (arg === "--help" || arg === "-h") {
      usage();
      process.exit(0);
    } else {
      fail(`unknown option: ${arg}`);
    }
  }
  options.engine = resolve(options.engine);
  options.hutch = resolve(options.hutch);
  options.runtime = resolve(options.runtime);
  return options;
}

function readJson(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

function loadHarnessDependencyPlan() {
  try {
    return readHarnessDependencyPlan(
      harnessDependencySourceRoot,
      join(suiteRoot, "test", "package.json"),
    );
  } catch (error) {
    fail(error.message);
  }
}

function toPosix(path) {
  return path.split(sep).join("/");
}

function discoverRunnableFiles(root) {
  const testRoot = join(root, "test");
  const result = [];
  const stack = [testRoot];
  while (stack.length > 0) {
    const current = stack.pop();
    for (const entry of readdirSync(current, { withFileTypes: true })) {
      const path = join(current, entry.name);
      if (entry.isDirectory() && entry.name === "node_modules") continue;
      if (entry.isDirectory() && !entry.isSymbolicLink()) {
        stack.push(path);
      } else if (entry.isFile() && runnablePattern.test(entry.name)) {
        result.push(toPosix(relative(root, path)));
      }
    }
  }
  return result.sort();
}

function listSnapshotFiles(root) {
  const files = [];
  const stack = [root];
  while (stack.length > 0) {
    const current = stack.pop();
    for (const entry of readdirSync(current, { withFileTypes: true })) {
      if (entry.name === "node_modules") {
        fail(`copied snapshot contains forbidden node_modules: ${relative(hutchRoot, join(current, entry.name))}`);
      }
      if (entry.isDirectory() && !entry.isSymbolicLink()) {
        stack.push(join(current, entry.name));
      } else {
        files.push(toPosix(relative(root, join(current, entry.name))));
      }
    }
  }
  return files.sort();
}

function countSnapshotFiles(root) {
  return listSnapshotFiles(root).length;
}

function sha256(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function removeGeneratedSuiteArtifacts() {
  if (!existsSync(suiteRoot)) return;
  const stack = [suiteRoot];
  while (stack.length > 0) {
    const current = stack.pop();
    for (const entry of readdirSync(current, { withFileTypes: true })) {
      const path = join(current, entry.name);
      const generated =
        entry.name === ".cottontail-tmp" ||
        entry.name === ".cottontail-compile-cache" ||
        entry.name === ".verdaccio-db.json" ||
        entry.name.startsWith(".cottontail-eval-") ||
        entry.name.startsWith(".cottontail-compat-") ||
        entry.name.startsWith("fstest");
      if (generated) {
        removeRunnerOwnedPath(path);
      } else if (entry.isDirectory() && !entry.isSymbolicLink()) {
        stack.push(path);
      }
    }
  }
}

function validateSuite() {
  loadHarnessDependencyPlan();
  for (const path of [manifestPath, statusPath, ownershipPath]) {
    if (!existsSync(path)) fail(`missing ${relative(hutchRoot, path)}`);
  }
  const manifest = readJson(manifestPath);
  const status = readJson(statusPath);
  const ownership = readJson(ownershipPath);
  const copiedTests = discoverRunnableFiles(suiteRoot);
  const manifestTests = (manifest.testFiles ?? []).map(entry => entry.path).sort();
  const ownershipTests = ownership.tests ?? [];
  const ownedFromIndex = ownershipTests
    .filter(entry => entry.owner === "hutch-package-manager")
    .map(entry => entry.path)
    .sort();
  const canonicalPaths = new Set(ownershipTests.map(entry => entry.path));

  if (
    manifest.canonicalRunnableFiles !== canonicalRunnableCount ||
    ownership.canonicalRunnableFiles !== canonicalRunnableCount
  ) {
    fail(`expected the ${canonicalRunnableCount}-file canonical Bun inventory`);
  }
  if (
    manifest.ownedRunnableFiles !== expectedOwnedCount ||
    ownership.ownerCounts?.["hutch-package-manager"] !== expectedOwnedCount
  ) {
    fail(`expected exactly ${expectedOwnedCount} Hutch-owned runnable files`);
  }

  if (canonicalPaths.size !== ownershipTests.length) {
    fail("ownership index contains duplicate canonical paths");
  }
  if (ownershipTests.length !== ownership.canonicalRunnableFiles) {
    fail(
      `ownership total mismatch: ${ownershipTests.length} entries, ` +
      `${ownership.canonicalRunnableFiles} declared`,
    );
  }
  if (ownership.canonicalRunnableFiles !== manifest.canonicalRunnableFiles) {
    fail("suite and ownership manifests disagree on the canonical denominator");
  }
  if (copiedTests.length !== manifest.ownedRunnableFiles) {
    fail(`copied test count mismatch: ${copiedTests.length} !== ${manifest.ownedRunnableFiles}`);
  }
  const copiedFiles = countSnapshotFiles(suiteRoot);
  if (copiedFiles !== manifest.copiedFiles) {
    fail(`copied file count mismatch: ${copiedFiles} !== ${manifest.copiedFiles}`);
  }

  if (manifest.fixtureTrees?.length !== 1) {
    fail("manifest must describe the one copied Next Pages fixture tree");
  }
  const nextPagesFixture = manifest.fixtureTrees[0];
  if (nextPagesFixture.path !== nextPagesFixtureRoot) {
    fail(`unexpected fixture tree: ${String(nextPagesFixture.path)}`);
  }
  const nextPagesRoot = join(suiteRoot, nextPagesFixtureRoot);
  const fixtureFiles = listSnapshotFiles(nextPagesRoot);
  const fixtureRecords = nextPagesFixture.files ?? [];
  const recordedFixtureFiles = fixtureRecords.map(entry => entry.path).sort();
  if (
    nextPagesFixture.copiedFiles !== 28 ||
    fixtureFiles.length !== 28 ||
    recordedFixtureFiles.length !== 28 ||
    fixtureFiles.some((path, index) => path !== recordedFixtureFiles[index])
  ) {
    fail("Next Pages fixture must contain exactly its 28 canonical tracked files");
  }
  const generatedCounter = nextPagesFixture.generatedAtRuntime?.[0];
  if (
    nextPagesFixture.generatedAtRuntime?.length !== 1 ||
    generatedCounter?.path !== nextPagesGeneratedCounter ||
    generatedCounter?.source !== "src/Counter1.txt"
  ) {
    fail("Next Pages fixture must declare its ignored runtime-generated Counter.tsx");
  }
  if (existsSync(join(nextPagesRoot, nextPagesGeneratedCounter))) {
    fail("Next Pages fixture contains runtime-generated src/Counter.tsx");
  }
  if (!existsSync(join(nextPagesRoot, generatedCounter.source))) {
    fail("Next Pages fixture is missing the Counter.tsx source template");
  }
  for (const record of fixtureRecords) {
    if (!record.sha256 || sha256(join(nextPagesRoot, record.path)) !== record.sha256) {
      fail(`Next Pages fixture hash does not match the manifest: ${record.path}`);
    }
  }
  for (const [label, paths] of [
    ["manifest", manifestTests],
    ["ownership index", ownedFromIndex],
  ]) {
    if (
      paths.length !== copiedTests.length ||
      paths.some((path, index) => path !== copiedTests[index])
    ) {
      fail(`${label} does not exactly match the copied runnable inventory`);
    }
  }
  for (const path of copiedTests) {
    if (!status.tests?.[path]) fail(`missing status entry: ${path}`);
    if (!["enabled", "expected-failure"].includes(status.tests[path].status)) {
      fail(`unsupported status for ${path}: ${status.tests[path].status}`);
    }
    const invocationArgs = testInvocationArgs({ path, ...status.tests[path] }, "<preload>");
    const invocationTimeouts = invocationArgs.filter(arg => arg.startsWith("--timeout="));
    if (invocationTimeouts.length !== 1) {
      fail(`expected exactly one effective test timeout for ${path}`);
    }
    if (path.startsWith(`${nextPagesFixtureRoot}/test/`)) {
      const innerTimeoutMs = Number(invocationTimeouts[0].slice("--timeout=".length));
      const outerTimeoutMs = Number(status.tests[path].timeoutMs);
      if (!Number.isFinite(outerTimeoutMs) || outerTimeoutMs - innerTimeoutMs < 60_000) {
        fail(`Next Pages outer timeout must exceed its inner timeout by at least 60000ms: ${path}`);
      }
    }
  }
  const statusCounts = copiedTests.reduce((counts, path) => {
    const value = status.tests[path].status;
    counts[value] = (counts[value] ?? 0) + 1;
    return counts;
  }, {});
  for (const value of ["enabled", "expected-failure"]) {
    if ((manifest.statusCounts?.[value] ?? 0) !== (statusCounts[value] ?? 0)) {
      fail(
        `manifest status count mismatch for ${value}: ` +
        `${manifest.statusCounts?.[value] ?? 0} !== ${statusCounts[value] ?? 0}`,
      );
    }
  }
  const manifestRecordByPath = new Map(
    (manifest.testFiles ?? []).map(entry => [entry.path, entry]),
  );
  for (const path of copiedTests) {
    const record = manifestRecordByPath.get(path);
    if (record?.status !== status.tests[path].status) {
      fail(`manifest status is stale for ${path}`);
    }
    if (!record.sha256 || sha256(join(suiteRoot, path)) !== record.sha256) {
      fail(`copied test hash does not match the manifest: ${path}`);
    }
  }

  const ownerCounts = ownershipTests.reduce((counts, entry) => {
    counts[entry.owner] = (counts[entry.owner] ?? 0) + 1;
    return counts;
  }, {});
  for (const [owner, expected] of Object.entries(ownership.ownerCounts ?? {})) {
    if (ownerCounts[owner] !== expected) {
      fail(`ownership count mismatch for ${owner}: ${ownerCounts[owner]} !== ${expected}`);
    }
  }

  return { manifest, status, ownership, copiedTests };
}

function selectedEntries(validated, options) {
  const requested = new Set(options.tests);
  for (const path of requested) {
    if (!validated.copiedTests.includes(path)) fail(`test is not owned by Hutch: ${path}`);
  }

  let paths = validated.copiedTests;
  if (!options.all) {
    paths = paths.filter(path => requested.has(path) || options.match?.test(path));
  }
  paths = paths.slice(0, options.maxTests);
  return paths.map(path => ({
    path,
    ...validated.status.tests[path],
  }));
}

function preflightBinary(path, label, args, environment = process.env) {
  if (!existsSync(path)) fail(`${label} not found: ${path}`);
  if (!statSync(path).isFile()) fail(`${label} is not a file: ${path}`);
  const result = spawnSync(path, args, {
    cwd: hutchRoot,
    env: environment,
    encoding: "utf8",
    timeout: 15_000,
    maxBuffer: 1024 * 1024,
  });
  if (result.error) fail(`${label} failed to start: ${result.error.message}`);
  if (result.status !== 0) {
    fail(
      `${label} preflight exited ${result.status ?? 1}\n` +
      [result.stdout, result.stderr].filter(Boolean).join("\n"),
    );
  }
  return result;
}

function preflight(options) {
  const runtime = preflightBinary(options.runtime, "Cottontail runtime", [
    "-e",
    'console.log("HUTCH_COTTONTAIL_PREFLIGHT:" + JSON.stringify({ version: process.versions?.cottontail, execPath: process.execPath }))',
  ]);
  const identityLine = String(runtime.stdout)
    .split(/\r?\n/)
    .find(line => line.startsWith("HUTCH_COTTONTAIL_PREFLIGHT:"));
  if (!identityLine) fail("Cottontail runtime preflight did not emit an identity record");
  let identity;
  try {
    identity = JSON.parse(identityLine.slice("HUTCH_COTTONTAIL_PREFLIGHT:".length));
  } catch (error) {
    fail(`Cottontail runtime preflight emitted invalid JSON: ${error.message}`);
  }
  if (typeof identity.version !== "string" || identity.version.length === 0) {
    fail("configured test runtime is not Cottontail");
  }
  if (!existsSync(options.engine) || !statSync(options.engine).isFile()) {
    fail(`Hutch engine not found: ${options.engine}`);
  }
  preflightBinary(options.hutch, "Hutch CLI", ["--version"], {
    ...process.env,
    HUTCH_ENGINE_BINARY: options.engine,
  });
  if (options.runtime === options.hutch) {
    fail("Hutch child CLI and Cottontail test runtime must be distinct executables");
  }

  const preloadPath = join(
    hutchRoot,
    "compat",
    "upstream",
    "hutch-package-manager-test-preload.ts",
  );
  const preload = preflightBinary(
    options.runtime,
    "Hutch package-manager preload",
    [
      "--preload",
      preloadPath,
      "-e",
      'console.log("HUTCH_CHILD_CLI_PREFLIGHT:" + process.execPath)',
    ],
    {
      ...process.env,
      COTTONTAIL_BINARY: options.runtime,
      DASH_COTTONTAIL: options.runtime,
      HUTCH_COMPAT_CLI: options.hutch,
      HUTCH_COMPAT_COTTONTAIL: options.runtime,
      HUTCH_ENGINE_BINARY: options.engine,
    },
  );
  const childCliLine = String(preload.stdout)
    .split(/\r?\n/)
    .find(line => line.startsWith("HUTCH_CHILD_CLI_PREFLIGHT:"));
  if (!childCliLine) fail("Hutch package-manager preload did not emit its identity record");
  const selectedChildCli = resolve(childCliLine.slice("HUTCH_CHILD_CLI_PREFLIGHT:".length));
  if (selectedChildCli !== options.hutch) {
    fail(`preload selected ${selectedChildCli} instead of ${options.hutch}`);
  }
}

function prepareHarnessDependencies(options) {
  const plan = loadHarnessDependencyPlan();
  const identity = createHarnessDependencyCacheIdentity();
  const cachedRoot = findValidHarnessDependencyGeneration(
    harnessDependencyCacheRoot,
    plan,
    identity,
  );
  if (cachedRoot) return cachedRoot;

  const stagingRoot = createHarnessDependencyStagingRoot(
    harnessDependencyCacheRoot,
    plan,
    identity,
  );
  let failureMessage = null;
  let published = null;
  try {
    writeFileSync(join(stagingRoot, "package.json"), plan.packageBytes);
    writeFileSync(join(stagingRoot, "bun.lock"), plan.lockBytes);

    console.log(`  installing frozen Bun test-harness dependencies (${plan.fingerprint.slice(0, 12)})...`);
    const result = spawnSync(
      options.hutch,
      [
        "install",
        "--cwd",
        stagingRoot,
        "--ignore-scripts",
        "--frozen-lockfile",
      ],
      {
        cwd: hutchRoot,
        env: {
          ...process.env,
          COTTONTAIL_BINARY: options.runtime,
          DASH_COTTONTAIL: options.runtime,
          HUTCH_ENGINE_BINARY: options.engine,
          HUTCH_NO_UPDATE_CHECK: "1",
        },
        encoding: "utf8",
        timeout: 10 * 60_000,
        maxBuffer: 64 * 1024 * 1024,
      },
    );
    if (result.error) {
      failureMessage = `could not install test-harness dependencies: ${result.error.message}`;
    } else {
      normalizeHarnessDependencyBinShims(stagingRoot, plan);
      const installErrors = harnessDependencyInstallErrors(stagingRoot, plan);
      if (result.status !== 0 || installErrors.length > 0) {
        failureMessage =
          `could not install test-harness dependencies (exit ${result.status ?? 1})\n` +
          [result.stdout, result.stderr, ...installErrors].filter(Boolean).join("\n");
      }
    }
    if (!failureMessage) {
      published = publishHarnessDependencyGeneration(
        stagingRoot,
        harnessDependencyCacheRoot,
        plan,
        identity,
      );
    }
  } catch (error) {
    failureMessage = `could not prepare immutable test-harness dependencies: ${error.message}`;
  } finally {
    // A successful publish moves stagingRoot. On every failure, remove only this
    // process's private staging directory, never a published cache generation.
    if (existsSync(stagingRoot)) removeRunnerOwnedPath(stagingRoot);
  }
  if (failureMessage) fail(failureMessage);
  if (published.reused) {
    console.log("  reused the immutable dependency generation published by another run");
  }
  return published.installRoot;
}

function killProcessTree(child) {
  if (!child.pid) return;
  if (process.platform === "win32") {
    // taskkill /t is best-effort rather than Job Object containment. Waiting for
    // it, then delaying temp removal, gives Chromium/server descendants a bounded
    // opportunity to exit and release files even after their direct parent exits.
    spawnSync("taskkill", ["/pid", String(child.pid), "/t", "/f"], {
      stdio: "ignore",
      timeout: windowsTaskkillTimeoutMs,
      windowsHide: true,
    });
    return;
  }
  try {
    process.kill(-child.pid, "SIGKILL");
  } catch {
    try {
      child.kill("SIGKILL");
    } catch {}
  }
}

function prepareExecutionSuite(tempRoot, harnessDependencyInstallRoot) {
  const executionSuiteRoot = join(tempRoot, "suite");
  cpSync(suiteRoot, executionSuiteRoot, {
    recursive: true,
    dereference: false,
    preserveTimestamps: true,
  });

  const preloadPath = join(
    hutchRoot,
    "compat",
    "upstream",
    "hutch-package-manager-test-preload.ts",
  );
  writeFileSync(
    join(executionSuiteRoot, "test", "bunfig.toml"),
    [
      "[test]",
      `preload = ["./preload.ts", ${JSON.stringify(preloadPath)}]`,
      "",
      "[install]",
      'linker = "isolated"',
      "",
    ].join("\n"),
  );
  // The cache is only a source for this private materialization. Reflink when
  // supported and copy otherwise, so cache cleanup cannot break an active run.
  cpSync(
    join(harnessDependencyInstallRoot, "node_modules"),
    join(executionSuiteRoot, "test", "node_modules"),
    {
      recursive: true,
      dereference: false,
      mode: fsConstants.COPYFILE_FICLONE,
      verbatimSymlinks: true,
    },
  );
  applyHermeticExecutionOverrides(executionSuiteRoot);
  return executionSuiteRoot;
}

function applyHermeticExecutionOverrides(executionSuiteRoot) {
  const bunxPath = join(executionSuiteRoot, "test", "cli", "install", "bunx.test.ts");
  const source = readFileSync(bunxPath, "utf8");
  const liveSpecifier = "@angular/cli@latest";
  const pinnedSpecifier = "@angular/cli@21.2.19";
  const occurrences = source.split(liveSpecifier).length - 1;
  if (occurrences !== 1) {
    fail(`expected one ${liveSpecifier} occurrence in the copied bunx test, found ${occurrences}`);
  }
  writeFileSync(bunxPath, source.replace(liveSpecifier, pinnedSpecifier));
}

function testInvocationArgs(entry, preloadPath) {
  const entryArgs = (entry.args ?? []).map(String);
  const argsWithoutTimeout = [];
  let timeoutMs = null;
  for (let index = 0; index < entryArgs.length; index += 1) {
    const arg = entryArgs[index];
    let timeoutValue = null;
    if (arg === "--timeout") {
      timeoutValue = entryArgs[index + 1];
      index += 1;
    } else if (arg.startsWith("--timeout=")) {
      timeoutValue = arg.slice("--timeout=".length);
    } else {
      argsWithoutTimeout.push(arg);
      continue;
    }

    const parsedTimeout = Number(timeoutValue);
    if (!Number.isInteger(parsedTimeout) || parsedTimeout < 1) {
      fail(`invalid test timeout for ${entry.path}: ${String(timeoutValue)}`);
    }
    if (timeoutMs != null) fail(`multiple test timeouts configured for ${entry.path}`);
    timeoutMs = parsedTimeout;
  }

  return [
    "--preload",
    preloadPath,
    "test",
    `--timeout=${timeoutMs ?? perTestTimeoutMs}`,
    entry.path,
    ...argsWithoutTimeout,
  ];
}

function runEntry(entry, options, tempRoot, executionSuiteRoot) {
  const timeout = Number(entry.timeoutMs ?? 30_000);
  if (!Number.isFinite(timeout) || timeout <= 0) {
    fail(`invalid outer timeout for ${entry.path}: ${String(entry.timeoutMs)}`);
  }
  const runTemp = mkdtempSync(join(tempRoot, "run-"));
  const preloadPath = join(
    hutchRoot,
    "compat",
    "upstream",
    "hutch-package-manager-test-preload.ts",
  );
  const childEnv = { ...process.env };
  delete childEnv.NODE_OPTIONS;
  delete childEnv.BUN_OPTIONS;
  delete childEnv.NODE_PATH;
  Object.assign(childEnv, {
    ...(entry.env ?? {}),
    BUN_TMPDIR: runTemp,
    COTTONTAIL_BINARY: options.runtime,
    COTTONTAIL_TMP_DIR: runTemp,
    COTTONTAIL_UPSTREAM_RUNTIME: "bun",
    COTTONTAIL_UPSTREAM_TEMP_OWNER: "launcher",
    COTTONTAIL_UPSTREAM_VERSION: "1.3.10",
    DASH_COTTONTAIL: options.runtime,
    HUTCH_COMPAT_CLI: options.hutch,
    HUTCH_COMPAT_COTTONTAIL: options.runtime,
    HUTCH_COMPAT_TEST_TIMEOUT_MS: String(perTestTimeoutMs),
    HUTCH_BUN_COMPAT: "1",
    HUTCH_ENGINE_BINARY: options.engine,
    TEMP: runTemp,
    TEST_TMPDIR: runTemp,
    TMP: runTemp,
    TMPDIR: runTemp,
    TZ: process.env.HUTCH_COMPAT_TZ ?? "Etc/UTC",
  });

  const args = testInvocationArgs(entry, preloadPath);
  const child = spawn(options.runtime, args, {
    cwd: executionSuiteRoot,
    env: childEnv,
    detached: process.platform !== "win32",
  });
  activeChildren.add(child);
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", chunk => {
    if (stdout.length < maxOutputBytes) stdout += chunk;
  });
  child.stderr.on("data", chunk => {
    if (stderr.length < maxOutputBytes) stderr += chunk;
  });

  return waitForChildCompletion(child, {
    timeoutMs: timeout,
    hardSettleTimeoutMs: childHardSettleTimeoutMs,
    settleDelayMs: childTreeSettleDelayMs,
    terminate: killProcessTree,
  }).then(result => {
    activeChildren.delete(child);
    if (result.processDeathProven) {
      if (!options.keepTemp) removeRunnerOwnedPath(runTemp);
    } else {
      unprovenDeathTempRoots.add(tempRoot);
    }
    return {
      ...result,
      stdout,
      stderr,
      ...(!result.processDeathProven ? { retainedTempRoot: tempRoot } : {}),
    };
  });
}

function capturedDiagnostics(result) {
  return [
    result.stdout ? `stdout:\n${result.stdout}` : "",
    result.stderr ? `stderr:\n${result.stderr}` : "",
    result.teardownError ? `process teardown error: ${result.teardownError.message}` : "",
    result.retainedTempRoot
      ? `retained temp root because process death was not observed: ${result.retainedTempRoot}`
      : "",
  ].filter(Boolean).join("\n");
}

function classify(entry, result) {
  if (result.teardownIncomplete) {
    return {
      ok: false,
      outcome: "unexpected-failure",
      message: `FAIL ${entry.path} process teardown did not complete`,
      diagnostics: capturedDiagnostics(result),
    };
  }
  if (result.error) {
    return {
      ok: false,
      outcome: "unexpected-failure",
      message: `FAIL ${entry.path} failed to start: ${result.error.message}`,
      diagnostics: capturedDiagnostics(result),
    };
  }
  if (result.timedOut) {
    return {
      ok: entry.status === "expected-failure",
      outcome: entry.status === "expected-failure" ? "expected-failure" : "unexpected-failure",
      message: `${entry.status === "expected-failure" ? "xfail" : "FAIL"} ${entry.path} timed out`,
      diagnostics: capturedDiagnostics(result),
    };
  }
  const shouldFail = entry.status === "expected-failure";
  const passed = result.code === 0;
  const ok = shouldFail ? !passed : passed;
  if (ok) {
    return {
      ok: true,
      outcome: shouldFail ? "expected-failure" : "passed",
      message: `${shouldFail ? "xfail" : "ok"} ${entry.path}`,
    };
  }
  return {
    ok: false,
    outcome: shouldFail ? "unexpected-pass" : "unexpected-failure",
    message: `${shouldFail ? "XPASS" : "FAIL"} ${entry.path} exited ${result.code ?? 1}`,
    diagnostics: capturedDiagnostics(result),
  };
}

async function runEntries(entries, options, tempRoot, executionSuiteRoot) {
  const outcomeCounts = {
    passed: 0,
    "expected-failure": 0,
    "unexpected-pass": 0,
    "unexpected-failure": 0,
  };
  let started = 0;
  let completed = 0;
  const serialIndexes = new Set();
  entries.forEach((entry, index) => {
    if (entry.serial === true) serialIndexes.add(index);
  });

  const runOne = async entry => {
    started += 1;
    console.log(
      `START [${started}/${entries.length}; running ${started - completed}] ${entry.path}`,
    );
    const result = classify(
      entry,
      await runEntry(entry, options, tempRoot, executionSuiteRoot),
    );
    outcomeCounts[result.outcome] += 1;
    completed += 1;
    const unexpected = outcomeCounts["unexpected-pass"] + outcomeCounts["unexpected-failure"];
    console.log(
      `DONE [${completed}/${entries.length}; running ${started - completed}] ${result.message}`,
    );
    console.log(
      `  progress: passed ${outcomeCounts.passed}; ` +
      `expected failures ${outcomeCounts["expected-failure"]}; unexpected ${unexpected}`,
    );
    if (result.diagnostics) console.log(result.diagnostics);
  };

  const queue = entries
    .map((entry, index) => ({ entry, index }))
    .filter(item => !serialIndexes.has(item.index));
  let cursor = 0;
  const worker = async () => {
    for (;;) {
      const item = queue[cursor++];
      if (!item) return;
      await runOne(item.entry);
    }
  };
  await Promise.all(Array.from({ length: Math.min(options.jobs, queue.length) || 1 }, worker));

  for (const index of serialIndexes) {
    await runOne(entries[index]);
  }
  return outcomeCounts;
}

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    for (const child of activeChildren) killProcessTree(child);
    process.exit(signal === "SIGINT" ? 130 : 143);
  });
}

const options = parseArgs(process.argv.slice(2));
if (!options.keepTemp) removeGeneratedSuiteArtifacts();
const validated = validateSuite();
const entries = selectedEntries(validated, options);
console.log(
  `Hutch Bun package-manager compatibility: ${validated.manifest.ownedRunnableFiles}/` +
  `${validated.manifest.canonicalRunnableFiles} canonical files owned by Hutch`,
);
console.log(
  `  remaining Cottontail runtime ownership: ` +
  `${validated.ownership.ownerCounts["cottontail-runtime"]}`,
);
const statusCounts = validated.copiedTests.reduce((counts, path) => {
  const status = validated.status.tests[path].status;
  counts[status] = (counts[status] ?? 0) + 1;
  return counts;
}, {});
console.log(
  `  owned status: ${statusCounts.enabled ?? 0} enabled, ` +
  `${statusCounts["expected-failure"] ?? 0} expected failure`,
);

if (options.check) {
  console.log("  ownership and copied-inventory checks passed");
  process.exit(0);
}

if (options.list) {
  console.log(`  selected: ${entries.length}`);
  for (const entry of entries) console.log(`    ${entry.status}\t${entry.path}`);
  process.exit(0);
}

if (!options.all && options.tests.length === 0 && options.match == null) {
  usage();
  fail("execution requires --test, --match, or --all");
}
if (entries.length === 0) fail("no owned tests matched the requested selection");

preflight(options);
const harnessDependencyInstallRoot = prepareHarnessDependencies(options);
const tempRoot = mkdtempSync(join(os.tmpdir(), "hutch-package-manager-compat-"));
try {
  const executionSuiteRoot = prepareExecutionSuite(tempRoot, harnessDependencyInstallRoot);
  const outcomeCounts = await runEntries(entries, options, tempRoot, executionSuiteRoot);
  const unexpected = outcomeCounts["unexpected-pass"] + outcomeCounts["unexpected-failure"];
  console.log(
    `  files: ${entries.length}; passed: ${outcomeCounts.passed}; ` +
    `expected failures: ${outcomeCounts["expected-failure"]}; unexpected: ${unexpected}`,
  );
  if (unexpected > 0) process.exitCode = 1;
} finally {
  if (options.keepTemp || unprovenDeathTempRoots.has(tempRoot)) {
    const reason = unprovenDeathTempRoots.has(tempRoot)
      ? " because at least one child process death was not observed"
      : "";
    console.error(`kept Hutch compatibility temp root${reason}: ${tempRoot}`);
  } else {
    removeRunnerOwnedPath(tempRoot);
    removeGeneratedSuiteArtifacts();
  }
}
