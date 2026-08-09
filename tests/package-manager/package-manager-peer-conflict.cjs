"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { gzipSync } = require("node:zlib");
const { spawn, spawnSync } = require("node:child_process");

const cottontail = path.resolve(process.argv[2] || "zig-out/bin/cottontail");
const root = fs.mkdtempSync(path.join(os.tmpdir(), "cottontail-peer-conflict-"));
const lockedPeerRoot = fs.mkdtempSync(path.join(os.tmpdir(), "cottontail-locked-peer-"));
const registryRoot = fs.mkdtempSync(path.join(os.tmpdir(), "cottontail-peer-registry-"));
const portFile = path.join(registryRoot, "port");

function writeTarField(header, offset, width, value) {
  const encoded = `${value.toString(8).padStart(width - 1, "0")}\0`;
  header.write(encoded, offset, width, "ascii");
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

function writeRegistryPackage(name, version, extra = {}) {
  const metadata = { name, version, ...extra };
  fs.writeFileSync(path.join(registryRoot, `${name}.json`), JSON.stringify(metadata));
  fs.writeFileSync(path.join(registryRoot, `${name}-${version}.tgz`), packageArchive(metadata));
}

function waitForPort() {
  const signal = new Int32Array(new SharedArrayBuffer(4));
  for (let attempt = 0; attempt < 250; attempt += 1) {
    if (fs.existsSync(portFile)) return Number(fs.readFileSync(portFile, "utf8"));
    Atomics.wait(signal, 0, 0, 20);
  }
  throw new Error("registry server did not start");
}

function runInstall(projectRoot = root, args = []) {
  return spawnSync(cottontail, ["install", ...args, "--ignore-scripts", "--silent"], {
    cwd: projectRoot,
    encoding: "utf8",
    timeout: 30_000,
  });
}

writeRegistryPackage("provider-npm", "1.0.0");
writeRegistryPackage("provider-npm", "2.0.0");
writeRegistryPackage("consumer-npm", "1.0.0", {
  peerDependencies: {
    "provider-npm": "^1.0.0",
  },
});
// This owner sorts before ajv-keywords, so its deferred dependency expansion
// materializes the incompatible root hoist before the consumer resolves peers.
writeRegistryPackage("aaa-ajv6-owner", "1.0.0", {
  dependencies: {
    ajv: "^6.0.0",
  },
});
writeRegistryPackage("ajv", "6.12.6");
writeRegistryPackage("ajv", "8.17.1");
writeRegistryPackage("ajv-keywords", "5.1.0", {
  peerDependencies: {
    ajv: "^8.8.2",
  },
});

const serverPath = path.join(registryRoot, "server.cjs");
fs.writeFileSync(
  serverPath,
  `
"use strict";
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const root = process.argv[2];
const portFile = process.argv[3];
const server = http.createServer((request, response) => {
  const pathname = decodeURIComponent(new URL(request.url, "http://localhost").pathname);
  if (pathname.startsWith("/tarballs/")) {
    const filename = path.join(root, path.basename(pathname));
    if (!fs.existsSync(filename)) {
      response.writeHead(404).end();
      return;
    }
    response.writeHead(200, { "content-type": "application/octet-stream" });
    fs.createReadStream(filename).pipe(response);
    return;
  }
  const name = pathname.slice(1);
  const versions = {};
  for (const filename of fs.readdirSync(root)) {
    if (!filename.startsWith(name + "-") || !filename.endsWith(".tgz")) continue;
    const version = filename.slice(name.length + 1, -4);
    const metadata = JSON.parse(fs.readFileSync(path.join(root, name + ".json"), "utf8"));
    metadata.version = version;
    metadata.dist = { tarball: "http://127.0.0.1:" + server.address().port + "/tarballs/" + filename };
    versions[version] = metadata;
  }
  if (Object.keys(versions).length === 0) {
    response.writeHead(404).end();
    return;
  }
  const latest = Object.keys(versions).sort().at(-1);
  response.writeHead(200, { "content-type": "application/json" });
  response.end(JSON.stringify({ name, "dist-tags": { latest }, versions }));
});
server.listen(0, "127.0.0.1", () => fs.writeFileSync(portFile, String(server.address().port)));
`,
);

const server = spawn(process.execPath, [serverPath, registryRoot, portFile], {
  stdio: ["ignore", "ignore", "inherit"],
});

try {
  const port = waitForPort();
  fs.writeFileSync(
    path.join(root, "bunfig.toml"),
    `[install]\nlinker = "isolated"\nregistry = "http://127.0.0.1:${port}/"\n`,
  );
  fs.writeFileSync(
    path.join(root, "package.json"),
    `${JSON.stringify(
      {
        name: "peer-conflict-root",
        version: "1.0.0",
        dependencies: {
          "consumer-npm": "1.0.0",
          "provider-npm": "2.0.0",
        },
      },
      null,
      2,
    )}\n`,
  );

  let result = runInstall();
  assert.equal(result.status, 0, `install failed\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`);
  assert.equal(
    result.stderr.match(/incorrect peer dependency "provider-npm@2\.0\.0"/g)?.length,
    1,
    result.stderr,
  );

  const packageJson = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
  packageJson.dependencies["provider-npm"] = "1.0.0";
  fs.writeFileSync(path.join(root, "package.json"), `${JSON.stringify(packageJson, null, 2)}\n`);
  result = runInstall();
  assert.equal(result.status, 0, `compatible install failed\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`);
  assert.doesNotMatch(result.stderr, /incorrect peer dependency/);

  fs.writeFileSync(
    path.join(lockedPeerRoot, "bunfig.toml"),
    `[install]\nlinker = "hoisted"\nregistry = "http://127.0.0.1:${port}/"\n`,
  );
  const lockedRootPackage = {
    name: "locked-hoisted-peer-root",
    version: "1.0.0",
    dependencies: {
      "aaa-ajv6-owner": "1.0.0",
      "ajv-keywords": "5.1.0",
      "consumer-npm": "1.0.0",
      "provider-npm": "2.0.0",
    },
  };
  fs.writeFileSync(
    path.join(lockedPeerRoot, "package.json"),
    `${JSON.stringify(lockedRootPackage, null, 2)}\n`,
  );
  const archiveURL = (name, version) =>
    `http://127.0.0.1:${port}/tarballs/${name}-${version}.tgz`;
  fs.writeFileSync(
    path.join(lockedPeerRoot, "bun.lock"),
    `${JSON.stringify(
      {
        lockfileVersion: 1,
        configVersion: 1,
        workspaces: {
          "": lockedRootPackage,
        },
        packages: {
          "aaa-ajv6-owner": [
            "aaa-ajv6-owner@1.0.0",
            archiveURL("aaa-ajv6-owner", "1.0.0"),
            { dependencies: { ajv: "^6.0.0" } },
            "",
          ],
          ajv: ["ajv@6.12.6", archiveURL("ajv", "6.12.6"), {}, ""],
          "ajv-keywords": [
            "ajv-keywords@5.1.0",
            archiveURL("ajv-keywords", "5.1.0"),
            { peerDependencies: { ajv: "^8.8.2" } },
            "",
          ],
          "ajv-keywords/ajv": ["ajv@8.17.1", archiveURL("ajv", "8.17.1"), {}, ""],
          "consumer-npm": [
            "consumer-npm@1.0.0",
            archiveURL("consumer-npm", "1.0.0"),
            { peerDependencies: { "provider-npm": "^1.0.0" } },
            "",
          ],
          "provider-npm": [
            "provider-npm@2.0.0",
            archiveURL("provider-npm", "2.0.0"),
            {},
            "",
          ],
          // An explicit root provider remains visible and authoritative even
          // when the loaded graph also contains a satisfying nested selection.
          "consumer-npm/provider-npm": [
            "provider-npm@1.0.0",
            archiveURL("provider-npm", "1.0.0"),
            {},
            "",
          ],
        },
      },
      null,
      2,
    )}\n`,
  );

  result = runInstall(lockedPeerRoot, ["--frozen-lockfile"]);
  assert.equal(
    result.status,
    0,
    `locked hoisted peer install failed\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`,
  );
  assert.doesNotMatch(result.stderr, /incorrect peer dependency "ajv@6\.12\.6"/);
  assert.equal(
    result.stderr.match(/incorrect peer dependency "provider-npm@2\.0\.0"/g)?.length,
    1,
    result.stderr,
  );

  const rootAjvPackage = path.join(lockedPeerRoot, "node_modules", "ajv", "package.json");
  const keywordsDir = path.join(lockedPeerRoot, "node_modules", "ajv-keywords");
  const nestedAjvPackage = path.join(keywordsDir, "node_modules", "ajv", "package.json");
  assert.equal(JSON.parse(fs.readFileSync(rootAjvPackage, "utf8")).version, "6.12.6");
  assert.equal(JSON.parse(fs.readFileSync(nestedAjvPackage, "utf8")).version, "8.17.1");
  assert.equal(
    fs.realpathSync(require.resolve("ajv/package.json", { paths: [keywordsDir] })),
    fs.realpathSync(nestedAjvPackage),
  );

  const rootProviderPackage = path.join(lockedPeerRoot, "node_modules", "provider-npm", "package.json");
  const consumerDir = path.join(lockedPeerRoot, "node_modules", "consumer-npm");
  assert.equal(JSON.parse(fs.readFileSync(rootProviderPackage, "utf8")).version, "2.0.0");
  assert.equal(
    fs.realpathSync(require.resolve("provider-npm/package.json", { paths: [consumerDir] })),
    fs.realpathSync(rootProviderPackage),
  );
  assert.equal(fs.existsSync(path.join(consumerDir, "node_modules", "provider-npm")), false);

  console.log("package-manager peer conflict diagnostics: pass");
} finally {
  server.kill();
  fs.rmSync(root, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
  fs.rmSync(lockedPeerRoot, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
  fs.rmSync(registryRoot, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
}
