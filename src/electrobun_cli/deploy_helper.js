import { closeSync, fstatSync, lstatSync, openSync, readFileSync, readSync, readdirSync } from "node:fs";
import { createHash } from "node:crypto";
import { join, resolve } from "node:path";

const PART_SIZE = 8 * 1024 * 1024;
const TARGET = /^(macos|linux|win)-(arm64|x64)$/;
const ID = /^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$/;
const RELEASE_ID = /^[a-zA-Z0-9][a-zA-Z0-9._+-]{0,127}$/;

function validReleaseId(releaseId) {
  return typeof releaseId === "string" && RELEASE_ID.test(releaseId) && !releaseId.includes("..") && !releaseId.endsWith(".");
}

function releaseIdentity(channel, version, explicit) {
  const releaseId = `${channel}-${version}`;
  if (!validReleaseId(releaseId)) throw new Error("The channel and version must form a plain release ID (letters, digits, periods, hyphens, underscores, or plus; up to 128 characters)");
  if (explicit !== undefined && explicit !== releaseId) throw new Error("--release must match <channel>-<version> from the generated artifacts; release aliases are not supported");
  return releaseId;
}

function parseArgs(command, args, defaults, env) {
  const values = {};
  const names = new Set(command === "publish" ? ["release", "app", "api-url", "api-key", "audience"] : ["env", "release", "app", "api-url", "api-key", "artifacts", "targets"]);
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--dry-run") { values.dryRun = true; continue; }
    if (arg === "--help" || arg === "-h") return { help: true };
    const match = /^--([^=]+)(?:=(.*))?$/.exec(arg);
    if (!match || !names.has(match[1])) throw new Error(`Unknown ${command} option; use hutch electrobun ${command} --help`);
    const name = match[1];
    if (values[name] !== undefined) throw new Error(`Duplicate --${name} option`);
    const value = match[2] ?? args[++i];
    if (!value || value.startsWith("--")) throw new Error(`Missing value for --${name}`);
    values[name] = value;
  }
  const channel = values.env;
  if (channel !== undefined && channel !== "stable" && channel !== "canary") throw new Error("--env must be canary or stable; dev builds do not create release artifacts");
  const appId = values.app ?? defaults.appId;
  const releaseId = values.release;
  if (!appId || !ID.test(appId)) throw new Error("Set --app or release.managed.appId to a valid app ID");
  if (command === "publish" && !releaseId) throw new Error("--release is required; use the release ID reported by upload");
  if (releaseId !== undefined && !validReleaseId(releaseId)) throw new Error("Set --release to a plain release ID (letters, digits, periods, hyphens, underscores, or plus; up to 128 characters)");
  const audience = values.audience ?? "public";
  if (audience !== "prerelease" && audience !== "public") throw new Error("--audience must be prerelease or public");
  const apiKey = values["api-key"] ?? env.ELECTROBUN_API_KEY;
  if ((command === "publish" || !values.dryRun) && (!apiKey || /[\r\n]/.test(apiKey))) throw new Error("Set ELECTROBUN_API_KEY or --api-key to an Electrobun Managed Deploys API key");
  const url = new URL(values["api-url"] ?? defaults.apiUrl ?? "https://api.electrobun.dev");
  const local = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
  if (url.username || url.password || url.search || url.hash || (url.protocol !== "https:" && !(url.protocol === "http:" && local && values["api-url"]))) {
    throw new Error("The API URL must use HTTPS with no credentials, query, or fragment; explicit loopback HTTP is allowed for local testing");
  }
  const path = url.pathname.replace(/\/+$/, "");
  if (path !== "" && path !== "/v1/electrobun") throw new Error("The API URL must be an origin or end in /v1/electrobun");
  url.pathname = "/v1/electrobun";
  const expectedTargets = values.targets ? [...new Set(values.targets.split(","))].sort() : null;
  if (expectedTargets && !expectedTargets.every((target) => TARGET.test(target))) throw new Error("--targets must be comma-separated Electrobun targets, such as macos-arm64,win-x64,linux-x64");
  return {
    channel, appId, releaseId, apiKey, apiUrl: url.href.replace(/\/$/, ""),
    artifacts: resolve(values.artifacts ?? defaults.artifactFolder ?? "artifacts"),
    dryRun: values.dryRun === true, expectedTargets, audience,
    offline: !!env.DASH_RELEASE_OFFLINE && !["0", "false", "no"].includes(env.DASH_RELEASE_OFFLINE.toLowerCase()),
  };
}

