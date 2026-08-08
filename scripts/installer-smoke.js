#!/usr/bin/env node

import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import {
  createReadStream,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const hutchRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const packageJson = JSON.parse(readFileSync(join(hutchRoot, "package.json"), "utf8"));
const platform = {
  "darwin-arm64": "macos-arm64",
  "linux-x64": "linux-x64",
  "linux-arm64": "linux-arm64",
  "win32-x64": "windows-x64",
}[`${process.platform}-${process.arch}`];
assert(platform, `unsupported installer smoke platform: ${process.platform}-${process.arch}`);

const artifactBase = `hutch-v${packageJson.version}-${platform}`;
const archivePath = join(hutchRoot, "release", `${artifactBase}.tar.gz`);
const metadata = JSON.parse(execFileSync(
  "tar",
  ["-xOzf", archivePath, `${artifactBase}/hutch-release.json`],
  { encoding: "utf8" },
));
const channel = metadata.channel;
assert(
  channel === "production" || channel === "canary",
  `invalid release channel: ${channel}`,
);
const archiveBytes = readFileSync(archivePath);
const archiveSha256 = createHash("sha256").update(archiveBytes).digest("hex");
const temporary = mkdtempSync(join(tmpdir(), "hutch-installer-smoke-"));
const dashHome = join(temporary, "home");
const shellHome = join(temporary, "shell-home");
const stableAliasHome = join(temporary, "stable-alias-home");

const server = createServer((request, response) => {
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  const bodies = {
    [`/hutch/channels/${channel}.json`]: {
      schema: 1,
      kind: "channel",
      product: "hutch",
      channel,
      version: metadata.version,
      revision: metadata.revision,
      release: {
        url: `${baseUrl}/hutch/releases/${metadata.version}/manifest.json`,
      },
    },
    [`/hutch/releases/${metadata.version}/manifest.json`]: {
      schema: 1,
      kind: "release",
      product: "hutch",
      channel,
      version: metadata.version,
      revision: metadata.revision,
      platforms: {
        [platform]: {
          archive: {
            url: `${baseUrl}/hutch/builds/${metadata.revision}/${platform}/hutch.tar.gz`,
            sha256: archiveSha256,
            size: statSync(archivePath).size,
          },
        },
      },
    },
    [`/hutch/builds/${metadata.revision}/manifest.json`]: {
      schema: 1,
      kind: "build",
      product: "hutch",
      version: metadata.version,
      revision: metadata.revision,
      platforms: {
        [platform]: {
          archive: {
            url: `${baseUrl}/hutch/builds/${metadata.revision}/${platform}/hutch.tar.gz`,
            sha256: archiveSha256,
            size: statSync(archivePath).size,
          },
        },
      },
    },
  };

  // A stable request must use the production channel endpoint. The installer
  // contract is independent of whether this smoke test was built from a
  // production or canary release artifact.
  bodies["/hutch/channels/production.json"] = {
    schema: 1,
    kind: "channel",
    product: "hutch",
    channel: "production",
    version: metadata.version,
    revision: metadata.revision,
    release: {
      url: `${baseUrl}/hutch/releases/${metadata.version}/manifest.json`,
    },
  };

  if (request.url in bodies) {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(`${JSON.stringify(bodies[request.url], null, 2)}\n`);
    return;
  }
  if (request.url?.endsWith("/hutch.tar.gz")) {
    response.writeHead(200, {
      "content-type": "application/gzip",
      "content-length": archiveBytes.length,
    });
    createReadStream(archivePath).pipe(response);
    return;
  }
  response.writeHead(404);
  response.end("not found");
});

function run(command, args, env = process.env) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { env, stdio: "inherit" });
    child.on("error", reject);
    child.on("exit", (code, signal) => {
      if (code === 0) resolve();
      else reject(new Error(`${basename(command)} exited ${code ?? signal}`));
    });
  });
}

function runCapture(command, args, options) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd,
      env: options.env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8").on("data", (chunk) => { stdout += chunk; });
    child.stderr.setEncoding("utf8").on("data", (chunk) => { stderr += chunk; });
    child.on("error", reject);
    child.on("exit", (code, signal) => {
      if (code === 0) resolve({ stdout, stderr });
      else reject(new Error(`hutch exited ${code ?? signal}\n${stderr || stdout}`));
    });
  });
}

function assertActiveInstall() {
  const installedRoot = join(
    dashHome,
    "products",
    "hutch",
    metadata.version,
    metadata.revision,
    platform,
  );
  const engine = join(
    installedRoot,
    "bin",
    process.platform === "win32" ? "hutch-engine.exe" : "hutch-engine",
  );
  const expected = engine;
  const actual = execFileSync(engine, ["self", "path", channel], {
    encoding: "utf8",
    env: {
      ...process.env,
      DASH_HOME: dashHome,
      HUTCH_ACTIVE_CHANNEL: channel,
      DASH_RELEASE_OFFLINE: "1",
    },
  }).trim();
  assert.equal(actual, expected);
}

