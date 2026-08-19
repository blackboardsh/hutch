#!/usr/bin/env node
// Live validation of the vendored bun toolchain on the current OS. Unlike the
// hermetic suites, this intentionally reaches bun's upstream releases: it
// shadows any system bun with a version-mismatched stub, runs `hutch pm
// --version` in a config-free directory, and requires Hutch to download the
// default bun into a scratch HUTCH_HOME and execute it. Run it on each release
// platform before shipping a bun default bump: `hutch run smoke:bun-toolchain`
// (needs a built zig-out; no tooling beyond Hutch itself).

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const hutchRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const platformKey = {
  "darwin-arm64": "macos-arm64",
  "darwin-x64": "macos-x64",
  "linux-x64": "linux-x64",
  "linux-arm64": "linux-arm64",
  "win32-x64": "windows-x64",
}[`${process.platform}-${process.arch}`];
assert(platformKey, `unsupported bun toolchain smoke platform: ${process.platform}-${process.arch}`);

const executableName = (name) => (process.platform === "win32" ? `${name}.exe` : name);
const hutch = join(hutchRoot, "zig-out", "bin", executableName("hutch"));
const engine = join(hutchRoot, "zig-out", "bin", executableName("hutch-engine"));
assert(existsSync(hutch), `Hutch must be built before this smoke: ${hutch}`);
assert(existsSync(engine), `Hutch engine must be built before this smoke: ${engine}`);

// The expected version is the constant the engine was compiled with.
const toolchainSource = readFileSync(join(hutchRoot, "src", "toolchain_store.zig"), "utf8");
const pinned = toolchainSource.match(/default_bun_version = "([^"]+)"/)?.[1];
assert(pinned, "could not read default_bun_version from src/toolchain_store.zig");

const fixture = mkdtempSync(join(tmpdir(), "hutch-bun-toolchain-smoke-"));
try {
  const home = join(fixture, "home");
  const project = join(fixture, "empty-project");
  const shadowBin = join(fixture, "shadow-bin");
  mkdirSync(project, { recursive: true });
  mkdirSync(shadowBin, { recursive: true });

  // A PATH bun that can never satisfy the pin, so resolution must download.
  if (process.platform === "win32") {
    writeFileSync(join(shadowBin, "bun.cmd"), "@echo 0.0.1-smoke-stub\r\n");
  } else {
    writeFileSync(join(shadowBin, "bun"), "#!/bin/sh\necho 0.0.1-smoke-stub\n");
    chmodSync(join(shadowBin, "bun"), 0o755);
  }

  const env = {
    ...process.env,
    HUTCH_HOME: home,
    HUTCH_ENGINE_BINARY: engine,
    HUTCH_NO_UPDATE_CHECK: "1",
  };
  const pathKey = Object.keys(env).find((key) => key.toLowerCase() === "path") ?? "PATH";
  env[pathKey] = `${shadowBin}${delimiter}${env[pathKey] ?? ""}`;

  const result = spawnSync(hutch, ["pm", "--version"], {
    cwd: project,
    encoding: "utf8",
    env,
    timeout: 300_000,
  });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.equal(
    result.stdout.trim(),
    pinned,
    `hutch pm --version must answer with the vendored bun, received: ${JSON.stringify(result.stdout)}`,
  );

  const managed = join(home, "toolchains", "bun", pinned, platformKey, executableName("bun"));
  assert(existsSync(managed), `expected the managed bun install: ${managed}`);
  const marker = readFileSync(join(dirname(managed), ".hutch-toolchain"), "utf8").trim();
  assert.equal(marker, pinned);

  // A second run must reuse the install (still under the shadowed PATH).
  const reused = spawnSync(hutch, ["pm", "--version"], {
    cwd: project,
    encoding: "utf8",
    env,
    timeout: 60_000,
  });
  assert.equal(reused.status, 0, reused.stderr || reused.stdout);
  assert.equal(reused.stdout.trim(), pinned);

  console.log(`OK bun ${pinned} vendored from upstream for ${platformKey}`);
  console.log(`OK managed install reused at ${managed}`);
} finally {
  rmSync(fixture, { recursive: true, force: true });
}
