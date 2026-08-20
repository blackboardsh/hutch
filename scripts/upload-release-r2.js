#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { createHash, createHmac } from "node:crypto";
import { existsSync, readFileSync, statSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  RELEASE_PLATFORMS,
  buildArchiveKey,
  buildManifestKey,
  channelManifestKey,
  createBuildManifest,
  createChannelManifest,
  createReleaseManifest,
  installerKey,
  releaseManifestKey,
  validateReleaseTag,
  validateRevision,
} from "./release-contract.js";
import { r2Setting } from "./r2-settings.js";

const hutchRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const repositoryRoot = hutchRoot;
const packageJson = JSON.parse(readFileSync(join(hutchRoot, "package.json"), "utf8"));
const dryRun = process.argv.includes("--dry-run") || process.env.HUTCH_R2_DRY_RUN === "1";
const publishAll = process.argv.includes("--all");
const bucket = "electrobun-artifacts";
const product = "hutch";

function fail(message) {
  console.error(`hutch publish: ${message}`);
  process.exit(1);
}

function setting(name) {
  return r2Setting(name, process.env);
}

function gitRevision() {
  if (process.env.GITHUB_SHA) return process.env.GITHUB_SHA;
  if (process.env.CIRCLE_SHA1) return process.env.CIRCLE_SHA1;
  return execFileSync("git", ["rev-parse", "HEAD"], {
    cwd: repositoryRoot,
    encoding: "utf8",
  }).trim();
}

