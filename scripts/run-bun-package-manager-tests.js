#!/usr/bin/env node

import {
  constants as fsConstants,
  cpSync,
  existsSync,
  lstatSync,
  mkdtempSync,
  readFileSync,
  readlinkSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import os from "node:os";
import { dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { isDeepStrictEqual } from "node:util";

import {
  createHarnessDependencyCacheIdentity,
  createHarnessDependencyStagingRoot,
  findValidHarnessDependencyGeneration,
  harnessDependencyGenerationIdentity,
  harnessDependencyInstallErrors,
  harnessDependencyTreeIdentity,
  normalizeHarnessDependencyBinShims,
  publishHarnessDependencyGeneration,
  readHarnessDependencyPlan,
} from "./bun-harness-dependencies.js";
import {
  startWindowsJobChild,
  startWindowsJobTermination,
  waitForChildCompletion,
} from "./bun-compat-child-lifecycle.js";
import { HutchCompatReporter } from "./bun-compat-reporter.js";
import {
  createTestInvocation,
  readGitHeadCommit,
} from "./bun-compat-runner-contract.js";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const hutchRoot = resolve(scriptDir, "..");
const suiteRoot = join(hutchRoot, "compat", "upstream", "bun", "v1.3.10");
const manifestPath = join(suiteRoot, "manifest.json");
const statusPath = join(suiteRoot, "status.json");
const ownershipPath = join(hutchRoot, "compat", "bun-v1.3.10-ownership.json");
const cottontailManifestPath = join(hutchRoot, "compat", "upstream", "cottontail.json");
const preloadPath = join(
  hutchRoot,
  "compat",
  "upstream",
  "hutch-package-manager-test-preload.ts",
);
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
const binarySuiteFilePattern = /\.(?:ico|lockb|tgz)$/i;
const executableSuffix = process.platform === "win32" ? ".exe" : "";
const defaultHutchBinary = join(hutchRoot, "zig-out", "bin", `hutch${executableSuffix}`);
const defaultHutchEngine = join(hutchRoot, "zig-out", "bin", `hutch-engine${executableSuffix}`);
const defaultWindowsJobLauncher = join(
  hutchRoot,
  "zig-out",
  "bin",
  "hutch-bun-compat-job.exe",
);
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
const defaultOuterTimeoutMarginMs = 15_000;
const defaultOuterTimeoutMs = perTestTimeoutMs + defaultOuterTimeoutMarginMs;
const overrideOuterTimeoutMarginMs = 60_000;
const childTreeSettleDelayMs = process.platform === "win32" ? 1_000 : 250;
const childHardSettleTimeoutMs = 5_000;
const windowsJobTerminationTimeoutMs = 3_500;
const windowsJobTerminatorWatchdogMs = 4_000;
const heartbeatMs = Number(process.env.HUTCH_COMPAT_HEARTBEAT_MS ?? 30_000);
const reportsRoot = resolve(
  process.env.HUTCH_COMPAT_REPORTS_DIR ??
  join(hutchRoot, ".hutch-local-tools", "bun-compat-runs"),
);
const cleanupOptions = {
  recursive: true,
  force: true,
  maxRetries: 10,
  retryDelay: 100,
};
const activeChildCompletions = new Set();
const unprovenDeathTempRoots = new Set();
let activeReporter = null;
let activeAbortController = null;

function fail(message) {
  if (activeReporter != null) throw new Error(message);
  console.error(`hutch-package-manager-compat: ${message}`);
  process.exit(1);
}

function throwIfAborted(signal) {
  if (!signal?.aborted) return;
  if (signal.reason instanceof Error) throw signal.reason;
  throw new Error(`Hutch compatibility execution aborted: ${String(signal.reason ?? "unknown")}`);
}

function hermeticChildEnvironment(overrides = {}) {
  const environment = { ...process.env };
  for (const name of [
    "BUN_OPTIONS",
    "COTTONTAIL_RUNTIME_MODULES_DIR",
    "NODE_OPTIONS",
    "NODE_PATH",
  ]) {
    delete environment[name];
  }
  return Object.assign(environment, overrides);
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

if (
  !Number.isSafeInteger(perTestTimeoutMs) ||
  perTestTimeoutMs < 1 ||
  perTestTimeoutMs > 2_147_483_647
) {
  fail(
    "HUTCH_COMPAT_TEST_TIMEOUT_MS must be a positive safe integer " +
    "no greater than 2147483647",
  );
}
if (defaultOuterTimeoutMs > 2_147_483_647) {
  fail(
    "HUTCH_COMPAT_TEST_TIMEOUT_MS leaves no room for the required " +
    `${defaultOuterTimeoutMarginMs}ms outer timeout margin`,
  );
}
if (!Number.isInteger(maxOutputBytes) || maxOutputBytes < 1) {
  fail("HUTCH_COMPAT_MAX_OUTPUT_BYTES must be a positive integer");
}
if (
  !Number.isSafeInteger(heartbeatMs) ||
  heartbeatMs < 1 ||
  heartbeatMs > 2_147_483_647
) {
  fail(
    "HUTCH_COMPAT_HEARTBEAT_MS must be a positive safe integer " +
    "no greater than 2147483647",
  );
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
    "  --job-launcher <path> Native Windows Job Object launcher.",
    "  --jobs <n>          Parallel file workers (default: up to 4).",
    "  --max-tests <n>     Bound the selected file count.",
    "  --report-dir <path> Write this run's durable events, logs, and summary here.",
    "  --keep-temp         Preserve the runner-owned temporary directory.",
    "",
    "Environment equivalents:",
    "  HUTCH_COMPAT_BINARY, HUTCH_COMPAT_ENGINE, HUTCH_COMPAT_COTTONTAIL,",
    "  COTTONTAIL_BINARY, HUTCH_COMPAT_JOB_LAUNCHER, HUTCH_COMPAT_HARNESS_CACHE_DIR,",
    "  HUTCH_COMPAT_TEST_TIMEOUT_MS, HUTCH_COMPAT_REPORT_DIR,",
    "  HUTCH_COMPAT_REPORTS_DIR, HUTCH_COMPAT_HEARTBEAT_MS",
  ].join("\n"));
}

function parseArgs(argv) {
  const options = {
    all: false,
    check: false,
    engine: process.env.HUTCH_COMPAT_ENGINE ?? defaultHutchEngine,
    hutch: process.env.HUTCH_COMPAT_BINARY ?? defaultHutchBinary,
    jobLauncher: process.env.HUTCH_COMPAT_JOB_LAUNCHER ?? defaultWindowsJobLauncher,
    jobs: defaultJobs,
    keepTemp: process.env.HUTCH_COMPAT_KEEP_TEMP === "1",
    list: false,
    match: null,
    maxTests: Infinity,
    reportDir: process.env.HUTCH_COMPAT_REPORT_DIR ?? null,
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
    } else if (arg === "--job-launcher") {
      options.jobLauncher = args.shift() ?? fail("--job-launcher requires a path");
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
    } else if (arg === "--report-dir") {
      options.reportDir = args.shift() ?? fail("--report-dir requires a path");
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
  options.jobLauncher = resolve(options.jobLauncher);
  options.runtime = resolve(options.runtime);
  if (options.reportDir != null) options.reportDir = resolve(options.reportDir);
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

function entryInvocation(entry, preloadPath) {
  try {
    return createTestInvocation(entry, preloadPath, {
      defaultInnerTimeoutMs: perTestTimeoutMs,
      defaultOuterTimeoutMs,
      defaultOuterMarginMs: defaultOuterTimeoutMarginMs,
      overrideOuterMarginMs: overrideOuterTimeoutMarginMs,
    });
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

function normalizeCrLf(bytes) {
  let crlfCount = 0;
  for (let index = 0; index + 1 < bytes.length; index += 1) {
    if (bytes[index] === 13 && bytes[index + 1] === 10) crlfCount += 1;
  }
  if (crlfCount === 0) return bytes;
  const normalized = Buffer.allocUnsafe(bytes.length - crlfCount);
  let outputIndex = 0;
  for (let index = 0; index < bytes.length; index += 1) {
    if (bytes[index] === 13 && bytes[index + 1] === 10) continue;
    normalized[outputIndex] = bytes[index];
    outputIndex += 1;
  }
  return normalized;
}

function canonicalSuiteFileBytes(path, relativePath) {
  const bytes = readFileSync(path);
  return binarySuiteFilePattern.test(relativePath) ? bytes : normalizeCrLf(bytes);
}

function canonicalSuiteSha256(path, relativePath) {
  return createHash("sha256")
    .update(canonicalSuiteFileBytes(path, relativePath))
    .digest("hex");
}

function normalizePrivateSuiteTextFiles(root) {
  for (const path of listSnapshotFiles(root)) {
    if (binarySuiteFilePattern.test(path)) continue;
    const absolutePath = join(root, ...path.split("/"));
    if (!lstatSync(absolutePath).isFile()) continue;
    const bytes = readFileSync(absolutePath);
    const normalized = normalizeCrLf(bytes);
    if (normalized !== bytes) writeFileSync(absolutePath, normalized);
  }
}

function snapshotFingerprint(root, { canonicalText = false } = {}) {
  const files = listSnapshotFiles(root);
  const hash = createHash("sha256");
  for (const path of files) {
    const absolutePath = join(root, ...path.split("/"));
    const stat = lstatSync(absolutePath);
    hash.update(path);
    hash.update("\0");
    hash.update(String(stat.mode & 0o7777));
    hash.update("\0");
    if (stat.isSymbolicLink()) {
      hash.update("symlink\0");
      hash.update(readlinkSync(absolutePath));
    } else if (stat.isFile()) {
      hash.update("file\0");
      hash.update(canonicalText
        ? canonicalSuiteFileBytes(absolutePath, path)
        : readFileSync(absolutePath));
    } else {
      throw new Error(`snapshot contains unsupported entry: ${path}`);
    }
    hash.update("\0");
  }
  return { files: files.length, sha256: hash.digest("hex") };
}

function sha256(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function repositoryCommit() {
  try {
    return readGitHeadCommit(hutchRoot);
  } catch (error) {
    fail(`could not record Hutch repository commit: ${error.message}`);
  }
}

function binaryIdentity(path) {
  const record = { path };
  try {
    if (!existsSync(path)) return { ...record, missing: true };
    if (!statSync(path).isFile()) return { ...record, notAFile: true };
    return { ...record, sha256: sha256(path) };
  } catch (error) {
    return { ...record, identityError: error.message };
  }
}

function runIdentity(validated, entries, options, { refreshMutableInputs = false } = {}) {
  const scriptPaths = [
    fileURLToPath(import.meta.url),
    join(scriptDir, "bun-compat-child-lifecycle.js"),
    join(scriptDir, "bun-compat-reporter.js"),
    join(scriptDir, "bun-compat-runner-contract.js"),
    join(scriptDir, "bun-harness-dependencies.js"),
    join(hutchRoot, "src", "bun_compat_job_launcher.zig"),
    preloadPath,
  ];
  return {
    runner: {
      node: process.version,
      platform: process.platform,
      arch: process.arch,
      hutchRepositoryCommit: repositoryCommit(),
      sources: Object.fromEntries(
        scriptPaths.map(path => [relative(hutchRoot, path), sha256(path)]),
      ),
    },
    binaries: {
      hutch: binaryIdentity(options.hutch),
      engine: binaryIdentity(options.engine),
      cottontail: binaryIdentity(options.runtime),
      ...(process.platform === "win32"
        ? { windowsJobLauncher: binaryIdentity(options.jobLauncher) }
        : {}),
    },
    provenance: {
      cottontail: readJson(cottontailManifestPath),
      cottontailManifestSha256: sha256(cottontailManifestPath),
      harnessDependencyPlanFingerprint: refreshMutableInputs
        ? loadHarnessDependencyPlan().fingerprint
        : validated.harnessDependencyPlan.fingerprint,
      manifestSha256: sha256(manifestPath),
      ownershipSha256: sha256(ownershipPath),
      statusSha256: sha256(statusPath),
      suiteSnapshot: refreshMutableInputs
        ? snapshotFingerprint(suiteRoot, { canonicalText: true })
        : validated.suiteSnapshot,
    },
    inventory: {
      canonicalRunnableFiles: validated.manifest.canonicalRunnableFiles,
      ownedRunnableFiles: validated.manifest.ownedRunnableFiles,
      ownerCounts: validated.ownership.ownerCounts,
    },
    selection: {
      jobs: options.jobs,
      files: entries.map(entry => {
        const invocation = entryInvocation(entry, preloadPath);
        return {
          path: entry.path,
          status: entry.status,
          args: invocation.args,
          env: entry.env ?? {},
          innerTimeoutMs: invocation.innerTimeoutMs,
          outerTimeoutMs: invocation.outerTimeoutMs,
          serial: entry.serial === true,
        };
      }),
    },
    settings: {
      defaultInnerTimeoutMs: perTestTimeoutMs,
      defaultOuterTimeoutMs,
      defaultOuterTimeoutMarginMs,
      overrideOuterTimeoutMarginMs,
      maxOutputBytes,
      timezone: process.env.HUTCH_COMPAT_TZ ?? "Etc/UTC",
    },
  };
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
  const harnessDependencyPlan = loadHarnessDependencyPlan();
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
  const suiteSnapshot = snapshotFingerprint(suiteRoot, { canonicalText: true });
  if (suiteSnapshot.files !== manifest.copiedFiles) {
    fail(`copied file count mismatch: ${suiteSnapshot.files} !== ${manifest.copiedFiles}`);
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
    if (
      !record.sha256 ||
      canonicalSuiteSha256(join(nextPagesRoot, record.path), record.path) !== record.sha256
    ) {
      fail(`Next Pages fixture hash does not match the manifest: ${record.path}`);
    }
  }
  for (const record of manifest.forkedFiles ?? []) {
    const forkedPath = join(suiteRoot, ...String(record.path).split("/"));
    if (
      !/^[0-9a-f]{64}$/.test(record.upstreamSha256 ?? "") ||
      !/^[0-9a-f]{64}$/.test(record.sha256 ?? "") ||
      !existsSync(forkedPath) ||
      canonicalSuiteSha256(forkedPath, record.path) !== record.sha256
    ) {
      fail(`forked copied-file hash does not match the manifest: ${record.path}`);
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
    const invocation = entryInvocation({ path, ...status.tests[path] }, "<preload>");
    const invocationArgs = invocation.args;
    const invocationTimeouts = invocationArgs.filter(arg => arg.startsWith("--timeout="));
    if (invocationTimeouts.length !== 1) {
      fail(`expected exactly one effective test timeout for ${path}`);
    }
    if (path.startsWith(`${nextPagesFixtureRoot}/test/`)) {
      if (invocation.outerTimeoutMs - invocation.innerTimeoutMs < 60_000) {
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
    if (!record.sha256 || canonicalSuiteSha256(join(suiteRoot, path), path) !== record.sha256) {
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

  return {
    manifest,
    status,
    ownership,
    copiedTests,
    harnessDependencyPlan,
    suiteSnapshot,
  };
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

function spawnContainedChild(command, args, spawnOptions, jobLauncher) {
  if (process.platform !== "win32") return spawn(command, args, spawnOptions);
  return startWindowsJobChild(command, args, {
    jobLauncher,
    spawnOptions,
    spawnProcess: spawn,
  });
}

function terminateDirectChild(child) {
  if (child.pid == null) return true;
  try {
    return child.kill("SIGKILL");
  } catch (error) {
    if (error?.code === "ESRCH") return true;
    throw error;
  }
}

async function runCapturedChild(command, args, options) {
  throwIfAborted(options.signal);
  const containOnWindows = process.platform === "win32" && options.containOnWindows !== false;
  const spawnOptions = {
    cwd: options.cwd,
    env: options.env,
    detached: process.platform !== "win32",
  };
  const child = containOnWindows
    ? spawnContainedChild(command, args, spawnOptions, options.jobLauncher)
    : spawn(command, args, spawnOptions);
  const output = {
    stdout: { bytes: 0, chunks: [] },
    stderr: { bytes: 0, chunks: [] },
  };
  const capture = (stream, chunk) => {
    const state = output[stream];
    const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk));
    const remaining = Math.max(0, options.maxOutputBytes - state.bytes);
    if (remaining === 0) return;
    const written = bytes.subarray(0, remaining);
    state.chunks.push(written);
    state.bytes += written.length;
  };
  child.stdout?.on("data", chunk => capture("stdout", chunk));
  child.stderr?.on("data", chunk => capture("stderr", chunk));
  const completion = waitForChildCompletion(child, {
    timeoutMs: options.timeoutMs,
    hardSettleTimeoutMs: childHardSettleTimeoutMs,
    naturalCloseProvesTreeDeath: !containOnWindows || process.platform === "win32",
    requireTerminationProof: containOnWindows,
    signal: options.signal,
    settleDelayMs: childTreeSettleDelayMs,
    terminate: containOnWindows ? killProcessTree : terminateDirectChild,
    terminateOnExit: !containOnWindows,
  });
  activeChildCompletions.add(completion);
  let result;
  try {
    result = await completion;
  } finally {
    activeChildCompletions.delete(completion);
  }
  return {
    ...result,
    status: result.code,
    stdout: Buffer.concat(output.stdout.chunks).toString("utf8"),
    stderr: Buffer.concat(output.stderr.chunks).toString("utf8"),
  };
}

async function preflightBinary(
  path,
  label,
  args,
  environment = process.env,
  signal = null,
  jobLauncher = null,
  containOnWindows = true,
) {
  throwIfAborted(signal);
  if (!existsSync(path)) fail(`${label} not found: ${path}`);
  if (!statSync(path).isFile()) fail(`${label} is not a file: ${path}`);
  const result = await runCapturedChild(path, args, {
    cwd: hutchRoot,
    env: environment,
    timeoutMs: 15_000,
    maxOutputBytes: 1024 * 1024,
    signal,
    jobLauncher,
    containOnWindows,
  });
  throwIfAborted(signal);
  if (result.error) fail(`${label} failed to start: ${result.error.message}`);
  if (result.timedOut) fail(`${label} preflight timed out`);
  if (result.teardownIncomplete) fail(`${label} preflight process teardown did not complete`);
  if (result.status !== 0) {
    fail(
      `${label} preflight exited ${result.status ?? 1}\n` +
      [result.stdout, result.stderr].filter(Boolean).join("\n"),
    );
  }
  return result;
}

async function preflight(options, signal) {
  if (process.platform === "win32") {
    await preflightBinary(
      options.jobLauncher,
      "Windows Job Object launcher",
      ["probe"],
      hermeticChildEnvironment(),
      signal,
      null,
      false,
    );
  }
  const runtime = await preflightBinary(options.runtime, "Cottontail runtime", [
    "-e",
    'console.log("HUTCH_COTTONTAIL_PREFLIGHT:" + JSON.stringify({ version: process.versions?.cottontail, execPath: process.execPath }))',
  ], hermeticChildEnvironment(), signal, options.jobLauncher);
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
  await preflightBinary(options.hutch, "Hutch CLI", ["--version"], hermeticChildEnvironment({
    HUTCH_ENGINE_BINARY: options.engine,
  }), signal, options.jobLauncher);
  if (options.runtime === options.hutch) {
    fail("Hutch child CLI and Cottontail test runtime must be distinct executables");
  }

  const preload = await preflightBinary(
    options.runtime,
    "Hutch package-manager preload",
    [
      "--preload",
      preloadPath,
      "-e",
      'console.log("HUTCH_CHILD_CLI_PREFLIGHT:" + process.execPath)',
    ],
    hermeticChildEnvironment({
      COTTONTAIL_BINARY: options.runtime,
      DASH_COTTONTAIL: options.runtime,
      HUTCH_COMPAT_CLI: options.hutch,
      HUTCH_COMPAT_COTTONTAIL: options.runtime,
      HUTCH_ENGINE_BINARY: options.engine,
    }),
    signal,
    options.jobLauncher,
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

async function prepareHarnessDependencies(options, signal, plan) {
  throwIfAborted(signal);
  const identity = createHarnessDependencyCacheIdentity();
  const cachedRoot = findValidHarnessDependencyGeneration(
    harnessDependencyCacheRoot,
    plan,
    identity,
  );
  if (cachedRoot) {
    return {
      cacheIdentity: identity,
      generation: harnessDependencyGenerationIdentity(cachedRoot, plan, identity),
      installRoot: cachedRoot,
    };
  }

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
    const result = await runCapturedChild(
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
        env: hermeticChildEnvironment({
          COTTONTAIL_BINARY: options.runtime,
          DASH_COTTONTAIL: options.runtime,
          HUTCH_ENGINE_BINARY: options.engine,
          HUTCH_NO_UPDATE_CHECK: "1",
        }),
        timeoutMs: 10 * 60_000,
        maxOutputBytes: 64 * 1024 * 1024,
        signal,
        jobLauncher: options.jobLauncher,
      },
    );
    throwIfAborted(signal);
    if (result.error) {
      failureMessage = `could not install test-harness dependencies: ${result.error.message}`;
    } else if (result.timedOut) {
      failureMessage = "could not install test-harness dependencies: install timed out";
    } else if (result.teardownIncomplete) {
      failureMessage = "could not install test-harness dependencies: process teardown did not complete";
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
  return {
    cacheIdentity: identity,
    generation: harnessDependencyGenerationIdentity(published.installRoot, plan, identity),
    installRoot: published.installRoot,
  };
}

function killProcessTree(child) {
  if (!child.pid) return true;
  if (process.platform === "win32") {
    return startWindowsJobTermination(child, {
      spawnProcess: spawn,
      timeoutMs: windowsJobTerminationTimeoutMs,
      watchdogMs: windowsJobTerminatorWatchdogMs,
    });
  }
  try {
    process.kill(-child.pid, "SIGKILL");
    return true;
  } catch (groupError) {
    if (groupError?.code === "ESRCH") return true;
    try {
      child.kill("SIGKILL");
    } catch {}
    throw new Error(
      `could not terminate POSIX process group ${child.pid}: ` +
      `${groupError?.message ?? String(groupError)}`,
      { cause: groupError },
    );
  }
}

function prepareExecutionSuite(
  tempRoot,
  harnessDependencyInstallRoot,
  expectedSnapshotFingerprint,
  expectedHarnessDependencies,
  harnessDependencyPlan,
  harnessDependencyCacheIdentity,
) {
  const executionSuiteRoot = join(tempRoot, "suite");
  cpSync(suiteRoot, executionSuiteRoot, {
    recursive: true,
    dereference: false,
    preserveTimestamps: true,
    verbatimSymlinks: true,
  });
  // Existing Windows worktrees can predate this branch's eol=lf attributes.
  // Accept CRLF only when its byte-for-byte LF form matches the immutable
  // manifest, then materialize the private execution copy in canonical form.
  normalizePrivateSuiteTextFiles(executionSuiteRoot);
  const copiedSnapshotFingerprint = snapshotFingerprint(executionSuiteRoot);
  if (!isDeepStrictEqual(copiedSnapshotFingerprint, expectedSnapshotFingerprint)) {
    fail(
      "copied compatibility suite changed after run identity was recorded: " +
      `${JSON.stringify(copiedSnapshotFingerprint)} !== ` +
      `${JSON.stringify(expectedSnapshotFingerprint)}`,
    );
  }

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
  const materializedDependencies = harnessDependencyTreeIdentity(
    join(executionSuiteRoot, "test", "node_modules"),
  );
  if (!isDeepStrictEqual(materializedDependencies, expectedHarnessDependencies.nodeModules)) {
    fail("private harness dependency materialization differs from its validated generation");
  }
  const sourceDependencies = harnessDependencyGenerationIdentity(
    harnessDependencyInstallRoot,
    harnessDependencyPlan,
    harnessDependencyCacheIdentity,
  );
  if (!isDeepStrictEqual(sourceDependencies, expectedHarnessDependencies)) {
    fail("immutable harness dependency generation changed while it was being materialized");
  }
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

function runEntry(
  entry,
  options,
  tempRoot,
  executionSuiteRoot,
  reporter,
  reportToken,
  abortController,
) {
  const runTemp = mkdtempSync(join(tempRoot, "run-"));
  const childEnv = hermeticChildEnvironment({
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
    HUTCH_COMPAT_VERDACCIO_EXEC_PATH: process.execPath,
    HUTCH_COMPAT_TEST_TIMEOUT_MS: String(perTestTimeoutMs),
    HUTCH_BUN_COMPAT: "1",
    HUTCH_ENGINE_BINARY: options.engine,
    TEMP: runTemp,
    TEST_TMPDIR: runTemp,
    TMP: runTemp,
    TMPDIR: runTemp,
    TZ: process.env.HUTCH_COMPAT_TZ ?? "Etc/UTC",
  });

  const invocation = entryInvocation(entry, preloadPath);
  const child = spawnContainedChild(options.runtime, invocation.args, {
    cwd: executionSuiteRoot,
    env: childEnv,
    detached: process.platform !== "win32",
  }, options.jobLauncher);
  let stdout = "";
  let stderr = "";
  let outputError = null;
  child.stdout.on("data", chunk => {
    try {
      reporter.appendOutput(reportToken, "stdout", chunk);
    } catch (error) {
      outputError ??= error;
      abortController.abort(error);
    }
    if (stdout.length < maxOutputBytes) stdout += chunk;
  });
  child.stderr.on("data", chunk => {
    try {
      reporter.appendOutput(reportToken, "stderr", chunk);
    } catch (error) {
      outputError ??= error;
      abortController.abort(error);
    }
    if (stderr.length < maxOutputBytes) stderr += chunk;
  });

  const lifecycleCompletion = waitForChildCompletion(child, {
    timeoutMs: invocation.outerTimeoutMs,
    hardSettleTimeoutMs: childHardSettleTimeoutMs,
    naturalCloseProvesTreeDeath: true,
    requireTerminationProof: process.platform === "win32",
    signal: abortController.signal,
    settleDelayMs: childTreeSettleDelayMs,
    terminate: killProcessTree,
    terminateOnExit: process.platform !== "win32",
  });
  activeChildCompletions.add(lifecycleCompletion);
  return lifecycleCompletion.then(result => {
    if (result.processDeathProven) {
      if (!options.keepTemp) removeRunnerOwnedPath(runTemp);
    } else {
      unprovenDeathTempRoots.add(tempRoot);
    }
    const completed = {
      ...result,
      stdout,
      stderr,
      ...(!result.processDeathProven ? { retainedTempRoot: tempRoot } : {}),
    };
    if (outputError) throw outputError;
    return completed;
  }).finally(() => {
    activeChildCompletions.delete(lifecycleCompletion);
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
  if (result.aborted) {
    return {
      ok: false,
      outcome: "unexpected-failure",
      message: `FAIL ${entry.path} canceled after a peer runner error`,
      diagnostics: capturedDiagnostics(result),
    };
  }
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

async function runEntries(
  entries,
  options,
  tempRoot,
  executionSuiteRoot,
  reporter,
  abortController,
) {
  throwIfAborted(abortController.signal);
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
    const reportToken = reporter.startEntry(entry, {
      started,
      completed,
      running: started - completed,
    });
    const executionResult = await runEntry(
      entry,
      options,
      tempRoot,
      executionSuiteRoot,
      reporter,
      reportToken,
      abortController,
    );
    const result = classify(entry, executionResult);
    outcomeCounts[result.outcome] += 1;
    completed += 1;
    const unexpected = outcomeCounts["unexpected-pass"] + outcomeCounts["unexpected-failure"];
    const execution = {
      code: executionResult.code,
      signal: executionResult.signal,
      timedOut: executionResult.timedOut,
      processDeathProven: executionResult.processDeathProven,
      teardownIncomplete: executionResult.teardownIncomplete,
      ...(executionResult.error
        ? { error: executionResult.error.message ?? String(executionResult.error) }
        : {}),
      ...(executionResult.teardownError
        ? { teardownError: executionResult.teardownError.message ?? String(executionResult.teardownError) }
        : {}),
      ...(executionResult.retainedTempRoot
        ? { retainedTempRoot: executionResult.retainedTempRoot }
        : {}),
    };
    const reportLog = reporter.finishEntry(
      reportToken,
      { ...result, execution },
      {
        started,
        completed,
        running: started - completed,
        outcomeCounts,
      },
    );
    console.log(
      `DONE [${completed}/${entries.length}; running ${started - completed}] ${result.message}`,
    );
    console.log(
      `  progress: passed ${outcomeCounts.passed}; ` +
      `expected failures ${outcomeCounts["expected-failure"]}; unexpected ${unexpected}`,
    );
    if (result.diagnostics) console.log(result.diagnostics);
    if (!result.ok) console.log(`  durable log: ${join(reporter.reportDir, reportLog)}`);
    if (executionResult.teardownIncomplete) {
      const error = new Error(
        `unsafe process teardown for ${entry.path}; stopped before reusing the execution suite`,
      );
      abortController.abort(error);
      throw error;
    }
    throwIfAborted(abortController.signal);
  };

  const queue = entries
    .map((entry, index) => ({ entry, index }))
    .filter(item => !serialIndexes.has(item.index));
  let cursor = 0;
  let firstError = null;
  const recordWorkerError = error => {
    firstError ??= error;
    abortController.abort(error);
  };
  const worker = async () => {
    while (!abortController.signal.aborted) {
      const item = queue[cursor++];
      if (!item) return;
      try {
        await runOne(item.entry);
      } catch (error) {
        recordWorkerError(error);
        return;
      }
    }
  };
  await Promise.all(Array.from({ length: Math.min(options.jobs, queue.length) || 1 }, worker));
  throwIfAborted(abortController.signal);
  if (firstError) throw firstError;

  for (const index of serialIndexes) {
    try {
      await runOne(entries[index]);
    } catch (error) {
      recordWorkerError(error);
      break;
    }
  }
  throwIfAborted(abortController.signal);
  if (firstError) throw firstError;
  return outcomeCounts;
}

let handlingSignal = false;
for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, async () => {
    if (handlingSignal) process.exit(signal === "SIGINT" ? 130 : 143);
    handlingSignal = true;
    activeAbortController?.abort(new Error(`runner interrupted by ${signal}`));
    try {
      activeReporter?.interrupt(signal);
    } catch (error) {
      console.error(`hutch-package-manager-compat: warning: could not record ${signal}: ${error.message}`);
    }
    await Promise.allSettled([...activeChildCompletions]);
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

const initialRunIdentity = runIdentity(validated, entries, options);
const executionAbortController = new AbortController();
activeAbortController = executionAbortController;
activeReporter = new HutchCompatReporter({
  forbiddenRoots: [suiteRoot],
  heartbeatMs,
  identity: initialRunIdentity,
  maxOutputBytes,
  onError(error) { executionAbortController.abort(error); },
  planned: entries.length,
  reportDir: options.reportDir,
  reportsRoot,
});
let tempRoot = null;
try {
  activeReporter.setPhase("preflight");
  await preflight(options, executionAbortController.signal);
  throwIfAborted(executionAbortController.signal);
  activeReporter.setPhase("harness-dependencies");
  const harnessDependencies = await prepareHarnessDependencies(
    options,
    executionAbortController.signal,
    validated.harnessDependencyPlan,
  );
  throwIfAborted(executionAbortController.signal);
  activeReporter.recordHarnessDependencies(harnessDependencies.generation);
  tempRoot = mkdtempSync(join(os.tmpdir(), "hutch-package-manager-compat-"));
  const executionSuiteRoot = prepareExecutionSuite(
    tempRoot,
    harnessDependencies.installRoot,
    initialRunIdentity.provenance.suiteSnapshot,
    harnessDependencies.generation,
    validated.harnessDependencyPlan,
    harnessDependencies.cacheIdentity,
  );
  activeReporter.setPhase("test-files");
  const outcomeCounts = await runEntries(
    entries,
    options,
    tempRoot,
    executionSuiteRoot,
    activeReporter,
    executionAbortController,
  );
  throwIfAborted(executionAbortController.signal);
  const unexpected = outcomeCounts["unexpected-pass"] + outcomeCounts["unexpected-failure"];
  console.log(
    `  files: ${entries.length}; passed: ${outcomeCounts.passed}; ` +
    `expected failures: ${outcomeCounts["expected-failure"]}; unexpected: ${unexpected}`,
  );
  const finalRunIdentity = runIdentity(validated, entries, options, {
    refreshMutableInputs: true,
  });
  if (!isDeepStrictEqual(finalRunIdentity, initialRunIdentity)) {
    throw new Error("run identity inputs changed while the compatibility suite was executing");
  }
  activeReporter.finish({
    files: entries.length,
    harnessDependencies: harnessDependencies.generation,
    outcomeCounts,
  });
  if (unexpected > 0) process.exitCode = 1;
} catch (error) {
  try {
    activeReporter.fatal(error);
  } catch (reportError) {
    console.error(
      `hutch-package-manager-compat: warning: could not finalize failed report: ${reportError.message}`,
    );
  }
  throw error;
} finally {
  if (tempRoot == null) {
    // Dependency preparation failed before an execution suite was created.
  } else if (options.keepTemp || unprovenDeathTempRoots.has(tempRoot)) {
    const reason = unprovenDeathTempRoots.has(tempRoot)
      ? " because at least one child process death was not observed"
      : "";
    console.error(`kept Hutch compatibility temp root${reason}: ${tempRoot}`);
  } else {
    removeRunnerOwnedPath(tempRoot);
    removeGeneratedSuiteArtifacts();
  }
  activeReporter = null;
  activeAbortController = null;
}