/** Upload discovers channel, version and targets from the generated manifests. */
export const parseUploadArgs = (args, defaults = {}, env = process.env) => parseArgs("upload", args, defaults, env);
export const parseDeployArgs = parseUploadArgs;
export const parsePublishArgs = (args, defaults = {}, env = process.env) => parseArgs("publish", args, defaults, env);

function artifactChannels(names) {
  return [...new Set(names.map(name => /^(stable|canary)-(macos|linux|win)-(arm64|x64)-update(?:-v2)?\.json$/.exec(name)?.[1]).filter(Boolean))].sort();
}

function isFileName(value) {
  return typeof value === "string" && value.length > 0 && value.length <= 255 && !/[\\/\x00-\x1f\x7f]/.test(value) && value !== "." && value !== "..";
}

function fileDetails(path) {
  const stat = lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error("Release artifacts must be regular files, not directories or symbolic links");
  if (!Number.isSafeInteger(stat.size) || stat.size <= 0) throw new Error("Release artifacts must be nonempty regular files");
  return stat;
}

function hashFile(path, expected) {
  const fd = openSync(path, "r");
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile() || stat.size !== expected.size || stat.mtimeMs !== expected.mtimeMs || stat.ino !== expected.ino) throw new Error("An artifact changed while it was being inventoried; finish the build before deploying");
    const hash = createHash("sha256");
    const buffer = Buffer.allocUnsafe(1024 * 1024);
    let position = 0;
    while (position < stat.size) {
      const count = readSync(fd, buffer, 0, Math.min(buffer.length, stat.size - position), position);
      if (!count) throw new Error("An artifact was truncated while being inventoried");
      hash.update(buffer.subarray(0, count));
      position += count;
    }
    return hash.digest("hex");
  } finally { closeSync(fd); }
}

