#!/usr/bin/env node

import {
  cpSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readlinkSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { createHash } from "node:crypto";
import { dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const hutchRoot = resolve(scriptDir, "..");
const defaultSourceRoot = resolve(
  hutchRoot,
  "..",
  "..",
  "cottontail",
  "compat",
  "upstream",
  "bun",
  "v1.3.10",
);
const suiteRoot = join(hutchRoot, "compat", "upstream", "bun", "v1.3.10");
const ownershipPath = join(hutchRoot, "compat", "bun-v1.3.10-ownership.json");
const runnablePattern = /\.test\.(?:js|mjs|cjs|ts|tsx|mts|cts)$/i;
const canonicalRunnableCount = 1_445;
const expectedOwnedCount = 100;

const runtimeOnlyTests = new Set([
  "test/cli/install/semver.test.ts",
  "test/cli/run/shell-keepalive.test.ts",
]);

const runtimeOnlyInstallCopiedPaths = [
  "test/cli/install/__snapshots__/semver.test.ts.snap",
  "test/cli/install/semver-fixture.js",
  "test/cli/install/semver.test.ts",
];

const orchestrationTests = [
  "test/cli/run/filter-workspace.test.ts",
  "test/cli/run/if-present.test.ts",
  "test/cli/run/multi-run.test.ts",
  "test/cli/run/run-autoinstall.test.ts",
  "test/cli/run/run-shell.test.ts",
  "test/cli/run/run_command.test.ts",
  "test/cli/run/workspaces.test.ts",
];

const projectMutationTests = [
  "test/cli/create/create-jsx.test.ts",
  "test/cli/init/init.test.ts",
  "test/cli/update_interactive_formatting.test.ts",
  "test/cli/update_interactive_install.test.ts",
  "test/cli/update_interactive_snapshots.test.ts",
];

const packageManagerRegressionTests = [
  "test/regression/issue/00631.test.ts",
  "test/regression/issue/026039.test.ts",
  "test/regression/issue/07740.test.ts",
  "test/regression/issue/08093.test.ts",
  "test/regression/issue/11806.test.ts",
  "test/regression/issue/13316.test.ts",
  "test/regression/issue/14945-lifecycle-script-crash.test.ts",
  "test/regression/issue/15276.test.ts",
  "test/regression/issue/24131.test.ts",
  "test/regression/issue/24314.test.ts",
  "test/regression/issue/24364.test.ts",
  "test/regression/issue/24502/bun-pm-ls-all-invalid-package-id.test.ts",
  "test/regression/issue/24806.test.ts",
  "test/regression/issue/26337.test.ts",
  "test/regression/issue/3192.test.ts",
  "test/regression/issue/ctrl-c.test.ts",
  "test/regression/issue/malformed-integrity-base64.test.ts",
  "test/regression/issue/update-interactive-formatting.test.ts",
];

const focusedPackageManagerTests = [
  "test/js/third_party/pnpm/pnpm.test.ts",
  "test/regression/issue/patch-bounds-check.test.ts",
];

const directlyCopiedPaths = [
  "LICENSE.md",
  "package.json",
  "tsconfig.base.json",
  "src/init/react-tailwind",
  "test/package.json",
  "test/bun.lock",
  "test/tsconfig.json",
  "test/harness.ts",
  "test/preload.ts",
  "test/_util/numeric.ts",
  "test/docker",
  "test/cli/install",
  "test/cli/create",
  "test/cli/init/init.test.ts",
  "test/js/third_party/pnpm",
  ...projectMutationTests.filter(path => !path.startsWith("test/cli/create/") && !path.startsWith("test/cli/init/")),
  ...orchestrationTests,
  ...packageManagerRegressionTests,
  ...focusedPackageManagerTests,
];

function usage() {
  console.log([
    "Usage: node scripts/import-bun-package-manager-tests.js [--source <bun-v1.3.10-snapshot>]",
    "",
    `Default source: ${defaultSourceRoot}`,
  ].join("\n"));
}

function parseArgs(argv) {
  let sourceRoot = defaultSourceRoot;
  const args = [...argv];
  while (args.length > 0) {
    const arg = args.shift();
    if (arg === "--source") {
      const value = args.shift();
      if (!value) throw new Error("--source requires a path");
      sourceRoot = resolve(value);
    } else if (arg === "--help" || arg === "-h") {
      usage();
      process.exit(0);
    } else {
      throw new Error(`unknown option: ${arg}`);
    }
  }
  return { sourceRoot };
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
      if (current === testRoot && /^\.tmp\.\d+$/.test(entry.name)) continue;
      if (entry.isDirectory() && !entry.isSymbolicLink()) {
        stack.push(path);
      } else if (entry.isFile() && runnablePattern.test(entry.name)) {
        result.push(toPosix(relative(root, path)));
      }
    }
  }
  return result.sort();
}

function shouldSkipCopy(sourcePath) {
  const name = sourcePath.slice(sourcePath.lastIndexOf(sep) + 1);
  return name === ".DS_Store" ||
    name === "node_modules" ||
    name === ".git" ||
    name === ".verdaccio-db.json" ||
    name.startsWith(".cottontail-") ||
    name.startsWith("fstest");
}

