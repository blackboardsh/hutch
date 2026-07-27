import assert from "node:assert/strict";
import test from "node:test";

import {
  buildArchiveKey,
  createBuildManifest,
  createChannelManifest,
  createReleaseManifest,
  releaseChannel,
  validateReleaseTag,
} from "./release-contract.js";

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
