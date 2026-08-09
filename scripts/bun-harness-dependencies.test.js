import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

import {
  createHarnessDependencyCacheIdentity,
  createHarnessDependencyStagingRoot,
  findValidHarnessDependencyGeneration,
  harnessDependencyInstallErrors,
  normalizeHarnessDependencyBinShims,
  publishHarnessDependencyGeneration,
  publishedHarnessDependencyInstallErrors,
  readHarnessDependencyPlan,
  windowsHarnessBinShim,
} from "./bun-harness-dependencies.js";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const hutchRoot = dirname(scriptDir);
const dependencySourceRoot = join(
  hutchRoot,
  "compat",
  "harness-dependencies",
  "bun-v1.3.10",
);
const upstreamPackagePath = join(
  hutchRoot,
  "compat",
  "upstream",
  "bun",
  "v1.3.10",
  "test",
  "package.json",
);

function syntheticPlan() {
  const packageBytes = Buffer.from(
    `${JSON.stringify({ private: true, dependencies: { top: "1.0.0" } }, null, 2)}\n`,
  );
  const lockBytes = Buffer.from("synthetic frozen lock\n");
  return {
    dependencies: { top: "1.0.0" },
    fingerprint: "1".repeat(64),
    lockBytes,
    lockedPackages: [
      {
        bins: { tool: "bin/tool.js" },
        key: "top",
        name: "top",
        relativePath: "node_modules/top",
        version: "1.0.0",
      },
      {
        bins: {},
        key: "top/transitive",
        name: "transitive",
        relativePath: "node_modules/top/node_modules/transitive",
        version: "2.0.0",
      },
    ],
    packageBytes,
  };
}

function populateSyntheticInstall(
  root,
  plan = syntheticPlan(),
  platform = process.platform,
) {
  writeFileSync(join(root, "package.json"), plan.packageBytes);
  writeFileSync(join(root, "bun.lock"), plan.lockBytes);

  const topRoot = join(root, "node_modules", "top");
  const transitiveRoot = join(topRoot, "node_modules", "transitive");
  mkdirSync(join(topRoot, "bin"), { recursive: true });
  mkdirSync(transitiveRoot, { recursive: true });
  writeFileSync(
    join(topRoot, "package.json"),
    `${JSON.stringify({ name: "top", version: "1.0.0", bin: { tool: "bin/tool.js" } })}\n`,
  );
  writeFileSync(join(topRoot, "index.js"), "export const top = true;\n");
  writeFileSync(join(topRoot, "bin", "tool.js"), "#!/usr/bin/env node\n");
  writeFileSync(
    join(transitiveRoot, "package.json"),
    `${JSON.stringify({ name: "transitive", version: "2.0.0" })}\n`,
  );
  writeFileSync(join(transitiveRoot, "index.js"), "export const transitive = true;\n");

  const binRoot = join(root, "node_modules", ".bin");
  mkdirSync(binRoot, { recursive: true });
  if (platform === "win32") {
    writeFileSync(
      join(binRoot, "tool.cmd"),
      `@"C:\\staging\\cottontail.exe" "${join(topRoot, "bin", "tool.js")}" %*\r\n`,
    );
  } else {
    symlinkSync("../top/bin/tool.js", join(binRoot, "tool"));
  }
}

function temporaryRoot(t, prefix) {
  const root = mkdtempSync(join(os.tmpdir(), prefix));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return root;
}

function waitForChild(child) {
  return new Promise((resolve, reject) => {
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", chunk => { stdout += chunk; });
    child.stderr.on("data", chunk => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", code => {
      if (code === 0) resolve(stdout.trim());
      else reject(new Error(`publication worker exited ${code}: ${stderr || stdout}`));
    });
  });
}

test("owns an exact frozen dependency plan for the Bun-derived harness", () => {
  const plan = readHarnessDependencyPlan(dependencySourceRoot, upstreamPackagePath);
  assert.deepEqual(plan.dependencies, {
    "p-queue": "8.1.0",
    verdaccio: "6.0.0",
  });
  assert.match(plan.fingerprint, /^[0-9a-f]{64}$/);
  assert.equal(plan.lockedPackages.length, 281);
  assert.deepEqual(
    plan.lockedPackages.find(record => record.key === "body-parser/debug/ms"),
    {
      bins: {},
      key: "body-parser/debug/ms",
      name: "ms",
      relativePath: "node_modules/body-parser/node_modules/debug/node_modules/ms",
      version: "2.0.0",
    },
  );
  assert.deepEqual(
    plan.lockedPackages.find(record => record.key === "verdaccio")?.bins,
    { verdaccio: "bin/verdaccio" },
  );
});