function copyOwnedPath(sourceRoot, relativePath) {
  const source = join(sourceRoot, relativePath);
  const destination = join(suiteRoot, relativePath);
  if (shouldSkipCopy(source)) return;

  let stat;
  try {
    stat = lstatSync(source);
  } catch (error) {
    throw new Error(`missing source path: ${relativePath}: ${error.message}`);
  }
  if (stat.isDirectory()) {
    mkdirSync(destination, { recursive: true });
    for (const entry of readdirSync(source)) {
      copyOwnedPath(sourceRoot, join(relativePath, entry));
    }
    return;
  }

  mkdirSync(dirname(destination), { recursive: true });
  if (stat.isSymbolicLink()) {
    rmSync(destination, { force: true });
    symlinkSync(readlinkSync(source), destination);
    return;
  }
  cpSync(source, destination, {
    dereference: false,
    force: true,
    preserveTimestamps: true,
  });
}

function patternStatusForPath(status, path) {
  let matched = null;
  for (const entry of status.patterns ?? []) {
    if (entry?.pattern && entry?.status && new RegExp(entry.pattern).test(path)) {
      matched = entry;
    }
  }
  return matched;
}

function statusForPath(status, existingStatus, path) {
  const existing = existingStatus?.tests?.[path];
  if (existing) {
    return {
      ...existing,
      owner: "hutch-package-manager",
    };
  }
  const pattern = patternStatusForPath(status, path);
  const result = {
    status: status.defaultStatus ?? "not-enabled",
    ...(pattern ?? {}),
    ...(status.tests?.[path] ?? {}),
  };
  delete result.pattern;
  if (result.status === "skip" && result.owner === "hutch-package-manager") {
    result.status = "enabled";
    result.reason = "Imported into Hutch ownership; run the Hutch compatibility corpus and record the measured result here.";
  }
  result.owner = "hutch-package-manager";
  return result;
}

function sha256(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function countCopiedFiles(root) {
  let count = 0;
  const stack = [root];
  while (stack.length > 0) {
    const current = stack.pop();
    for (const entry of readdirSync(current, { withFileTypes: true })) {
      if (entry.isDirectory() && !entry.isSymbolicLink()) {
        stack.push(join(current, entry.name));
      } else {
        count += 1;
      }
    }
  }
  return count;
}

function writeJson(path, value) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
}

