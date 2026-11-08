import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFileSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  deployArtifacts,
  inventoryArtifacts,
  inventoryReleases,
  parseUploadArgs,
  parsePublishArgs,
  publishRelease,
  uploadArtifacts,
  parseDeployArgs,
  runDeploy,
} from "../../src/electrobun_cli/deploy_helper.js";

const partSize = 8 * 1024 * 1024;
const key = "emd_test_not-a-real-secret";
const digest = (data) => createHash("sha256").update(data).digest("hex");
const md5 = (data) => createHash("md5").update(data).digest("base64");
const partETag = (data) => createHash("md5").update(data).digest("hex");
const json = (body, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { "content-type": "application/json" },
});

function signedGrant(url, part) {
  assert.match(part.md5, /^[A-Za-z0-9+/]{22}==$/);
  assert.ok(Number.isSafeInteger(part.size) && part.size > 0 && part.size <= partSize);
  return { url, headers: { "content-md5": part.md5, "content-length": String(part.size) } };
}

function verifyDirectPart(headers, bytes) {
  headers = new Headers(headers);
  assert.equal(headers.get("authorization"), null, "Dash API keys must never be sent to R2");
  assert.equal(headers.get("content-md5"), md5(bytes));
  assert.equal(headers.get("content-length"), String(bytes.length));
  assert.ok(bytes.length <= partSize);
}

async function serve(t, handler) {
  const server = createServer(handler);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(() => new Promise((resolve) => {
    server.closeAllConnections();
    server.close(resolve);
  }));
  return `http://127.0.0.1:${server.address().port}`;
}

async function requestBody(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return Buffer.concat(chunks);
}

function reply(response, body, status = 200) {
  response.writeHead(status, { "content-type": "application/json" });
  response.end(JSON.stringify(body));
}

