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

test("Hutch uses standalone semantic-version release tags", () => {
  assert.deepEqual(validateReleaseTag("v1.2.3", "1.2.3"), {
    tag: "v1.2.3",
    version: "1.2.3",
    channel: "production",
  });
  assert.throws(() => validateReleaseTag("hutch-v1.2.3", "1.2.3"), /does not match/);
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

test("release jobs build Hutch before integration tests", () => {
  const workflow = readFileSync(
    new URL("../.github/workflows/release.yml", import.meta.url),
    "utf8",
  );
  const build = workflow.indexOf("name: Build Hutch release executables");
  const tests = workflow.indexOf("name: Run Hutch tests");

  assert.ok(build >= 0 && tests >= 0, "build and test steps exist");
  assert.ok(build < tests, "Hutch executables are available to integration tests");
  const serializedTests = /node --test --test-concurrency=1 \\\r?\n/;
  assert.match(workflow, serializedTests);
  assert.match(workflow.replace(/\r?\n/g, "\r\n"), serializedTests);
});

test("Linux ARM releases run on the Cottontail-compatible Ubuntu image", () => {
  const workflow = readFileSync(
    new URL("../.github/workflows/release.yml", import.meta.url),
    "utf8",
  );
  assert.match(workflow, /platform: linux-arm64\s+runner: ubuntu-24\.04-arm/);
});

test("publishing waits for the complete platform matrix", () => {
  const workflow = readFileSync(
    new URL("../.github/workflows/release.yml", import.meta.url),
    "utf8",
  );
  assert.match(workflow, /publish:\s+name: Publish complete release matrix to R2\s+needs: build/);
  assert.match(workflow, /merge-multiple: true/);
  assert.match(workflow, /node scripts\/upload-release-r2\.js --all/);
});