function releaseTag() {
  if (process.env.GITHUB_REF_TYPE === "tag") return process.env.GITHUB_REF_NAME;
  if (process.env.CIRCLE_TAG) return process.env.CIRCLE_TAG;
  const argument = process.argv.find((value) => value.startsWith("--tag="));
  if (argument) return argument.slice("--tag=".length);
  if (dryRun) return `v${packageJson.version}`;
  return fail("publishing is only allowed from a Hutch release tag");
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function hmac(key, value) {
  return createHmac("sha256", key).update(value).digest();
}

function awsEncode(value) {
  return encodeURIComponent(value).replace(/[!'()*]/g, (character) =>
    `%${character.charCodeAt(0).toString(16).toUpperCase()}`
  );
}

export function signingHeaders({
  accountId,
  accessKeyId,
  secretAccessKey,
  bucket: bucketName,
  key,
  body = Buffer.alloc(0),
  contentType,
  cacheControl,
  ifNoneMatch,
  method = "PUT",
  now = new Date(),
}) {
  const endpoint = new URL(`https://${accountId}.r2.cloudflarestorage.com`);
  const canonicalUri = `/${[bucketName, ...key.split("/")].map(awsEncode).join("/")}`;
  const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, "");
  const date = amzDate.slice(0, 8);
  const payloadHash = sha256(body);
  const canonicalHeaderEntries = [
    ["cache-control", cacheControl],
    ["content-type", contentType],
    ["host", endpoint.host],
    ["if-none-match", ifNoneMatch],
    ["x-amz-content-sha256", payloadHash],
    ["x-amz-date", amzDate],
  ]
    .filter(([, value]) => value !== undefined)
    .sort(([left], [right]) => left.localeCompare(right));
  const canonicalHeaders = `${canonicalHeaderEntries
    .map(([name, value]) => `${name}:${String(value).trim().replace(/\s+/g, " ")}`)
    .join("\n")}\n`;
  const signedHeaders = canonicalHeaderEntries.map(([name]) => name).join(";");
  const canonicalRequest = [
    method,
    canonicalUri,
    "",
    canonicalHeaders,
    signedHeaders,
    payloadHash,
  ].join("\n");
  const scope = `${date}/auto/s3/aws4_request`;
  const stringToSign = [
    "AWS4-HMAC-SHA256",
    amzDate,
    scope,
    sha256(canonicalRequest),
  ].join("\n");
  const dateKey = hmac(Buffer.from(`AWS4${secretAccessKey}`), date);
  const regionKey = hmac(dateKey, "auto");
  const serviceKey = hmac(regionKey, "s3");
  const signingKey = hmac(serviceKey, "aws4_request");
  const signature = createHmac("sha256", signingKey).update(stringToSign).digest("hex");
  const headers = {
    Authorization: `AWS4-HMAC-SHA256 Credential=${accessKeyId}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`,
    "x-amz-content-sha256": payloadHash,
    "x-amz-date": amzDate,
  };
  if (cacheControl !== undefined) headers["Cache-Control"] = cacheControl;
  if (contentType !== undefined) headers["Content-Type"] = contentType;
  if (ifNoneMatch !== undefined) headers["If-None-Match"] = ifNoneMatch;
  return {
    url: new URL(canonicalUri, endpoint).href,
    headers,
  };
}

export async function objectExists(
  config,
  key,
  {
    dryRunMode = dryRun,
    fetchImpl = globalThis.fetch,
    log = console.log,
  } = {},
) {
  if (dryRunMode) {
    log(`dry-run HEAD ${key}`);
    return false;
  }
  const request = signingHeaders({ ...config, key, method: "HEAD" });
  const response = await fetchImpl(request.url, {
    method: "HEAD",
    headers: request.headers,
  });
  if (response.status === 404) return false;
  if (response.ok) return true;
  throw new Error(
    `R2 preflight failed for ${key}: ${response.status} ${await response.text()}`,
  );
}

export async function putObject(
  config,
  object,
  {
    dryRunMode = dryRun,
    fetchImpl = globalThis.fetch,
    ifAbsent = false,
    log = console.log,
  } = {},
) {
  if (dryRunMode) {
    log(`dry-run PUT ${object.key} (${object.body.length} bytes)`);
    return;
  }
  const request = signingHeaders({
    ...config,
    ...object,
    ifNoneMatch: ifAbsent ? "*" : undefined,
  });
  const response = await fetchImpl(request.url, {
    method: "PUT",
    headers: request.headers,
    body: object.body,
  });
  if (!response.ok) {
    if (ifAbsent && (response.status === 409 || response.status === 412)) {
      throw new Error(
        `R2 immutable object already exists; refusing to overwrite ${object.key}`,
      );
    }
    throw new Error(
      `R2 upload failed for ${object.key}: ${response.status} ${await response.text()}`,
    );
  }
  log(`uploaded ${object.key}`);
}

export async function publishObjectPlan({
  immutableObjects,
  mutableObjects,
  objectExistsFn,
  putObjectFn,
}) {
  const existing = [];
  for (const object of immutableObjects) {
    if (await objectExistsFn(object)) existing.push(object.key);
  }
  if (existing.length > 0) {
    throw new Error(
      `R2 immutable release objects already exist; refusing to overwrite: ${existing.join(", ")}`,
    );
  }

  for (const object of immutableObjects) {
    await putObjectFn(object, { ifAbsent: true });
  }
  for (const object of mutableObjects) {
    await putObjectFn(object, { ifAbsent: false });
  }
}

function readArtifact(platform) {
  const archiveName = `hutch-v${packageJson.version}-${platform}.tar.gz`;
  const archivePath = join(hutchRoot, "release", archiveName);
  const checksumPath = `${archivePath}.sha256`;
  if (!existsSync(archivePath) || !existsSync(checksumPath)) {
    fail(`release matrix is incomplete; missing ${archivePath} or its checksum`);
  }

  const archive = readFileSync(archivePath);
  const checksumFile = readFileSync(checksumPath);
  const checksum = sha256(archive);
  if (checksum !== checksumFile.toString("utf8").trim().split(/\s+/, 1)[0]) {
    fail(`release checksum mismatch for ${basename(archivePath)}`);
  }
  return {
    platform,
    archivePath,
    checksumFile,
    sha256: checksum,
    size: statSync(archivePath).size,
  };
}

function jsonBody(value) {
  return Buffer.from(`${JSON.stringify(value, null, 2)}\n`);
}

export async function main() {
  if (!publishAll) fail("publishing requires --all and a complete platform matrix");
  if (!dryRun) {
    const missing = [
      "R2_ACCOUNT_ID",
      "R2_ACCESS_KEY_ID",
      "R2_SECRET_ACCESS_KEY",
      "R2_PUBLIC_BASE_URL",
    ].filter((name) => !setting(name));
    if (missing.length > 0) {
      fail(`missing R2 settings: ${missing.join(", ")}`);
    }
  }

  const version = packageJson.version;
  const revision = gitRevision();
  let release;
  try {
    validateRevision(revision);
    release = validateReleaseTag(releaseTag(), version);
  } catch (error) {
    fail(error.message);
  }

  const publicBaseUrl = (
    setting("R2_PUBLIC_BASE_URL") ?? "https://artifacts.invalid"
  ).replace(/\/+$/, "");
  const artifacts = RELEASE_PLATFORMS.map(readArtifact);
  const publishedAt = new Date().toISOString();
  const manifestOptions = {
    product,
    version,
    revision,
    publishedAt,
    publicBaseUrl,
    artifacts,
  };
  const config = {
    accountId: setting("R2_ACCOUNT_ID") ?? "dry-run-account",
    accessKeyId: setting("R2_ACCESS_KEY_ID") ?? "dry-run-access-key",
    secretAccessKey: setting("R2_SECRET_ACCESS_KEY") ?? "dry-run-secret",
    bucket,
  };
  const immutableCacheControl = "public, max-age=31536000, immutable";
  const mutableCacheControl = "no-cache, no-store, must-revalidate";
  const immutableObjects = [];

  for (const artifact of artifacts) {
    const archiveKey = buildArchiveKey(product, revision, artifact.platform);
    immutableObjects.push({
      key: archiveKey,
      body: readFileSync(artifact.archivePath),
      contentType: "application/gzip",
      cacheControl: immutableCacheControl,
    }, {
      key: `${archiveKey}.sha256`,
      body: artifact.checksumFile,
      contentType: "text/plain; charset=utf-8",
      cacheControl: immutableCacheControl,
    });
  }

  immutableObjects.push({
    key: buildManifestKey(product, revision),
    body: jsonBody(createBuildManifest(manifestOptions)),
    contentType: "application/json; charset=utf-8",
    cacheControl: immutableCacheControl,
  }, {
    key: releaseManifestKey(product, version),
    body: jsonBody(createReleaseManifest(manifestOptions)),
    contentType: "application/json; charset=utf-8",
    cacheControl: immutableCacheControl,
  });

  const mutableObjects = [
    ["install.sh", "text/x-shellscript; charset=utf-8"],
    ["install.ps1", "text/plain; charset=utf-8"],
  ].map(([name, contentType]) => ({
    key: installerKey(product, name),
    body: readFileSync(join(hutchRoot, "scripts", name)),
    contentType,
    cacheControl: mutableCacheControl,
  }));

  // Keep the channel pointer last: consumers only see the release after every
  // immutable object and mutable installer has uploaded successfully.
  mutableObjects.push({
    key: channelManifestKey(product, release.channel),
    body: jsonBody(createChannelManifest(manifestOptions)),
    contentType: "application/json; charset=utf-8",
    cacheControl: mutableCacheControl,
  });

  await publishObjectPlan({
    immutableObjects,
    mutableObjects,
    objectExistsFn: (object) => objectExists(config, object.key),
    putObjectFn: (object, options) => putObject(config, object, options),
  });

  console.log(JSON.stringify({
    product,
    channel: release.channel,
    version,
    revision,
    platforms: RELEASE_PLATFORMS,
  }, null, 2));
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main();
}