export function inventoryArtifacts(options) {
  const names = readdirSync(options.artifacts).sort();
  if (!options.channel) {
    const channels = artifactChannels(names);
    if (!channels.length) throw new Error("No canary or stable release update manifests found in the artifact directory");
    if (channels.length > 1) throw new Error("The artifact folder contains multiple channels; use inventoryReleases to upload each release, or select --env");
    options = { ...options, channel: channels[0] };
  }
  const manifests = new Map();
  const manifestPattern = new RegExp(`^${options.channel}-(macos|linux|win)-(arm64|x64)-update(-v2)?\\.json$`);
  let version;
  let identifier;
  for (const filename of names) {
    const match = manifestPattern.exec(filename);
    if (!match) continue;
    const target = `${match[1]}-${match[2]}`;
    const path = join(options.artifacts, filename);
    if (fileDetails(path).size > 64 * 1024) throw new Error(`Update manifest is too large: ${filename}`);
    let manifest;
    try { manifest = JSON.parse(readFileSync(path, "utf8")); } catch { throw new Error(`Invalid update manifest: ${filename}`); }
    if (manifest.schemaVersion !== 1 || manifest.channel !== options.channel || manifest.platform !== match[1] || manifest.arch !== match[2] ||
        typeof manifest.version !== "string" || !manifest.version || typeof manifest.identifier !== "string" || !manifest.identifier ||
        typeof manifest.hash !== "string" || !/^[a-z0-9]+$/i.test(manifest.hash) || !isFileName(manifest.artifact?.file)) {
      throw new Error(`Invalid Electrobun update manifest: ${filename}`);
    }
    if (!manifest.artifact.file.startsWith(`${options.channel}-${target}-`) || !manifest.artifact.file.endsWith(".tar.zst")) throw new Error(`Manifest artifact must name this target's .tar.zst archive: ${filename}`);
    if ((match[3] || manifest.artifact.tarSha256 !== undefined || manifest.artifact.tarSize !== undefined) && (!/^[a-f0-9]{64}$/i.test(manifest.artifact.tarSha256 ?? "") || !Number.isSafeInteger(manifest.artifact.tarSize) || manifest.artifact.tarSize <= 0)) throw new Error(`Invalid update manifest tar integrity: ${filename}`);
    if ((version !== undefined && version !== manifest.version) || (identifier !== undefined && identifier !== manifest.identifier)) throw new Error("All artifacts in a release must have the same application identifier and version");
    version = manifest.version;
    identifier = manifest.identifier;
    const existing = manifests.get(target);
    if (existing && (existing.hash !== manifest.hash || existing.artifact.file !== manifest.artifact.file)) throw new Error(`Update manifests disagree for ${target}`);
    if (existing?.artifact.tarSha256 !== undefined && manifest.artifact.tarSha256 !== undefined && (existing.artifact.tarSha256 !== manifest.artifact.tarSha256 || existing.artifact.tarSize !== manifest.artifact.tarSize)) throw new Error(`Update manifests disagree for ${target}`);
    manifests.set(target, manifest);
  }
  if (!manifests.size) throw new Error(`No ${options.channel} release update manifests found in the artifact directory`);
  const targets = [...manifests.keys()].sort();
  if (options.expectedTargets && targets.some((target) => !options.expectedTargets.includes(target))) throw new Error("Uploaded targets must be included in --targets");
  for (const [target, manifest] of manifests) {
    if (!names.includes(manifest.artifact.file)) throw new Error(`Missing archive for ${target}: ${manifest.artifact.file}`);
  }
  const files = [];
  for (const filename of names) {
    const target = targets.find((item) => filename.startsWith(`${options.channel}-${item}-`) || (options.channel === "stable" && filename.startsWith(`${item}-`)));
    if (!target) continue;
    if (!isFileName(filename) || !/(?:-update(?:-v2)?\.json|\.tar\.zst|\.patch|\.dmg|\.zip|\.exe|\.tar\.gz)$/.test(filename)) continue;
    const path = join(options.artifacts, filename);
    const stat = fileDetails(path);
    files.push({filename, target, path, size: stat.size, sha256: hashFile(path, stat), mtimeMs: stat.mtimeMs, ino: stat.ino});
  }
  // Finish archives before uploading manifests, so dashboard checks become ready last.
  files.sort((a, b) => Number(a.filename.endsWith(".json")) - Number(b.filename.endsWith(".json")) || a.filename.localeCompare(b.filename));
  return {version, identifier, targets, files, channel: options.channel};
}

/** Inventory every release before starting network writes, including mixed-channel folders. */
export function inventoryReleases(options) {
  const channels = options.channel ? [options.channel] : artifactChannels(readdirSync(options.artifacts));
  if (!channels.length) throw new Error("No canary or stable release update manifests found in the artifact directory");
  if (channels.length > 1 && options.releaseId) throw new Error("--release selects one release; this folder contains both canary and stable artifacts. Omit --release or use --env to select a channel");
  return channels.map(channel => {
    const inventory = inventoryArtifacts({ ...options, channel });
    return { options: { ...options, channel, releaseId: releaseIdentity(channel, inventory.version, options.releaseId) }, inventory };
  });
}

function apiRequest(options, fetchImpl) {
  return async (path, method = "GET", body) => {
    const headers = {Authorization: `Bearer ${options.apiKey}`};
    if (body !== undefined) headers["Content-Type"] = "application/json";
    let response;
    try {
      response = await fetchImpl(`${options.apiUrl}${path}`, {
        method, headers, redirect: "manual",
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(120_000),
      });
    } catch { throw new Error("Managed Deploys request failed; retry the same release to resume uploaded files"); }
    if (response.status >= 300 && response.status < 400) throw new Error("Managed Deploys API redirected; use its canonical API URL (credentials were not forwarded)");
    // Do not print response bodies: an untrusted server could echo credentials.
    if (!response.ok) throw new Error(`Managed Deploys request failed (HTTP ${response.status}); retry the same release after resolving the error`);
    let result;
    try { result = await response.json(); } catch { throw new Error("Managed Deploys API returned invalid JSON"); }
    return result;
  };
}

