import { createHash, randomUUID } from "node:crypto";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  readlinkSync,
  realpathSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import {
  basename,
  dirname,
  isAbsolute,
  join,
  relative,
  resolve,
  sep,
} from "node:path";

export const expectedHarnessDependencies = Object.freeze({
  "p-queue": "8.1.0",
  verdaccio: "6.0.0",
});

export const harnessDependencyCacheMarker = ".hutch-harness-cache.json";

const cacheSchemaVersion = 1;
const installLayout = "hoisted-node-modules-v1";
const sourceFingerprintDomain = "hutch-harness-dependencies-v1\0";
const cachePathFingerprintLength = 32;
const publishWaitArray = new Int32Array(new SharedArrayBuffer(4));

function sha256Bytes(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function readJson(path, label) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    throw new Error(`could not read ${label} at ${path}: ${error.message}`);
  }
}

function regexpEscape(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map(key => [key, canonicalize(value[key])]),
    );
  }
  return value;
}

function canonicalJson(value) {
  return `${JSON.stringify(canonicalize(value), null, 2)}\n`;
}

function assertExactOwnedDependencies(manifest, manifestPath) {
  const actual = manifest.dependencies ?? {};
  const actualNames = Object.keys(actual).sort();
  const expectedNames = Object.keys(expectedHarnessDependencies).sort();
  if (
    actualNames.length !== expectedNames.length ||
    actualNames.some((name, index) => name !== expectedNames[index])
  ) {
    throw new Error(
      `${manifestPath} must contain only the pinned test-harness dependencies: ` +
      expectedNames.join(", "),
    );
  }
  for (const [name, version] of Object.entries(expectedHarnessDependencies)) {
    if (actual[name] !== version) {
      throw new Error(`${manifestPath} must pin ${name} to exactly ${version}`);
    }
  }
}

function assertUpstreamPins(upstreamPackage, upstreamPackagePath) {
  for (const [name, version] of Object.entries(expectedHarnessDependencies)) {
    if (upstreamPackage.dependencies?.[name] !== version) {
      throw new Error(
        `${upstreamPackagePath} must pin ${name} to exactly ${version}`,
      );
    }
  }
}

function assertLockPins(lockText, lockPath) {
  const packagesMarker = '\n  "packages": {';
  const packagesOffset = lockText.indexOf(packagesMarker);
  if (packagesOffset === -1) {
    throw new Error(`${lockPath} does not contain a Bun text-lock package table`);
  }
  const workspaceText = lockText.slice(0, packagesOffset);
  const packageText = lockText.slice(packagesOffset);
  for (const [name, version] of Object.entries(expectedHarnessDependencies)) {
    const escapedName = regexpEscape(name);
    const escapedVersion = regexpEscape(version);
    const workspacePin = new RegExp(
      `^\\s*"${escapedName}": "${escapedVersion}",?$`,
      "m",
    );
    const packagePin = new RegExp(
      `^\\s*"${escapedName}": \\["${escapedName}@${escapedVersion}"(?:,|\\])`,
      "m",
    );
    if (!workspacePin.test(workspaceText) || !packagePin.test(packageText)) {
      throw new Error(`${lockPath} does not lock ${name} to exactly ${version}`);
    }
  }
}

function packageIdentity(resolution, lockPath) {
  const versionSeparator = resolution.lastIndexOf("@");
  if (versionSeparator <= 0 || versionSeparator === resolution.length - 1) {
    throw new Error(`${lockPath} has an unsupported package resolution: ${resolution}`);
  }
  return {
    name: resolution.slice(0, versionSeparator),
    version: resolution.slice(versionSeparator + 1),
  };
}

