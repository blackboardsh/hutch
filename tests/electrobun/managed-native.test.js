import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repository = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const binary = resolve(process.env.HUTCH_BINARY || join(repository, "zig-out/bin", process.platform === "win32" ? "hutch.exe" : "hutch"));
const native = { skip: !existsSync(binary) && "Build Hutch or set HUTCH_BINARY to run native managed CLI tests", timeout: 30_000 };
const partSize = 8 * 1024 * 1024;
const apiKey = "emd_native_test_secret";
const hash = (algorithm, bytes, format = "hex") => createHash(algorithm).update(bytes).digest(format);

function project(t) {
  const directory = mkdtempSync(join(tmpdir(), "hutch-managed-native-"));
  mkdirSync(join(directory, "empty-path"));
  writeFileSync(join(directory, "electrobun.config.ts"), "throw new Error('Managed commands must not evaluate TypeScript config');\n");
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  return directory;
}

function artifacts(directory, { folder = "artifacts", channel = "canary", archiveSize = 31, integrity = true } = {}) {
  const output = join(directory, folder);
  mkdirSync(output, { recursive: true });
  const prefix = `${channel}-macos-arm64`;
  const archiveName = `${prefix}-Example.app.tar.zst`;
  const archive = Buffer.alloc(archiveSize, 0x67);
  const manifest = {
    schemaVersion: 1, identifier: "dev.electrobun.native", channel, version: "1.2.3",
    hash: "123abc", platform: "macos", arch: "arm64", artifact: { file: archiveName, ...(integrity ? { tarSha256: "a".repeat(64), tarSize: 123 } : {}) },
  };
  const files = new Map([
    [archiveName, archive],
    [`${prefix}-update.json`, Buffer.from(JSON.stringify(manifest))],
  ]);
  for (const [filename, bytes] of files) writeFileSync(join(output, filename), bytes);
  return { output, prefix, files, manifest, archiveName };
}

