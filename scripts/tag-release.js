#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline/promises";
import { fileURLToPath } from "node:url";

import {
  compareReleaseVersions,
  isReleaseVersionForMode,
  parseReleaseVersion,
  suggestReleaseVersion,
} from "./release-version.js";

const hutchRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const repositoryRoot = hutchRoot;
const packageJsonPath = join(hutchRoot, "package.json");
const versionZigPath = join(hutchRoot, "src", "version.zig");
const dashConfigPath = join(hutchRoot, "dash.config.ts");
const tagPrefix = "v";

function fail(message) {
  console.error(`hutch release: ${message}`);
  process.exit(1);
}

function git(args, options = {}) {
  const output = execFileSync("git", args, {
    cwd: repositoryRoot,
    encoding: "utf8",
    stdio: options.inherit ? "inherit" : ["ignore", "pipe", "pipe"],
  });
  return typeof output === "string" ? output.trim() : "";
}

function updateDashPin(path, field, version) {
  const source = readFileSync(path, "utf8");
  const pattern = new RegExp(`^(// @dash .*\\b${field}=)[^\\s]+`, "m");
  const updated = source.replace(pattern, (_, prefix) => `${prefix}${version}`);
  if (updated === source) fail(`could not update ${field} in ${path}`);
  writeFileSync(path, updated);
}

if (process.argv.includes("--help")) {
  console.log("Usage: node scripts/tag-release.js [canary|production]");
  console.log("Prompt for a Hutch semantic version, then commit, tag, and atomically push it.");
  process.exit(0);
}
const mode = process.argv[2] ?? "manual";
if (!["canary", "production", "manual"].includes(mode)) {
  fail(`expected canary or production, received ${JSON.stringify(mode)}`);
}
if (git(["branch", "--show-current"]) !== "main") {
  fail("releases must be created from main");
}
if (git(["status", "--porcelain"])) {
  fail("the working tree must be clean before creating a release");
}

git(["fetch", "origin", "main", "--tags", "--prune"], { inherit: true });
const [aheadText, behindText] = git([
  "rev-list",
  "--left-right",
  "--count",
  "HEAD...origin/main",
]).split(/\s+/);
if (Number(behindText) > 0) fail("main is behind origin/main");

const versions = git(["tag", "--list", `${tagPrefix}*`])
  .split("\n")
  .filter(Boolean)
  .map((tag) => ({ tag, version: parseReleaseVersion(tag.slice(tagPrefix.length)) }))
  .filter((entry) => entry.version)
  .sort((left, right) => compareReleaseVersions(right.version, left.version));
const targetVersions = versions.filter((entry) =>
  isReleaseVersionForMode(mode, entry.version)
);
const latest = targetVersions[0] ?? null;
const packageJson = JSON.parse(readFileSync(packageJsonPath, "utf8"));
const current = parseReleaseVersion(packageJson.version);
if (!current) fail(`package.json contains an invalid version: ${packageJson.version}`);
const suggested = suggestReleaseVersion(
  mode,
  current.version,
  latest?.version.version,
);

console.log(`Latest Hutch ${mode} tag: ${latest?.tag ?? "(none)"}`);
console.log(`Package version:     ${tagPrefix}${packageJson.version}`);
if (Number(aheadText) > 0) console.log(`Local main:           ${aheadText} unpushed commit(s)`);

const prompt = createInterface({ input: process.stdin, output: process.stdout });
const label = mode === "manual" ? "release" : mode;
const response = await prompt.question(`New ${label} semantic version [${suggested}]: `);
const answer = (response.trim() || suggested).replace(/^v/, "");
const next = parseReleaseVersion(answer);
if (!next) {
  prompt.close();
  fail(`${JSON.stringify(answer)} is not a valid semantic version`);
}
if (!isReleaseVersionForMode(mode, next)) {
  prompt.close();
  fail(`${tagPrefix}${answer} is not a ${mode} release version`);
}
if (latest && compareReleaseVersions(next, latest.version) <= 0) {
  prompt.close();
  fail(`${tagPrefix}${answer} must be newer than ${latest.tag}`);
}
const tag = `${tagPrefix}${answer}`;
if (versions.some((entry) => entry.tag === tag)) {
  prompt.close();
  fail(`${tag} already exists`);
}

const confirmation = (await prompt.question(`Create and push ${tag}? [y/N] `)).trim().toLowerCase();
prompt.close();
if (confirmation !== "y" && confirmation !== "yes") {
  console.log("Release cancelled; no files were changed.");
  process.exit(0);
}

packageJson.version = answer;
writeFileSync(packageJsonPath, `${JSON.stringify(packageJson, null, 2)}\n`);
const versionZig = readFileSync(versionZigPath, "utf8");
const updatedVersionZig = versionZig.replace(
  /pub const version = "[^"]+";/,
  `pub const version = "${answer}";`,
);
if (updatedVersionZig === versionZig) fail("could not update src/version.zig");
writeFileSync(versionZigPath, updatedVersionZig);
updateDashPin(dashConfigPath, "cli", answer);

git([
  "add",
  "package.json",
  "src/version.zig",
  "dash.config.ts",
], { inherit: true });
git(["commit", "-m", tag], { inherit: true });
git(["tag", "--annotate", tag, "--message", tag], { inherit: true });
git(["push", "--atomic", "origin", "HEAD:main", `refs/tags/${tag}`], { inherit: true });

console.log(`${tag} was pushed. GitHub Actions will publish its complete matrix.`);