function unquotedETag(etag) {
  return etag.startsWith('"') && etag.endsWith('"') ? etag.slice(1, -1) : etag;
}

async function uploadSignedPart(options, request, fetchImpl, uploadPath, partNumber, chunk, md5) {
  const grant = await request(`${uploadPath}/parts/${partNumber}`, "POST", {md5, size: chunk.length});
  let url, headers;
  try {
    if (!grant || typeof grant.url !== "string" || !grant.headers || typeof grant.headers !== "object" || Array.isArray(grant.headers)) throw new Error();
    url = new URL(grant.url);
    const apiUrl = new URL(options.apiUrl);
    const loopback = hostname => ["localhost", "127.0.0.1", "[::1]"].includes(hostname);
    const local = apiUrl.protocol === "http:" && loopback(apiUrl.hostname) && url.protocol === "http:" && loopback(url.hostname);
    if (url.username || url.password || url.hash || (url.protocol !== "https:" && !local)) throw new Error();
    headers = new Headers();
    for (const [name, value] of Object.entries(grant.headers)) {
      if (typeof value !== "string" || /^(authorization|proxy-authorization|cookie|cookie2)$/i.test(name) || headers.has(name)) throw new Error();
      headers.set(name, value);
    }
    if (headers.get("content-md5") !== md5 || headers.get("content-length") !== String(chunk.length)) throw new Error();
  } catch { throw new Error("Managed Deploys API returned an invalid signed upload grant"); }
  let response;
  try {
    response = await fetchImpl(url.href, {
      method: "PUT", headers, body: chunk, redirect: "manual", credentials: "omit",
      signal: AbortSignal.timeout(120_000),
    });
  } catch { throw new Error("Direct artifact upload request failed; retry the same release to resume uploaded files"); }
  if (response.status >= 300 && response.status < 400) throw new Error("Direct artifact upload redirected; the signed upload was not forwarded");
  if (!response.ok) throw new Error(`Direct artifact upload failed (HTTP ${response.status}); retry the same release after resolving the error`);
  const etag = unquotedETag(response.headers.get("etag") ?? "");
  if (!etag || !etag.trim()) throw new Error("Direct artifact upload returned no ETag; retry the same release to resume uploaded files");
  return {partNumber, etag};
}

