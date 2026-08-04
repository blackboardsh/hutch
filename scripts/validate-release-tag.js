#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { appendFileSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { validateReleaseTag, validateRevision } from "./release-contract.js";

const hutchRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const repositoryRoot = hutchRoot;
const packageJson = JSON.parse(readFileSync(join(hutchRoot, "package.json"), "utf8"));
const versionZig = readFileSync(join(hutchRoot, "src", "version.zig"), "utf8");

function fail(message) {
  console.error(`hutch release: ${message}`);
  process.exit(1);
}

const tag = process.env.GITHUB_REF_TYPE === "tag"
  ? process.env.GITHUB_REF_NAME
  : process.env.CIRCLE_TAG ??
    process.argv.find((argument) => argument.startsWith("--tag="))?.slice("--tag=".length);
if (!tag) fail("a Hutch release tag is required");

const revision =
  process.env.GITHUB_SHA ||
  process.env.CIRCLE_SHA1 ||
  execFileSync("git", ["rev-parse", "HEAD"], {
    cwd: repositoryRoot,
    encoding: "utf8",
  }).trim();

let release;
try {
  release = validateReleaseTag(tag, packageJson.version);
  validateRevision(revision);
} catch (error) {
  fail(error.message);
}

const versionMatch = versionZig.match(/pub const version = "([^"]+)";/);
if (!versionMatch) fail("src/version.zig does not declare pub const version");
if (versionMatch[1] !== packageJson.version) {
  fail(`src/version.zig ${versionMatch[1]} does not match package.json ${packageJson.version}`);
}

const metadata = { ...release, revision };
if (process.env.GITHUB_OUTPUT) {
  appendFileSync(
    process.env.GITHUB_OUTPUT,
    Object.entries(metadata).map(([key, value]) => `${key}=${value}\n`).join(""),
  );
}
console.log(JSON.stringify(metadata, null, 2));
