const semverPattern = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/;
const revisionPattern = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/;

export const RELEASE_SCHEMA = 1;
export const RELEASE_PLATFORMS = [
  "macos-arm64",
  "linux-x64",
  "linux-arm64",
  "windows-x64",
];

export function parseSemver(version) {
  if (typeof version !== "string") return null;
  const match = version.match(semverPattern);
  if (!match) return null;
  return {
    version,
    core: [Number(match[1]), Number(match[2]), Number(match[3])],
    prerelease: match[4]?.split(".") ?? [],
  };
}

export function releaseChannel(version) {
  const parsed = parseSemver(version);
  if (!parsed) throw new Error(`Invalid semantic version: ${version}`);
  return parsed.prerelease.length === 0 ? "production" : "canary";
}

export function validateReleaseTag(tag, version) {
  releaseChannel(version);
  const expected = `hutch-v${version}`;
  if (tag !== expected) {
    throw new Error(`Release tag ${JSON.stringify(tag)} does not match ${expected}`);
  }
  return { tag, version, channel: releaseChannel(version) };
}

export function validateRevision(revision) {
  if (!revisionPattern.test(revision)) {
    throw new Error(`Expected a full Git revision, received ${JSON.stringify(revision)}`);
  }
  return revision;
}

export function buildArchiveKey(product, revision, platform) {
  validateRevision(revision);
  if (!RELEASE_PLATFORMS.includes(platform)) {
    throw new Error(`Unsupported release platform: ${platform}`);
  }
  return `${product}/builds/${revision}/${platform}/${product}.tar.gz`;
}

export function buildManifestKey(product, revision) {
  validateRevision(revision);
  return `${product}/builds/${revision}/manifest.json`;
}

export function releaseManifestKey(product, version) {
  releaseChannel(version);
  return `${product}/releases/${version}/manifest.json`;
}

export function channelManifestKey(product, channel) {
  if (channel !== "production" && channel !== "canary") {
    throw new Error(`Unsupported release channel: ${channel}`);
  }
  return `${product}/channels/${channel}.json`;
}

function platformManifest({ product, revision, publicBaseUrl, artifacts }) {
  const byPlatform = new Map(artifacts.map((artifact) => [artifact.platform, artifact]));
  const missing = RELEASE_PLATFORMS.filter((platform) => !byPlatform.has(platform));
  if (missing.length > 0 || byPlatform.size !== artifacts.length) {
    throw new Error(
      `Invalid release artifact matrix: ${missing.length ? `missing ${missing.join(", ")}` : "duplicate platforms"}`,
    );
  }

  return Object.fromEntries(RELEASE_PLATFORMS.map((platform) => {
    const artifact = byPlatform.get(platform);
    if (!/^[0-9a-f]{64}$/.test(artifact.sha256)) {
      throw new Error(`Invalid SHA-256 for ${platform}`);
    }
    if (!Number.isSafeInteger(artifact.size) || artifact.size <= 0) {
      throw new Error(`Invalid archive size for ${platform}`);
    }
    return [platform, {
      archive: {
        url: `${publicBaseUrl.replace(/\/+$/, "")}/${buildArchiveKey(product, revision, platform)}`,
        sha256: artifact.sha256,
        size: artifact.size,
      },
    }];
  }));
}

export function createBuildManifest(options) {
  releaseChannel(options.version);
  validateRevision(options.revision);
  return {
    schema: RELEASE_SCHEMA,
    kind: "build",
    product: options.product,
    version: options.version,
    revision: options.revision,
    publishedAt: options.publishedAt,
    platforms: platformManifest(options),
  };
}

export function createReleaseManifest(options) {
  const channel = releaseChannel(options.version);
  validateRevision(options.revision);
  return {
    schema: RELEASE_SCHEMA,
    kind: "release",
    product: options.product,
    channel,
    version: options.version,
    revision: options.revision,
    publishedAt: options.publishedAt,
    build: {
      url: `${options.publicBaseUrl.replace(/\/+$/, "")}/${buildManifestKey(options.product, options.revision)}`,
    },
    platforms: platformManifest(options),
  };
}

export function createChannelManifest(options) {
  const channel = releaseChannel(options.version);
  validateRevision(options.revision);
  return {
    schema: RELEASE_SCHEMA,
    kind: "channel",
    product: options.product,
    channel,
    version: options.version,
    revision: options.revision,
    updatedAt: options.publishedAt,
    release: {
      url: `${options.publicBaseUrl.replace(/\/+$/, "")}/${releaseManifestKey(options.product, options.version)}`,
    },
  };
}