export async function deployArtifacts(options, inventory, {fetchImpl = fetch, log = console.log} = {}) {
  const channel = options.channel ?? inventory.channel;
  options = { ...options, channel, releaseId: releaseIdentity(channel, inventory.version, options.releaseId) };
  if (options.dryRun) return {dryRun: true, inventory};
  if (options.offline) throw new Error("Upload requires network access; unset DASH_RELEASE_OFFLINE or use --dry-run");
  const request = apiRequest(options, fetchImpl);
  const appPath = `/apps/${encodeURIComponent(options.appId)}`;
  const releasePath = `${appPath}/releases/${encodeURIComponent(options.releaseId)}`;
  await request(`${appPath}/releases`, "POST", {releaseId: options.releaseId, channel: options.channel, version: inventory.version, expectedTargets: options.expectedTargets ?? inventory.targets});
  for (const file of inventory.files) {
    const stat = fileDetails(file.path);
    if (stat.size !== file.size || stat.mtimeMs !== file.mtimeMs || stat.ino !== file.ino) throw new Error("An artifact changed after inventory; rebuild the inventory before deploying");
    const initialized = await request(`${releasePath}/uploads`, "POST", {filename: file.filename, target: file.target, size: file.size, sha256: file.sha256});
    const upload = initialized.upload;
    if (!upload || typeof upload.id !== "string" || !ID.test(upload.id)) throw new Error("Managed Deploys API returned an invalid upload ID");
    if (upload.status === "complete" || upload.status === "completed") { log(`Already staged ${file.filename}`); continue; }
    if ((initialized.partSize ?? upload.partSize) !== PART_SIZE) throw new Error("Managed Deploys API requested an unsupported multipart size");
    const uploadPath = `${releasePath}/uploads/${encodeURIComponent(upload.id)}`;
    const completed = new Map();
    for (const part of upload.parts ?? []) {
      if (!Number.isSafeInteger(part.partNumber) || part.partNumber < 1 || part.partNumber > Math.ceil(file.size / PART_SIZE) || typeof part.etag !== "string" || !part.etag) throw new Error("Managed Deploys API returned invalid resume metadata");
      completed.set(part.partNumber, {partNumber: part.partNumber, etag: unquotedETag(part.etag)});
    }
    const fd = openSync(file.path, "r");
    try {
      const opened = fstatSync(fd);
      if (!opened.isFile() || opened.size !== file.size || opened.mtimeMs !== file.mtimeMs || opened.ino !== file.ino) throw new Error("An artifact changed while starting its upload");
      const buffer = Buffer.allocUnsafe(Math.min(file.size, PART_SIZE));
      const hash = createHash("sha256");
      for (let offset = 0, partNumber = 1; offset < file.size; offset += PART_SIZE, partNumber++) {
        const length = Math.min(PART_SIZE, file.size - offset);
        let filled = 0;
        while (filled < length) {
          const count = readSync(fd, buffer, filled, length - filled, offset + filled);
          if (!count) throw new Error("An artifact was truncated during upload");
          filled += count;
        }
        const chunk = buffer.subarray(0, length);
        hash.update(chunk);
        const md5 = createHash("md5").update(chunk).digest();
        // A failed attempt may have uploaded changed bytes before the final SHA
        // check. Reuse a remote part only when its ETag identifies these bytes.
        if (completed.get(partNumber)?.etag === md5.toString("hex")) continue;
        const part = await uploadSignedPart(options, request, fetchImpl, uploadPath, partNumber, chunk, md5.toString("base64"));
        completed.set(partNumber, part);
      }
      if (hash.digest("hex") !== file.sha256) throw new Error("An artifact changed during upload; it was not completed. Rebuild and retry");
      await request(`${uploadPath}/complete`, "POST", {parts: [...completed.values()].sort((a, b) => a.partNumber - b.partNumber)});
      log(`Staged ${file.filename} (${file.size} bytes)`);
    } finally { closeSync(fd); }
  }
  const status = await request(releasePath);
  log(`Release ${options.releaseId} staged. After all runners finish, publish to prerelease in the dashboard or run hutch electrobun publish --app=${options.appId} --release=${options.releaseId} --audience=prerelease.`);
  log("Use --audience=public to publish to all installs.");
  if (status.checks?.ready === false) log("This release is waiting for additional artifacts or validation; see its dashboard checks.");
  return status;
}

export async function uploadArtifacts(options, dependencies = {}) {
  const releases = [];
  for (const planned of inventoryReleases(options)) {
    releases.push(await deployArtifacts(planned.options, planned.inventory, dependencies));
  }
  return { releases };
}

/** Publication is a separate CI step: it never reads or uploads local artifacts. */
export async function publishRelease(options, { fetchImpl = fetch, log = console.log } = {}) {
  if (options.offline) throw new Error("Publish requires network access, including --dry-run; unset DASH_RELEASE_OFFLINE");
  const audience = options.audience ?? "public";
  if (audience !== "prerelease" && audience !== "public") throw new Error("--audience must be prerelease or public");
  const request = apiRequest(options, fetchImpl);
  const path = `/apps/${encodeURIComponent(options.appId)}/releases/${encodeURIComponent(options.releaseId)}`;
  const status = await request(path);
  const { release, checks } = status ?? {};
  if (!release || release.id !== options.releaseId || !["canary", "stable"].includes(release.channel) ||
      typeof release.version !== "string" || !release.version || `${release.channel}-${release.version}` !== release.id || !Array.isArray(release.artifacts) || !Array.isArray(release.expectedTargets) ||
      typeof checks?.ready !== "boolean" || !Array.isArray(checks.errors)) {
    throw new Error("Managed Deploys API returned invalid release details");
  }
  const report = line => log(options.apiKey ? String(line).split(options.apiKey).join("[redacted]") : String(line));
  report(`Release ${release.id}: ${release.channel} ${release.version}, ${release.artifacts.length} files on ${release.expectedTargets.join(", ")}`);
  for (const file of release.artifacts) {
    if (!file.deletedAt) report(`  ${file.filename} (${file.size} bytes)`);
  }
  if (!checks.ready) {
    for (const error of checks.errors) report(`  ${error}`);
    throw new Error("Release is not ready to publish; finish the uploads and resolve its checks first");
  }
  if (options.dryRun) {
    report(`Release ${release.id} passes checks for ${audience}. Dry run: nothing was published.`);
    return { ...status, dryRun: true };
  }
  // The server validates again while locking publication, so a concurrent upload
  // cannot bypass integrity checks between inspection and the pointer change.
  const published = await request(`${path}/publish`, "POST", { audience });
  if (published?.release?.id !== release.id || published.release.status !== (audience === "prerelease" ? "prerelease" : "published")) {
    throw new Error("Managed Deploys API did not confirm publication; inspect the release before retrying");
  }
  report(audience === "prerelease" ? `Published ${release.id} to prerelease.` : `Published ${release.id} to public.`);
  return published;
}

