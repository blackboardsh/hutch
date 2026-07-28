#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { createHash, createHmac } from "node:crypto";
import { existsSync, readFileSync, statSync } from "node:fs";
import { basename, dirname, join } from "node:path";
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
const repositoryRoot = dirname(hutchRoot);
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
  if (dryRun) return `hutch-v${packageJson.version}`;
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

function signingHeaders({
  accountId,
  accessKeyId,
  secretAccessKey,
  bucket: bucketName,
  key,
  body,
  contentType,
  cacheControl,
  method = "PUT",
  now = new Date(),
}) {
  const endpoint = new URL(`https://${accountId}.r2.cloudflarestorage.com`);
  const canonicalUri = `/${[bucketName, ...key.split("/")].map(awsEncode).join("/")}`;
  const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, "");
  const date = amzDate.slice(0, 8);
  const payloadHash = sha256(body);
  const canonicalHeaders = [
    `cache-control:${cacheControl}`,
    `content-type:${contentType}`,
    `host:${endpoint.host}`,
    `x-amz-content-sha256:${payloadHash}`,
    `x-amz-date:${amzDate}`,
    "",
  ].join("\n");
  const signedHeaders = "cache-control;content-type;host;x-amz-content-sha256;x-amz-date";
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
  return {
    url: new URL(canonicalUri, endpoint).href,
    headers: {
      Authorization: `AWS4-HMAC-SHA256 Credential=${accessKeyId}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`,
      "Cache-Control": cacheControl,
      "Content-Type": contentType,
      "x-amz-content-sha256": payloadHash,
      "x-amz-date": amzDate,
    },
  };
}

async function putObject(config, object) {
  if (dryRun) {
    console.log(`dry-run PUT ${object.key} (${object.body.length} bytes)`);
    return;
  }
  const request = signingHeaders({ ...config, ...object });
  const response = await fetch(request.url, {
    method: "PUT",
    headers: request.headers,
    body: object.body,
  });
  if (!response.ok) {
    throw new Error(
      `R2 upload failed for ${object.key}: ${response.status} ${await response.text()}`,
    );
  }
  console.log(`uploaded ${object.key}`);
}

async function deleteObject(config, key) {
  const request = signingHeaders({
    ...config,
    key,
    body: Buffer.alloc(0),
    contentType: "application/octet-stream",
    cacheControl: "no-cache",
    method: "DELETE",
  });
  if (dryRun) {
    console.log(`dry-run DELETE ${key}`);
    return;
  }
  const response = await fetch(request.url, {
    method: "DELETE",
    headers: request.headers,
  });
  if (!response.ok) {
    throw new Error(
      `R2 delete failed for ${key}: ${response.status} ${await response.text()}`,
    );
  }
  console.log(`deleted legacy root object ${key}`);
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
const immutable = "public, max-age=31536000, immutable";

for (const artifact of artifacts) {
  const archiveKey = buildArchiveKey(product, revision, artifact.platform);
  await putObject(config, {
    key: archiveKey,
    body: readFileSync(artifact.archivePath),
    contentType: "application/gzip",
    cacheControl: immutable,
  });
  await putObject(config, {
    key: `${archiveKey}.sha256`,
    body: artifact.checksumFile,
    contentType: "text/plain; charset=utf-8",
    cacheControl: immutable,
  });
}

await putObject(config, {
  key: buildManifestKey(product, revision),
  body: jsonBody(createBuildManifest(manifestOptions)),
  contentType: "application/json; charset=utf-8",
  cacheControl: immutable,
});
await putObject(config, {
  key: releaseManifestKey(product, version),
  body: jsonBody(createReleaseManifest(manifestOptions)),
  contentType: "application/json; charset=utf-8",
  cacheControl: immutable,
});

for (const [name, contentType] of [
  ["install.sh", "text/x-shellscript; charset=utf-8"],
  ["install.ps1", "text/plain; charset=utf-8"],
]) {
  const body = readFileSync(join(hutchRoot, "scripts", name));
  await putObject(config, {
    key: installerKey(product, name),
    body,
    contentType,
    cacheControl: "no-cache, no-store, must-revalidate",
  });
}

// Canary.5 briefly published these installers at the bucket root. Keep the
// product-prefix invariant true even if that workflow finishes late.
for (const key of ["install.sh", "install.ps1"]) {
  await deleteObject(config, key);
}

// Publish the mutable pointer only after every immutable object is available.
await putObject(config, {
  key: channelManifestKey(product, release.channel),
  body: jsonBody(createChannelManifest(manifestOptions)),
  contentType: "application/json; charset=utf-8",
  cacheControl: "no-cache, no-store, must-revalidate",
});

console.log(JSON.stringify({
  product,
  channel: release.channel,
  version,
  revision,
  platforms: RELEASE_PLATFORMS,
}, null, 2));
