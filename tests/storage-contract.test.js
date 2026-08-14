import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readlinkSync,
  readdirSync,
  realpathSync,
  rmSync,
  statSync,
  symlinkSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const repository = dirname(dirname(fileURLToPath(import.meta.url)));
const packageMetadata = JSON.parse(readFileSync(join(repository, "package.json"), "utf8"));
const platform = {
  "darwin-arm64": "macos-arm64",
  "darwin-x64": "macos-x64",
  "linux-arm64": "linux-arm64",
  "linux-x64": "linux-x64",
  "win32-x64": "windows-x64",
}[`${process.platform}-${process.arch}`];

assert(platform, `unsupported Hutch storage-contract platform: ${process.platform}-${process.arch}`);

const executableSuffix = process.platform === "win32" ? ".exe" : "";
const testBin = process.env.HUTCH_TEST_BIN_DIR ?? join(repository, "zig-out", "bin");
const builtLauncher = join(testBin, `hutch${executableSuffix}`);
const builtEngine = join(testBin, `hutch-engine${executableSuffix}`);
const currentVersion = packageMetadata.version;
const currentRevision = "0123456789abcdef0123456789abcdef01234567";
const unusedRevision = "89abcdef0123456789abcdef0123456789abcdef";
const archiveSha256 = "a".repeat(64);
const automaticRetentionSeconds = 10 * 24 * 60 * 60;

function fixture(prefix) {
  const root = mkdtempSync(join(tmpdir(), prefix));
  const home = join(root, "home");
  mkdirSync(home, { recursive: true });
  return { root, home };
}

function markOwnedStore(home, canonicalRoot = realpathSync(home)) {
  mkdirSync(join(home, "state"), { recursive: true });
  writeFileSync(
    join(home, "state", "store.json"),
    `${JSON.stringify({
      schemaVersion: 1,
      kind: "hutch-store",
      canonicalRoot,
    }, null, 2)}\n`,
  );
}

function writeSelections(home, products) {
  mkdirSync(join(home, "state"), { recursive: true });
  writeFileSync(
    join(home, "state", "selections.json"),
    `${JSON.stringify({
      schemaVersion: 1,
      kind: "hutch-selections",
      products,
    }, null, 2)}\n`,
  );
}

function releaseRoot(home, product, version, revision) {
  return join(home, "releases", product, version, revision, platform);
}

function createRelease(home, {
  product,
  version,
  revision,
  executable,
  currentHutch = false,
}) {
  const root = releaseRoot(home, product, version, revision);
  const bin = join(root, "bin");
  mkdirSync(bin, { recursive: true });
  const executableName = product === "hutch"
    ? `hutch-engine${executableSuffix}`
    : process.platform === "win32" ? `${executable}.exe` : executable;
  const executablePath = join(bin, executableName);

  if (currentHutch) {
    copyFileSync(builtEngine, executablePath);
    copyFileSync(builtLauncher, join(bin, `hutch${executableSuffix}`));
    if (process.platform !== "win32") {
      chmodSync(executablePath, 0o755);
      chmodSync(join(bin, "hutch"), 0o755);
    }
  } else {
    writeFileSync(executablePath, `${product} storage fixture\n`);
    if (process.platform !== "win32") chmodSync(executablePath, 0o755);
  }

  writeFileSync(join(root, ".dash-installed"), archiveSha256);
  writeFileSync(
    join(root, `${product}-release.json`),
    `${JSON.stringify({
      schema: 1,
      kind: "archive",
      product,
      channel: "production",
      version,
      platform,
      revision,
      executable: `bin/${executableName}`,
    }, null, 2)}\n`,
  );
  writeFileSync(`${root}.lock`, "");
  return root;
}