try {
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const baseUrl = `http://127.0.0.1:${server.address().port}`;

  if (process.platform === "win32") {
    await run("powershell.exe", [
      "-NoLogo",
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      join(hutchRoot, "scripts", "install.ps1"),
      "-Channel",
      channel,
      "-DashHome",
      dashHome,
      "-ArtifactsBaseUrl",
      baseUrl,
    ]);
    assertActiveInstall();
    const commandName = channel === "canary" ? "hutch-canary.exe" : "hutch.exe";
    const output = execFileSync(
      join(dashHome, "bin", commandName),
      ["--version"],
      {
        encoding: "utf8",
        env: { ...process.env, DASH_HOME: dashHome },
      },
    ).trim();
    assert.equal(output, metadata.version);

    await run("powershell.exe", [
      "-NoLogo",
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      join(hutchRoot, "scripts", "install.ps1"),
      "-Channel",
      "stable",
      "-DashHome",
      stableAliasHome,
      "-ArtifactsBaseUrl",
      baseUrl,
    ]);
  } else {
    mkdirSync(shellHome, { recursive: true });
    const installerEnvironment = {
      ...process.env,
      DASH_ARTIFACTS_BASE_URL: baseUrl,
      HOME: shellHome,
      SHELL: "/bin/zsh",
    };
    await run("sh", [
      join(hutchRoot, "scripts", "install.sh"),
      "--channel",
      channel,
      "--dash-home",
      dashHome,
    ], installerEnvironment);
    await run("sh", [
      join(hutchRoot, "scripts", "install.sh"),
      "--channel",
      channel,
      "--dash-home",
      dashHome,
    ], installerEnvironment);
    const pathLine = `export PATH='${join(dashHome, "bin")}':"$PATH"`;
    const shellProfile = readFileSync(join(shellHome, ".zshrc"), "utf8");
    assert.equal(
      shellProfile.split(pathLine).length - 1,
      1,
      "installer must add the Hutch PATH entry exactly once",
    );
    assertActiveInstall();
    const commandName = channel === "canary" ? "hutch-canary" : "hutch";
    const output = execFileSync(
      join(dashHome, "bin", commandName),
      ["--version"],
      {
        encoding: "utf8",
        env: { ...process.env, DASH_HOME: dashHome },
      },
    ).trim();
    assert.equal(output, metadata.version);

    await run("sh", [
      join(hutchRoot, "scripts", "install.sh"),
      "--channel",
      "stable",
      "--dash-home",
      stableAliasHome,
      "--no-modify-path",
    ], installerEnvironment);
  }

  const productionPointer = join(
    stableAliasHome,
    "channels",
    "hutch",
    "production",
  );
  assert(existsSync(productionPointer));
  assert(!existsSync(join(stableAliasHome, "channels", "hutch", "stable")));
  const stableCommand = join(
    stableAliasHome,
    "bin",
    process.platform === "win32" ? "hutch.exe" : "hutch",
  );
  assert(existsSync(stableCommand));
  if (metadata.channel === "production") {
    const stableInstallRoot = readFileSync(productionPointer, "utf8").trim();
    const stableEngine = join(
      stableInstallRoot,
      "bin",
      process.platform === "win32" ? "hutch-engine.exe" : "hutch-engine",
    );
    assert.equal(
      execFileSync(stableEngine, ["self", "path", "stable"], {
        encoding: "utf8",
        env: {
          ...process.env,
          DASH_HOME: stableAliasHome,
          DASH_RELEASE_OFFLINE: "1",
          HUTCH_ACTIVE_CHANNEL: "stable",
        },
      }).trim(),
      stableEngine,
    );
  }

  const pinProject = join(temporary, "pinned-project");
  const pinHome = join(temporary, "pin-home");
  mkdirSync(pinProject, { recursive: true });
  writeFileSync(
    join(pinProject, "hutch.config.ts"),
    `// @dash cli=build:${metadata.revision}\nexport default {};\n`,
  );
  const builtLauncher = join(
    hutchRoot,
    "zig-out",
    "bin",
    process.platform === "win32" ? "hutch.exe" : "hutch",
  );
  const pinned = await runCapture(builtLauncher, ["--version"], {
    cwd: pinProject,
    env: {
      ...process.env,
      DASH_HOME: pinHome,
      HUTCH_ACTIVE_CHANNEL: "production",
      DASH_ARTIFACTS_BASE_URL: baseUrl,
      HUTCH_NO_UPDATE_CHECK: "1",
    },
  });
  assert.equal(pinned.stdout.trim(), metadata.version);
  assert(
    pinned.stderr.includes(`downloading hutch ${metadata.version}`),
    pinned.stderr,
  );
  console.log(`Hutch installer smoke passed for ${platform}`);
} finally {
  await new Promise((resolve) => server.close(resolve));
  rmSync(temporary, { recursive: true, force: true });
}