test("validation covers locked transitives, frozen inputs, and platform bin shims", t => {
  const plan = syntheticPlan();
  const installRoot = temporaryRoot(t, "hutch-harness-deps-validation-");
  populateSyntheticInstall(installRoot, plan);
  assert.deepEqual(harnessDependencyInstallErrors(installRoot, plan), []);

  const transitivePackage = join(
    installRoot,
    "node_modules",
    "top",
    "node_modules",
    "transitive",
    "package.json",
  );
  rmSync(transitivePackage);
  assert.match(
    harnessDependencyInstallErrors(installRoot, plan).join("\n"),
    /missing locked transitive transitive@2\.0\.0/,
  );
  writeFileSync(transitivePackage, '{"name":"transitive","version":"2.0.0"}\n');

  const shim = join(
    installRoot,
    "node_modules",
    ".bin",
    process.platform === "win32" ? "tool.cmd" : "tool",
  );
  rmSync(shim);
  assert.match(
    harnessDependencyInstallErrors(installRoot, plan).join("\n"),
    /missing platform bin shim for top:tool/,
  );

  writeFileSync(join(installRoot, "bun.lock"), "modified\n");
  assert.match(
    harnessDependencyInstallErrors(installRoot, plan).join("\n"),
    /bun\.lock differs from the Hutch-owned source/,
  );
});

test("Windows bin shims are normalized and validated as relocatable", t => {
  const plan = syntheticPlan();
  const installRoot = temporaryRoot(t, "hutch-harness-deps-windows-shim-");
  populateSyntheticInstall(installRoot, plan, "win32");
  assert.match(
    harnessDependencyInstallErrors(installRoot, plan, "win32").join("\n"),
    /non-relocatable content for top:tool/,
  );

  normalizeHarnessDependencyBinShims(installRoot, plan, "win32");
  assert.equal(
    readFileSync(join(installRoot, "node_modules", ".bin", "tool.cmd"), "utf8"),
    windowsHarnessBinShim("../top/bin/tool.js"),
  );
  assert.deepEqual(harnessDependencyInstallErrors(installRoot, plan, "win32"), []);

  writeFileSync(
    join(installRoot, "node_modules", ".bin", "tool.cmd"),
    '@"C:\\staging\\cottontail.exe" "C:\\staging\\node_modules\\top\\bin\\tool.js" %*\r\n',
  );
  assert.match(
    harnessDependencyInstallErrors(installRoot, plan, "win32").join("\n"),
    /non-relocatable content for top:tool/,
  );
});

test("published generations are content-addressed, reusable, and self-repairing", t => {
  const cacheRoot = temporaryRoot(t, "hutch-harness-deps-cache-");
  const plan = syntheticPlan();
  const identity = createHarnessDependencyCacheIdentity();

  const firstStaging = createHarnessDependencyStagingRoot(cacheRoot, plan, identity);
  populateSyntheticInstall(firstStaging, plan);
  const first = publishHarnessDependencyGeneration(firstStaging, cacheRoot, plan, identity);
  assert.equal(first.reused, false);
  assert.match(first.installRoot, /[\\/][0-9a-f]{32}[\\/]install$/);
  assert.deepEqual(publishedHarnessDependencyInstallErrors(first.installRoot, plan, identity), []);
  assert.equal(
    findValidHarnessDependencyGeneration(cacheRoot, plan, identity),
    first.installRoot,
  );

  const duplicateStaging = createHarnessDependencyStagingRoot(cacheRoot, plan, identity);
  populateSyntheticInstall(duplicateStaging, plan);
  const duplicate = publishHarnessDependencyGeneration(
    duplicateStaging,
    cacheRoot,
    plan,
    identity,
  );
  assert.deepEqual(duplicate, { installRoot: first.installRoot, reused: true });
  assert.equal(existsSync(duplicateStaging), false);

  const corruptedFile = join(first.installRoot, "node_modules", "top", "index.js");
  writeFileSync(corruptedFile, "corrupt but package manifests still look valid\n");
  assert.match(
    publishedHarnessDependencyInstallErrors(first.installRoot, plan, identity).join("\n"),
    /full-tree manifest/,
  );

  const repairStaging = createHarnessDependencyStagingRoot(cacheRoot, plan, identity);
  populateSyntheticInstall(repairStaging, plan);
  const repaired = publishHarnessDependencyGeneration(repairStaging, cacheRoot, plan, identity);
  assert.notEqual(repaired.installRoot, first.installRoot);
  assert.equal(existsSync(corruptedFile), true, "the invalid published occupant was preserved");
  assert.deepEqual(publishedHarnessDependencyInstallErrors(repaired.installRoot, plan, identity), []);
});