function installCurrentHutch(home) {
  markOwnedStore(home);
  const locks = join(home, "state", "locks");
  mkdirSync(locks, { recursive: true });
  for (const name of ["store.lock", "selections.lock", "graph.lock"]) {
    writeFileSync(join(locks, name), "");
  }
  const root = createRelease(home, {
    product: "hutch",
    version: currentVersion,
    revision: currentRevision,
    executable: "hutch-engine",
    currentHutch: true,
  });
  writeSelections(home, {
    hutch: {
      production: {
        version: currentVersion,
        revision: currentRevision,
        platform,
      },
    },
  });
  mkdirSync(join(home, "bin"), { recursive: true });
  copyFileSync(join(root, "bin", `hutch${executableSuffix}`), join(home, "bin", `hutch${executableSuffix}`));
  if (process.platform !== "win32") chmodSync(join(home, "bin", "hutch"), 0o755);
  return root;
}

function createToolchain(home, version) {
  const root = join(home, "toolchains", "zig", version, platform);
  mkdirSync(root, { recursive: true });
  writeFileSync(join(root, ".hutch-toolchain"), `${version}\n`);
  writeFileSync(join(root, `zig${executableSuffix}`), "zig storage fixture\n");
  writeFileSync(`${root}.lock`, "");
  return root;
}

function relativeRoot(home, path) {
  return relative(home, path).split(sep).join("/");
}

function unreachableSincePath(home, managedRoot) {
  const relativePath = relativeRoot(home, managedRoot);
  const digest = createHash("sha256").update(relativePath).digest("hex");
  return join(home, "state", "unreachable-since", `${digest}.timestamp`);
}

