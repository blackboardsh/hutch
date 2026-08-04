#!/usr/bin/env node

import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { releaseChannel } from "./release-contract.js";

const hutchRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const repositoryRoot = hutchRoot;
const packageJson = JSON.parse(readFileSync(join(hutchRoot, "package.json"), "utf8"));
const zigVersionSource = readFileSync(join(hutchRoot, "src", "version.zig"), "utf8");

function fail(message) {
  console.error(`hutch release: ${message}`);
  process.exit(1);
}

const zigVersion = zigVersionSource.match(/pub const version = "([^"]+)";/)?.[1];
if (zigVersion !== packageJson.version) {
  fail(
    `version mismatch: package.json=${packageJson.version}, src/version.zig=${zigVersion ?? "missing"}`,
  );
}

function platformKey() {
  const key = `${process.platform}-${process.arch}`;
  return {
    "darwin-arm64": "macos-arm64",
    "linux-x64": "linux-x64",
    "linux-arm64": "linux-arm64",
    "win32-x64": "windows-x64",
  }[key] ?? fail(`unsupported release platform: ${key}`);
}

function sha256(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function gitRevision() {
  if (process.env.GITHUB_SHA) return process.env.GITHUB_SHA;
  if (process.env.CIRCLE_SHA1) return process.env.CIRCLE_SHA1;
  try {
    return execFileSync("git", ["rev-parse", "HEAD"], {
      cwd: repositoryRoot,
      encoding: "utf8",
    }).trim();
  } catch {
    return fail("unable to determine the release revision");
  }
}

const platform = platformKey();
const launcherName = process.platform === "win32" ? "hutch.exe" : "hutch";
const engineName = process.platform === "win32" ? "hutch-engine.exe" : "hutch-engine";
const builtLauncher = join(hutchRoot, "zig-out", "bin", launcherName);
const builtEngine = join(hutchRoot, "zig-out", "bin", engineName);

for (const [label, path] of [
  ["Hutch launcher", builtLauncher],
  ["Hutch engine", builtEngine],
]) {
  if (!existsSync(path)) fail(`missing ${label}: ${path}`);
}

const releaseRoot = join(hutchRoot, "release");
const artifactBase = `hutch-v${packageJson.version}-${platform}`;
const packageRoot = join(releaseRoot, artifactBase);
const binRoot = join(packageRoot, "bin");
const archivePath = join(releaseRoot, `${artifactBase}.tar.gz`);

rmSync(packageRoot, { recursive: true, force: true });
mkdirSync(binRoot, { recursive: true });
copyFileSync(builtLauncher, join(binRoot, launcherName));
copyFileSync(builtEngine, join(binRoot, engineName));
if (process.platform !== "win32") {
  chmodSync(join(binRoot, launcherName), 0o755);
  chmodSync(join(binRoot, engineName), 0o755);
}

const manifest = {
  schema: 1,
  kind: "archive",
  product: "hutch",
  channel: releaseChannel(packageJson.version),
  version: packageJson.version,
  platform,
  revision: gitRevision(),
  launcher: `bin/${launcherName}`,
  executable: `bin/${engineName}`,
};
writeFileSync(
  join(packageRoot, "hutch-release.json"),
  `${JSON.stringify(manifest, null, 2)}\n`,
);

for (const executable of [join(binRoot, launcherName), join(binRoot, engineName)]) {
  const smoke = spawnSync(executable, ["--version"], {
    cwd: packageRoot,
    encoding: "utf8",
  });
  if (smoke.status !== 0 || smoke.stdout.trim() !== packageJson.version) {
    fail(
      `packaged executable smoke test failed for ${basename(executable)}:\n` +
        (smoke.stderr || smoke.stdout),
    );
  }
}

rmSync(archivePath, { force: true });
const tar = spawnSync(
  "tar",
  ["-czf", archivePath, "-C", releaseRoot, basename(packageRoot)],
  { cwd: hutchRoot, encoding: "utf8" },
);
if (tar.status !== 0) fail(`failed to create ${archivePath}:\n${tar.stderr || tar.stdout}`);

const digest = sha256(archivePath);
writeFileSync(`${archivePath}.sha256`, `${digest}  ${basename(archivePath)}\n`);
rmSync(packageRoot, { recursive: true, force: true });

console.log(JSON.stringify({ archive: archivePath, sha256: digest }, null, 2));