test("concurrent publishers atomically converge on one immutable generation", { timeout: 15_000 }, async t => {
  const cacheRoot = temporaryRoot(t, "hutch-harness-deps-race-");
  const plan = syntheticPlan();
  const identity = createHarnessDependencyCacheIdentity();
  const stagingRoots = [
    createHarnessDependencyStagingRoot(cacheRoot, plan, identity),
    createHarnessDependencyStagingRoot(cacheRoot, plan, identity),
  ];
  for (const stagingRoot of stagingRoots) populateSyntheticInstall(stagingRoot, plan);

  const barrier = join(cacheRoot, "start");
  const moduleUrl = pathToFileURL(join(scriptDir, "bun-harness-dependencies.js")).href;
  const wirePlan = {
    ...plan,
    lockBytes: plan.lockBytes.toString("base64"),
    packageBytes: plan.packageBytes.toString("base64"),
  };
  const workerSource = `
    import { existsSync } from "node:fs";
    const api = await import(process.env.HUTCH_CACHE_MODULE_URL);
    const plan = JSON.parse(process.env.HUTCH_CACHE_PLAN);
    plan.lockBytes = Buffer.from(plan.lockBytes, "base64");
    plan.packageBytes = Buffer.from(plan.packageBytes, "base64");
    const identity = JSON.parse(process.env.HUTCH_CACHE_IDENTITY);
    while (!existsSync(process.env.HUTCH_CACHE_BARRIER)) {
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
    }
    const result = api.publishHarnessDependencyGeneration(
      process.env.HUTCH_CACHE_STAGING,
      process.env.HUTCH_CACHE_ROOT,
      plan,
      identity,
    );
    console.log(JSON.stringify(result));
  `;
  const workers = stagingRoots.map(stagingRoot => spawn(
    process.execPath,
    ["--input-type=module", "--eval", workerSource],
    {
      env: {
        ...process.env,
        HUTCH_CACHE_BARRIER: barrier,
        HUTCH_CACHE_IDENTITY: JSON.stringify(identity),
        HUTCH_CACHE_MODULE_URL: moduleUrl,
        HUTCH_CACHE_PLAN: JSON.stringify(wirePlan),
        HUTCH_CACHE_ROOT: cacheRoot,
        HUTCH_CACHE_STAGING: stagingRoot,
      },
      stdio: ["ignore", "pipe", "pipe"],
    },
  ));
  const results = workers.map(waitForChild);
  writeFileSync(barrier, "go\n");
  const [left, right] = (await Promise.all(results)).map(output => JSON.parse(output));
  assert.equal(left.installRoot, right.installRoot);
  assert.equal([left.reused, right.reused].filter(Boolean).length, 1);
  assert.deepEqual(publishedHarnessDependencyInstallErrors(left.installRoot, plan, identity), []);
});

test("runner installs privately and materializes an exact published generation", () => {
  const runner = readFileSync(join(scriptDir, "run-bun-package-manager-tests.js"), "utf8");
  assert.match(runner, /createHarnessDependencyStagingRoot\(/);
  assert.match(runner, /findValidHarnessDependencyGeneration\(/);
  assert.match(runner, /publishHarnessDependencyGeneration\(/);
  assert.match(runner, /"--frozen-lockfile"/);
  assert.match(runner, /prepareExecutionSuite\(tempRoot, harnessDependencyInstallRoot\)/);
  assert.match(runner, /HUTCH_COMPAT_HARNESS_CACHE_DIR/);
  assert.match(runner, /join\(os\.tmpdir\(\), "hutch-js-deps"\)/);
  assert.match(runner, /COPYFILE_FICLONE/);
  assert.match(runner, /cpSync\(\s*join\(harnessDependencyInstallRoot, "node_modules"\)/);
  assert.doesNotMatch(runner, /symlinkSync\(\s*join\(harnessDependencyInstallRoot/);
  assert.doesNotMatch(runner, /removeRunnerOwnedPath\(harnessDependencyCacheRoot\)/);
});