function reportFailure(command, error, args, env) {
  // Filesystem errors and remote metadata may contain supplied values. Never
  // echo an API key, even if it was accidentally reused in another argument.
  let message = String(error?.message ?? `${command} failed`);
  const secrets = [env.ELECTROBUN_API_KEY];
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--api-key") secrets.push(args[i + 1]);
    else if (args[i].startsWith("--api-key=")) secrets.push(args[i].slice(10));
  }
  for (const secret of secrets) if (secret) message = message.split(secret).join("[redacted]");
  console.error(`hutch electrobun ${command}: ${message}`);
  process.exitCode = 1;
}

export async function runUpload(args, defaults = {}, env = process.env) {
  try {
    const options = parseUploadArgs(args, defaults, env);
    if (options.help) {
      console.log("hutch electrobun upload [--release=<channel-version>] [--app=<id>] [--artifacts=<directory>] [--dry-run]\n\nUploads existing artifacts and infers their channel, version and platforms from the generated manifests.\nThe release ID is <channel>-<version>; --release, when provided, must match it. Runners for the same build accumulate files in that release.\nSet ELECTROBUN_API_KEY (or --api-key) and release.managed.appId in electrobun.config.ts (or --app).\nAfter every build runner succeeds, run hutch electrobun publish --release=<id> --audience=prerelease, or publish in the dashboard.\n--env optionally selects one channel from a mixed folder; --targets remains an optional explicit completeness check.\nFor service development, --api-url overrides the standard endpoint. deploy is an alias for upload.");
      return;
    }
    const planned = inventoryReleases(options);
    for (const { options: resolved, inventory } of planned) {
      console.log(`${options.dryRun ? "Preview" : "Stage"} ${resolved.channel} release ${resolved.releaseId}: ${inventory.version}, ${inventory.targets.join(", ")}, ${inventory.files.length} files`);
      if (options.dryRun) {
        console.log(JSON.stringify({appId: options.appId, releaseId: resolved.releaseId, channel: resolved.channel, version: inventory.version, expectedTargets: options.expectedTargets ?? inventory.targets, files: inventory.files.map(({filename, target, size, sha256}) => ({filename, target, size, sha256}))}, null, 2));
      } else await deployArtifacts(resolved, inventory);
    }
  } catch (error) { reportFailure("upload", error, args, env); }
}

export const runDeploy = runUpload;

export async function runPublish(args, defaults = {}, env = process.env) {
  try {
    const options = parsePublishArgs(args, defaults, env);
    if (options.help) {
      console.log("hutch electrobun publish --release=<channel-version> [--audience=prerelease|public] [--app=<id>] [--dry-run]\n\nInspect the uploaded files and validate the release, then publish to registered prerelease installs or publish to public (the default).\nRun this in a final CI step that depends on every build/upload runner succeeding.\nUses ELECTROBUN_API_KEY (or --api-key) and release.managed.appId (or --app); no local artifacts are needed.\n--dry-run checks the server release for the chosen audience without publishing and still requires an API key and network access.");
      return;
    }
    await publishRelease(options);
  } catch (error) { reportFailure("publish", error, args, env); }
}
