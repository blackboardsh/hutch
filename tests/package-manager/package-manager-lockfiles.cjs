"use strict";

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawn, spawnSync } = require("node:child_process");
const { gzipSync } = require("node:zlib");

const cottontail = path.resolve(process.argv[2] || "zig-out/bin/cottontail");
const nodeProbe = spawnSync("node", ["-p", "process.execPath"], { encoding: "utf8" });
assert.equal(nodeProbe.status, 0, `failed to resolve host Node executable: ${nodeProbe.stderr}`);
const nodeRuntime = path.resolve(nodeProbe.stdout.trim());
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "cottontail-lockfiles-"));
const servers = [];

function writeJson(root, relative, value) {
  const filename = path.join(root, relative);
  fs.mkdirSync(path.dirname(filename), { recursive: true });
  fs.writeFileSync(filename, `${JSON.stringify(value, null, 2)}\n`);
}

function writeTarField(header, offset, width, value) {
  header.write(`${value.toString(8).padStart(width - 1, "0")}\0`, offset, width, "ascii");
}

function packageArchive(packageJson) {
  const body = Buffer.from(`${JSON.stringify(packageJson)}\n`);
  const header = Buffer.alloc(512);
  header.write("package/package.json", 0, 100, "utf8");
  writeTarField(header, 100, 8, 0o644);
  writeTarField(header, 108, 8, 0);
  writeTarField(header, 116, 8, 0);
  writeTarField(header, 124, 12, body.length);
  writeTarField(header, 136, 12, 0);
  header.fill(0x20, 148, 156);
  header[156] = "0".charCodeAt(0);
  header.write("ustar\0", 257, 6, "ascii");
  header.write("00", 263, 2, "ascii");
  const checksum = header.reduce((sum, byte) => sum + byte, 0);
  header.write(checksum.toString(8).padStart(6, "0"), 148, 6, "ascii");
  header[154] = 0;
  header[155] = 0x20;
  const padding = Buffer.alloc((512 - (body.length % 512)) % 512);
  return gzipSync(Buffer.concat([header, body, padding, Buffer.alloc(1024)]));
}

function writeArchive(root, name = "archived", version = "1.2.3") {
  const archive = packageArchive({ name, version });
  fs.writeFileSync(path.join(root, `${name}.tgz`), archive);
  return {
    archive,
    integrity: `sha512-${crypto.createHash("sha512").update(archive).digest("base64")}`,
  };
}

function install(root, args = [], silent = true) {
  return spawnSync(
    cottontail,
    ["install", ...args, "--ignore-scripts", ...(silent ? ["--silent"] : [])],
    { cwd: root, encoding: "utf8", timeout: 30_000 },
  );
}

function expectSuccess(result) {
  assert.equal(result.status, 0, `install failed\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`);
}

function waitForFile(filename) {
  const signal = new Int32Array(new SharedArrayBuffer(4));
  for (let attempt = 0; attempt < 250; attempt += 1) {
    if (fs.existsSync(filename)) return;
    Atomics.wait(signal, 0, 0, 20);
  }
  throw new Error(`timed out waiting for ${filename}`);
}