function run(directory, command, args = [], overrides = {}) {
  return new Promise((done, reject) => {
    const env = {
      ...process.env,
      PATH: join(directory, "empty-path"),
      HUTCH_RUNTIME: "invalid-runtime-managed-commands-must-ignore",
      COTTONTAIL_BINARY: join(directory, "missing-cottontail"),
      HUTCH_BUN_BINARY: join(directory, "missing-bun"),
      BUN_BINARY: join(directory, "missing-bun"),
      ELECTROBUN_APP_ID: undefined,
      ELECTROBUN_API_KEY: apiKey,
      DASH_RELEASE_OFFLINE: "0",
      ...overrides,
    };
    // Windows treats environment names case-insensitively. A retained `Path`
    // must not accidentally expose a runtime when PATH is deliberately empty.
    for (const name of Object.keys(env)) if (env[name] === undefined || (name !== "PATH" && name.toUpperCase() === "PATH")) delete env[name];
    const child = spawn(binary, ["electrobun", command, ...args], {
      cwd: directory,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    const timeout = setTimeout(() => child.kill(), 20_000);
    child.stdout.on("data", (data) => { stdout += data; });
    child.stderr.on("data", (data) => { stderr += data; });
    child.once("error", (error) => { clearTimeout(timeout); reject(error); });
    child.once("close", (status, signal) => {
      clearTimeout(timeout);
      done({ status, signal, stdout, stderr });
    });
  });
}

function succeeded(result) {
  assert.equal(result.status, 0, `${result.signal || ""}\n${result.stdout}\n${result.stderr}`);
  assert.ok(!`${result.stdout}${result.stderr}`.includes(apiKey), "CLI output must not expose its API key");
}

function failed(result) {
  assert.equal(result.signal, null, `CLI must return an error rather than time out: ${result.stderr}`);
  assert.notEqual(result.status, 0);
  assert.ok(!`${result.stdout}${result.stderr}`.includes(apiKey), "CLI output must not expose its API key");
}

async function body(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return Buffer.concat(chunks);
}

function reply(response, value, status = 200) {
  response.writeHead(status, { "Content-Type": "application/json" });
  response.end(JSON.stringify(value));
}

async function serve(t, handler) {
  const errors = [];
  const server = createServer((request, response) => {
    Promise.resolve().then(() => handler(request, response)).catch((error) => {
      errors.push(error);
      if (!response.headersSent) reply(response, { error: "Mock assertion failed" }, 500);
      else response.end();
    });
  });
  await new Promise((done) => server.listen(0, "127.0.0.1", done));
  t.after(() => new Promise((done) => {
    server.closeAllConnections();
    server.close(done);
  }));
  return { origin: `http://127.0.0.1:${server.address().port}`, errors };
}

async function service(t, { redirectStorageTo, resumeArchivePartByte } = {}) {
  const uploads = new Map();
  const releases = new Map();
  const requests = [];
  const storageRequests = [];
  const signed = new Map();
  let publishCount = 0;
  const storage = await serve(t, async (request, response) => {
    const bytes = await body(request);
    storageRequests.push({ method: request.method, url: request.url, headers: request.headers, bytes });
    assert.equal(request.method, "PUT");
    assert.equal(request.headers.authorization, undefined, "Dash credentials must never reach artifact storage");
    const part = signed.get(request.url);
    assert.ok(part, "Storage URL must have been signed by the API");
    assert.equal(bytes.length, part.size);
    assert.equal(request.headers["content-md5"], part.md5);
    assert.equal(hash("md5", bytes, "base64"), part.md5);
    if (redirectStorageTo) {
      response.writeHead(307, { location: redirectStorageTo });
      response.end();
      return;
    }
    const etag = hash("md5", bytes);
    uploads.get(part.id).parts.set(part.number, { bytes, etag });
    response.writeHead(200, { ETag: `"${etag}"` });
    response.end();
  });
  const api = await serve(t, async (request, response) => {
    const path = new URL(request.url, "http://localhost").pathname;
    const bytes = await body(request);
    const payload = bytes.length ? JSON.parse(bytes.toString()) : undefined;
    requests.push({ method: request.method, path, payload });
    assert.equal(request.headers.authorization, `Bearer ${apiKey}`);
    const base = "/v1/electrobun/apps/native-app/releases";
    if (path === base && request.method === "POST") {
      assert.ok(["canary", "stable"].includes(payload.channel));
      assert.equal(payload.releaseId, `${payload.channel}-${payload.version}`, "Every runner must use the canonical channel/version release");
      assert.deepEqual(payload.expectedTargets, ["macos-arm64"]);
      releases.set(payload.releaseId, { id: payload.releaseId, channel: payload.channel, version: payload.version, expectedTargets: payload.expectedTargets, status: "staging" });
      return reply(response, { release: releases.get(payload.releaseId) });
    }
    const match = path.match(/^\/v1\/electrobun\/apps\/native-app\/releases\/([^/]+)(.*)$/);
    assert.ok(match, `Unexpected API path ${path}`);
    const releaseId = decodeURIComponent(match[1]);
    const release = releases.get(releaseId);
    assert.ok(release, `Unknown release ${releaseId}`);
    const suffix = match[2];
    if (suffix === "/uploads" && request.method === "POST") {
      const id = `upload-${uploads.size + 1}`;
      const parts = new Map();
      if (resumeArchivePartByte !== undefined && payload.filename.endsWith(".tar.zst")) {
        const bytes = Buffer.alloc(Math.min(partSize, payload.size), resumeArchivePartByte);
        parts.set(1, { bytes, etag: hash("md5", bytes) });
      }
      uploads.set(id, { metadata: payload, releaseId, parts, complete: false });
      const resume = [...parts].map(([partNumber, part]) => ({ partNumber, etag: part.etag }));
      return reply(response, { upload: { id, partSize, parts: resume, status: "uploading" }, partSize });
    }
    const part = suffix.match(/^\/uploads\/([^/]+)\/parts\/(\d+)$/);
    if (part) {
      assert.equal(request.method, "POST", "API signs parts; artifact bytes must go directly to storage");
      assert.deepEqual(Object.keys(payload).sort(), ["md5", "size"]);
      assert.match(payload.md5, /^[A-Za-z0-9+/]{22}==$/);
      assert.ok(Number.isSafeInteger(payload.size) && payload.size > 0 && payload.size <= partSize);
      const url = `/parts/${part[1]}/${part[2]}?signature=native-test`;
      signed.set(url, { ...payload, id: part[1], number: Number(part[2]) });
      return reply(response, { url: storage.origin + url, headers: { "Content-MD5": payload.md5, "Content-Length": String(payload.size), "Content-Type": "application/octet-stream" } });
    }
    const complete = suffix.match(/^\/uploads\/([^/]+)\/complete$/);
    if (complete && request.method === "POST") {
      const upload = uploads.get(complete[1]);
      const parts = [...upload.parts].sort(([a], [b]) => a - b);
      assert.deepEqual(payload.parts, parts.map(([partNumber, part]) => ({ partNumber, etag: part.etag })));
      const content = Buffer.concat(parts.map(([, part]) => part.bytes));
      assert.equal(content.length, upload.metadata.size);
      assert.equal(hash("sha256", content), upload.metadata.sha256);
      upload.complete = true;
      return reply(response, { upload: { id: complete[1], status: "completed" } });
    }
    if (suffix === "/publish" && request.method === "POST") {
      assert.deepEqual(Object.keys(payload), ["audience"]);
      assert.ok(["prerelease", "public"].includes(payload.audience));
      publishCount++;
      release.status = payload.audience === "prerelease" ? "prerelease" : "published";
      return reply(response, { release });
    }
    if (!suffix && request.method === "GET") {
      const artifacts = [...uploads.values()].filter((upload) => upload.releaseId === releaseId && upload.complete).map((upload) => upload.metadata);
      const ready = artifacts.some(artifact => artifact.filename.endsWith("-update.json")) && artifacts.some(artifact => artifact.filename.endsWith(".tar.zst"));
      return reply(response, { release: { ...release, artifacts }, checks: { ready, errors: [] } });
    }
    assert.fail(`Unexpected request: ${request.method} ${path}`);
  });
  return { api, storage, uploads, releases, requests, storageRequests, get publishCount() { return publishCount; } };
}

test("native upload and deploy preview existing artifacts without any script runtime", native, async (t) => {
  const directory = project(t);
  const files = artifacts(directory);
  for (const command of ["upload", "deploy"]) {
    const result = await run(directory, command, ["--app=native-app", `--artifacts=${files.output}`, "--dry-run"], { ELECTROBUN_API_KEY: command === "deploy" ? "" : undefined, DASH_RELEASE_OFFLINE: "1" });
    succeeded(result);
    assert.match(result.stdout, /canary-1\.2\.3/);
    assert.ok(result.stdout.includes(files.archiveName));
  }
});

test("native upload reads public build metadata without evaluating config", native, async (t) => {
  const directory = project(t);
  const files = artifacts(directory, { folder: "build-output" });
  mkdirSync(join(directory, ".hutch"));
  writeFileSync(join(directory, ".hutch/managed-deploy.json"), JSON.stringify({ appId: "sidecar-app", apiUrl: "https://api.electrobun.dev", artifactFolder: "build-output" }));
  const result = await run(directory, "upload", ["--dry-run"], { ELECTROBUN_API_KEY: undefined, DASH_RELEASE_OFFLINE: "1" });
  succeeded(result);
  assert.match(result.stdout, /sidecar-app/);
  assert.ok(result.stdout.includes(files.archiveName));
  const overridden = await run(directory, "upload", ["--app=explicit-app", "--dry-run"], { ELECTROBUN_API_KEY: undefined, DASH_RELEASE_OFFLINE: "1" });
  succeeded(overridden);
  assert.match(overridden.stdout, /explicit-app/);

  const copiedJob = project(t);
  const copiedFiles = artifacts(copiedJob, { folder: "copied-output" });
  writeFileSync(join(copiedFiles.output, "managed-deploy.json"), JSON.stringify({ appId: "copied-app", apiUrl: "https://api.electrobun.dev", artifactFolder: "old-build-machine-path" }));
  const copied = await run(copiedJob, "upload", [`--artifacts=${copiedFiles.output}`, "--dry-run"], { ELECTROBUN_API_KEY: undefined, DASH_RELEASE_OFFLINE: "1" });
  succeeded(copied);
  assert.match(copied.stdout, /copied-app/);
  assert.ok(copied.stdout.includes(copiedFiles.archiveName));
});

for (const integrity of [true, false]) test(`native upload sends signed parts directly to storage and publishes canonical update.json ${integrity ? "with" : "without"} tar integrity and no script runtime`, native, async (t) => {
  const directory = project(t);
  const files = artifacts(directory, { archiveSize: partSize + 31, integrity });
  const remote = await service(t);
  const result = await run(directory, "upload", ["--app=native-app", `--artifacts=${files.output}`, `--api-url=${remote.api.origin}`]);
  assert.deepEqual(remote.api.errors, []);
  assert.deepEqual(remote.storage.errors, []);
  succeeded(result);
  assert.equal(remote.publishCount, 0, "Upload must only stage files");
  assert.equal(remote.uploads.size, files.files.size);
  assert.equal(remote.storageRequests.length, files.files.size + 1, "Large archives use bounded multipart uploads");
  assert.deepEqual(remote.storageRequests.map((request) => request.bytes.length).sort((a, b) => b - a).slice(0, 1), [partSize]);
  for (const upload of remote.uploads.values()) {
    assert.ok(upload.complete);
    assert.equal(upload.metadata.sha256, hash("sha256", files.files.get(upload.metadata.filename)));
  }
  const publishDirectory = project(t);
  const publishArgs = ["--app=native-app", "--release=canary-1.2.3", `--api-url=${remote.api.origin}`];
  const preview = await run(publishDirectory, "publish", [...publishArgs, "--dry-run"]);
  succeeded(preview);
  assert.match(preview.stdout, /public/i);
  assert.equal(remote.publishCount, 0);
  const published = await run(publishDirectory, "publish", publishArgs);
  succeeded(published);
  assert.match(published.stdout, /public/i);
  assert.equal(remote.publishCount, 1);
  assert.deepEqual(remote.requests.find((request) => request.path.endsWith("/publish")).payload, { audience: "public" });
  assert.equal(remote.releases.get("canary-1.2.3").status, "published");
  assert.deepEqual(remote.api.errors, []);
});

test("native publish exposes a release to prerelease installs before publishing to public", native, async (t) => {
  const directory = project(t);
  const files = artifacts(directory);
  const remote = await service(t);
  succeeded(await run(directory, "upload", ["--app=native-app", `--artifacts=${files.output}`, `--api-url=${remote.api.origin}`]));
  const publishDirectory = project(t);
  const args = ["--app=native-app", "--release=canary-1.2.3", `--api-url=${remote.api.origin}`];

  const preview = await run(publishDirectory, "publish", [...args, "--audience=prerelease", "--dry-run"]);
  succeeded(preview);
  assert.match(preview.stdout, /prerelease/i);
  assert.equal(remote.publishCount, 0, "Preview must not expose a release to any install");

  const testing = await run(publishDirectory, "publish", [...args, "--audience=prerelease"]);
  succeeded(testing);
  assert.match(testing.stdout, /prerelease/i);
  assert.equal(remote.releases.get("canary-1.2.3").status, "prerelease");
  assert.equal(remote.publishCount, 1);

  const published = await run(publishDirectory, "publish", [...args, "--audience", "public"]);
  succeeded(published);
  assert.match(published.stdout, /public/i);
  assert.equal(remote.releases.get("canary-1.2.3").status, "published");
  assert.equal(remote.publishCount, 2);
  assert.deepEqual(remote.requests.filter((request) => request.path.endsWith("/publish")).map((request) => request.payload), [
    { audience: "prerelease" }, { audience: "public" },
  ]);
  assert.deepEqual(remote.api.errors, []);
  assert.deepEqual(remote.storage.errors, []);
});

test("native publish validates audience before network requests and upload cannot select an audience", native, async (t) => {
  const directory = project(t);
  const files = artifacts(directory);
  let requests = 0;
  const api = await serve(t, async (_request, response) => { requests++; reply(response, {}); });
  const common = ["--app=native-app", `--api-url=${api.origin}`];
  for (const audience of ["", "test", "everyone", "testing", "all", "canary", "PRERELEASE", "prerelease/public"]) {
    failed(await run(directory, "publish", [...common, "--release=canary-1.2.3", `--audience=${audience}`]));
    assert.equal(requests, 0, `Invalid audience must fail before network requests: ${audience}`);
  }
  failed(await run(directory, "publish", [...common, "--release=canary-1.2.3", "--audience=prerelease", "--audience=public"]));
  for (const command of ["upload", "deploy"]) {
    failed(await run(directory, command, [...common, `--artifacts=${files.output}`, "--audience=prerelease"]));
  }
  assert.equal(requests, 0);
  assert.deepEqual(api.errors, []);
});

test("native publish requires ready artifacts for both prerelease and public", native, async (t) => {
  const directory = project(t);
  const remote = await service(t);
  remote.releases.set("canary-1.2.3", {
    id: "canary-1.2.3", channel: "canary", version: "1.2.3", expectedTargets: ["macos-arm64"], status: "staging",
  });
  for (const audience of ["prerelease", "public"]) {
    const result = await run(directory, "publish", ["--app=native-app", "--release=canary-1.2.3", `--api-url=${remote.api.origin}`, `--audience=${audience}`]);
    failed(result);
    assert.match(result.stderr, /release checks failed/i);
  }
  assert.equal(remote.publishCount, 0, "Neither audience can expose an incomplete release");
  assert.ok(remote.requests.every((request) => request.method === "GET"));
  assert.deepEqual(remote.api.errors, []);
});

test("native upload rejects custom release aliases and accepts the inferred channel/version identity", native, async (t) => {
  const directory = project(t);
  const files = artifacts(directory);
  let requests = 0;
  const api = await serve(t, async (_request, response) => { requests++; reply(response, {}); });
  const args = ["--app=native-app", `--api-url=${api.origin}`, `--artifacts=${files.output}`];
  for (const release of ["arbitrary-attempt", "1.2.3", "stable-1.2.3", "canary-1.2.4", "canary-1.2.3-retry"]) {
    failed(await run(directory, "upload", [...args, `--release=${release}`]));
    assert.equal(requests, 0, `Release alias must fail before networking: ${release}`);
  }
  const canonical = await run(directory, "upload", [...args, "--release=canary-1.2.3", "--dry-run"]);
  succeeded(canonical);
  assert.match(canonical.stdout, /canary-1\.2\.3/);
  assert.equal(requests, 0);
  assert.deepEqual(api.errors, []);
});

test("native upload validates every channel before creating a remote release", native, async (t) => {
  const directory = project(t);
  const canary = artifacts(directory);
  const stable = artifacts(directory, { channel: "stable" });
  let requests = 0;
  const api = await serve(t, async (_request, response) => { requests++; reply(response, {}); });
  const args = ["--app=native-app", `--artifacts=${canary.output}`, `--api-url=${api.origin}`];
  const ambiguous = await run(directory, "upload", [...args, "--release=shared-release"]);
  failed(ambiguous);
  assert.equal(requests, 0);
  writeFileSync(join(stable.output, `${stable.prefix}-update.json`), JSON.stringify({ ...stable.manifest, channel: "canary" }));
  const mixedUp = await run(directory, "upload", args);
  failed(mixedUp);
  assert.equal(requests, 0, "A bad stable manifest must reject the entire plan before a canary upload starts");
  const selected = await run(directory, "upload", [...args, "--env=canary", "--dry-run"]);
  succeeded(selected);
  assert.equal(requests, 0);
});

test("native upload rejects outside-folder artifact references before any network request", native, async (t) => {
  const directory = project(t);
  const files = artifacts(directory);
  const outside = join(directory, "outside.tar.zst");
  writeFileSync(outside, "outside-artifact-must-never-be-uploaded");
  let requests = 0;
  const api = await serve(t, async (_request, response) => { requests++; reply(response, {}); });
  const args = ["--app=native-app", `--artifacts=${files.output}`, `--api-url=${api.origin}`];
  const manifestPath = join(files.output, `${files.prefix}-update.json`);
  for (const reference of [
    "../outside.tar.zst",
    `${files.prefix}-../../outside.tar.zst`,
    outside,
    "C:\\outside.tar.zst",
    "\\\\server\\outside.tar.zst",
    `${files.prefix}-%2e%2e%2foutside.tar.zst`,
    `${files.prefix}-%2E%2E%5Coutside.tar.zst`,
    `${files.prefix}-%252e%252e%252foutside.tar.zst`,
    "stable-macos-arm64-outside.tar.zst",
    "canary-linux-x64-outside.tar.zst",
  ]) {
    writeFileSync(manifestPath, JSON.stringify({ ...files.manifest, artifact: { ...files.manifest.artifact, file: reference } }));
    failed(await run(directory, "upload", args));
    assert.equal(requests, 0, `Reference must fail local preflight: ${reference}`);
  }
  assert.deepEqual(api.errors, []);
});

test("native upload rejects malformed or incomplete canonical tar integrity before network requests", native, async (t) => {
  const directory = project(t);
  const files = artifacts(directory);
  let requests = 0;
  const api = await serve(t, async (_request, response) => { requests++; reply(response, {}); });
  const args = ["--app=native-app", `--artifacts=${files.output}`, `--api-url=${api.origin}`];
  for (const fields of [
    { tarSha256: undefined },
    { tarSize: undefined },
    { tarSha256: null },
    { tarSha256: "invalid" },
    { tarSize: 0 },
    { tarSize: Number.MAX_SAFE_INTEGER + 1 },
  ]) {
    writeFileSync(join(files.output, `${files.prefix}-update.json`), JSON.stringify({ ...files.manifest, artifact: { ...files.manifest.artifact, ...fields } }));
    failed(await run(directory, "upload", args));
    assert.equal(requests, 0, "Invalid canonical integrity must fail local preflight");
  }
  assert.deepEqual(api.errors, []);
});

test("native upload rejects manifest and archive symlinks to files outside its artifact folder", { ...native, skip: native.skip || (process.platform === "win32" && "Windows symlink creation requires privileges") }, async (t) => {
  const directory = project(t);
  const files = artifacts(directory);
  let requests = 0;
  const api = await serve(t, async (_request, response) => { requests++; reply(response, {}); });
  const args = ["--app=native-app", `--artifacts=${files.output}`, `--api-url=${api.origin}`];
  for (const filename of [`${files.prefix}-update.json`, files.archiveName]) {
    const target = join(directory, filename);
    writeFileSync(target, files.files.get(filename));
    const path = join(files.output, filename);
    rmSync(path);
    symlinkSync(target, path);
    failed(await run(directory, "upload", args));
    assert.equal(requests, 0, "A symlink must not result in an upload request");
    rmSync(path);
    writeFileSync(path, files.files.get(filename));
  }
  assert.deepEqual(api.errors, []);
});

test("native app release and returned upload IDs cannot inject another API route", native, async (t) => {
  const directory = project(t);
  const files = artifacts(directory);
  const paths = [];
  let unsafeUploadId = "../other-app";
  const api = await serve(t, async (request, response) => {
    paths.push(request.url);
    await body(request);
    if (request.url.endsWith("/uploads")) return reply(response, { upload: { id: unsafeUploadId, status: "uploading", partSize, parts: [] }, partSize });
    reply(response, {});
  });
  for (const input of ["../other", "%2e%2e%2fother", "name%2fother", "name\\other", "/other", "name?channel=stable", "name#other"]) {
    for (const option of ["app", "release"]) {
      const args = [`--artifacts=${files.output}`, `--api-url=${api.origin}`, ...(option === "app" ? [] : ["--app=native-app"]), `--${option}=${input}`];
      failed(await run(directory, "upload", args));
      assert.deepEqual(paths, [], `${option} must be validated before networking`);
    }
  }
  for (const input of ["../other-app", "safe%2fother", "safe\\other", "safe?part=1", "safe#other"]) {
    paths.length = 0;
    unsafeUploadId = input;
    failed(await run(directory, "upload", ["--app=native-app", `--artifacts=${files.output}`, `--api-url=${api.origin}`]));
    assert.deepEqual(paths, [
      "/v1/electrobun/apps/native-app/releases",
      "/v1/electrobun/apps/native-app/releases/canary-1.2.3/uploads",
    ], "An untrusted upload ID must never be interpolated into a request path");
  }
  assert.deepEqual(api.errors, []);
});

test("native resume reuses matching parts and replaces parts with different content", native, async (t) => {
  for (const resumeArchivePartByte of [0x67, 0x42]) {
    const directory = project(t);
    const files = artifacts(directory);
    const remote = await service(t, { resumeArchivePartByte });
    const result = await run(directory, "upload", ["--app=native-app", `--artifacts=${files.output}`, `--api-url=${remote.api.origin}`]);
    assert.deepEqual(remote.api.errors, []);
    assert.deepEqual(remote.storage.errors, []);
    succeeded(result);
    assert.equal(remote.storageRequests.length, resumeArchivePartByte === 0x67 ? 1 : 2);
    assert.ok([...remote.uploads.values()].every((upload) => upload.complete));
  }
});

test("native API requests refuse redirects without forwarding or printing credentials", native, async (t) => {
  const directory = project(t);
  const files = artifacts(directory);
  let targetRequests = 0;
  const target = await serve(t, async (_request, response) => { targetRequests++; reply(response, {}); });
  const source = await serve(t, async (_request, response) => {
    response.writeHead(307, { location: `${target.origin}/stolen` });
    response.end(apiKey);
  });
  const result = await run(directory, "upload", ["--app=native-app", `--artifacts=${files.output}`, `--api-url=${source.origin}`]);
  failed(result);
  assert.equal(targetRequests, 0);
});

test("native direct storage uploads refuse redirects and never complete failed objects", native, async (t) => {
  const directory = project(t);
  const files = artifacts(directory);
  let targetRequests = 0;
  const target = await serve(t, async (_request, response) => { targetRequests++; reply(response, {}); });
  const remote = await service(t, { redirectStorageTo: `${target.origin}/redirected-part` });
  const result = await run(directory, "upload", ["--app=native-app", `--artifacts=${files.output}`, `--api-url=${remote.api.origin}`]);
  failed(result);
  assert.deepEqual(remote.api.errors, []);
  assert.deepEqual(remote.storage.errors, []);
  assert.equal(remote.storageRequests.length, 1);
  assert.equal(targetRequests, 0);
  assert.ok([...remote.uploads.values()].every((upload) => !upload.complete));
});
