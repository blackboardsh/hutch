#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const rootDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const manifestPath = join(rootDir, "compat", "upstream", "cottontail.json");
const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));

if (manifest.schema !== 1) {
  throw new Error(`Unsupported Cottontail manifest schema: ${manifest.schema}`);
}
if (!/^https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\.git$/.test(manifest.repository)) {
  throw new Error(
    `Cottontail repository must be an explicit HTTPS GitHub URL: ${manifest.repository}`,
  );
}
if (!/^[0-9a-f]{40}$/.test(manifest.commit)) {
  throw new Error(`Cottontail commit must be a full Git commit: ${manifest.commit}`);
}
if (manifest.bunCompatibilityVersion !== "1.3.10") {
  throw new Error(
    `Cottontail pin targets Bun ${manifest.bunCompatibilityVersion}; Hutch owns Bun 1.3.10`,
  );
}

const checkoutBase = resolve(
  process.env.HUTCH_UPSTREAM_COTTONTAIL_ROOT ??
    join(rootDir, ".hutch-local-tools", "upstream-cottontail"),
);
const checkoutRoot = join(checkoutBase, manifest.commit);
const executableName = process.platform === "win32" ? "cottontail.exe" : "cottontail";
const binaryPath = join(checkoutRoot, "zig-out", "bin", executableName);

function run(command, args, cwd = rootDir) {
  execFileSync(command, args, {
    cwd,
    // Reserve stdout for the final machine-readable binary path.
    stdio: ["inherit", process.stderr, process.stderr],
  });
}

function output(command, args, cwd = rootDir) {
  return execFileSync(command, args, { cwd, encoding: "utf8" }).trim();
}

if (!existsSync(join(checkoutRoot, ".git"))) {
  if (existsSync(checkoutRoot)) {
    throw new Error(`Refusing to replace non-Git Cottontail checkout at ${checkoutRoot}`);
  }
  mkdirSync(checkoutRoot, { recursive: true });
  run("git", ["init", "--quiet"], checkoutRoot);
  run("git", ["remote", "add", "origin", manifest.repository], checkoutRoot);
  // The Node-derived test suite contains fixture paths beyond Windows' MAX_PATH.
  run("git", ["config", "core.longpaths", "true"], checkoutRoot);
  run("git", ["fetch", "--quiet", "--depth", "1", "origin", manifest.commit], checkoutRoot);
  run("git", ["checkout", "--quiet", "--detach", "FETCH_HEAD"], checkoutRoot);
}

const checkedOutCommit = output("git", ["rev-parse", "HEAD"], checkoutRoot);
if (checkedOutCommit !== manifest.commit) {
  throw new Error(
    `Pinned Cottontail checkout mismatch: expected ${manifest.commit}, received ${checkedOutCommit}`,
  );
}

if (!existsSync(binaryPath) || statSync(binaryPath).size === 0) {
  run(process.execPath, ["scripts/setup.js"], checkoutRoot);
  run(process.execPath, ["scripts/setup-zig-html-rewriter.js"], checkoutRoot);
  run(process.execPath, ["scripts/setup-jsc.js"], checkoutRoot);
  const buildArgs = [
    "scripts/zig.js",
    "build",
    "-Doptimize=ReleaseSmall",
    ...(process.platform === "win32" ? ["-Dtarget=x86_64-windows-msvc"] : []),
    "-Dcpu=baseline",
  ];
  run(
    process.execPath,
    buildArgs,
    checkoutRoot,
  );
}
if (!existsSync(binaryPath) || !statSync(binaryPath).isFile() || statSync(binaryPath).size === 0) {
  throw new Error(`Pinned Cottontail build did not produce ${binaryPath}`);
}

console.log(binaryPath);
