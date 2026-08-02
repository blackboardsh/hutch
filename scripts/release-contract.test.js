import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  buildArchiveKey,
  createBuildManifest,
  createChannelManifest,
  createReleaseManifest,
  installerKey,
  releaseChannel,
  validateReleaseTag,
} from "./release-contract.js";
import "./x64-baseline-release.test.js";

const revision = "0123456789abcdef0123456789abcdef01234567";
const artifacts = [
  "macos-arm64",
  "linux-x64",
  "linux-arm64",
  "windows-x64",
].map((platform, index) => ({
  platform,
  sha256: String(index + 1).repeat(64),
  size: index + 1,
}));
const options = {
  product: "hutch",
  version: "1.2.3-canary.4",
  revision,
  publishedAt: "2026-07-25T12:00:00.000Z",
  publicBaseUrl: "https://artifacts.example.test",
  artifacts,
};

test("production and canary versions select separate targets", () => {
  assert.equal(releaseChannel("1.2.3"), "production");
  assert.equal(releaseChannel("1.2.3-canary.4"), "canary");
});

test("Hutch tags are product-scoped in the monorepo", () => {
  assert.deepEqual(validateReleaseTag("hutch-v1.2.3", "1.2.3"), {
    tag: "hutch-v1.2.3",
    version: "1.2.3",
    channel: "production",
  });
  assert.throws(() => validateReleaseTag("v1.2.3", "1.2.3"), /does not match/);
});

test("installers remain inside the Hutch bucket prefix", () => {
  assert.equal(installerKey("hutch", "install.sh"), "hutch/install.sh");
  assert.equal(installerKey("hutch", "install.ps1"), "hutch/install.ps1");
  assert.throws(() => installerKey("hutch", "../install.sh"), /Unsupported installer/);
});

test("build and release manifests reference one archive copy", () => {
  const build = createBuildManifest(options);
  const release = createReleaseManifest(options);
  const channel = createChannelManifest(options);
  const expected = `${options.publicBaseUrl}/${buildArchiveKey("hutch", revision, "linux-x64")}`;
  assert.equal(build.platforms["linux-x64"].archive.url, expected);
  assert.equal(release.platforms["linux-x64"].archive.url, expected);
  assert.equal(channel.channel, "canary");
});

test("complete platform matrices are required", () => {
  assert.throws(
    () => createBuildManifest({ ...options, artifacts: artifacts.slice(1) }),
    /missing macos-arm64/,
  );
});

test("Unix release jobs build Hutch before integration tests", () => {
  const config = readFileSync(
    new URL("../../.circleci/config.yml", import.meta.url),
    "utf8",
  );
  const start = config.indexOf("  build_hutch_unix:");
  const end = config.indexOf("\njobs:", start);
  const command = config.slice(start, end);
  const build = command.indexOf("name: Build Hutch release executables");
  const tests = command.indexOf("name: Run Hutch tests");

  assert.ok(start >= 0 && end > start, "build_hutch_unix command exists");
  assert.ok(build >= 0 && tests >= 0, "build and test steps exist");
  assert.ok(build < tests, "Hutch executables are available to integration tests");
  const serializedTests = /node --test --test-concurrency=1 \\\r?\n/;
  assert.match(command, serializedTests);
  assert.match(command.replace(/\r?\n/g, "\r\n"), serializedTests);
});

test("Linux ARM releases run on the Cottontail-compatible Ubuntu image", () => {
  const config = readFileSync(
    new URL("../../.circleci/config.yml", import.meta.url),
    "utf8",
  );
  const start = config.indexOf("  build-hutch-linux-arm64:");
  const end = config.indexOf("\n  build-hutch-macos-arm64:", start);
  const job = config.slice(start, end);

  assert.ok(start >= 0 && end > start, "Linux ARM release job exists");
  assert.match(job, /image: ubuntu-2404:current/);
  assert.match(job, /resource_class: arm\.medium/);
});