function writeUnreachableSince(home, managedRoot, seconds) {
  const path = unreachableSincePath(home, managedRoot);
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${seconds}\n`);
  const date = new Date(seconds * 1000);
  utimesSync(path, date, date);
  return path;
}

function environment(home, extra = {}) {
  return {
    ...process.env,
    CI: "1",
    HUTCH_HOME: home,
    HUTCH_ACTIVE_CHANNEL: "production",
    HUTCH_NO_UPDATE_CHECK: "1",
    DASH_RELEASE_OFFLINE: "1",
    ...extra,
  };
}

function run(binary, args, home, options = {}) {
  return spawnSync(binary, args, {
    cwd: options.cwd,
    encoding: "utf8",
    env: environment(home, options.env),
    timeout: 15_000,
  });
}

function runAsync(binary, args, home, options = {}) {
  return new Promise((resolveRun, rejectRun) => {
    const child = spawn(binary, args, {
      cwd: options.cwd,
      env: environment(home, options.env),
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8").on("data", (chunk) => { stdout += chunk; });
    child.stderr.setEncoding("utf8").on("data", (chunk) => { stderr += chunk; });
    const timeout = setTimeout(() => child.kill(), 15_000);
    child.once("error", (error) => {
      clearTimeout(timeout);
      rejectRun(error);
    });
    child.once("close", (status, signal) => {
      clearTimeout(timeout);
      resolveRun({ status, signal, stdout, stderr });
    });
  });
}

function assertSucceeded(result) {
  assert.equal(result.error, undefined, result.error?.message);
  assert.equal(result.signal, null, result.stderr || result.stdout);
  assert.equal(result.status, 0, result.stderr || result.stdout);
}

function walkFiles(root) {
  if (!existsSync(root)) return [];
  const output = [];
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    const path = join(root, entry.name);
    if (entry.isDirectory()) output.push(...walkFiles(path));
    else if (entry.isFile()) output.push(path);
  }
  return output;
}

function snapshotTree(root) {
  const entries = [];
  function visit(path, relativePath) {
    const stat = lstatSync(path);
    if (stat.isDirectory()) {
      entries.push({ path: relativePath, type: "directory" });
      for (const entry of readdirSync(path).sort()) {
        visit(join(path, entry), relativePath ? `${relativePath}/${entry}` : entry);
      }
    } else if (stat.isSymbolicLink()) {
      entries.push({ path: relativePath, type: "symlink", target: readlinkSync(path) });
    } else if (stat.isFile()) {
      const bytes = readFileSync(path);
      entries.push({
        path: relativePath,
        type: "file",
        size: bytes.length,
        sha256: createHash("sha256").update(bytes).digest("hex"),
        mtimeMs: stat.mtimeMs,
      });
    } else {
      entries.push({ path: relativePath, type: `other:${stat.mode}` });
    }
  }
  for (const entry of readdirSync(root).sort()) visit(join(root, entry), entry);
  return entries;
}

function createMissingProjectRegistration(home, missingProject) {
  const name = `${createHash("sha256").update(missingProject).digest("hex")}.json`;
  const projects = join(home, "state", "projects");
  mkdirSync(projects, { recursive: true });
  writeFileSync(
    join(projects, name),
    `${JSON.stringify({
      schemaVersion: 1,
      kind: "hutch-project-registration",
      canonicalRoot: missingProject,
      projectLockSha256: "0".repeat(64),
      lastSeenUnixSeconds: Math.floor(Date.now() / 1000),
    }, null, 2)}\n`,
  );
}

function registerProjectObjects(home, project, objects) {
  const canonicalRoot = realpathSync(project);
  const projectState = join(project, ".hutch");
  mkdirSync(projectState, { recursive: true });
  const lockBytes = `${JSON.stringify({
    schemaVersion: 1,
    kind: "hutch-project-dependencies",
    objects,
  })}\n`;
  writeFileSync(join(projectState, "dependencies.lock"), lockBytes);

  const projects = join(home, "state", "projects");
  mkdirSync(projects, { recursive: true });
  const registrationName = `${createHash("sha256").update(canonicalRoot).digest("hex")}.json`;
  writeFileSync(
    join(projects, registrationName),
    `${JSON.stringify({
      schemaVersion: 1,
      kind: "hutch-project-registration",
      canonicalRoot,
      projectLockSha256: createHash("sha256").update(lockBytes).digest("hex"),
      lastSeenUnixSeconds: Math.floor(Date.now() / 1000),
    })}\n`,
  );
}

function projectWithPinnedHutch(root) {
  const project = join(root, "pinned-project");
  mkdirSync(project, { recursive: true });
  writeFileSync(
    join(project, "hutch.config.ts"),
    "// @hutch cli=9.9.9\nexport default {};\n",
  );
  return project;
}

test("top-level help exposes the complete maintenance CLI", () => {
  const { root, home } = fixture("hutch-storage-help-");
  try {
    const result = run(builtEngine, ["--help"], home);
    assertSucceeded(result);
    assert.match(result.stdout, /hutch prune \[--dry-run\]/);
    assert.match(result.stdout, /hutch reset/);
    assert.doesNotMatch(result.stdout, /hutch cache(?:\s|$)/);
    assert.doesNotMatch(result.stdout, /--yes/);

    const pruneHelp = run(builtEngine, ["prune", "--help"], home);
    assertSucceeded(pruneHelp);
    assert.match(pruneHelp.stdout, /--dry-run/);

    const legacyNamespace = run(builtEngine, ["cache", "prune", "--dry-run"], home);
    assert.notEqual(legacyNamespace.status, 0, "the old cache namespace must not remain callable");

    const legacyClean = run(builtEngine, ["cache", "clean", "--dry-run"], home);
    assert.notEqual(legacyClean.status, 0, "the old cache clean command must not remain callable");

    const topLevelClean = run(builtEngine, ["clean"], home);
    assert.notEqual(topLevelClean.status, 0, "clean was replaced by reset");

    for (const flag of ["--yes", "--dry-run"]) {
      const flaggedReset = run(builtEngine, ["reset", flag], home);
      assert.notEqual(flaggedReset.status, 0, `reset must reject ${flag}`);
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("manual prune is immediate and unresolved projects protect nothing", () => {
  const { root, home } = fixture("hutch-storage-prune-");
  try {
    const currentRoot = installCurrentHutch(home);
    const cottontailRoot = createRelease(home, {
      product: "cottontail",
      version: "0.1.0",
      revision: unusedRevision,
      executable: "cottontail",
    });
    const toolchainRoot = createToolchain(home, "0.14.1");
    const oldToolchainRoot = createToolchain(home, "0.13.0");
    const now = Math.floor(Date.now() / 1000);
    writeUnreachableSince(home, toolchainRoot, now);
    const oldUnreachableSince = writeUnreachableSince(
      home,
      oldToolchainRoot,
      now - automaticRetentionSeconds - 24 * 60 * 60,
    );
    const oldUnreachableSinceContents = readFileSync(oldUnreachableSince, "utf8");
    const oldUnreachableSinceMtime = statSync(oldUnreachableSince).mtimeMs;
    createMissingProjectRegistration(home, join(root, "missing-project"));
    const staleTrash = join(
      home,
      "state",
      "trash",
      "111111111111111111111111",
      "leftover",
    );
    mkdirSync(dirname(staleTrash), { recursive: true });
    writeFileSync(staleTrash, "must survive a preview");
    const project = projectWithPinnedHutch(root);
    const launcher = join(currentRoot, "bin", `hutch${executableSuffix}`);

    const beforePreview = snapshotTree(home);
    const preview = run(launcher, ["prune", "--dry-run"], home, { cwd: project });
    assertSucceeded(preview);
    assert.deepEqual(
      snapshotTree(home),
      beforePreview,
      "dry-run must not add, remove, rewrite, or retimestamp store state",
    );
    assert(existsSync(cottontailRoot), "dry-run must retain an unused Cottontail release");
    assert(existsSync(toolchainRoot), "dry-run must retain an unused toolchain");
    assert(existsSync(oldToolchainRoot), "dry-run must suppress the automatic retention sweep");
    assert.equal(readFileSync(oldUnreachableSince, "utf8"), oldUnreachableSinceContents);
    assert.equal(statSync(oldUnreachableSince).mtimeMs, oldUnreachableSinceMtime);
    assert.match(preview.stdout, /cottontail/);
    assert.match(preview.stdout, /toolchains[\\/]zig/);

    const prune = run(launcher, ["prune"], home, { cwd: project });
    assertSucceeded(prune);
    assert(!existsSync(cottontailRoot), "manual prune removes a fresh, unreferenced release");
    assert(!existsSync(toolchainRoot), "manual prune removes a fresh, unreferenced toolchain");
    assert(!existsSync(oldToolchainRoot), "manual prune removes an expired toolchain");
    assert(existsSync(currentRoot), "manual prune retains the selected Hutch release");
    assert(!existsSync(staleTrash), "a real prune cleans detached trash");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("lazy pruning tracks each continuous period of unreachability", () => {
  const { root, home } = fixture("hutch-storage-unreachable-since-");
  try {
    const currentRoot = installCurrentHutch(home);
    const toolchainRoot = createToolchain(home, "0.14.3");
    const marker = unreachableSincePath(home, toolchainRoot);
    const launcher = join(currentRoot, "bin", `hutch${executableSuffix}`);

    const first = run(launcher, ["--version"], home, { cwd: root });
    assertSucceeded(first);
    assert(existsSync(marker), "the first unreachable observation starts retention");
    const firstContents = readFileSync(marker, "utf8");
    assert.match(firstContents, /^\d+\n$/);

    const fixedMtime = new Date(1_000_000);
    utimesSync(marker, fixedMtime, fixedMtime);
    const second = run(launcher, ["--version"], home, { cwd: root });
    assertSucceeded(second);
    assert.equal(readFileSync(marker, "utf8"), firstContents);
    assert.equal(
      statSync(marker).mtimeMs,
      fixedMtime.getTime(),
      "ordinary invocations must not restart an existing retention period",
    );

    const project = join(root, "live-project");
    mkdirSync(project, { recursive: true });
    registerProjectObjects(home, project, [{
      type: "toolchain",
      relativeRoot: relativeRoot(home, toolchainRoot),
      version: "0.14.3",
      platform,
      toolchain: "zig",
    }]);
    const reachable = run(launcher, ["--version"], home, { cwd: root });
    assertSucceeded(reachable);
    assert(!existsSync(marker), "becoming reachable clears unreachable-since state");
    assert(existsSync(toolchainRoot));

    rmSync(project, { recursive: true, force: true });
    const restartFloor = Math.floor(Date.now() / 1000) - 1;
    const unreachableAgain = run(launcher, ["--version"], home, { cwd: root });
    assertSucceeded(unreachableAgain);
    assert(existsSync(marker), "a later unreachable period gets a fresh timestamp");
    assert(Number.parseInt(readFileSync(marker, "utf8"), 10) >= restartFloor);

    writeUnreachableSince(
      home,
      toolchainRoot,
      Math.floor(Date.now() / 1000) - automaticRetentionSeconds - 1,
    );
    const expired = run(launcher, ["--version"], home, { cwd: root });
    assertSucceeded(expired);
    assert(!existsSync(toolchainRoot), "automatic pruning removes the object after ten days");
    assert(!existsSync(marker), "pruning also removes unreachable-since state");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("manual prune protects selected and currently executing Hutch releases independently", () => {
  const { root, home } = fixture("hutch-storage-current-selection-");
  try {
    const currentRoot = installCurrentHutch(home);
    const selectedRoot = createRelease(home, {
      product: "hutch",
      version: "9.9.9",
      revision: unusedRevision,
      executable: "hutch-engine",
    });
    const unusedRoot = createToolchain(home, "0.14.4");
    writeSelections(home, {
      hutch: {
        production: {
          version: "9.9.9",
          revision: unusedRevision,
          platform,
        },
      },
    });

    const currentEngine = join(currentRoot, "bin", `hutch-engine${executableSuffix}`);
    const prune = run(currentEngine, ["prune"], home, { cwd: root });
    assertSucceeded(prune);
    assert(existsSync(currentRoot), "the executing managed Hutch remains usable when unselected");
    assert(existsSync(selectedRoot), "an independently selected Hutch release remains installed");
    assert(!existsSync(unusedRoot), "an unrelated unused object is still pruned");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("every invocation lazily prunes objects older than ten days", () => {
  const { root, home } = fixture("hutch-storage-lazy-prune-");
  try {
    const currentRoot = installCurrentHutch(home);
    const oldRoot = createToolchain(home, "0.14.1");
    const youngRoot = createToolchain(home, "0.14.2");
    const now = Math.floor(Date.now() / 1000);
    writeUnreachableSince(home, oldRoot, now - automaticRetentionSeconds - 24 * 60 * 60);
    writeUnreachableSince(home, youngRoot, now - automaticRetentionSeconds + 24 * 60 * 60);

    const launcher = join(currentRoot, "bin", `hutch${executableSuffix}`);
    const version = run(launcher, ["--version"], home, { cwd: root });
    assertSucceeded(version);
    assert.equal(version.stdout.trim(), currentVersion);
    assert(!existsSync(oldRoot), "the 11-day-old unreachable toolchain is pruned lazily");
    assert(existsSync(youngRoot), "the 9-day-old unreachable toolchain remains inside retention");
    assert(existsSync(currentRoot), "the selected Hutch release remains reachable");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("release resolution retains payloads and selections, never fetched metadata", async () => {
  const { root, home } = fixture("hutch-storage-metadata-");
  const version = "9.8.7";
  const revision = unusedRevision;
  const executableName = process.platform === "win32" ? "cottontail.exe" : "cottontail";
  const packageName = `cottontail-v${version}-${platform}`;
  const packageRoot = join(root, packageName);
  const packageBin = join(packageRoot, "bin");
  const archivePath = join(root, "cottontail.tar.gz");
  const poison = "remote-metadata-must-not-persist";
  let server;
  let artifactsBaseUrl;

  try {
    markOwnedStore(home);
    mkdirSync(packageBin, { recursive: true });
    writeFileSync(join(packageBin, executableName), "cottontail release fixture\n");
    if (process.platform !== "win32") chmodSync(join(packageBin, executableName), 0o755);
    writeFileSync(
      join(packageRoot, "cottontail-release.json"),
      `${JSON.stringify({
        schema: 1,
        kind: "archive",
        product: "cottontail",
        channel: "production",
        version,
        platform,
        revision,
        executable: `bin/${executableName}`,
      }, null, 2)}\n`,
    );
    const tar = spawnSync("tar", ["-czf", archivePath, "-C", root, packageName], { encoding: "utf8" });
    assertSucceeded(tar);
    const archive = readFileSync(archivePath);
    const checksum = createHash("sha256").update(archive).digest("hex");

    server = createServer((request, response) => {
      const metadata = {
        "/cottontail/channels/production.json": {
          schema: 1,
          kind: "channel",
          product: "cottontail",
          channel: "production",
          version,
          revision,
          poison,
          release: { url: `${artifactsBaseUrl}/cottontail/releases/${version}/manifest.json` },
        },
        [`/cottontail/releases/${version}/manifest.json`]: {
          schema: 1,
          kind: "release",
          product: "cottontail",
          channel: "production",
          version,
          revision,
          poison,
          platforms: {
            [platform]: {
              archive: {
                url: `${artifactsBaseUrl}/cottontail/builds/${revision}/${platform}/cottontail.tar.gz`,
                sha256: checksum,
                size: archive.length,
              },
            },
          },
        },
      };
      if (request.url in metadata) {
        response.writeHead(200, { "content-type": "application/json" });
        response.end(`${JSON.stringify(metadata[request.url])}\n`);
      } else if (request.url?.endsWith("/cottontail.tar.gz")) {
        response.writeHead(200, {
          "content-type": "application/gzip",
          "content-length": archive.length,
        });
        response.end(archive);
      } else {
        response.writeHead(404);
        response.end("not found");
      }
    });
    await new Promise((resolveListen, rejectListen) => {
      server.once("error", rejectListen);
      server.listen(0, "127.0.0.1", resolveListen);
    });
    artifactsBaseUrl = `http://127.0.0.1:${server.address().port}`;

    const result = await runAsync(builtEngine, ["cottontail", "path", "production"], home, {
      env: {
        DASH_ARTIFACTS_BASE_URL: artifactsBaseUrl,
        DASH_RELEASE_OFFLINE: "0",
      },
    });
    assert.equal(result.status, 0, result.stderr || result.stdout);
    const installed = result.stdout.trim();
    assert(installed.startsWith(join(home, "releases", "cottontail") + sep));
    assert(existsSync(installed));

    const topLevel = readdirSync(home).sort();
    assert(!topLevel.includes("cache"), "remote metadata has no persistent cache root");
    assert(!topLevel.includes("channels"), "local selections have no channels root");
    assert(!topLevel.includes("products"), "installed payloads use releases, not products");
    assert(topLevel.every((name) => ["bin", "releases", "state", "toolchains"].includes(name)));
    for (const file of walkFiles(home)) {
      if (statSync(file).size > 1024 * 1024) continue;
      const bytes = readFileSync(file);
      assert(!bytes.includes(poison), `fetched metadata leaked into ${file}`);
      if (!file.startsWith(join(home, "releases") + sep)) {
        assert(!bytes.includes(artifactsBaseUrl), `a fetched artifact URL leaked into ${file}`);
        assert(!bytes.includes(checksum), `a fetched artifact checksum leaked into ${file}`);
      }
    }
  } finally {
    if (server?.listening) await new Promise((resolveClose) => server.close(resolveClose));
    rmSync(root, { recursive: true, force: true });
  }
});