function main() {
  const { sourceRoot } = parseArgs(process.argv.slice(2));
  const sourceManifestPath = join(sourceRoot, "manifest.json");
  const sourceStatusPath = join(sourceRoot, "status.json");
  if (!existsSync(sourceManifestPath) || !existsSync(sourceStatusPath)) {
    throw new Error(`not a pinned Bun compatibility snapshot: ${sourceRoot}`);
  }

  const sourceManifest = JSON.parse(readFileSync(sourceManifestPath, "utf8"));
  const sourceStatus = JSON.parse(readFileSync(sourceStatusPath, "utf8"));
  const existingStatusPath = join(suiteRoot, "status.json");
  const existingStatus = existsSync(existingStatusPath)
    ? JSON.parse(readFileSync(existingStatusPath, "utf8"))
    : null;
  if (sourceManifest.version !== "1.3.10") {
    throw new Error(`expected Bun 1.3.10, received ${String(sourceManifest.version)}`);
  }

  const canonicalTests = discoverRunnableFiles(sourceRoot);
  if (canonicalTests.length !== canonicalRunnableCount) {
    throw new Error(
      `canonical Bun inventory changed: expected ${canonicalRunnableCount}, found ${canonicalTests.length}`,
    );
  }

  const canonicalInstallTests = canonicalTests.filter(path => path.startsWith("test/cli/install/"));
  if (canonicalInstallTests.length !== 69) {
    throw new Error(`expected 69 canonical install tests, found ${canonicalInstallTests.length}`);
  }
  const installTests = canonicalInstallTests.filter(path => !runtimeOnlyTests.has(path));

  const ownedTests = [
    ...installTests,
    ...projectMutationTests,
    ...orchestrationTests,
    ...packageManagerRegressionTests,
    ...focusedPackageManagerTests,
  ].sort();
  const uniqueOwnedTests = new Set(ownedTests);
  if (uniqueOwnedTests.size !== ownedTests.length) {
    throw new Error("duplicate path in Hutch package-manager ownership list");
  }
  for (const path of runtimeOnlyTests) {
    if (!canonicalTests.includes(path)) throw new Error(`runtime-only test is not canonical: ${path}`);
    if (uniqueOwnedTests.has(path)) throw new Error(`runtime-only test is still Hutch-owned: ${path}`);
  }
  if (ownedTests.length !== expectedOwnedCount) {
    throw new Error(`expected ${expectedOwnedCount} owned tests, found ${ownedTests.length}`);
  }
  for (const path of ownedTests) {
    if (!canonicalTests.includes(path)) throw new Error(`owned test is not canonical: ${path}`);
  }

  rmSync(suiteRoot, { recursive: true, force: true });
  for (const path of directlyCopiedPaths) copyOwnedPath(sourceRoot, path);
  for (const path of runtimeOnlyInstallCopiedPaths) {
    rmSync(join(suiteRoot, path), { recursive: true, force: true });
  }

  writeFileSync(
    join(suiteRoot, "test", "bunfig.toml"),
    [
      "[test]",
      'preload = ["./preload.ts", "../../../hutch-package-manager-test-preload.ts"]',
      "",
      "[install]",
      'linker = "isolated"',
      "",
    ].join("\n"),
  );

  const copiedRunnableTests = discoverRunnableFiles(suiteRoot);
  if (
    copiedRunnableTests.length !== ownedTests.length ||
    copiedRunnableTests.some((path, index) => path !== ownedTests[index])
  ) {
    throw new Error(
      "copied runnable inventory does not exactly match the Hutch ownership list",
    );
  }

  const statuses = Object.fromEntries(
    ownedTests.map(path => [path, statusForPath(sourceStatus, existingStatus, path)]),
  );
  const statusCounts = Object.values(statuses).reduce((counts, entry) => {
    counts[entry.status] = (counts[entry.status] ?? 0) + 1;
    return counts;
  }, {});

  writeJson(join(suiteRoot, "status.json"), {
    schema: 1,
    defaultStatus: "not-enabled",
    tests: statuses,
  });

  const testRecords = ownedTests.map(path => {
    const importedHash = sha256(join(suiteRoot, path));
    const sourceHash = sha256(join(sourceRoot, path));
    if (importedHash !== sourceHash) {
      throw new Error(`copied test differs from Bun source: ${path}`);
    }
    return {
      path,
      sha256: importedHash,
      status: statuses[path].status,
    };
  });

  writeJson(join(suiteRoot, "manifest.json"), {
    schema: 1,
    suite: "hutch-bun-package-manager",
    runtime: "bun",
    version: sourceManifest.version,
    tag: sourceManifest.tag,
    commit: sourceManifest.commit,
    source: sourceManifest.source,
    copiedAt: new Date().toISOString().slice(0, 10),
    canonicalRunnableFiles: canonicalRunnableCount,
    ownedRunnableFiles: ownedTests.length,
    copiedFiles: countCopiedFiles(suiteRoot) + 1,
    statusCounts,
    ownershipManifest: "compat/bun-v1.3.10-ownership.json",
    testFiles: testRecords,
    copiedPaths: directlyCopiedPaths.map(toPosix).sort(),
    notes: [
      "This is an owned Hutch compatibility-test snapshot copied from Bun v1.3.10.",
      "Cottontail is the JavaScript test runtime; the Hutch-specific preload redirects bunExe() and process.execPath child commands to Hutch.",
      "The snapshot excludes node_modules, generated test artifacts, and unrelated Bun runtime, bundler, benchmark, and integration fixtures.",
      "Copied upstream tests remain byte-identical. Hutch-owned runner and preload behavior lives outside the copied Bun test tree.",
    ],
    intentionallyDeferred: [
      {
        path: "test/regression/issue/26058.test.ts",
        owner: "cottontail-runtime",
        reason: "The assertion is built-in REPL behavior; package-manager text only proves the runtime no longer shells out.",
      },
      {
        path: "test/regression/issue/26225.test.ts",
        owner: "cottontail-runtime",
        reason: "Package installation is fixture setup; the assertions cover fetch, streams, multipart parsing, and Blob behavior.",
      },
      {
        pattern: "test/bundler/**",
        owner: "cottontail-runtime",
        reason: "Bun.build remains physically implemented by Cottontail in this cycle.",
      },
      {
        pattern: "test/cli/run/** (except the seven owned files)",
        owner: "cottontail-runtime",
        reason: "The remaining files primarily assert runtime loading, transforms, profiling, diagnostics, or process behavior.",
      },
    ],
  });

  const ownerByPath = new Map(ownedTests.map(path => [path, "hutch-package-manager"]));
  const ownershipTests = canonicalTests.map(path => ({
    path,
    owner: ownerByPath.get(path) ?? "cottontail-runtime",
  }));
  writeJson(ownershipPath, {
    schema: 1,
    runtime: "bun",
    version: sourceManifest.version,
    commit: sourceManifest.commit,
    canonicalRunnableFiles: canonicalTests.length,
    ownerCounts: {
      "cottontail-runtime": canonicalTests.length - ownedTests.length,
      "hutch-package-manager": ownedTests.length,
    },
    tests: ownershipTests,
    notes: [
      "Each canonical Bun v1.3.10 runnable file has exactly one compatibility owner.",
      "Physical source copies may temporarily coexist during migration; aggregate compatibility reporting must use this ownership index and never sum repository-local discovery counts.",
    ],
  });

  console.log(
    `Imported ${ownedTests.length}/${canonicalTests.length} Bun v1.3.10 runnable files into Hutch ` +
    `(${countCopiedFiles(suiteRoot)} copied files).`,
  );
}

try {
  main();
} catch (error) {
  console.error(`import-bun-package-manager-tests: ${error.message}`);
  process.exit(1);
}