function runCli(args, cwd, env, command = "deploy") {
  return new Promise((resolve, reject) => {
    const child = spawn(process.env.HUTCH_BINARY, ["electrobun", command, ...args], {
      cwd,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.once("error", reject);
    child.once("close", (status) => resolve({ status, stdout, stderr }));
  });
}

function fixture(t, { archiveSize = 23, channel = "canary", platform = "macos", arch = "arm64" } = {}) {
  const directory = mkdtempSync(join(tmpdir(), "hutch-managed-deploy-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const prefix = `${channel}-${platform}-${arch}`;
  const archiveName = `${prefix}-Example.app.tar.zst`;
  const archive = Buffer.alloc(archiveSize, 0x67);
  writeFileSync(join(directory, archiveName), archive);
  const manifest = {
    schemaVersion: 1,
    identifier: "dev.electrobun.example",
    channel,
    version: "1.2.3",
    hash: "n61b2c3",
    platform,
    arch,
    artifact: { file: archiveName, tarSha256: "a".repeat(64), tarSize: 123 },
  };
  writeFileSync(join(directory, `${prefix}-update.json`), JSON.stringify(manifest));
  return { directory, prefix, archiveName, archive, manifest };
}

function options(directory, extra = []) {
  return parseDeployArgs([
    "--env=canary", "--release=canary-1.2.3", "--app=app-1", `--artifacts=${directory}`, ...extra,
  ], {}, { ELECTROBUN_API_KEY: key });
}

test("managed deploy reads configuration defaults and gives CLI credentials precedence", () => {
  const result = parseDeployArgs([
    "--env=canary", "--release=canary-1.2.3", "--api-key=override-secret", "--targets=macos-arm64,win-x64",
  ], { appId: "configured-app", apiUrl: "https://staging.example.test/", artifactFolder: "output" }, {
    ELECTROBUN_API_KEY: key,
  });
  assert.equal(result.channel, "canary");
  assert.equal(result.releaseId, "canary-1.2.3");
  assert.equal(result.appId, "configured-app");
  assert.equal(result.apiKey, "override-secret");
  assert.equal(result.apiUrl, "https://staging.example.test/v1/electrobun");
  assert.deepEqual(result.expectedTargets, ["macos-arm64", "win-x64"]);
  assert.match(result.artifacts, /output$/);
});

test("managed deploy uses the standard service with only the configured app ID", () => {
  const result = parseDeployArgs(["--env=canary", "--release=canary-1.2.3", "--dry-run"], {
    appId: "configured-app",
  }, {});
  assert.equal(result.appId, "configured-app");
  assert.equal(result.apiUrl, "https://api.electrobun.dev/v1/electrobun");
});

test("managed deploy accepts space-separated options and a normalized API root", () => {
  const result = parseDeployArgs([
    "--env", "stable", "--release", "stable-1.2.3", "--app", "app-2",
    "--api-url", "https://api.example.test/v1/electrobun/", "--dry-run",
  ], {}, {});
  assert.equal(result.channel, "stable");
  assert.equal(result.releaseId, "stable-1.2.3");
  assert.equal(result.apiUrl, "https://api.example.test/v1/electrobun");
  assert.equal(result.dryRun, true);
});

test("managed deploy accepts semantic version release IDs and rejects traversal IDs", () => {
  const args = ["--env=canary", "--app=app-1", "--dry-run"];
  assert.equal(parseDeployArgs([...args, "--release=canary-1.2.3-canary.4"], {}, {}).releaseId, "canary-1.2.3-canary.4");
  for (const releaseId of ["..", "../release", "release/../other", "release..other"]) {
    assert.throws(() => parseDeployArgs([...args, `--release=${releaseId}`], {}, {}));
  }
});

test("managed upload rejects unsupported channels and unsafe API endpoints", () => {
  const base = ["--env=canary", "--release=build-1", "--app=app-1", "--dry-run"];
  for (const channel of ["dev", "preview", "beta", ""]) {
    assert.throws(() => parseDeployArgs([`--env=${channel}`, ...base.slice(1)], {}, {}));
  }
  assert.equal(parseDeployArgs(base.filter((arg) => !arg.startsWith("--release=")), {}, {}).releaseId, undefined);
  assert.throws(() => parseDeployArgs([...base, "--unknown-option"], {}, {}));
  assert.throws(() => parseDeployArgs([...base, "--api-url=https://user:pass@example.test"], {}, {}));
  assert.throws(() => parseDeployArgs([...base, "--api-url=http://example.test"], {}, {}));
  assert.throws(() => parseDeployArgs([...base, "--api-url=https://example.test?token=secret"], {}, {}));
});

test("managed deploy inventories existing Hutch artifacts with compressed-object checksums", async (t) => {
  const f = fixture(t);
  const patchName = `${f.prefix}-previoushash.patch`;
  writeFileSync(join(f.directory, patchName), "existing-patch");
  const inventory = await inventoryArtifacts(options(f.directory));
  assert.equal(inventory.version, "1.2.3");
  assert.equal(inventory.identifier, "dev.electrobun.example");
  assert.deepEqual(inventory.targets, ["macos-arm64"]);
  assert.equal(inventory.files.length, 3);
  const archive = inventory.files.find((file) => file.filename === f.archiveName);
  assert.ok(archive);
  assert.equal(archive.size, f.archive.length);
  assert.equal(archive.sha256, digest(f.archive));
  assert.notEqual(archive.sha256, f.manifest.artifact.tarSha256);
  assert.equal(archive.target, "macos-arm64");
  assert.ok(inventory.files.some((file) => file.filename === patchName));
});

test("managed inventory uploads a build checksum before the legacy canonical manifest", (t) => {
  const f = fixture(t);
  f.manifest.hash = "zzzhash";
  f.manifest.artifact = { file: f.archiveName };
  writeFileSync(join(f.directory, `${f.prefix}-update.json`), JSON.stringify(f.manifest));
  assert.equal(inventoryArtifacts(options(f.directory)).files.length, 2, "Old builds without checksums still upload");
  const filename = `${f.prefix}-${f.manifest.hash}-checksum.json`;
  const bytes = JSON.stringify({ tarSha256: "a".repeat(64), tarSize: 123 });
  writeFileSync(join(f.directory, filename), bytes);
  const inventory = inventoryArtifacts(options(f.directory));
  assert.deepEqual(inventory.files.map(file => file.filename), [f.archiveName, filename, `${f.prefix}-update.json`]);
  assert.equal(inventory.files[1].sha256, digest(bytes));
  assert.equal(inventory.files[1].target, "macos-arm64");
});

test("managed inventory rejects checksum identity and content mismatches", (t) => {
  for (const [name, body] of [
    ["otherhash", { tarSha256: "a".repeat(64), tarSize: 123 }],
    ["n61b2c3", null],
    ["n61b2c3", { tarSha256: "invalid", tarSize: 123 }],
    ["n61b2c3", { tarSha256: ["a".repeat(64)], tarSize: 123 }],
    ["n61b2c3", { tarSha256: "a".repeat(64) }],
    ["n61b2c3", { tarSha256: "a".repeat(64), tarSize: 0 }],
    ["n61b2c3", { tarSha256: "a".repeat(64), tarSize: Number.MAX_SAFE_INTEGER + 1 }],
    ["n61b2c3", { tarSha256: "b".repeat(64), tarSize: 123 }],
  ]) {
    const f = fixture(t);
    writeFileSync(join(f.directory, `${f.prefix}-${name}-checksum.json`), JSON.stringify(body));
    assert.throws(() => inventoryArtifacts(options(f.directory)), /[Cc]hecksum/);
  }
});

test("managed deploy rejects absent archives, traversal and mismatched manifests", async (t) => {
  for (const mutate of [
    (f) => writeFileSync(join(f.directory, `${f.prefix}-update.json`), JSON.stringify({ ...f.manifest, artifact: { ...f.manifest.artifact, tarSha256: ["a".repeat(64)] } })),
    (f) => rmSync(join(f.directory, f.archiveName)),
    (f) => writeFileSync(join(f.directory, `${f.prefix}-update.json`), JSON.stringify({ ...f.manifest, channel: "stable" })),
    (f) => writeFileSync(join(f.directory, `${f.prefix}-update-v2.json`), JSON.stringify({ ...f.manifest, hash: "differenthash" })),
    (f) => writeFileSync(join(f.directory, `${f.prefix}-update-v2.json`), JSON.stringify({ ...f.manifest, version: "8.9.0" })),
    (f) => writeFileSync(join(f.directory, `${f.prefix}-update-v2.json`), JSON.stringify({ ...f.manifest, artifact: { ...f.manifest.artifact, tarSize: 124 } })),
    (f) => writeFileSync(join(f.directory, `${f.prefix}-update.json`), JSON.stringify({ ...f.manifest, artifact: { ...f.manifest.artifact, file: "../secret.tar.zst" } })),
    (f) => writeFileSync(join(f.directory, `${f.prefix}-update.json`), JSON.stringify({ ...f.manifest, artifact: { ...f.manifest.artifact, tarSha256: "invalid" } })),
    (f) => writeFileSync(join(f.directory, `${f.prefix}-update.json`), JSON.stringify({ ...f.manifest, artifact: { ...f.manifest.artifact, tarSize: 0 } })),
    (f) => writeFileSync(join(f.directory, `${f.prefix}-update.json`), JSON.stringify({ ...f.manifest, artifact: { ...f.manifest.artifact, tarSize: undefined } })),
    (f) => writeFileSync(join(f.directory, `${f.prefix}-update.json`), JSON.stringify({ ...f.manifest, artifact: { ...f.manifest.artifact, tarSha256: undefined } })),
  ]) {
    const f = fixture(t);
    mutate(f);
    await assert.rejects(async () => inventoryArtifacts(options(f.directory)));
  }
});

test("managed deploy rejects artifact symlinks instead of uploading outside files", {
  skip: process.platform === "win32" && "Windows symlink creation requires privileges",
}, async (t) => {
  const f = fixture(t);
  const external = join(f.directory, "private.txt");
  writeFileSync(external, "do not upload");
  rmSync(join(f.directory, f.archiveName));
  symlinkSync(external, join(f.directory, f.archiveName));
  await assert.rejects(async () => inventoryArtifacts(options(f.directory)));
});

for (const integrity of [true, false]) test(`managed deploy accepts canonical update.json ${integrity ? "with" : "without"} tar integrity`, (t) => {
  const f = fixture(t);
  if (!integrity) writeFileSync(join(f.directory, `${f.prefix}-update.json`), JSON.stringify({ ...f.manifest, artifact: { file: f.archiveName } }));
  const inventory = inventoryArtifacts(options(f.directory));
  assert.equal(inventory.version, "1.2.3");
  assert.deepEqual(inventory.targets, ["macos-arm64"]);
  assert.deepEqual(inventory.files.map(file => file.filename).sort(), [f.archiveName, `${f.prefix}-update.json`].sort());
});

test("managed deploy accepts a matching legacy companion manifest", (t) => {
  const f = fixture(t);
  writeFileSync(join(f.directory, `${f.prefix}-update-v2.json`), JSON.stringify(f.manifest));
  assert.equal(inventoryArtifacts(options(f.directory)).files.length, 3);
});

test("managed deploy rejects cross-target release identities before upload", async (t) => {
  const f = fixture(t);
  const prefix = "canary-win-x64";
  const archiveName = `${prefix}-Example.tar.zst`;
  writeFileSync(join(f.directory, archiveName), "windows-archive");
  const manifest = {
    ...f.manifest,
    platform: "win",
    arch: "x64",
    identifier: "dev.electrobun.some-other-app",
    artifact: { file: archiveName },
  };
  writeFileSync(join(f.directory, `${prefix}-update.json`), JSON.stringify(manifest));
  await assert.rejects(async () => inventoryArtifacts(options(f.directory)));
});

test("managed deploy signs bounded parts and uploads directly without forwarding API credentials", async (t) => {
  const f = fixture(t, { archiveSize: partSize + 31 });
  const config = options(f.directory, ["--targets=macos-arm64,win-x64"]);
  const inventory = await inventoryArtifacts(config);
  const uploads = new Map();
  const logs = [];
  const requests = [];
  let createBody;
  const fetchImpl = async (url, request = {}) => {
    requests.push({ url: String(url), method: request.method ?? "GET" });
    assert.equal(request.redirect, "manual", "credentials must not follow redirects");
    const { pathname, origin } = new URL(url);
    if (origin === "https://r2.example.test") {
      assert.equal(request.method, "PUT");
      assert.equal(request.credentials, "omit");
      const [, id, partNumber] = pathname.split("/");
      const upload = uploads.get(id);
      assert.ok(upload);
      const bytes = Buffer.from(await new Response(request.body).arrayBuffer());
      verifyDirectPart(request.headers, bytes);
      assert.equal(new Headers(request.headers).get("x-amz-test"), "signed-header");
      const metadata = { partNumber: Number(partNumber), etag: partETag(bytes) };
      upload.parts.push(metadata);
      upload.bytes.push(bytes);
      return new Response(null, { status: 200, headers: { etag: `"${metadata.etag}"` } });
    }
    assert.equal(new Headers(request.headers).get("authorization"), `Bearer ${key}`);
    if (pathname === "/v1/electrobun/apps/app-1/releases") {
      createBody = JSON.parse(request.body);
      return json({ release: { id: "canary-1.2.3", status: "staged" } });
    }
    if (pathname.endsWith("/uploads")) {
      const body = JSON.parse(request.body);
      const id = `upload-${uploads.size + 1}`;
      uploads.set(id, { body, parts: [], bytes: [] });
      return json({ upload: { id, partSize, parts: [], status: "uploading" }, partSize });
    }
    const part = pathname.match(/\/uploads\/([^/]+)\/parts\/(\d+)$/);
    if (part) {
      assert.equal(request.method, "POST");
      assert.equal(new Headers(request.headers).get("content-type"), "application/json");
      const grant = signedGrant(`https://r2.example.test/${part[1]}/${part[2]}?signature=private`, JSON.parse(request.body));
      grant.headers["x-amz-test"] = "signed-header";
      return json(grant);
    }
    const complete = pathname.match(/\/uploads\/([^/]+)\/complete$/);
    if (complete) {
      const upload = uploads.get(complete[1]);
      assert.deepEqual(JSON.parse(request.body), { parts: upload.parts });
      const bytes = Buffer.concat(upload.bytes);
      assert.equal(bytes.length, upload.body.size);
      assert.equal(digest(bytes), upload.body.sha256);
      assert.deepEqual(bytes, readFileSync(join(f.directory, upload.body.filename)));
      return json({ artifact: upload.body, release: { id: "canary-1.2.3", status: "staged" } });
    }
    assert.equal(pathname, "/v1/electrobun/apps/app-1/releases/canary-1.2.3");
    assert.equal(request.method ?? "GET", "GET");
    return json({ release: { id: "canary-1.2.3", status: "staged" }, checks: { ready: false, targets: [], errors: [] } });
  };
  await deployArtifacts(config, inventory, { fetchImpl, log: (line) => logs.push(line) });
  assert.equal(createBody.releaseId, "canary-1.2.3");
  assert.equal(createBody.channel, "canary");
  assert.equal(createBody.version, "1.2.3");
  assert.deepEqual(createBody.expectedTargets, ["macos-arm64", "win-x64"]);
  assert.equal(uploads.size, inventory.files.length);
  const archiveUpload = [...uploads.values()].find((upload) => upload.body.filename === f.archiveName);
  assert.deepEqual(archiveUpload.bytes.map((part) => part.length), [partSize, 31]);
  assert.equal(requests.some((request) => request.url.includes("/publish")), false);
  assert.equal(logs.join("\n").includes(key), false);
});

test("managed deploy rejects files changed after inventory before starting their upload", async (t) => {
  const f = fixture(t);
  const config = options(f.directory);
  const inventory = inventoryArtifacts(config);
  writeFileSync(join(f.directory, f.archiveName), "changed-length-after-inventory");
  const paths = [];
  await assert.rejects(() => deployArtifacts(config, inventory, {
    fetchImpl: async (url) => {
      paths.push(new URL(url).pathname);
      return json({ release: { id: "canary-1.2.3" } });
    },
    log: () => {},
  }), /changed after inventory/);
  assert.deepEqual(paths, ["/v1/electrobun/apps/app-1/releases"]);
});

test("managed deploy never completes an artifact changed during upload", async (t) => {
  const f = fixture(t, { archiveSize: partSize + 31 });
  const config = options(f.directory);
  const inventory = inventoryArtifacts(config);
  let completed = false;
  let sentParts = 0;
  await assert.rejects(() => deployArtifacts(config, inventory, {
    fetchImpl: async (url, request) => {
      const { pathname, origin } = new URL(url);
      if (origin === "https://r2.example.test") {
        sentParts += 1;
        if (pathname === "/1") {
          const changed = Buffer.from(f.archive);
          changed[partSize] ^= 0xff;
          writeFileSync(join(f.directory, f.archiveName), changed);
        }
        verifyDirectPart(request.headers, request.body);
        return new Response(null, { headers: { etag: digest(request.body) } });
      }
      if (pathname.endsWith("/uploads")) {
        return json({ upload: { id: "upload-1", partSize, parts: [], status: "uploading" }, partSize });
      }
      const part = pathname.match(/\/parts\/(\d+)$/);
      if (part) {
        assert.equal(request.method, "POST");
        return json(signedGrant(`https://r2.example.test/${part[1]}`, JSON.parse(request.body)));
      }
      if (pathname.endsWith("/complete")) completed = true;
      return json({ release: { id: "canary-1.2.3" } });
    },
    log: () => {},
  }), /changed during upload/);
  assert.equal(sentParts, 2);
  assert.equal(completed, false);
});

test("managed deploy repairs changed remote parts when resuming a failed integrity check", async (t) => {
  const f = fixture(t, { archiveSize: partSize + 31 });
  const config = options(f.directory);
  const uploads = new Map(), fileIds = new Map(), attempts = new Map();
  let changed = false, completed = 0;
  const fetchImpl = async (url, request) => {
    const { origin, pathname } = new URL(url);
    if (origin === "https://r2.example.test") {
      const [, id, part] = pathname.split("/");
      const upload = uploads.get(id);
      const partNumber = Number(part), bytes = Buffer.from(request.body);
      verifyDirectPart(request.headers, bytes);
      attempts.set(`${id}-${part}`, (attempts.get(`${id}-${part}`) ?? 0) + 1);
      upload.parts.set(partNumber, { partNumber, etag: partETag(bytes), bytes });
      if (upload.body.filename === f.archiveName && partNumber === 1 && !changed) {
        changed = true;
        const changedBytes = Buffer.from(f.archive);
        changedBytes[partSize] ^= 0xff;
        writeFileSync(join(f.directory, f.archiveName), changedBytes);
      }
      return new Response(null, { headers: { etag: `"${partETag(bytes)}"` } });
    }
    if (pathname.endsWith("/uploads")) {
      const body = JSON.parse(request.body);
      const id = fileIds.get(body.filename) ?? `upload-${uploads.size + 1}`;
      if (!uploads.has(id)) {
        fileIds.set(body.filename, id);
        uploads.set(id, { body, parts: new Map() });
      }
      const upload = uploads.get(id);
      assert.deepEqual(body, upload.body);
      // The API may expose quoted or unquoted S3 ETags. Both identify the part.
      return json({ upload: { id, parts: [...upload.parts.values()].map(({ partNumber, etag }) => ({ partNumber, etag: `"${etag}"` })) }, partSize });
    }
    const part = pathname.match(/\/uploads\/([^/]+)\/parts\/(\d+)$/);
    if (part) return json(signedGrant(`https://r2.example.test/${part[1]}/${part[2]}`, JSON.parse(request.body)));
    const complete = pathname.match(/\/uploads\/([^/]+)\/complete$/);
    if (complete) {
      completed += 1;
      const upload = uploads.get(complete[1]);
      const parts = [...upload.parts.values()].sort((a, b) => a.partNumber - b.partNumber);
      assert.deepEqual(JSON.parse(request.body), { parts: parts.map(({ partNumber, etag }) => ({ partNumber, etag })) });
      assert.equal(digest(Buffer.concat(parts.map(({ bytes }) => bytes))), upload.body.sha256);
    }
    return json({ release: { id: "canary-1.2.3" } });
  };
  await assert.rejects(() => deployArtifacts(config, inventoryArtifacts(config), { fetchImpl, log: () => {} }), /changed during upload/);
  assert.equal(completed, 0);
  writeFileSync(join(f.directory, f.archiveName), f.archive);
  await deployArtifacts(config, inventoryArtifacts(config), { fetchImpl, log: () => {} });
  const archiveId = fileIds.get(f.archiveName);
  assert.equal(attempts.get(`${archiveId}-1`), 1, "the matching first part is reused");
  assert.equal(attempts.get(`${archiveId}-2`), 2, "the changed second part is replaced before completion");
  assert.equal(completed, 2);
});

test("managed deploy rejects unsafe or mismatched signed upload grants before sending artifact bytes", async (t) => {
  const f = fixture(t);
  const config = options(f.directory);
  const inventory = inventoryArtifacts(config);
  for (const mutate of [
    grant => { grant.url = "http://r2.example.test/part"; },
    grant => { grant.url = "http://127.0.0.1/part"; },
    grant => { grant.url = "https://user:secret@r2.example.test/part"; },
    grant => { grant.url += "#fragment"; },
    grant => { grant.url = "file:///tmp/part"; },
    grant => { delete grant.headers["content-md5"]; },
    grant => { grant.headers["content-md5"] = md5("different bytes"); },
    grant => { grant.headers["content-length"] = "999"; },
    grant => { grant.headers.Authorization = `Bearer ${key}`; },
    grant => { grant.headers.Cookie = "session=secret"; },
    grant => { grant.headers["Proxy-Authorization"] = "secret"; },
    grant => { grant.headers["Content-Length"] = grant.headers["content-length"]; },
    grant => { grant.headers = []; },
  ]) {
    const calls = [];
    await assert.rejects(() => deployArtifacts(config, inventory, {
      log: () => {},
      fetchImpl: async (url, request) => {
        calls.push([url, request.method]);
        if (url.endsWith("/uploads")) return json({ upload: { id: "upload-1", parts: [] }, partSize });
        if (url.endsWith("/parts/1")) {
          const grant = signedGrant("https://r2.example.test/part?signature=private", JSON.parse(request.body));
          mutate(grant);
          return json(grant);
        }
        return json({});
      },
    }), /invalid signed upload grant/);
    assert.equal(calls.length, 3);
    assert.ok(calls.every(([url, method]) => url.startsWith(config.apiUrl) && method === "POST"));
  }
});

test("managed deploy requires a successful R2 part response with an ETag before completing", async (t) => {
  const f = fixture(t);
  const config = options(f.directory);
  for (const result of [
    () => new Response(null, { status: 403, headers: { etag: "unaccepted" } }),
    () => new Response(null, { status: 200 }),
    () => new Response(null, { status: 200, headers: { etag: " " } }),
    () => new Response(null, { status: 200, headers: { etag: '\"\"' } }),
    () => { throw new Error("https://r2.example.test/part?signature=private"); },
  ]) {
    let completed = false;
    await assert.rejects(() => deployArtifacts(config, inventoryArtifacts(config), {
      log: () => {},
      fetchImpl: async (url, request) => {
        if (url.startsWith("https://r2.example.test")) return result();
        if (url.endsWith("/uploads")) return json({ upload: { id: "upload-1", parts: [] }, partSize });
        if (url.endsWith("/parts/1")) return json(signedGrant("https://r2.example.test/part?signature=private", JSON.parse(request.body)));
        if (url.endsWith("/complete")) completed = true;
        return json({});
      },
    }), error => {
      assert.match(error.message, /Direct artifact upload/);
      assert.equal(error.message.includes("signature=private"), false);
      return true;
    });
    assert.equal(completed, false);
  }
});

test("managed deploy refuses API redirects and never forwards credentials", async (t) => {
  const f = fixture(t);
  const config = options(f.directory);
  const inventory = await inventoryArtifacts(config);
  let calls = 0;
  await assert.rejects(() => deployArtifacts(config, inventory, {
    fetchImpl: async (_url, request) => {
      calls += 1;
      assert.equal(request.redirect, "manual");
      return new Response(null, { status: 307, headers: { location: "https://untrusted.example.test/steal" } });
    },
    log: () => {},
  }));
  assert.equal(calls, 1);
});

test("managed deploy resumes a real interrupted multipart upload with the same release identity", { timeout: 30_000 }, async (t) => {
  const f = fixture(t, { archiveSize: partSize + 31 });
  const uploads = new Map();
  const fileIds = new Map();
  const createBodies = [];
  const errors = [];
  const attempts = new Map();
  let interrupted = false;
  const r2Url = await serve(t, async (request, response) => {
    try {
      assert.equal(request.method, "PUT");
      const [, id, part] = new URL(request.url, "http://localhost").pathname.split("/");
      const upload = uploads.get(id);
      const partNumber = Number(part);
      const bytes = await requestBody(request);
      verifyDirectPart(request.headers, bytes);
      const attemptKey = `${id}-${partNumber}`;
      attempts.set(attemptKey, (attempts.get(attemptKey) ?? 0) + 1);
      if (upload.body.filename === f.archiveName && partNumber === 2 && !interrupted) {
        interrupted = true;
        response.destroy();
        return;
      }
      const receipt = { partNumber, etag: partETag(bytes) };
      upload.parts.set(partNumber, { receipt, bytes });
      response.writeHead(200, { etag: `"${receipt.etag}"` });
      response.end();
    } catch (error) {
      errors.push(error);
      reply(response, { error: "R2 fixture error" }, 500);
    }
  });
  const baseUrl = await serve(t, async (request, response) => {
    try {
      assert.equal(request.headers.authorization, `Bearer ${key}`);
      const pathname = new URL(request.url, "http://localhost").pathname;
      if (pathname === "/v1/electrobun/apps/app-1/releases") {
        createBodies.push(JSON.parse(await requestBody(request)));
        reply(response, { release: { id: "canary-1.2.3", status: "staged" } });
        return;
      }
      if (pathname.endsWith("/uploads")) {
        const body = JSON.parse(await requestBody(request));
        const id = fileIds.get(body.filename) ?? `upload-${uploads.size + 1}`;
        if (!uploads.has(id)) {
          fileIds.set(body.filename, id);
          uploads.set(id, { body, parts: new Map(), status: "uploading" });
        }
        const upload = uploads.get(id);
        assert.deepEqual(body, upload.body);
        reply(response, {
          upload: { id, partSize, status: upload.status, parts: [...upload.parts.values()].map(({ receipt }) => receipt) },
          partSize,
        });
        return;
      }
      const part = pathname.match(/\/uploads\/([^/]+)\/parts\/(\d+)$/);
      if (part) {
        assert.equal(request.method, "POST");
        assert.equal(request.headers["content-type"], "application/json");
        reply(response, signedGrant(`${r2Url}/${part[1]}/${part[2]}`, JSON.parse(await requestBody(request))));
        return;
      }
      const complete = pathname.match(/\/uploads\/([^/]+)\/complete$/);
      if (complete) {
        const upload = uploads.get(complete[1]);
        const ordered = [...upload.parts.values()].sort((a, b) => a.receipt.partNumber - b.receipt.partNumber);
        assert.deepEqual(JSON.parse(await requestBody(request)), { parts: ordered.map(({ receipt }) => receipt) });
        assert.equal(digest(Buffer.concat(ordered.map(({ bytes }) => bytes))), upload.body.sha256);
        upload.status = "completed";
        reply(response, { artifact: upload.body, release: { id: "canary-1.2.3" } });
        return;
      }
      assert.equal(pathname, "/v1/electrobun/apps/app-1/releases/canary-1.2.3");
      reply(response, { release: { id: "canary-1.2.3", status: "staged" }, checks: { ready: true, targets: [], errors: [] } });
    } catch (error) {
      errors.push(error);
      reply(response, { error: "test fixture error" }, 500);
    }
  });
  const config = options(f.directory, [`--api-url=${baseUrl}`]);
  const inventory = await inventoryArtifacts(config);
  await assert.rejects(() => deployArtifacts(config, inventory, { log: () => {} }), /request failed/);
  assert.equal(interrupted, true);
  const result = await deployArtifacts(config, inventory, { log: () => {} });
  assert.equal(result.checks.ready, true);
  const archiveId = fileIds.get(f.archiveName);
  assert.equal(attempts.get(`${archiveId}-1`), 1, "resume must preserve the uploaded first part");
  assert.equal(attempts.get(`${archiveId}-2`), 2, "only the interrupted second part is sent again");
  assert.equal(createBodies.length, 2);
  assert.deepEqual(createBodies[0], createBodies[1]);
  assert.deepEqual(errors, []);

  const partRequests = [...attempts.values()].reduce((sum, count) => sum + count, 0);
  await deployArtifacts(config, inventory, { log: () => {} });
  assert.equal([...attempts.values()].reduce((sum, count) => sum + count, 0), partRequests, "completed files are not uploaded again");
});

test("managed deploy does not send an API key to a real redirect target", async (t) => {
  const f = fixture(t);
  let redirectedRequests = 0;
  const destination = await serve(t, (_request, response) => {
    redirectedRequests += 1;
    reply(response, {});
  });
  const source = await serve(t, (_request, response) => {
    response.writeHead(307, { location: `${destination}/collect-credentials` });
    response.end();
  });
  const config = options(f.directory, [`--api-url=${source}`]);
  await assert.rejects(() => deployArtifacts(config, inventoryArtifacts(config), { log: () => {} }), /redirected/);
  assert.equal(redirectedRequests, 0);
});

test("managed deploy refuses direct R2 redirects without forwarding the artifact or signature", async (t) => {
  const f = fixture(t);
  const errors = [];
  let destinationRequests = 0, directRequests = 0, completed = false;
  const destination = await serve(t, (_request, response) => {
    destinationRequests += 1;
    response.end();
  });
  const r2Url = await serve(t, async (request, response) => {
    try {
      directRequests += 1;
      verifyDirectPart(request.headers, await requestBody(request));
      response.writeHead(307, { location: `${destination}/collect-artifact` });
      response.end();
    } catch (error) { errors.push(error); reply(response, {}, 500); }
  });
  const apiUrl = await serve(t, async (request, response) => {
    try {
      assert.equal(request.headers.authorization, `Bearer ${key}`);
      if (request.url.endsWith("/uploads")) return reply(response, { upload: { id: "upload-1", parts: [] }, partSize });
      if (request.url.endsWith("/parts/1")) return reply(response, signedGrant(`${r2Url}/part?signature=private`, JSON.parse(await requestBody(request))));
      if (request.url.endsWith("/complete")) completed = true;
      reply(response, {});
    } catch (error) { errors.push(error); reply(response, {}, 500); }
  });
  const config = options(f.directory, [`--api-url=${apiUrl}`]);
  await assert.rejects(() => deployArtifacts(config, inventoryArtifacts(config), { log: () => {} }), /Direct artifact upload redirected/);
  assert.equal(directRequests, 1);
  assert.equal(destinationRequests, 0);
  assert.equal(completed, false);
  assert.deepEqual(errors, []);
});

test("managed deploy dry run needs no key and performs no network requests", async (t) => {
  const f = fixture(t);
  const originalFetch = globalThis.fetch;
  const originalLog = console.log;
  const output = [];
  globalThis.fetch = () => { throw new Error("dry run attempted network access"); };
  console.log = (...args) => output.push(args.join(" "));
  try {
    await runDeploy([
      "--env=canary", "--release=canary-1.2.3", "--app=app-1", `--artifacts=${f.directory}`, "--dry-run",
    ], {}, {});
    await runDeploy([
      "--env=canary", "--release=canary-1.2.3", "--app=app-1", `--artifacts=${f.directory}`, "--dry-run",
    ], {}, { ELECTROBUN_API_KEY: key });
    assert.ok(output.length > 0);
    assert.equal(output.join("\n").includes(key), false);
  } finally {
    globalThis.fetch = originalFetch;
    console.log = originalLog;
  }
});

test("native Hutch deploy uses build metadata and uploads without a JavaScript runtime", {
  skip: !process.env.HUTCH_BINARY && "Set HUTCH_BINARY to a built Hutch executable for the native CLI smoke test",
  timeout: 60_000,
}, async (t) => {
  const f = fixture(t, { archiveSize: partSize + 31 });
  writeFileSync(join(f.directory, "managed-deploy.json"), JSON.stringify({ appId: "app-1", artifactFolder: "." }));
  const env = { ...process.env, ELECTROBUN_API_KEY: "", DASH_RELEASE_OFFLINE: "1" };
  const args = ["--env=canary", "--release=canary-1.2.3", "--artifacts=."];
  const dry = await runCli([...args, "--dry-run"], f.directory, env);
  assert.equal(dry.status, 0, dry.stderr || dry.stdout);
  assert.match(dry.stdout, /App app-1, release canary-1.2.3: canary 1\.2\.3/);
  assert.match(dry.stdout, /Dry run: no files uploaded/);
  assert.match(dry.stdout, new RegExp(f.archiveName.replaceAll(".", "\\.")));

  const uploads = new Map();
  const errors = [];
  const methods = [];
  const r2Url = await serve(t, async (request, response) => {
    try {
      assert.equal(request.method, "PUT");
      const [, id, part] = new URL(request.url, "http://localhost").pathname.split("/");
      const upload = uploads.get(id);
      const chunk = await requestBody(request);
      verifyDirectPart(request.headers, chunk);
      const receipt = { partNumber: Number(part), etag: partETag(chunk) };
      upload.parts.push(receipt);
      upload.chunks.push(chunk);
      response.writeHead(200, { etag: `"${receipt.etag}"` });
      response.end();
    } catch (error) {
      errors.push(error);
      reply(response, { error: "R2 fixture error" }, 500);
    }
  });
  const apiUrl = await serve(t, async (request, response) => {
    try {
      methods.push(`${request.method} ${request.url}`);
      assert.equal(request.headers.authorization, `Bearer ${key}`);
      const pathname = new URL(request.url, "http://localhost").pathname;
      if (pathname === "/v1/electrobun/apps/app-1/releases") {
        assert.deepEqual(JSON.parse(await requestBody(request)), {
          releaseId: "canary-1.2.3", channel: "canary", version: "1.2.3", expectedTargets: ["macos-arm64"],
        });
        reply(response, { release: { id: "canary-1.2.3", status: "staged" } });
        return;
      }
      if (pathname.endsWith("/uploads")) {
        const body = JSON.parse(await requestBody(request));
        const id = `upload-${uploads.size + 1}`;
        uploads.set(id, { body, parts: [], chunks: [] });
        reply(response, { upload: { id, partSize, parts: [], status: "uploading" }, partSize });
        return;
      }
      const part = pathname.match(/\/uploads\/([^/]+)\/parts\/(\d+)$/);
      if (part) {
        assert.equal(request.method, "POST");
        assert.equal(request.headers["content-type"], "application/json");
        reply(response, signedGrant(`${r2Url}/${part[1]}/${part[2]}`, JSON.parse(await requestBody(request))));
        return;
      }
      const complete = pathname.match(/\/uploads\/([^/]+)\/complete$/);
      if (complete) {
        const upload = uploads.get(complete[1]);
        assert.deepEqual(JSON.parse(await requestBody(request)), { parts: upload.parts });
        assert.equal(digest(Buffer.concat(upload.chunks)), upload.body.sha256);
        reply(response, { artifact: upload.body, release: { id: "canary-1.2.3" } });
        return;
      }
      assert.equal(pathname, "/v1/electrobun/apps/app-1/releases/canary-1.2.3");
      reply(response, { release: { id: "canary-1.2.3", status: "staged" }, checks: { ready: true, errors: [] } });
    } catch (error) {
      errors.push(error);
      reply(response, { error: "test fixture error" }, 500);
    }
  });
  const uploaded = await runCli([...args, `--api-url=${apiUrl}`], f.directory, {
    ...env, DASH_RELEASE_OFFLINE: "0", ELECTROBUN_API_KEY: key,
  });
  assert.equal(uploaded.status, 0, uploaded.stderr || uploaded.stdout);
  assert.equal(uploads.size, 2);
  assert.equal([...uploads.values()].find((upload) => upload.body.filename === f.archiveName).parts.length, 2);
  assert.equal(methods.some((method) => method.includes("/publish")), false);
  assert.equal(`${uploaded.stdout}${uploaded.stderr}`.includes(key), false);
  assert.match(uploaded.stdout, /Staged canary-1\.2\.3\. After all runners finish, publish to prerelease/);
  assert.match(uploaded.stdout, /--release=canary-1\.2\.3 --audience=prerelease/);
  assert.match(uploaded.stdout, /--audience=public to publish to all installs/);
  assert.deepEqual(errors, []);
});

test("native Hutch deploy rejects redirects without forwarding API credentials", {
  skip: !process.env.HUTCH_BINARY && "Set HUTCH_BINARY to a built Hutch executable for the native CLI smoke test",
  timeout: 60_000,
}, async (t) => {
  const f = fixture(t);
  let destinationRequests = 0;
  let sourceAuthorization;
  const destination = await serve(t, (_request, response) => {
    destinationRequests += 1;
    reply(response, {});
  });
  const source = await serve(t, (request, response) => {
    sourceAuthorization = request.headers.authorization;
    response.writeHead(307, { location: `${destination}/collect-credentials` });
    response.end();
  });
  const result = await runCli([
    "--env=canary", "--release=canary-1.2.3", "--app=app-1", `--artifacts=${f.directory}`, `--api-url=${source}`,
  ], f.directory, { ...process.env, ELECTROBUN_API_KEY: key, DASH_RELEASE_OFFLINE: "0" });
  assert.notEqual(result.status, 0, result.stdout);
  assert.equal(sourceAuthorization, `Bearer ${key}`);
  assert.equal(destinationRequests, 0);
  assert.match(result.stderr, /redirected/);
  assert.equal(`${result.stdout}${result.stderr}`.includes(key), false);
});


test("upload infers channel, version and platform from the generated artifacts", t => {
  const f = fixture(t, { channel: "stable", platform: "linux", arch: "x64" });
  const config = parseUploadArgs([`--artifacts=${f.directory}`], { appId: "app-1" }, { ELECTROBUN_API_KEY: key });
  assert.equal(config.channel, undefined);
  assert.equal(config.expectedTargets, null);
  const [planned] = inventoryReleases(config);
  assert.equal(planned.options.releaseId, "stable-1.2.3");
  assert.equal(planned.options.channel, "stable");
  assert.deepEqual(planned.inventory.targets, ["linux-x64"]);
  assert.equal(planned.inventory.files.length, 2);
  assert.equal(inventoryArtifacts(config).channel, "stable", "Single-release helper also supports discovery");
});

test("mixed artifact folders stage separate canary and stable releases with no target list", async t => {
  const canary = fixture(t);
  const stable = fixture(t, { channel: "stable", platform: "win", arch: "x64" });
  for (const name of readdirSync(stable.directory)) copyFileSync(join(stable.directory, name), join(canary.directory, name));
  const config = parseUploadArgs([`--artifacts=${canary.directory}`], { appId: "app-1" }, { ELECTROBUN_API_KEY: key });
  const planned = inventoryReleases(config);
  assert.deepEqual(planned.map(item => item.options.releaseId), ["canary-1.2.3", "stable-1.2.3"]);
  const staged = [], calls = [];
  const response = await uploadArtifacts(config, {
    log: () => {},
    fetchImpl: async (url, init) => {
      calls.push([url, init.method]);
      if (url.endsWith("/releases")) { staged.push(JSON.parse(init.body)); return json({}); }
      if (url.endsWith("/uploads")) return json({ upload: { id: "already-uploaded", status: "complete" } });
      const id = url.split("/").at(-1);
      return json({ release: { id, status: "staging" }, checks: { ready: true, errors: [] } });
    },
  });
  assert.deepEqual(staged.map(item => [item.releaseId, item.channel, item.expectedTargets]), [
    ["canary-1.2.3", "canary", ["macos-arm64"]], ["stable-1.2.3", "stable", ["win-x64"]],
  ]);
  assert.equal(response.releases.length, 2);
  assert.equal(calls.some(([url]) => url.endsWith("/publish")), false);
  assert.throws(() => inventoryReleases({ ...config, releaseId: "build-42" }), /both canary and stable/);
  assert.throws(() => inventoryReleases({ ...config, releaseId: "build-42", channel: "stable" }), /must match <channel>-<version>/);
  assert.equal(inventoryReleases({ ...config, releaseId: "stable-1.2.3", channel: "stable" })[0].options.releaseId, "stable-1.2.3");
});

test("upload inventories every discovered release before starting network writes", async t => {
  const canary = fixture(t);
  const stable = fixture(t, { channel: "stable" });
  for (const name of readdirSync(stable.directory)) copyFileSync(join(stable.directory, name), join(canary.directory, name));
  rmSync(join(canary.directory, stable.archiveName));
  const config = parseUploadArgs([`--artifacts=${canary.directory}`], { appId: "app-1" }, { ELECTROBUN_API_KEY: key });
  let requests = 0;
  await assert.rejects(uploadArtifacts(config, { fetchImpl: async () => { requests++; return json({}); } }), /Missing archive/);
  assert.equal(requests, 0);
});

test("upload rejects aliases and cross-channel release IDs before network writes", async t => {
  const f = fixture(t);
  for (const releaseId of ["build-42", "stable-1.2.3", "canary-1.2.4"]) {
    const config = parseUploadArgs([`--artifacts=${f.directory}`, `--release=${releaseId}`], { appId: "app-1" }, { ELECTROBUN_API_KEY: key });
    let requests = 0;
    await assert.rejects(uploadArtifacts(config, { fetchImpl: async () => { requests++; return json({}); } }), /must match <channel>-<version>/);
    assert.equal(requests, 0);
    await assert.rejects(deployArtifacts(config, inventoryArtifacts(config), { fetchImpl: async () => { requests++; return json({}); } }), /must match <channel>-<version>/);
    assert.equal(requests, 0);
  }
});

test("publish requires a release and authentication even for a server-side dry run", () => {
  const env = { ELECTROBUN_API_KEY: key };
  assert.throws(() => parsePublishArgs([], { appId: "app-1" }, env), /--release is required/);
  assert.throws(() => parsePublishArgs(["--release=stable-1.2.3", "--dry-run"], { appId: "app-1" }, {}), /API_KEY/);
  assert.throws(() => parsePublishArgs(["--release=stable-1.2.3", "--env=stable"], { appId: "app-1" }, env), /Unknown publish option/);
  assert.equal(parsePublishArgs(["--release=stable-1.2.3"], { appId: "app-1" }, env).releaseId, "stable-1.2.3");
});

test("publish accepts only explicit prerelease or public audiences and defaults to public", () => {
  const defaults = { appId: "app-1" }, env = { ELECTROBUN_API_KEY: key };
  assert.equal(parsePublishArgs(["--release=stable-1.2.3"], defaults, env).audience, "public");
  assert.equal(parsePublishArgs(["--release=stable-1.2.3", "--audience", "prerelease"], defaults, env).audience, "prerelease");
  assert.equal(parsePublishArgs(["--release=stable-1.2.3", "--audience=public"], defaults, env).audience, "public");
  for (const audience of ["test", "everyone", "preview", "stable", "canary", "PRERELEASE"]) {
    assert.throws(() => parsePublishArgs(["--release=stable-1.2.3", `--audience=${audience}`], defaults, env), /--audience must be prerelease or public/);
  }
  assert.throws(() => parseUploadArgs(["--audience=prerelease"], defaults, env), /Unknown upload option/);
});

function stagedForPublish() {
  return {
    release: { id: "stable-1.2.3", channel: "stable", version: "1.2.3", status: "staging", expectedTargets: ["macos-arm64", "linux-x64"],
      artifacts: [{ filename: "stable-macos-arm64-Example.app.tar.zst", size: 128 }, { filename: "stable-linux-x64-Example.tar.zst", size: 256 }] },
    checks: { ready: true, errors: [] },
  };
}

const publishOptions = (extra = []) => parsePublishArgs(["--release=stable-1.2.3", ...extra], { appId: "app-1" }, { ELECTROBUN_API_KEY: key });

test("publish inspects accumulated server files then explicitly changes the live release", async () => {
  const staged = stagedForPublish(), calls = [], output = [];
  const result = await publishRelease(publishOptions(), {
    log: line => output.push(line),
    fetchImpl: async (url, init) => {
      calls.push([url, init.method]);
      assert.equal(init.headers.Authorization, `Bearer ${key}`);
      assert.equal(init.redirect, "manual");
      if (init.method === "POST") assert.deepEqual(JSON.parse(init.body), { audience: "public" });
      return json(init.method === "GET" ? staged : { ...staged, release: { ...staged.release, status: "published" } });
    },
  });
  assert.deepEqual(calls.map(([url, method]) => [url.replace("https://api.electrobun.dev", ""), method]), [
    ["/v1/electrobun/apps/app-1/releases/stable-1.2.3", "GET"], ["/v1/electrobun/apps/app-1/releases/stable-1.2.3/publish", "POST"],
  ]);
  assert.equal(result.release.status, "published");
  assert.match(output.join("\n"), /stable-linux-x64-Example.tar.zst/);
  assert.match(output.join("\n"), /Published stable-1\.2\.3 to public/);
});

test("publish to prerelease sends prerelease audience and requires prerelease confirmation", async () => {
  const staged = stagedForPublish(), calls = [], output = [];
  const result = await publishRelease(publishOptions(["--audience=prerelease"]), {
    log: line => output.push(line),
    fetchImpl: async (_url, init) => {
      calls.push(init.method);
      if (init.method === "GET") return json(staged);
      assert.deepEqual(JSON.parse(init.body), { audience: "prerelease" });
      return json({ ...staged, release: { ...staged.release, status: "prerelease" } });
    },
  });
  assert.equal(result.release.status, "prerelease");
  assert.deepEqual(calls, ["GET", "POST"]);
  assert.match(output.join("\n"), /Published stable-1\.2\.3 to prerelease\./);
  for (const [audience, status] of [["prerelease", "published"], ["public", "prerelease"]]) {
    await assert.rejects(publishRelease(publishOptions([`--audience=${audience}`]), {
      log: () => {}, fetchImpl: async (_url, init) => json(init.method === "GET" ? staged : { ...staged, release: { ...staged.release, status } }),
    }), /did not confirm publication/);
  }
});

for (const audience of ["prerelease", "public"]) test(`publish dry run identifies ${audience} audience without changing routing`, async () => {
  const calls = [], output = [];
  const result = await publishRelease(publishOptions([`--audience=${audience}`, "--dry-run"]), {
    log: line => output.push(line), fetchImpl: async (_url, init) => { calls.push(init.method); return json(stagedForPublish()); },
  });
  assert.equal(result.dryRun, true);
  assert.deepEqual(calls, ["GET"]);
  assert.match(output.join("\n"), audience === "prerelease" ? /checks for prerelease/ : /checks for public/);
});

test("publish dry run checks remote files without publishing or reading local artifacts", async () => {
  const calls = [];
  const result = await publishRelease({ ...publishOptions(["--dry-run"]), artifacts: "/does-not-exist" }, {
    log: () => {}, fetchImpl: async (url, init) => { calls.push([url, init.method]); return json(stagedForPublish()); },
  });
  assert.equal(result.dryRun, true);
  assert.equal(calls.length, 1);
  assert.equal(calls[0][1], "GET");
});

test("publish refuses incomplete or malformed remote releases and never falls through to POST", async () => {
  for (const response of [
    { ...stagedForPublish(), checks: { ready: false, errors: ["Upload is incomplete"] } },
    { ...stagedForPublish(), checks: {} },
    { ...stagedForPublish(), release: { ...stagedForPublish().release, id: "some-other-release" } },
  ]) {
    const calls = [];
    await assert.rejects(publishRelease(publishOptions(), { log: () => {}, fetchImpl: async (_url, init) => { calls.push(init.method); return json(response); } }), /not ready|invalid release details/);
    assert.deepEqual(calls, ["GET"]);
  }
});

test("publish respects the final server validation and refuses credential-bearing redirects", async () => {
  const calls = [];
  await assert.rejects(publishRelease(publishOptions(), {
    log: () => {}, fetchImpl: async (_url, init) => { calls.push(init.method); return init.method === "GET" ? json(stagedForPublish()) : json({ error: "Upload started concurrently" }, 409); },
  }), /HTTP 409/);
  assert.deepEqual(calls, ["GET", "POST"]);
  await assert.rejects(publishRelease(publishOptions(), { log: () => {}, fetchImpl: async (_url, init) => {
    assert.equal(init.redirect, "manual"); return new Response(null, { status: 307, headers: { Location: "https://untrusted.example/" } });
  } }), /redirected/);
});

test("publish redacts credentials echoed in remote metadata", async () => {
  const staged = stagedForPublish(); staged.release.artifacts[0].filename = `${key}.tar.zst`;
  const output = [];
  await publishRelease(publishOptions(["--dry-run"]), { log: line => output.push(line), fetchImpl: async () => json(staged) });
  assert.equal(output.join("\n").includes(key), false);
  assert.match(output.join("\n"), /\[redacted\]/);
});

test("native Hutch upload discovers its release and publish runs without an artifacts directory", {
  skip: !process.env.HUTCH_BINARY && "Set HUTCH_BINARY to a built Hutch executable for the native CLI smoke test",
  timeout: 60_000,
}, async t => {
  const f = fixture(t);
  const env = { ...process.env, ELECTROBUN_API_KEY: key, DASH_RELEASE_OFFLINE: "0" };
  const dry = await runCli(["--app=app-1", `--artifacts=${f.directory}`, "--dry-run"], f.directory, env, "upload");
  assert.equal(dry.status, 0, dry.stderr || dry.stdout);
  assert.match(dry.stdout, /App app-1, release canary-1\.2\.3: canary 1\.2\.3/);
  assert.match(dry.stdout, /Dry run: no files uploaded/);
  const empty = mkdtempSync(join(tmpdir(), "hutch-publish-empty-"));
  t.after(() => rmSync(empty, { recursive: true, force: true }));
  const calls = [], errors = [];
  const staged = stagedForPublish();
  const apiUrl = await serve(t, async (request, response) => {
    try {
      assert.equal(request.headers.authorization, `Bearer ${key}`);
      calls.push([request.url, request.method]);
      reply(response, request.method === "GET" ? staged : { ...staged, release: { ...staged.release, status: "published" } });
    } catch (error) { errors.push(error); reply(response, {}, 500); }
  });
  const args = ["--app=app-1", "--release=stable-1.2.3", `--api-url=${apiUrl}`];
  const inspect = await runCli([...args, "--dry-run"], empty, env, "publish");
  assert.equal(inspect.status, 0, inspect.stderr || inspect.stdout);
  assert.deepEqual(calls.map(([, method]) => method), ["GET"]);
  const published = await runCli(args, empty, env, "publish");
  assert.equal(published.status, 0, published.stderr || published.stdout);
  assert.match(published.stdout, /Published stable-1\.2\.3 to public\./);
  assert.deepEqual(calls.map(([, method]) => method), ["GET", "GET", "POST"]);
  assert.deepEqual(errors, []);
});
