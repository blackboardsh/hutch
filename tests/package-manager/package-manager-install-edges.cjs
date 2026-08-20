"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawn, spawnSync } = require("node:child_process");
const { gzipSync } = require("node:zlib");

const cottontail = path.resolve(
  process.argv[2] ||
    path.join("zig-out", "bin", process.platform === "win32" ? "cottontail.exe" : "cottontail"),
);
const nodeProbe = spawnSync("node", ["-p", "process.execPath"], { encoding: "utf8" });
assert.equal(nodeProbe.status, 0, `failed to resolve host Node executable: ${nodeProbe.stderr}`);
const nodeRuntime = path.resolve(nodeProbe.stdout.trim());
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "cottontail-install-edges-"));
const childTimeout = process.platform === "win32" ? 120_000 : 30_000;

function writeJson(filename, value) {
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
  return gzipSync(
    Buffer.concat([
      header,
      body,
      Buffer.alloc((512 - (body.length % 512)) % 512),
      Buffer.alloc(1024),
    ]),
  );
}

function isolatedEnvironment(home, extra = {}) {
  const env = { ...process.env, HOME: home, ...extra };
  for (const name of [
    "BUN_INSTALL_CACHE_DIR",
    "XDG_CACHE_HOME",
    "npm_config_cache",
    "NPM_CONFIG_CACHE",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "ALL_PROXY",
    "http_proxy",
    "https_proxy",
    "all_proxy",
  ]) {
    delete env[name];
  }
  return env;
}

function runInstall(root, home, args = [], extraEnvironment = {}, silent = true) {
  fs.mkdirSync(home, { recursive: true });
  return spawnSync(cottontail, ["install", ...(silent ? ["--silent"] : []), ...args], {
    cwd: root,
    env: isolatedEnvironment(home, extraEnvironment),
    encoding: "utf8",
    timeout: childTimeout,
  });
}

function expectSuccess(label, result) {
  assert.equal(
    result.status,
    0,
    `${label} failed\nerror:\n${result.error?.stack || result.error || ""}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`,
  );
}

function waitForFile(filename) {
  const signal = new Int32Array(new SharedArrayBuffer(4));
  for (let attempt = 0; attempt < 500; attempt += 1) {
    if (fs.existsSync(filename)) return;
    Atomics.wait(signal, 0, 0, 10);
  }
  throw new Error(`timed out waiting for ${filename}`);
}

function testNodeGypLifecycle() {
  // The built-in resolver never runs lifecycle scripts: no root scripts, no
  // dependency scripts, no automatic node-gyp.
  const root = path.join(scratch, "root-node-gyp");
  const home = path.join(scratch, "root-node-gyp-home");
  fs.mkdirSync(root, { recursive: true });
  fs.writeFileSync(
    path.join(root, "record-lifecycle.cjs"),
    'require("node:fs").appendFileSync("node-gyp-events", "ran\n");\n',
  );
  writeJson(path.join(root, "package.json"), {
    name: "root-node-gyp",
    version: "1.0.0",
    scripts: {
      preinstall: "node record-lifecycle.cjs",
      postinstall: "node record-lifecycle.cjs",
    },
  });
  fs.writeFileSync(path.join(root, "binding.gyp"), "{}\n");
  const result = runInstall(root, home);
  expectSuccess("root lifecycle scripts are skipped", result);
  assert.ok(!fs.existsSync(path.join(root, "node-gyp-events")));
  assert.ok(!fs.existsSync(path.join(root, "build.node")));

  const dependency = path.join(scratch, "native-dependency");
  writeJson(path.join(dependency, "package.json"), {
    name: "native-dependency",
    version: "1.0.0",
    scripts: { postinstall: "node -e \"process.exit(1)\"" },
  });
  fs.writeFileSync(path.join(dependency, "binding.gyp"), "{}\n");
  const dependencyRoot = path.join(scratch, "dependency-node-gyp");
  const dependencyHome = path.join(scratch, "dependency-node-gyp-home");
  writeJson(path.join(dependencyRoot, "package.json"), {
    name: "dependency-node-gyp",
    version: "1.0.0",
    dependencies: { "native-dependency": "file:../native-dependency" },
  });
  const skipped = runInstall(dependencyRoot, dependencyHome, []);
  expectSuccess("dependency lifecycle scripts are skipped", skipped);
  assert.ok(!fs.existsSync(path.join(dependencyRoot, "node-gyp-events")));
  const notice = runInstall(dependencyRoot, dependencyHome, ["--force"], {}, false);
  expectSuccess("skip notice reinstall", notice);
}