function normalizeBins(value, packageName, lockPath) {
  if (value == null) return {};
  if (typeof value === "string") {
    return { [packageName.split("/").at(-1)]: value };
  }
  if (typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${lockPath} has an invalid bin declaration for ${packageName}`);
  }
  const bins = {};
  for (const [name, target] of Object.entries(value)) {
    if (typeof target !== "string" || target.length === 0) {
      throw new Error(`${lockPath} has an invalid ${name} bin for ${packageName}`);
    }
    bins[name] = target;
  }
  return bins;
}

function readLockedPackages(lockText, lockPath) {
  const records = [];
  for (const line of lockText.split(/\r?\n/)) {
    const match = line.match(/^    ("(?:[^"\\]|\\.)+"): (\[.*\]),?$/);
    if (!match) continue;
    let key;
    let record;
    try {
      [key, record] = JSON.parse(`[${match[1]},${match[2]}]`);
    } catch (error) {
      throw new Error(`${lockPath} has an unreadable package record: ${error.message}`);
    }
    if (!Array.isArray(record) || typeof record[0] !== "string") {
      throw new Error(`${lockPath} has an invalid package record for ${String(key)}`);
    }
    const identity = packageIdentity(record[0], lockPath);
    records.push({
      bins: normalizeBins(record[2]?.bin, identity.name, lockPath),
      key,
      ...identity,
    });
  }
  if (records.length === 0) {
    throw new Error(`${lockPath} does not contain any readable locked packages`);
  }

  const byKey = new Map(records.map(record => [record.key, record]));
  const resolving = new Set();
  const resolveRelativePath = record => {
    if (record.relativePath) return record.relativePath;
    if (resolving.has(record.key)) {
      throw new Error(`${lockPath} contains a cyclic package placement for ${record.key}`);
    }
    resolving.add(record.key);
    if (record.key === record.name) {
      record.relativePath = `node_modules/${record.name}`;
    } else {
      const suffix = `/${record.name}`;
      if (!record.key.endsWith(suffix)) {
        throw new Error(
          `${lockPath} cannot map ${record.key} to locked package ${record.name}`,
        );
      }
      const parentKey = record.key.slice(0, -suffix.length);
      const parent = byKey.get(parentKey);
      if (!parent) {
        throw new Error(`${lockPath} is missing placement parent ${parentKey}`);
      }
      record.relativePath = `${resolveRelativePath(parent)}/node_modules/${record.name}`;
    }
    resolving.delete(record.key);
    return record.relativePath;
  };
  for (const record of records) resolveRelativePath(record);
  return records;
}

export function readHarnessDependencyPlan(sourceRoot, upstreamPackagePath) {
  const packagePath = join(sourceRoot, "package.json");
  const lockPath = join(sourceRoot, "bun.lock");
  if (!existsSync(packagePath)) {
    throw new Error(`missing Hutch-owned harness dependency manifest: ${packagePath}`);
  }
  if (!existsSync(lockPath)) {
    throw new Error(`missing Hutch-owned frozen harness dependency lock: ${lockPath}`);
  }

  const packageBytes = readFileSync(packagePath);
  const lockBytes = readFileSync(lockPath);
  const lockText = lockBytes.toString("utf8");
  const manifest = readJson(packagePath, "Hutch-owned harness dependency manifest");
  const upstreamPackage = readJson(upstreamPackagePath, "pinned upstream test package");
  assertExactOwnedDependencies(manifest, packagePath);
  assertUpstreamPins(upstreamPackage, upstreamPackagePath);
  assertLockPins(lockText, lockPath);

  return {
    dependencies: expectedHarnessDependencies,
    fingerprint: sha256Bytes(
      Buffer.concat([
        Buffer.from(sourceFingerprintDomain),
        packageBytes,
        Buffer.from("\0"),
        lockBytes,
      ]),
    ),
    lockBytes,
    lockedPackages: readLockedPackages(lockText, lockPath),
    lockPath,
    packageBytes,
    packagePath,
  };
}

function packageRootsIn(nodeModulesRoot, installRoot, result) {
  if (!existsSync(nodeModulesRoot)) return;
  for (const entry of readdirSync(nodeModulesRoot, { withFileTypes: true })) {
    if (entry.name === ".bin") continue;
    const entryPath = join(nodeModulesRoot, entry.name);
    const packageRoots = [];
    if (entry.name.startsWith("@") && entry.isDirectory()) {
      for (const scopedEntry of readdirSync(entryPath, { withFileTypes: true })) {
        if (scopedEntry.isDirectory() || scopedEntry.isSymbolicLink()) {
          packageRoots.push(join(entryPath, scopedEntry.name));
        }
      }
    } else if (entry.isDirectory() || entry.isSymbolicLink()) {
      packageRoots.push(entryPath);
    }
    for (const packageRoot of packageRoots) {
      if (!existsSync(join(packageRoot, "package.json"))) continue;
      result.push(relative(installRoot, packageRoot).split(sep).join("/"));
      packageRootsIn(join(packageRoot, "node_modules"), installRoot, result);
    }
  }
}

function containingNodeModulesRoot(packageRoot, packageName) {
  let root = dirname(packageRoot);
  if (packageName.startsWith("@")) root = dirname(root);
  return root;
}

function pathIsInside(root, path) {
  const relativePath = relative(root, path);
  return (
    relativePath === "" ||
    (!isAbsolute(relativePath) && relativePath !== ".." && !relativePath.startsWith(`..${sep}`))
  );
}

export function windowsHarnessBinShim(relativeTarget) {
  const windowsTarget = relativeTarget.replaceAll("/", "\\");
  return `@"%HUTCH_COMPAT_COTTONTAIL%" "%~dp0${windowsTarget}" %*\r\n`;
}

function expectedWindowsBinShim(binRoot, targetPath) {
  return windowsHarnessBinShim(relative(binRoot, targetPath));
}

export function normalizeHarnessDependencyBinShims(
  installRoot,
  plan,
  platform = process.platform,
) {
  if (platform !== "win32") return;
  for (const record of plan.lockedPackages ?? []) {
    const packageRoot = join(installRoot, ...record.relativePath.split("/"));
    const binRoot = join(containingNodeModulesRoot(packageRoot, record.name), ".bin");
    for (const [binName, target] of Object.entries(record.bins ?? {})) {
      const shimPath = join(binRoot, `${binName}.cmd`);
      if (!existsSync(shimPath)) continue;
      const targetPath = resolve(packageRoot, target);
      writeFileSync(shimPath, expectedWindowsBinShim(binRoot, targetPath));
    }
  }
}

function validatePackageBin(packageRoot, record, binName, target, errors, platform) {
  const targetPath = resolve(packageRoot, target);
  if (!pathIsInside(packageRoot, targetPath)) {
    errors.push(`locked ${record.name} bin ${binName} escapes its package root`);
    return;
  }
  if (!existsSync(targetPath) || !statSync(targetPath).isFile()) {
    errors.push(`missing locked ${record.name} bin target ${target}`);
    return;
  }

  const binRoot = join(containingNodeModulesRoot(packageRoot, record.name), ".bin");
  if (platform === "win32") {
    const shimPath = join(binRoot, `${binName}.cmd`);
    if (!existsSync(shimPath) || !lstatSync(shimPath).isFile()) {
      errors.push(`missing platform bin shim for ${record.name}:${binName}`);
      return;
    }
    const expected = expectedWindowsBinShim(binRoot, targetPath);
    if (readFileSync(shimPath, "utf8") !== expected) {
      errors.push(`platform bin shim has non-relocatable content for ${record.name}:${binName}`);
    }
    return;
  }

  const shimPath = join(binRoot, binName);
  if (!existsSync(shimPath)) {
    errors.push(`missing platform bin shim for ${record.name}:${binName}`);
    return;
  }
  const shimStat = lstatSync(shimPath);
  if (!shimStat.isSymbolicLink()) {
    errors.push(`platform bin shim is not a symlink for ${record.name}:${binName}`);
    return;
  }
  try {
    if (realpathSync(shimPath) !== realpathSync(targetPath)) {
      errors.push(`platform bin shim has the wrong target for ${record.name}:${binName}`);
    }
  } catch (error) {
    errors.push(`could not resolve platform bin shim for ${record.name}:${binName}: ${error.message}`);
  }
}

export function harnessDependencyInstallErrors(
  installRoot,
  plan,
  platform = process.platform,
) {
  const errors = [];
  for (const [filename, expectedBytes] of [
    ["package.json", plan.packageBytes],
    ["bun.lock", plan.lockBytes],
  ]) {
    const installedPath = join(installRoot, filename);
    if (!existsSync(installedPath)) {
      errors.push(`missing staged ${filename}`);
      continue;
    }
    const actualBytes = readFileSync(installedPath);
    if (sha256Bytes(actualBytes) !== sha256Bytes(expectedBytes)) {
      errors.push(`staged ${filename} differs from the Hutch-owned source`);
    }
  }

  const expectedPackageRoots = new Set();
  for (const record of plan.lockedPackages ?? []) {
    expectedPackageRoots.add(record.relativePath);
    const packageRoot = join(installRoot, ...record.relativePath.split("/"));
    const installedPackagePath = join(packageRoot, "package.json");
    if (!existsSync(installedPackagePath)) {
      errors.push(`missing locked transitive ${record.name}@${record.version} at ${record.relativePath}`);
      continue;
    }
    let installedPackage;
    try {
      installedPackage = readJson(installedPackagePath, `installed ${record.name} package`);
    } catch (error) {
      errors.push(error.message);
      continue;
    }
    if (installedPackage.name !== record.name || installedPackage.version !== record.version) {
      errors.push(
        `installed ${record.relativePath} is ` +
        `${String(installedPackage.name)}@${String(installedPackage.version)}, ` +
        `expected ${record.name}@${record.version}`,
      );
    }
    for (const [binName, target] of Object.entries(record.bins ?? {})) {
      validatePackageBin(packageRoot, record, binName, target, errors, platform);
    }
  }

  const actualPackageRoots = [];
  packageRootsIn(join(installRoot, "node_modules"), installRoot, actualPackageRoots);
  for (const actualPath of actualPackageRoots) {
    if (!expectedPackageRoots.has(actualPath)) {
      errors.push(`unexpected installed transitive at ${actualPath}`);
    }
  }
  for (const [name, version] of Object.entries(plan.dependencies)) {
    const installedPackagePath = join(installRoot, "node_modules", name, "package.json");
    if (!existsSync(installedPackagePath)) {
      errors.push(`missing installed ${name}@${version}`);
      continue;
    }
    let installedPackage;
    try {
      installedPackage = readJson(installedPackagePath, `installed ${name} package`);
    } catch (error) {
      errors.push(error.message);
      continue;
    }
    if (installedPackage.version !== version) {
      errors.push(
        `installed ${name} version is ${String(installedPackage.version)}, expected ${version}`,
      );
    }
  }
  return errors;
}

function payloadEntries(installRoot) {
  const entries = [];
  const visit = (root, relativeRoot) => {
    for (const entry of readdirSync(root, { withFileTypes: true })
      .sort((left, right) => left.name < right.name ? -1 : left.name > right.name ? 1 : 0)) {
      if (relativeRoot === "" && entry.name === harnessDependencyCacheMarker) continue;
      const path = join(root, entry.name);
      const relativePath = relativeRoot
        ? `${relativeRoot}/${entry.name}`
        : entry.name;
      const stats = lstatSync(path);
      if (stats.isSymbolicLink()) {
        const target = readlinkSync(path);
        const resolvedTarget = resolve(dirname(path), target);
        if (isAbsolute(target) || !pathIsInside(installRoot, resolvedTarget)) {
          throw new Error(`cache payload contains a non-relocatable symlink: ${relativePath} -> ${target}`);
        }
        if (!existsSync(resolvedTarget)) {
          throw new Error(`cache payload contains a broken symlink: ${relativePath} -> ${target}`);
        }
        entries.push({ path: relativePath, target, type: "symlink" });
      } else if (stats.isDirectory()) {
        visit(path, relativePath);
      } else if (stats.isFile()) {
        entries.push({
          mode: stats.mode & 0o777,
          path: relativePath,
          sha256: sha256Bytes(readFileSync(path)),
          size: stats.size,
          type: "file",
        });
      } else {
        throw new Error(`cache payload contains an unsupported entry: ${relativePath}`);
      }
    }
  };
  visit(installRoot, "");
  return entries;
}

export function createHarnessDependencyCacheIdentity({
  arch = process.arch,
  platform = process.platform,
} = {}) {
  return canonicalize({
    arch,
    cacheSchemaVersion,
    installLayout,
    platform,
  });
}

function identityFingerprint(identity) {
  return sha256Bytes(Buffer.from(canonicalJson(identity)));
}

export function harnessDependencyCacheNamespace(cacheRoot, plan, identity) {
  const namespaceFingerprint = sha256Bytes(
    Buffer.from(`${plan.fingerprint}\0${identityFingerprint(identity)}`),
  ).slice(0, cachePathFingerprintLength);
  return join(cacheRoot, namespaceFingerprint);
}

export function createHarnessDependencyStagingRoot(cacheRoot, plan, identity) {
  const namespace = harnessDependencyCacheNamespace(cacheRoot, plan, identity);
  mkdirSync(namespace, { recursive: true });
  return mkdtempSync(join(namespace, ".staging-"));
}

function writeCacheMarker(installRoot, plan, identity, repairNonce) {
  const installErrors = harnessDependencyInstallErrors(installRoot, plan);
  if (installErrors.length > 0) {
    throw new Error(`cannot publish invalid harness dependencies:\n${installErrors.join("\n")}`);
  }
  const entries = payloadEntries(installRoot);
  const marker = {
    schemaVersion: cacheSchemaVersion,
    planFingerprint: plan.fingerprint,
    identity: canonicalize(identity),
    payloadFingerprint: sha256Bytes(Buffer.from(canonicalJson(entries))),
    entries,
    ...(repairNonce == null ? {} : { repairNonce }),
  };
  const markerBytes = Buffer.from(canonicalJson(marker));
  writeFileSync(join(installRoot, harnessDependencyCacheMarker), markerBytes);
  return {
    fingerprint: sha256Bytes(markerBytes),
    marker,
    markerBytes,
  };
}

function markerErrors(installRoot, plan, identity) {
  const errors = harnessDependencyInstallErrors(installRoot, plan);
  const markerPath = join(installRoot, harnessDependencyCacheMarker);
  if (!existsSync(markerPath)) {
    errors.push(`missing immutable cache marker ${harnessDependencyCacheMarker}`);
    return errors;
  }

  const markerBytes = readFileSync(markerPath);
  let marker;
  try {
    marker = JSON.parse(markerBytes.toString("utf8"));
  } catch (error) {
    errors.push(`invalid immutable cache marker: ${error.message}`);
    return errors;
  }
  if (marker.schemaVersion !== cacheSchemaVersion) {
    errors.push(`immutable cache marker schema is ${String(marker.schemaVersion)}`);
  }
  if (marker.planFingerprint !== plan.fingerprint) {
    errors.push("immutable cache marker has the wrong dependency-plan fingerprint");
  }
  if (canonicalJson(marker.identity) !== canonicalJson(identity)) {
    errors.push("immutable cache marker has the wrong platform or installer identity");
  }
  if (basename(installRoot) !== "install") {
    errors.push("immutable cache payload is not in its published install directory");
  } else if (
    basename(dirname(installRoot)) !==
    sha256Bytes(markerBytes).slice(0, cachePathFingerprintLength)
  ) {
    errors.push("immutable cache generation path does not match its content fingerprint");
  }

  let actualEntries;
  try {
    actualEntries = payloadEntries(installRoot);
  } catch (error) {
    errors.push(error.message);
    return errors;
  }
  if (!Array.isArray(marker.entries)) {
    errors.push("immutable cache marker has no payload manifest");
    return errors;
  }
  const recordedFingerprint = sha256Bytes(Buffer.from(canonicalJson(marker.entries)));
  if (recordedFingerprint !== marker.payloadFingerprint) {
    errors.push("immutable cache marker payload fingerprint is corrupt");
  }
  if (canonicalJson(actualEntries) !== canonicalJson(marker.entries)) {
    errors.push("immutable cache payload differs from its full-tree manifest");
  }
  return errors;
}

export function publishedHarnessDependencyInstallErrors(installRoot, plan, identity) {
  try {
    return markerErrors(installRoot, plan, identity);
  } catch (error) {
    return [`could not validate immutable cache payload at ${installRoot}: ${error.message}`];
  }
}

export function findValidHarnessDependencyGeneration(cacheRoot, plan, identity) {
  const namespace = harnessDependencyCacheNamespace(cacheRoot, plan, identity);
  if (!existsSync(namespace)) return null;
  for (const entry of readdirSync(namespace, { withFileTypes: true })
    .filter(entry => entry.isDirectory() && /^[0-9a-f]{32}$/.test(entry.name))
    .sort((left, right) => left.name.localeCompare(right.name))) {
    const installRoot = join(namespace, entry.name, "install");
    if (publishedHarnessDependencyInstallErrors(installRoot, plan, identity).length === 0) {
      return installRoot;
    }
  }
  return null;
}

function waitForPublishedGeneration(installRoot, plan, identity) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (existsSync(join(installRoot, harnessDependencyCacheMarker))) {
      return publishedHarnessDependencyInstallErrors(installRoot, plan, identity).length === 0;
    }
    Atomics.wait(publishWaitArray, 0, 0, 25);
  }
  return false;
}

export function publishHarnessDependencyGeneration(
  stagingRoot,
  cacheRoot,
  plan,
  identity,
) {
  const namespace = harnessDependencyCacheNamespace(cacheRoot, plan, identity);
  if (dirname(stagingRoot) !== namespace || !basename(stagingRoot).startsWith(".staging-")) {
    throw new Error("harness dependency staging root is outside its cache namespace");
  }

  let marker = writeCacheMarker(stagingRoot, plan, identity, null);
  for (;;) {
    const generationRoot = join(
      namespace,
      marker.fingerprint.slice(0, cachePathFingerprintLength),
    );
    const installRoot = join(generationRoot, "install");
    try {
      // mkdir is the no-overwrite reservation. The subsequent rename publishes
      // the complete payload, marker included, in one filesystem operation.
      mkdirSync(generationRoot);
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      if (waitForPublishedGeneration(installRoot, plan, identity)) {
        rmSync(stagingRoot, { recursive: true, force: true });
        return { installRoot, reused: true };
      }
      // Never remove or replace an invalid published occupant. A nonce in the
      // marker produces a new content-derived generation for self-repair.
      marker = writeCacheMarker(stagingRoot, plan, identity, randomUUID());
      continue;
    }

    try {
      renameSync(stagingRoot, installRoot);
    } catch (error) {
      // This directory is our unpublished reservation and contains no payload.
      // Removing it cannot affect a consumer or another publisher.
      rmSync(generationRoot, { recursive: true, force: true });
      throw error;
    }
    const publishErrors = publishedHarnessDependencyInstallErrors(installRoot, plan, identity);
    if (publishErrors.length > 0) {
      throw new Error(`published invalid harness dependencies:\n${publishErrors.join("\n")}`);
    }
    return { installRoot, reused: false };
  }
}