function startRegistry() {
  const root = path.join(scratch, "registry");
  fs.mkdirSync(root, { recursive: true });
  const archive = packageArchive({ name: "remote", version: "1.0.0" });
  const integrity = `sha512-${crypto.createHash("sha512").update(archive).digest("base64")}`;
  fs.writeFileSync(path.join(root, "remote.tgz"), archive);
  const portFile = path.join(root, "port");
  const requestFile = path.join(root, "requests");
  const serverFile = path.join(root, "server.cjs");
  fs.writeFileSync(
    serverFile,
    `
"use strict";
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const [root, portFile, requestFile, integrity] = process.argv.slice(2);
const server = http.createServer((request, response) => {
  fs.appendFileSync(requestFile, request.url + "\\n");
  if (request.url === "/remote.tgz") {
    response.writeHead(200, { "content-type": "application/octet-stream" });
    fs.createReadStream(path.join(root, "remote.tgz")).pipe(response);
    return;
  }
  if (request.url !== "/remote") return response.writeHead(404).end();
  const tarball = "http://127.0.0.1:" + server.address().port + "/remote.tgz";
  response.writeHead(200, { "content-type": "application/json" });
  response.end(JSON.stringify({
    name: "remote",
    "dist-tags": { latest: "1.0.0" },
    versions: { "1.0.0": { name: "remote", version: "1.0.0", dist: { tarball, integrity } } },
  }));
});
server.listen(0, "127.0.0.1", () => fs.writeFileSync(portFile, String(server.address().port)));
`,
  );
  const server = spawn(nodeRuntime, [serverFile, root, portFile, requestFile, integrity], {
    stdio: ["ignore", "ignore", "inherit"],
  });
  servers.push(server);
  waitForFile(portFile);
  return {
    requestFile,
    url: `http://127.0.0.1:${fs.readFileSync(portFile, "utf8")}/`,
  };
}

function makeLocalProject(root, dependencyOrder = ["zeta", "alpha"]) {
  const dependencies = {};
  for (const name of dependencyOrder) dependencies[name] = `file:./vendor/${name}`;
  writeJson(root, "package.json", { name: "deterministic", dependencies });
  writeJson(root, "vendor/alpha/package.json", {
    name: "alpha",
    version: "1.0.0",
    bin: { zeta: "z.js", alpha: "a.js" },
  });
  writeJson(root, "vendor/zeta/package.json", { name: "zeta", version: "2.0.0" });
}