function testRegistryAndMinimumAge() {
  const registryRoot = path.join(scratch, "registry");
  const portFile = path.join(registryRoot, "port");
  const statsFile = path.join(registryRoot, "stats.json");
  fs.mkdirSync(registryRoot, { recursive: true });

  const versions = {
    "edge-package": ["1.0.0"],
    "external-child": ["1.0.0"],
    "cross-package": ["1.0.0"],
    "redirect-manifest-package": ["1.0.0"],
    "redirect-tarball-package": ["1.0.0"],
    "empty-integrity-package": ["1.0.0"],
    "malformed-integrity-package": ["1.0.0"],
    "nonstring-integrity-package": ["1.0.0"],
    "wrong-integrity-package": ["1.0.0"],
    "retry-package": ["1.0.0"],
    "age-package": ["1.0.0", "2.0.0"],
    "excluded-package": ["1.0.0", "2.0.0"],
    "invalid-time-package": ["1.0.0"],
    "direct-musl-package": ["1.0.0"],
    "glibc-package": ["1.0.0"],
    "musl-package": ["1.0.0"],
  };
  for (const [name, packageVersions] of Object.entries(versions)) {
    for (const version of packageVersions) {
      const libc = name === "glibc-package"
        ? ["glibc"]
        : name === "musl-package" || name === "direct-musl-package"
          ? ["musl"]
          : undefined;
      fs.writeFileSync(
        path.join(registryRoot, `${name}-${version}.tgz`),
        packageArchive({
          name,
          version,
          ...(libc ? { os: ["linux"], cpu: [process.arch], libc } : {}),
        }),
      );
    }
  }

  const serverFile = path.join(registryRoot, "server.cjs");
  fs.writeFileSync(
    serverFile,
    `
"use strict";
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const [root, portFile, statsFile] = process.argv.slice(2);
const stats = { requests: [], retryManifestRequests: 0 };
function save() { fs.writeFileSync(statsFile, JSON.stringify(stats)); }
const server = http.createServer((request, response) => {
  const url = new URL(request.url, "http://localhost");
  stats.requests.push({
    host: request.headers.host,
    pathname: url.pathname,
    authorization: request.headers.authorization || null,
    npmAuthType: request.headers["npm-auth-type"] || null,
    accept: request.headers.accept || null,
  });
  if (url.pathname === "/retry-package") {
    stats.retryManifestRequests += 1;
    if (stats.retryManifestRequests <= 2) {
      save();
      response.writeHead(429).end("retry");
      return;
    }
  }
  if (url.pathname === "/redirect-manifest-package" && request.headers.host.startsWith("127.0.0.1:")) {
    save();
    response.writeHead(302, {
      location: "http://localhost:" + server.address().port + "/redirected-manifest-package",
    }).end();
    return;
  }
  if (url.pathname.startsWith("/redirect-tarballs/")) {
    save();
    response.writeHead(302, {
      location: "http://localhost:" + server.address().port + "/tarballs/" + path.basename(url.pathname),
    }).end();
    return;
  }
  if (url.pathname.startsWith("/tarballs/")) {
    const filename = path.join(root, path.basename(url.pathname));
    save();
    if (!fs.existsSync(filename)) return response.writeHead(404).end();
    response.writeHead(200, { "content-type": "application/octet-stream" });
    return fs.createReadStream(filename).pipe(response);
  }
  const name = url.pathname === "/redirected-manifest-package"
    ? "redirect-manifest-package"
    : url.pathname.slice(1);
  const packageVersions = ${JSON.stringify(versions)}[name];
  if (!packageVersions) {
    save();
    return response.writeHead(404).end();
  }
  const now = Date.now();
  const manifestVersions = {};
  const time = {};
  for (const version of packageVersions) {
    let tarball = "/tarballs/" + name + "-" + version + ".tgz";
    if (name === "cross-package") {
      tarball = "http://localhost:" + server.address().port + tarball;
    } else if (name === "redirect-tarball-package") {
      tarball = "/redirect-tarballs/" + name + "-" + version + ".tgz";
    }
    const dist = { tarball };
    if (name === "empty-integrity-package") dist.integrity = "";
    if (name === "malformed-integrity-package") dist.integrity = "sha512-not-base64";
    if (name === "nonstring-integrity-package") dist.integrity = 42;
    if (name === "wrong-integrity-package") {
      dist.integrity = "sha512-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==";
    }
    manifestVersions[version] = { name, version, dist };
    if (version === "1.0.0") time[version] = new Date(now - 20 * 86400000).toISOString();
    else time[version] = new Date(now - 86400000).toISOString();
  }
  if (name === "invalid-time-package") time["1.0.0"] = "not-a-date";
  save();
  response.writeHead(200, { "content-type": "application/json" });
  response.end(JSON.stringify({
    name,
    "dist-tags": { latest: packageVersions[packageVersions.length - 1] },
    versions: manifestVersions,
    time,
  }));
});
save();
server.listen(0, () => fs.writeFileSync(portFile, String(server.address().port)));
`,
  );

  const server = spawn(nodeRuntime, [serverFile, registryRoot, portFile, statsFile], {
    stdio: ["ignore", "ignore", "inherit"],
  });
  try {
    waitForFile(portFile);
    const port = Number(fs.readFileSync(portFile, "utf8"));
    const root = path.join(scratch, "registry-project");
    const home = path.join(scratch, "registry-project-home");
    const externalPackage = path.join(scratch, "external-registry-package");
    writeJson(path.join(externalPackage, "package.json"), {
      name: "external-registry-package",
      version: "1.0.0",
      dependencies: {
        "external-child": "*",
      },
    });
    writeJson(path.join(root, "package.json"), {
      name: "registry-project",
      version: "1.0.0",
      dependencies: {
        "edge-package": "*",
        "external-registry-package": "file:../external-registry-package",
        "cross-package": "*",
        "redirect-manifest-package": "*",
        "redirect-tarball-package": "*",
        "retry-package": "*",
        "age-package": "*",
        "excluded-package": "*",
        "invalid-time-package": "*",
        "direct-musl-package": "*",
      },
      optionalDependencies: {
        "glibc-package": "*",
        "musl-package": "*",
      },
    });
    fs.writeFileSync(
      path.join(root, "bunfig.toml"),
      `[install]\nregistry = "http://127.0.0.1:${port}///"\nminimumReleaseAge = ${5 * 86400}\nminimumReleaseAgeExcludes = ["excluded-package"]\n`,
    );

    const result = runInstall(root, home, ["--no-verify"], {
      BUN_CONFIG_TOKEN: "edge-token",
    });
    expectSuccess(
      `registry edge and minimum release age install; registry stats: ${
        fs.existsSync(statsFile) ? fs.readFileSync(statsFile, "utf8") : "<missing>"
      }`,
      result,
    );
    assert.ok(
      fs.lstatSync(path.join(root, "node_modules", "external-registry-package")).isDirectory(),
      "external file package should be materialized as a directory",
    );
    assert.equal(
      JSON.parse(fs.readFileSync(path.join(root, "node_modules", "external-child", "package.json"))).version,
      "1.0.0",
    );
    assert.equal(
      JSON.parse(fs.readFileSync(path.join(root, "node_modules", "age-package", "package.json"))).version,
      "1.0.0",
    );
    assert.equal(
      JSON.parse(fs.readFileSync(path.join(root, "node_modules", "excluded-package", "package.json"))).version,
      "2.0.0",
    );
    assert.equal(
      JSON.parse(fs.readFileSync(path.join(root, "node_modules", "invalid-time-package", "package.json"))).version,
      "1.0.0",
    );
    if (process.platform === "linux") {
      assert.ok(fs.existsSync(path.join(root, "node_modules", "glibc-package", "package.json")));
      assert.ok(!fs.existsSync(path.join(root, "node_modules", "musl-package")));
      assert.ok(!fs.existsSync(path.join(root, "node_modules", "direct-musl-package")));

      // Bun's current lock format does not persist libc metadata, so a
      // lockfile reinstall must rehydrate it from the package archives.
      fs.rmSync(path.join(root, "node_modules"), { recursive: true, force: true });
      const lockedResult = runInstall(root, home, ["--no-verify"], {
        BUN_CONFIG_TOKEN: "edge-token",
      });
      expectSuccess("registry libc install from legacy lock metadata", lockedResult);
      assert.ok(fs.existsSync(path.join(root, "node_modules", "glibc-package", "package.json")));
      assert.ok(!fs.existsSync(path.join(root, "node_modules", "musl-package")));
      assert.ok(!fs.existsSync(path.join(root, "node_modules", "direct-musl-package")));
    }

    // Repeat a redirected archive without any cache so the synchronous fetch
    // path receives the same cross-origin credential-stripping coverage as
    // the concurrent archive prefetch path above.
    const redirectNoCacheRoot = path.join(scratch, "redirect-no-cache-project");
    const redirectNoCacheHome = path.join(scratch, "redirect-no-cache-home");
    writeJson(path.join(redirectNoCacheRoot, "package.json"), {
      name: "redirect-no-cache-project",
      dependencies: { "redirect-tarball-package": "1.0.0" },
    });
    fs.writeFileSync(
      path.join(redirectNoCacheRoot, "bunfig.toml"),
      `[install]\nregistry = "http://127.0.0.1:${port}/"\n`,
    );
    expectSuccess(
      "cross-origin redirect without archive cache",
      runInstall(redirectNoCacheRoot, redirectNoCacheHome, ["--no-cache", "--no-verify"], {
        BUN_CONFIG_TOKEN: "edge-token",
      }),
    );

    const stats = JSON.parse(fs.readFileSync(statsFile, "utf8"));
    assert.ok(stats.retryManifestRequests >= 3, "429 manifest response was not retried");
    const manifests = stats.requests.filter(
      (request) => !request.pathname.startsWith("/tarballs/") &&
        !request.pathname.startsWith("/redirect-tarballs/"),
    );
    const firstOriginManifests = manifests.filter((request) => request.host.startsWith("127.0.0.1:"));
    assert.ok(firstOriginManifests.length >= 10);
    assert.ok(firstOriginManifests.every((request) => !request.pathname.startsWith("//")));
    assert.ok(firstOriginManifests.every((request) => request.authorization === "Bearer edge-token"));
    assert.ok(firstOriginManifests.every((request) => request.npmAuthType === "legacy"));
    assert.ok(firstOriginManifests.every((request) => request.accept.includes("application/json")));

    const redirectedManifest = manifests.find(
      (request) => request.pathname === "/redirected-manifest-package" &&
        request.host.startsWith("localhost:"),
    );
    assert.ok(redirectedManifest, "cross-origin manifest redirect target was not requested");
    assert.equal(redirectedManifest.authorization, null);
    assert.equal(redirectedManifest.npmAuthType, null);
    assert.ok(redirectedManifest.accept.includes("application/json"));

    const sameOriginTarballs = stats.requests.filter(
      (request) => request.pathname.startsWith("/tarballs/") && request.host.startsWith("127.0.0.1:"),
    );
    assert.ok(sameOriginTarballs.length > 0);
    assert.ok(sameOriginTarballs.every((request) => request.authorization === "Bearer edge-token"));
    const crossOriginTarball = stats.requests.find(
      (request) => request.pathname === "/tarballs/cross-package-1.0.0.tgz" && request.host.startsWith("localhost:"),
    );
    assert.ok(crossOriginTarball, "cross-origin tarball was not requested");
    assert.equal(crossOriginTarball.authorization, null);
    const redirectedTarballs = stats.requests.filter(
      (request) => request.pathname === "/tarballs/redirect-tarball-package-1.0.0.tgz" &&
        request.host.startsWith("localhost:"),
    );
    assert.ok(redirectedTarballs.length >= 2, "both archive fetch paths must follow the redirect");
    assert.ok(redirectedTarballs.every((request) => request.authorization === null));
    const redirectFirstHops = stats.requests.filter(
      (request) => request.pathname === "/redirect-tarballs/redirect-tarball-package-1.0.0.tgz" &&
        request.host.startsWith("127.0.0.1:"),
    );
    assert.ok(redirectFirstHops.length >= 2);
    assert.ok(redirectFirstHops.every((request) => request.authorization === "Bearer edge-token"));

    function registryIntegrityInstall(packageName, args) {
      const fixtureRoot = path.join(scratch, `integrity-${packageName}`);
      const fixtureHome = path.join(scratch, `integrity-${packageName}-home`);
      writeJson(path.join(fixtureRoot, "package.json"), {
        name: `fixture-${packageName}`,
        dependencies: { [packageName]: "1.0.0" },
      });
      fs.writeFileSync(
        path.join(fixtureRoot, "bunfig.toml"),
        `[install]\nregistry = "http://127.0.0.1:${port}/"\n`,
      );
      return { fixtureRoot, result: runInstall(fixtureRoot, fixtureHome, args) };
    }

    const emptyIntegrity = registryIntegrityInstall("empty-integrity-package", ["--no-cache"]);
    expectSuccess("empty registry integrity remains an absent claim", emptyIntegrity.result);
    assert.equal(
      JSON.parse(fs.readFileSync(path.join(
        emptyIntegrity.fixtureRoot,
        "node_modules",
        "empty-integrity-package",
        "package.json",
      ))).name,
      "empty-integrity-package",
    );

    for (const packageName of ["malformed-integrity-package", "nonstring-integrity-package"]) {
      const malformed = registryIntegrityInstall(packageName, ["--no-cache", "--no-verify"]);
      assert.equal(malformed.result.status, 1, `${packageName} unexpectedly installed`);
      assert.match(malformed.result.stderr, /InvalidRegistryIntegrity/);
      assert.equal(
        fs.existsSync(path.join(malformed.fixtureRoot, "node_modules", packageName)),
        false,
      );
    }

    const wrongIntegrity = registryIntegrityInstall("wrong-integrity-package", ["--no-cache"]);
    assert.equal(wrongIntegrity.result.status, 1);
    assert.match(wrongIntegrity.result.stderr, /Integrity check failed/);

    if (process.platform === "linux") {
      const offlineRoot = path.join(scratch, "registry-offline-project");
      const offlineHome = path.join(scratch, "registry-offline-home");
      writeJson(path.join(offlineRoot, "package.json"), {
        name: "registry-offline-project",
        version: "1.0.0",
        dependencies: { "edge-package": "*" },
      });
      fs.writeFileSync(
        path.join(offlineRoot, "bunfig.toml"),
        `[install]\nregistry = "http://127.0.0.1:${port}/"\n`,
      );
      expectSuccess(
        "registry offline fixture initial install",
        runInstall(offlineRoot, offlineHome, ["--no-verify"]),
      );

      const lockPath = path.join(offlineRoot, "hutch.lock");
      const lockSource = fs.readFileSync(lockPath, "utf8");
      const unreachableLockSource = lockSource.replaceAll(`:${port}`, ":1");
      assert.notEqual(unreachableLockSource, lockSource, "offline fixture lock should contain registry URLs");
      fs.writeFileSync(lockPath, unreachableLockSource);
      fs.rmSync(path.join(offlineHome, ".bun", "install", "cache"), {
        recursive: true,
        force: true,
      });
      expectSuccess(
        "intact legacy lock reinstall without registry or tarball cache",
        runInstall(offlineRoot, offlineHome, ["--no-verify"]),
      );
    }
  } finally {
    server.kill();
  }
}

try {
  testNodeGypLifecycle();
  testRegistryAndMinimumAge();
  console.log("package-manager install edges: pass");
} finally {
  if (process.env.COTTONTAIL_KEEP_TEMP === "1") {
    console.error(`preserved package-manager edge fixture: ${scratch}`);
  } else {
    fs.rmSync(scratch, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
  }
}