test("reset refuses unowned, mismatched, and symlinked stores before mutation", () => {
  const expectedReason = {
    unmarked: /(?:not owned|ownership|store marker)/i,
    mismatched: /(?:canonical|mismatch|does not match)/i,
    symlinked: /(?:symlink|symbolic link)/i,
  };
  for (const scenario of ["unmarked", "mismatched", "symlinked"]) {
    const { root, home } = fixture(`hutch-storage-reset-${scenario}-`);
    try {
      const sentinel = join(home, "must-survive.txt");
      writeFileSync(sentinel, scenario);
      let invokedHome = home;
      if (scenario === "mismatched") {
        markOwnedStore(home, join(root, "different-home"));
      } else if (scenario === "symlinked") {
        markOwnedStore(home);
        invokedHome = join(root, "home-link");
        symlinkSync(home, invokedHome, process.platform === "win32" ? "junction" : "dir");
        assert(lstatSync(invokedHome).isSymbolicLink());
      }

      const result = run(builtEngine, ["reset"], invokedHome, { cwd: root });
      assert.notEqual(result.status, 0, `${scenario} store reset unexpectedly succeeded`);
      assert.match(
        `${result.stdout}\n${result.stderr}`,
        expectedReason[scenario],
        `${scenario} store was rejected without the expected ownership reason`,
      );
      assert.equal(readFileSync(sentinel, "utf8"), scenario, `${scenario} store was mutated`);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  }
});

test("reset immediately recreates a minimal store around the selected Hutch", () => {
  const { root, home } = fixture("hutch-storage-reset-");
  try {
    const currentRoot = installCurrentHutch(home);
    const pinnedRoot = createRelease(home, {
      product: "hutch",
      version: "9.9.9",
      revision: unusedRevision,
      executable: "hutch-engine",
    });
    const cottontailRoot = createRelease(home, {
      product: "cottontail",
      version: "0.1.0",
      revision: unusedRevision,
      executable: "cottontail",
    });
    const toolchainRoot = createToolchain(home, "0.14.1");
    mkdirSync(join(home, "cache", "legacy"), { recursive: true });
    mkdirSync(join(home, "channels", "legacy"), { recursive: true });
    mkdirSync(join(home, "products", "legacy"), { recursive: true });
    writeFileSync(join(home, "unmanaged-junk"), "remove me");
    const project = projectWithPinnedHutch(root);
    const launcher = join(currentRoot, "bin", `hutch${executableSuffix}`);

    const unsupportedConfirmation = run(launcher, ["reset", "--yes"], home, { cwd: project });
    assert.notEqual(unsupportedConfirmation.status, 0, "reset has no confirmation flag");
    assert(existsSync(pinnedRoot), "an invalid reset invocation must not mutate the store");

    const result = run(launcher, ["reset"], home, { cwd: project });
    assertSucceeded(result);
    assert(!existsSync(pinnedRoot), "reset removes an arbitrary pinned Hutch release");
    assert(!existsSync(cottontailRoot), "reset removes non-Hutch releases");
    assert(!existsSync(toolchainRoot), "reset removes every toolchain");
    assert(!existsSync(join(home, "cache")));
    assert(!existsSync(join(home, "channels")));
    assert(!existsSync(join(home, "products")));
    assert(!existsSync(join(home, "unmanaged-junk")));
    assert(existsSync(currentRoot), "reset reseeds the selected current Hutch release");

    const topLevel = readdirSync(home).sort();
    assert(topLevel.includes("bin"));
    assert(topLevel.includes("releases"));
    assert(topLevel.includes("state"));
    assert(topLevel.every((name) => ["bin", "releases", "state", "toolchains"].includes(name)));
    if (topLevel.includes("toolchains")) {
      assert.deepEqual(readdirSync(join(home, "toolchains")), []);
    }
    const store = JSON.parse(readFileSync(join(home, "state", "store.json"), "utf8"));
    assert.deepEqual(store, {
      schemaVersion: 1,
      kind: "hutch-store",
      canonicalRoot: realpathSync(home),
    });
    const selections = JSON.parse(readFileSync(join(home, "state", "selections.json"), "utf8"));
    assert.deepEqual(selections, {
      schemaVersion: 1,
      kind: "hutch-selections",
      products: {
        hutch: {
          production: {
            version: currentVersion,
            revision: currentRevision,
            platform,
          },
        },
      },
    });

    const installedLauncher = join(home, "bin", `hutch${executableSuffix}`);
    assert(existsSync(installedLauncher), "reset restores the global Hutch launcher");
    const version = run(installedLauncher, ["--version"], home, { cwd: root });
    assertSucceeded(version);
    assert.equal(version.stdout.trim(), currentVersion);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