try {
  // Integrity: a corrupted archive must fail a frozen install and leave the
  // lockfile untouched.
  const integrityRoot = path.join(scratch, "integrity");
  fs.mkdirSync(integrityRoot, { recursive: true });
  const integrityArchive = writeArchive(integrityRoot);
  writeJson(integrityRoot, "package.json", {
    name: "integrity-fixture",
    dependencies: { archived: "file:./archived.tgz" },
  });
  expectSuccess(install(integrityRoot));
  const integrityLock = fs.readFileSync(path.join(integrityRoot, "hutch.lock"), "utf8");
  assert.ok(integrityLock.includes(integrityArchive.integrity));
  fs.rmSync(path.join(integrityRoot, "node_modules"), { recursive: true, force: true });
  fs.writeFileSync(
    path.join(integrityRoot, "archived.tgz"),
    Buffer.concat([integrityArchive.archive, Buffer.from("corrupt")]),
  );
  const integrityFailure = install(integrityRoot, ["--frozen-lockfile"]);
  assert.equal(integrityFailure.status, 1);
  assert.match(integrityFailure.stderr, /Integrity check failed/);
  assert.equal(fs.readFileSync(path.join(integrityRoot, "hutch.lock"), "utf8"), integrityLock);

  // Determinism: dependency declaration order must not change hutch.lock.
  const first = path.join(scratch, "deterministic-first");
  const second = path.join(scratch, "deterministic-second");
  makeLocalProject(first, ["zeta", "alpha"]);
  makeLocalProject(second, ["alpha", "zeta"]);
  expectSuccess(install(first));
  expectSuccess(install(second));
  const firstLock = fs.readFileSync(path.join(first, "hutch.lock"), "utf8");
  const secondLock = fs.readFileSync(path.join(second, "hutch.lock"), "utf8");
  assert.equal(firstLock, secondLock);
  assert.match(firstLock, /"configVersion": 1/);
  assert.ok(firstLock.indexOf('"alpha"') < firstLock.indexOf('"zeta"'));

  fs.writeFileSync(path.join(first, "hutch.lock"), firstLock.replace(/  "configVersion": 1,\n/, ""));
  expectSuccess(install(first));
  assert.match(fs.readFileSync(path.join(first, "hutch.lock"), "utf8"), /"configVersion": 0/);

  const beforeFrozen = fs.readFileSync(path.join(second, "hutch.lock"), "utf8");
  const changedPackage = JSON.parse(fs.readFileSync(path.join(second, "package.json"), "utf8"));
  changedPackage.dependencies.alpha = "file:./vendor/zeta";
  writeJson(second, "package.json", changedPackage);
  const frozen = install(second, ["--frozen-lockfile"]);
  assert.equal(frozen.status, 1);
  assert.match(frozen.stderr, /lockfile had changes, but lockfile is frozen/);
  assert.equal(fs.readFileSync(path.join(second, "hutch.lock"), "utf8"), beforeFrozen);

  // A frozen install without a lockfile is valid only when the declared
  // dependency/workspace graph is provably empty. It remains a read-only
  // no-op and must not manufacture an empty lockfile or node_modules tree.
  const frozenEmpty = path.join(scratch, "frozen-empty");
  writeJson(frozenEmpty, "package.json", { name: "frozen-empty", version: "1.0.0" });
  expectSuccess(install(frozenEmpty, ["--frozen-lockfile"]));
  assert.equal(fs.existsSync(path.join(frozenEmpty, "hutch.lock")), false);
  assert.equal(fs.existsSync(path.join(frozenEmpty, "node_modules")), false);

  const frozenEmptyWorkspaceList = path.join(scratch, "frozen-empty-workspaces");
  writeJson(frozenEmptyWorkspaceList, "package.json", {
    name: "frozen-empty-workspaces",
    workspaces: { packages: [] },
  });
  expectSuccess(install(frozenEmptyWorkspaceList, ["--frozen-lockfile"]));
  assert.equal(fs.existsSync(path.join(frozenEmptyWorkspaceList, "hutch.lock")), false);
  assert.equal(fs.existsSync(path.join(frozenEmptyWorkspaceList, "node_modules")), false);

  const frozenEmptyWorkspaceArray = path.join(scratch, "frozen-empty-workspace-array");
  writeJson(frozenEmptyWorkspaceArray, "package.json", {
    name: "frozen-empty-workspace-array",
    workspaces: [],
  });
  expectSuccess(install(frozenEmptyWorkspaceArray, ["--frozen-lockfile"]));
  assert.equal(fs.existsSync(path.join(frozenEmptyWorkspaceArray, "hutch.lock")), false);
  assert.equal(fs.existsSync(path.join(frozenEmptyWorkspaceArray, "node_modules")), false);

  const frozenMissingDependency = path.join(scratch, "frozen-missing-dependency");
  writeJson(frozenMissingDependency, "package.json", {
    name: "frozen-missing-dependency",
    dependencies: { missing: "file:./missing" },
  });
  const missingDependencyResult = install(frozenMissingDependency, ["--frozen-lockfile"]);
  assert.equal(missingDependencyResult.status, 1);
  assert.match(missingDependencyResult.stderr, /lockfile not found, but lockfile is frozen/);
  assert.equal(fs.existsSync(path.join(frozenMissingDependency, "hutch.lock")), false);
  assert.equal(fs.existsSync(path.join(frozenMissingDependency, "node_modules")), false);

  const frozenMissingWorkspace = path.join(scratch, "frozen-missing-workspace");
  writeJson(frozenMissingWorkspace, "package.json", {
    name: "frozen-missing-workspace",
    workspaces: ["packages/*"],
  });
  const missingWorkspaceResult = install(frozenMissingWorkspace, ["--frozen-lockfile"]);
  assert.equal(missingWorkspaceResult.status, 1);
  assert.match(missingWorkspaceResult.stderr, /lockfile not found, but lockfile is frozen/);
  assert.equal(fs.existsSync(path.join(frozenMissingWorkspace, "hutch.lock")), false);
  assert.equal(fs.existsSync(path.join(frozenMissingWorkspace, "node_modules")), false);

  // Dependency aliases are filesystem destinations. Reject a malicious root
  // edge before node_modules preparation or any outside-tree mutation.
  const traversalBase = path.join(scratch, "root-traversal");
  const traversalRoot = path.join(traversalBase, "project");
  const traversalSentinel = path.join(traversalBase, "sentinel");
  writeJson(traversalRoot, "package.json", {
    name: "root-traversal",
    dependencies: { "../../sentinel": "file:../sentinel" },
  });
  fs.mkdirSync(traversalSentinel, { recursive: true });
  fs.writeFileSync(path.join(traversalSentinel, "marker"), "preserve\n");
  const traversalResult = install(traversalRoot);
  assert.equal(traversalResult.status, 1);
  assert.match(traversalResult.stderr, /InvalidDependencyAlias/);
  assert.equal(fs.readFileSync(path.join(traversalSentinel, "marker"), "utf8"), "preserve\n");
  assert.equal(fs.existsSync(path.join(traversalRoot, "hutch.lock")), false);
  assert.equal(fs.existsSync(path.join(traversalRoot, "node_modules")), false);

  if (process.platform !== "win32") {
    // A lexical in-tree path is still unsafe when its scoped ancestor is a
    // symlink. Refuse to traverse it and preserve the external sentinel.
    const scopeRoot = path.join(scratch, "scope-symlink");
    const scopeOutside = path.join(scratch, "scope-outside");
    writeJson(scopeRoot, "package.json", {
      name: "scope-symlink",
      dependencies: { "@scope/pkg": "file:./vendor/pkg" },
    });
    writeJson(scopeRoot, "vendor/pkg/package.json", { name: "@scope/pkg", version: "1.0.0" });
    fs.mkdirSync(path.join(scopeRoot, "node_modules"), { recursive: true });
    fs.mkdirSync(path.join(scopeOutside, "pkg"), { recursive: true });
    fs.writeFileSync(path.join(scopeOutside, "pkg", "marker"), "preserve\n");
    fs.symlinkSync(scopeOutside, path.join(scopeRoot, "node_modules", "@scope"), "dir");
    const scopeResult = install(scopeRoot);
    assert.equal(scopeResult.status, 1);
    assert.match(scopeResult.stderr, /InvalidPackageDestination/);
    assert.equal(fs.readFileSync(path.join(scopeOutside, "pkg", "marker"), "utf8"), "preserve\n");
    assert.equal(fs.existsSync(path.join(scopeRoot, "hutch.lock")), false);

    // Isolated finalization enumerates managed .bin directories. A preexisting
    // symlink must be rejected before pruning so it cannot delete external files.
    const isolatedBinRoot = path.join(scratch, "isolated-bin-symlink");
    const isolatedBinOutside = path.join(scratch, "isolated-bin-outside");
    writeJson(isolatedBinRoot, "package.json", {
      name: "isolated-bin-symlink",
      dependencies: { safe: "file:./vendor/safe" },
    });
    writeJson(isolatedBinRoot, "vendor/safe/package.json", { name: "safe", version: "1.0.0" });
    fs.writeFileSync(path.join(isolatedBinRoot, "bunfig.toml"), '[install]\nlinker = "isolated"\n');
    fs.mkdirSync(path.join(isolatedBinRoot, "node_modules", ".bun", "node_modules"), { recursive: true });
    fs.mkdirSync(isolatedBinOutside, { recursive: true });
    fs.writeFileSync(path.join(isolatedBinOutside, "marker"), "preserve\n");
    fs.symlinkSync(isolatedBinOutside, path.join(isolatedBinRoot, "node_modules", ".bin"), "dir");
    const isolatedBinResult = install(isolatedBinRoot);
    assert.equal(isolatedBinResult.status, 1);
    assert.match(isolatedBinResult.stderr, /InvalidPackageDestination/);
    assert.equal(fs.readFileSync(path.join(isolatedBinOutside, "marker"), "utf8"), "preserve\n");

    // Folder packages are linked into node_modules. Bin preparation must not
    // chmod or normalize the physical source through that symlinked base.
    const linkedBinRoot = path.join(scratch, "linked-bin-source");
    const linkedBinTarget = path.join(linkedBinRoot, "vendor", "linked", "cli.js");
    writeJson(linkedBinRoot, "package.json", {
      name: "linked-bin-source",
      dependencies: { linked: "file:./vendor/linked" },
    });
    writeJson(linkedBinRoot, "vendor/linked/package.json", {
      name: "linked",
      version: "1.0.0",
      bin: { linked: "cli.js" },
    });
    fs.writeFileSync(linkedBinTarget, "#!/usr/bin/env node\r\nconsole.log('linked');\n");
    fs.chmodSync(linkedBinTarget, 0o644);
    expectSuccess(install(linkedBinRoot));
    assert.equal(fs.statSync(linkedBinTarget).mode & 0o111, 0, "install chmodded a linked package source");
    assert.match(fs.readFileSync(linkedBinTarget, "utf8"), /node\r\n/);
  }

  // A crafted transitive lock alias is rejected during lock parsing, before
  // it can become a nested node_modules destination.
  const craftedLockRoot = path.join(scratch, "crafted-lock-traversal");
  writeJson(craftedLockRoot, "package.json", {
    name: "crafted-lock-traversal",
    dependencies: { safe: "1.0.0" },
  });
  const craftedLock = {
    lockfileVersion: 1,
    workspaces: { "": { name: "crafted-lock-traversal", dependencies: { safe: "1.0.0" } } },
    packages: {
      safe: ["safe@1.0.0", "", { dependencies: { "../../sentinel": "1.0.0" } }, ""],
    },
  };
  writeJson(craftedLockRoot, "hutch.lock", craftedLock);
  const craftedSentinel = path.join(scratch, "sentinel");
  fs.mkdirSync(craftedSentinel, { recursive: true });
  fs.writeFileSync(path.join(craftedSentinel, "marker"), "preserve\n");
  const craftedBefore = fs.readFileSync(path.join(craftedLockRoot, "hutch.lock"), "utf8");
  const craftedResult = install(craftedLockRoot, ["--frozen-lockfile"]);
  assert.equal(craftedResult.status, 1);
  assert.match(craftedResult.stderr, /InvalidDependencyAlias/);
  assert.equal(fs.readFileSync(path.join(craftedSentinel, "marker"), "utf8"), "preserve\n");
  assert.equal(fs.readFileSync(path.join(craftedLockRoot, "hutch.lock"), "utf8"), craftedBefore);
  assert.equal(fs.existsSync(path.join(craftedLockRoot, "node_modules")), false);

  const noSave = path.join(scratch, "no-save");
  makeLocalProject(noSave, ["alpha"]);
  expectSuccess(install(noSave, ["--no-save"]));
  assert.equal(fs.existsSync(path.join(noSave, "hutch.lock")), false);

  // Registry resolution through the local fixture server, lockfile-only.
  const lockfileOnly = path.join(scratch, "lockfile-only");
  const registry = startRegistry();
  writeJson(lockfileOnly, "package.json", { name: "lockfile-only", dependencies: { remote: "1.0.0" } });
  fs.writeFileSync(path.join(lockfileOnly, "bunfig.toml"), `[install]\nregistry = "${registry.url}"\n`);
  expectSuccess(install(lockfileOnly, ["--lockfile-only"]));
  assert.equal(fs.existsSync(path.join(lockfileOnly, "hutch.lock")), true);
  assert.equal(fs.existsSync(path.join(lockfileOnly, "node_modules")), false);
  assert.deepEqual(fs.readFileSync(registry.requestFile, "utf8").trim().split(/\r?\n/), ["/remote"]);

  // hutch.lock owns resolver selection; a stale foreign lockfile beside it
  // is neither read, migrated, nor modified.
  const foreignRoot = path.join(scratch, "foreign-lockfile");
  makeLocalProject(foreignRoot, ["alpha"]);
  expectSuccess(install(foreignRoot));
  const foreignLockBefore = fs.readFileSync(path.join(foreignRoot, "hutch.lock"), "utf8");
  fs.writeFileSync(path.join(foreignRoot, "bun.lockb"), "not a lockfile hutch would read");
  expectSuccess(install(foreignRoot));
  assert.equal(fs.readFileSync(path.join(foreignRoot, "hutch.lock"), "utf8"), foreignLockBefore);
  assert.equal(
    fs.readFileSync(path.join(foreignRoot, "bun.lockb"), "utf8"),
    "not a lockfile hutch would read",
  );

  // Git dependencies install as checked out from a pinned commit; lifecycle
  // scripts (including prepare) never run.
  const gitFixture = path.join(scratch, "git-fixture-repo");
  fs.mkdirSync(gitFixture, { recursive: true });
  writeJson(gitFixture, "package.json", {
    name: "git-dep",
    version: "1.0.0",
    scripts: { prepare: "node -e \"require('fs').writeFileSync('prepare-ran','')\"" },
  });
  fs.writeFileSync(path.join(gitFixture, "lib.js"), "module.exports = 42;\n");
  const git = (args, cwd = gitFixture) => {
    const result = spawnSync("git", args, { cwd, encoding: "utf8" });
    assert.equal(result.status, 0, `git ${args.join(" ")} failed: ${result.stderr}`);
  };
  git(["init", "--quiet", "--initial-branch=main"]);
  git(["-c", "user.email=t@t", "-c", "user.name=t", "add", "."]);
  git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--quiet", "-m", "v1"]);
  git(["tag", "v1.0.0"]);

  const gitRoot = path.join(scratch, "git-consumer");
  writeJson(gitRoot, "package.json", {
    name: "git-consumer",
    dependencies: { "git-dep": `git+file://${gitFixture}#v1.0.0` },
  });
  expectSuccess(install(gitRoot));
  const gitLock = fs.readFileSync(path.join(gitRoot, "hutch.lock"), "utf8");
  assert.match(gitLock, /git-dep@git\+file/);
  const installedGitDep = path.join(gitRoot, "node_modules", "git-dep");
  assert.equal(
    JSON.parse(fs.readFileSync(path.join(installedGitDep, "package.json"), "utf8")).version,
    "1.0.0",
  );
  assert.equal(
    fs.existsSync(path.join(installedGitDep, "prepare-ran")),
    false,
    "git dependencies must install without running prepare",
  );
  fs.rmSync(path.join(gitRoot, "node_modules"), { recursive: true, force: true });
  expectSuccess(install(gitRoot, ["--frozen-lockfile"]));
  assert.equal(fs.readFileSync(path.join(gitRoot, "hutch.lock"), "utf8"), gitLock);

  // Workspaces are out of scope for the built-in resolver.
  const monorepo = path.join(scratch, "workspaces-rejected");
  writeJson(monorepo, "package.json", { name: "monorepo", workspaces: ["packages/*"] });
  writeJson(monorepo, "packages/app/package.json", { name: "app", version: "1.0.0" });
  const workspaceResult = install(monorepo);
  assert.equal(workspaceResult.status, 1);
  assert.match(workspaceResult.stderr, /does not support workspaces/);

  console.log("package-manager lockfiles: pass");
} finally {
  for (const server of servers) server.kill();
  if (process.env.COTTONTAIL_KEEP_TEST_TEMP) {
    console.error(`kept lockfile fixtures at ${scratch}`);
  } else {
    fs.rmSync(scratch, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
  }
}
