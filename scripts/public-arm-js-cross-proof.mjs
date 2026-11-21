#!/usr/bin/env node

// Runner-only proof: build real x64 apps with native ARM64 tools, then inspect
// their release archives as data. This script never starts a target executable.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import {
  appendFileSync, closeSync, existsSync, lstatSync, mkdirSync, openSync,
  readFileSync, readdirSync, readSync, realpathSync, rmSync, statSync, writeFileSync,
} from "node:fs";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const repository = dirname(dirname(fileURLToPath(import.meta.url)));
const reports = join(repository, "proof-reports");
mkdirSync(reports, { recursive: true });
const reportPrefix = `${process.platform}-${process.arch}-js-cross`;
const logPath = join(reports, `${reportPrefix}.log`);
const reportPath = join(reports, `${reportPrefix}.json`);
const hutchVersion = "0.31.0-canary.2";
const electrobunVersion = "2.0.7-beta.24";
const applicationVersion = "1.2.3";
const report = {
  schemaVersion: 1, status: "running", startedAt: new Date().toISOString(),
  platform: process.platform, hostArch: process.arch, targetArch: "x64",
  hutchVersion, electrobunVersion, runtimeValidation: false, targetExecution: false,
  limits: ["Build and packaging only", "No target execution", "No CEF or WGPU", "No delta patch", "No code signing"],
  hostTools: [], apps: [],
};
writeFileSync(logPath, "");

function log(message) {
  const text = `${message}\n`;
  process.stdout.write(text);
  appendFileSync(logPath, text);
}
function saveReport() { writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`); }
function json(path) { return JSON.parse(readFileSync(path, "utf8")); }
function requiredAbsolute(name) {
  assert(process.env[name] && isAbsolute(process.env[name]), `${name} must be an absolute path`);
  return resolve(process.env[name]);
}
function within(parent, child) {
  const path = relative(parent, child);
  return path === "" || (!isAbsolute(path) && path !== ".." && !path.startsWith(`..${sep}`));
}
function sha256(path) {
  const file = openSync(path, "r");
  const hash = createHash("sha256");
  const buffer = Buffer.alloc(256 * 1024);
  try {
    for (;;) {
      const count = readSync(file, buffer);
      if (!count) break;
      hash.update(buffer.subarray(0, count));
    }
  } finally { closeSync(file); }
  return hash.digest("hex");
}
function header(path) {
  const file = openSync(path, "r");
  const bytes = Buffer.alloc(Math.min(statSync(path).size, 64 * 1024));
  try { readSync(file, bytes, 0, bytes.length, 0); } finally { closeSync(file); }
  if (bytes.length >= 20 && bytes.subarray(0, 4).equals(Buffer.from([0x7f, 69, 76, 70]))) {
    assert.equal(bytes[4], 2, `Expected ELF64: ${path}`);
    assert.equal(bytes[5], 1, `Expected little-endian ELF: ${path}`);
    const machine = bytes.readUInt16LE(18);
    return { format: "ELF", arch: { 62: "x64", 183: "arm64" }[machine] ?? `machine-${machine}` };
  }
  if (bytes.length >= 64 && bytes.subarray(0, 2).toString("ascii") === "MZ") {
    const offset = bytes.readUInt32LE(60);
    assert(offset <= bytes.length - 6, `PE header outside inspection window: ${path}`);
    assert.equal(bytes.subarray(offset, offset + 4).toString("binary"), "PE\0\0", `Invalid PE: ${path}`);
    const machine = bytes.readUInt16LE(offset + 4);
    return { format: "PE", arch: { 0x8664: "x64", 0xaa64: "arm64" }[machine] ?? `machine-${machine}` };
  }
  return null;
}
function nativeFile(path, expected, label) {
  const actual = header(path);
  assert(actual, `${label} must be a native ELF or PE file: ${path}`);
  assert.equal(actual.arch, expected, `${label} architecture: ${path}`);
  return { label, path, ...actual, size: statSync(path).size, sha256: sha256(path) };
}
function hostTool(path, label) {
  const checked = nativeFile(path, "arm64", label);
  if (!report.hostTools.some(item => item.path === checked.path)) report.hostTools.push(checked);
  return checked;
}
function files(root, boundary = root) {
  const output = [];
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    const path = join(root, entry.name);
    if (entry.isDirectory()) output.push(...files(path, boundary));
    else {
      assert(entry.isFile() || entry.isSymbolicLink(), `Unexpected filesystem entry: ${path}`);
      assert(within(realpathSync(boundary), realpathSync(path)), `File escapes inspected tree: ${path}`);
      assert(statSync(path).isFile(), `Expected regular file: ${path}`);
      output.push(path);
    }
  }
  return output.sort();
}
function targetFiles(root) {
  const inspected = [];
  for (const path of files(root)) {
    const actual = header(path);
    if (actual) {
      assert.equal(actual.arch, "x64", `Target payload has host/foreign native code: ${path}`);
      inspected.push({ path: relative(root, path).split(sep).join("/"), ...actual, size: statSync(path).size, sha256: sha256(path) });
    } else if (/\.(?:exe|dll|node|so(?:\.\d+)*)$/i.test(path)) {
      assert.fail(`Native payload has an unrecognized binary header: ${path}`);
    }
  }
  assert(inspected.length > 0, `No native target payload found: ${root}`);
  return inspected;
}
function compareFile(source, destination) {
  assert.equal(statSync(destination).size, statSync(source).size, `Runtime size differs: ${destination}`);
  assert.equal(sha256(destination), sha256(source), `Runtime bytes differ: ${destination}`);
  return { path: destination, size: statSync(destination).size, sha256: sha256(destination) };
}
function compareTree(source, destination) {
  const expected = files(source).map(path => relative(source, path)).sort();
  const actual = files(destination).map(path => relative(destination, path)).sort();
  assert.deepEqual(actual, expected, `Copied runtime tree differs: ${destination}`);
  return actual.map(path => ({ ...compareFile(join(source, path), join(destination, path)), path: path.split(sep).join("/") }));
}
async function run(executable, args, { cwd, env, timeout = 20 * 60_000 } = {}) {
  hostTool(executable, `executed ${basename(executable)}`);
  log(`Run ${JSON.stringify([executable, ...args])}`);
  return await new Promise((resolvePromise, reject) => {
    const child = spawn(executable, args, { cwd, env, shell: false, windowsHide: true, stdio: ["ignore", "pipe", "pipe"] });
    let output = "";
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; child.kill(); }, timeout);
    function receive(chunk) {
      const text = chunk.toString();
      appendFileSync(logPath, text);
      process.stdout.write(text);
      if (output.length < 2 * 1024 * 1024) output += text;
    }
    child.stdout.on("data", receive);
    child.stderr.on("data", receive);
    child.once("error", error => { clearTimeout(timer); reject(error); });
    child.once("close", (code, signal) => {
      clearTimeout(timer);
      if (timedOut || code !== 0) reject(new Error(`Command failed: ${basename(executable)}, exit=${code}, signal=${signal}, timedOut=${timedOut}`));
      else resolvePromise(output);
    });
  });
}
function releaseRoot(home, product, version, platform) {
  const parent = join(home, "releases", product, version);
  const matches = readdirSync(parent, { withFileTypes: true }).filter(item => item.isDirectory()).map(item => join(parent, item.name, platform)).filter(root => existsSync(join(root, `${product}-release.json`)));
  assert.equal(matches.length, 1, `Expected one exact ${product} ${version} ${platform} release`);
  const metadata = json(join(matches[0], `${product}-release.json`));
  assert.equal(metadata.product, product);
  assert.equal(metadata.version, version);
  assert.equal(metadata.platform, platform);
  assert.match(metadata.revision, /^[0-9a-f]{40}$/);
  return { root: matches[0], metadata };
}

async function main() {
  assert.equal(process.env.GITHUB_ACTIONS, "true", "This proof only runs in GitHub Actions");
  assert.equal(process.arch, "arm64", "Proof requires native ARM64 Node");
  assert(["linux", "win32"].includes(process.platform), "Proof supports Linux and Windows runners");
  const home = requiredAbsolute("HUTCH_HOME");
  const proofRoot = requiredAbsolute("CROSS_PROOF_ROOT");
  const hutch = requiredAbsolute("HUTCH_BINARY");
  const runnerTemp = requiredAbsolute("RUNNER_TEMP");
  assert(within(runnerTemp, home) && within(runnerTemp, proofRoot), "Proof and store must be isolated in RUNNER_TEMP");
  assert(!within(repository, proofRoot) && !within(proofRoot, repository), "Proof apps must be outside the checkout");
  assert(!within(home, proofRoot) && !within(proofRoot, home), "Proof output and managed store must be separate");
  mkdirSync(proofRoot, { recursive: true });
  assert.equal(readdirSync(proofRoot).length, 0, "CROSS_PROOF_ROOT must be empty");
  const os = process.platform === "win32" ? "win" : "linux";
  const storeOs = process.platform === "win32" ? "windows" : "linux";
  const extension = process.platform === "win32" ? ".exe" : "";
  const hostPlatform = `${storeOs}-arm64`;
  const targetPlatform = `${storeOs}-x64`;
  const env = { ...process.env, HUTCH_HOME: home, HUTCH_NO_UPDATE_CHECK: "1", HUTCH_RUNTIME: "bun" };
  // These app/runtime overrides must not hide the published default paths.
  for (const key of ["DASH_HOME", "DASH_COTTONTAIL", "COTTONTAIL_BINARY", "DASH_USE_LOCAL_COTTONTAIL", "HUTCH_ELECTROBUN_COTTONTAIL_BINARY", "HUTCH_ELECTROBUN_BUILD_LOCK", "HUTCH_ENGINE_BINARY", "HUTCH_ELECTROBUN_DEVKIT_ROOT", "HUTCH_ELECTROBUN_HOST_DEVKIT_ROOT", "DASH_RELEASE_OFFLINE", "DASH_ARTIFACTS_BASE_URL", "ELECTROBUN_RELEASES_BASE_URL"]) delete env[key];
  hostTool(process.execPath, "Node runner");
  hostTool(hutch, "Hutch launcher");
  const hutchRelease = releaseRoot(home, "hutch", hutchVersion, hostPlatform);
  const engine = join(hutchRelease.root, "bin", `hutch-engine${extension}`);
  hostTool(engine, "Hutch exact release engine");
  report.hutchRelease = hutchRelease.metadata;
  const versionOutput = await run(hutch, ["--version"], { cwd: proofRoot, env, timeout: 60_000 });
  assert(versionOutput.includes(hutchVersion), "Launcher must select the exact canary release");
  const tar = process.platform === "win32" ? join(requiredAbsolute("SystemRoot"), "System32", "tar.exe") : "/usr/bin/tar";
  hostTool(tar, "System tar");

  for (const mainProcess of ["bun", "cottontail"]) {
    const project = join(proofRoot, mainProcess);
    const name = mainProcess === "bun" ? "CrossBunProof" : "CrossCottontailProof";
    const identifier = `dev.electrobun.public-cross-${mainProcess}`;
    const marker = `public-arm-x64-${mainProcess}-proof`;
    mkdirSync(join(project, "src"), { recursive: true });
    writeFileSync(join(project, "hutch.config.ts"), `// @hutch cli=${hutchVersion}\nexport default { electrobun: { version: ${JSON.stringify(electrobunVersion)} } };\n`);
    const platformBuild = { bundleCEF: false, bundleWGPU: false };
    const config = {
      app: { name, identifier, version: applicationVersion },
      build: {
        ...(mainProcess === "cottontail" ? { mainProcess, cottontail: { entrypoint: "src/main.ts", capabilities: ["compression"] } } : { bun: { entrypoint: "src/main.ts" } }),
        mac: { ...platformBuild, icons: null, codesign: false, notarize: false, createDmg: false },
        win: platformBuild, linux: platformBuild,
      },
      release: { generatePatch: false }, scripts: { preBuild: "capture-host.mjs" },
    };
    writeFileSync(join(project, "electrobun.config.ts"), `export default ${JSON.stringify(config, null, 2)};\n`);
    writeFileSync(join(project, "src", "main.ts"), `${mainProcess === "cottontail" ? 'import { gzipSync } from "node:zlib";\n' : ""}const marker: string = ${JSON.stringify(marker)};\nconsole.log(marker${mainProcess === "cottontail" ? ', gzipSync(new Uint8Array([1, 2, 3])).length' : ""});\n`);
    writeFileSync(join(project, "capture-host.mjs"), 'import { writeFileSync } from "node:fs";\nwriteFileSync("host-tool-proof.json", JSON.stringify({ host: process.arch, platform: process.platform, executable: process.execPath, bun: process.versions.bun, target: process.env.ELECTROBUN_ARCH, hostDeclared: process.env.ELECTROBUN_HOST_ARCH }));\n');
    log(`Build ${mainProcess} application with native ARM64 helpers for x64`);
    await run(hutch, ["electrobun", "build", "--env=canary", "--arch=x64"], { cwd: project, env });
    const helper = json(join(project, "host-tool-proof.json"));
    assert.equal(helper.host, "arm64");
    assert.equal(helper.hostDeclared, "arm64");
    assert.equal(helper.target, "x64");
    assert.equal(helper.platform, process.platform);
    assert(helper.bun, "The default helper must be Bun");
    hostTool(helper.executable, "Bun config/build/hook helper");

    const hostSdk = join(home, "releases", "electrobun", electrobunVersion, hostPlatform);
    const targetSdk = join(home, "releases", "electrobun", electrobunVersion, targetPlatform);
    const hostManifest = json(join(hostSdk, "native-devkit.json"));
    const targetManifest = json(join(targetSdk, "native-devkit.json"));
    assert.deepEqual(hostManifest.target, { os, arch: "arm64" });
    assert.deepEqual(targetManifest.target, { os, arch: "x64" });
    assert.equal(targetManifest.product.version, electrobunVersion);
    assert.equal(hostManifest.product.version, electrobunVersion);
    assert.equal(targetManifest.layout.runtime.bun, undefined, "Exercise separately resolved target Bun, not legacy embedded runtime");
    const projection = json(join(project, ".hutch", "devkit", "projection.json"));
    assert.deepEqual(projection.target, { os, arch: "x64" });
    assert.equal(projection.sourceManifestSha256, sha256(join(targetSdk, "native-devkit.json")));
    const zstd = join(hostSdk, hostManifest.layout.runtime.zigZstd);
    hostTool(zstd, "SDK compressor/decompressor");
    hostTool(join(hostSdk, hostManifest.layout.runtime.bsdiff), "SDK delta tool");

    const prefix = `canary-${os}-x64`;
    const update = json(join(project, "artifacts", `${prefix}-update.json`));
    const checksum = json(join(project, "artifacts", `${prefix}-checksum.json`));
    assert.equal(update.identifier, identifier);
    assert.equal(update.channel, "canary");
    assert.equal(update.version, applicationVersion);
    assert.equal(update.platform, os);
    assert.equal(update.arch, "x64");
    assert.equal(update.hash, checksum.hash);
    assert.equal(basename(update.artifact.file), update.artifact.file);
    assert(update.artifact.file.startsWith(`${prefix}-`) && update.artifact.file.endsWith(".tar.zst"));
    const archive = join(project, "artifacts", update.artifact.file);
    const tarPath = join(project, "inspected.tar");
    await run(zstd, ["decompress", "-i", archive, "-o", tarPath], { cwd: project, env });
    assert.equal(statSync(tarPath).size, checksum.tarSize);
    assert.equal(sha256(tarPath), checksum.tarSha256);
    const unpacked = join(project, "unpacked");
    mkdirSync(unpacked);
    await run(tar, ["-xf", tarPath, "-C", unpacked], { cwd: project, env });
    const bundle = join(unpacked, `${name}-canary`);
    const execDirectory = join(bundle, "bin");
    const resources = join(bundle, "Resources");
    const build = json(join(resources, "build.json"));
    const version = json(join(resources, "version.json"));
    assert.equal(build.mainProcess, mainProcess);
    assert.equal(build.electrobunVersion, electrobunVersion);
    assert.equal(build.buildEnvironment, "canary");
    assert.equal(build.runtimeVersions[mainProcess], targetManifest.toolchains[mainProcess].defaultVersion);
    assert.equal(version.hash, update.hash);
    assert.equal(version.identifier, identifier);
    assert(readFileSync(join(resources, "app", "bun", "index.js"), "utf8").includes(marker));
    const appReport = {
      mainProcess, identifier, runtimeValidation: false, targetExecution: false, helper, update, checksum, build,
      sdk: { hostRoot: hostSdk, targetRoot: targetSdk, targetManifestSha256: projection.sourceManifestSha256 },
      archive: { name: update.artifact.file, size: statSync(archive).size, sha256: sha256(archive) },
      targetNativeFiles: targetFiles(bundle),
      outerNativeFiles: targetFiles(join(project, "build", prefix)),
      artifacts: readdirSync(join(project, "artifacts")).sort().map(name => ({
        name, size: statSync(join(project, "artifacts", name)).size,
        sha256: sha256(join(project, "artifacts", name)),
      })),
      copiedRuntime: {},
    };
    for (const key of ["launcher", "coreLibrary", "nativeWrapper", "asarLibrary", "bspatch", "zigZstd"]) {
      const source = join(targetSdk, targetManifest.layout.runtime[key]);
      compareFile(source, join(execDirectory, basename(source)));
    }
    if (mainProcess === "bun") {
      const pin = targetManifest.toolchains.bun.defaultVersion;
      const sourceRoot = join(home, "toolchains", "bun", pin, targetPlatform);
      const source = join(sourceRoot, `bun${extension}`);
      const targetMetadata = json(join(sourceRoot, ".hutch-bun-target.json"));
      assert.equal(targetMetadata.version, pin);
      assert.equal(targetMetadata.platform, targetPlatform);
      assert.equal(sha256(source), targetMetadata.binarySha256);
      appReport.copiedRuntime = { sourceMetadata: targetMetadata, binary: compareFile(source, join(execDirectory, `bun${extension}`)) };
    } else {
      const pin = targetManifest.toolchains.cottontail.defaultVersion;
      const runtime = releaseRoot(home, "cottontail", pin, targetPlatform);
      const sourceBin = join(runtime.root, "bin");
      const copied = {
        release: runtime.metadata,
        archiveSha256: readFileSync(join(runtime.root, ".dash-installed"), "utf8").trim(),
        binary: compareFile(join(sourceBin, `cottontail${extension}`), join(execDirectory, `cottontail${extension}`)),
        core: compareTree(join(sourceBin, "cottontail-core"), join(execDirectory, "cottontail-core")),
        capabilities: {},
      };
      assert.match(copied.archiveSha256, /^[0-9a-f]{64}$/);
      const stdlib = join(execDirectory, "cottontail-stdlib");
      const capabilities = readdirSync(stdlib).filter(name => lstatSync(join(stdlib, name)).isDirectory());
      assert(capabilities.includes("compression"), "Proof must include a native capability");
      for (const capability of capabilities) copied.capabilities[capability] = compareTree(join(sourceBin, "cottontail-stdlib", capability), join(stdlib, capability));
      assert(targetFiles(join(stdlib, "compression")).length > 0, "Compression capability must include native target code");
      appReport.copiedRuntime = copied;
    }
    report.apps.push(appReport);
    saveReport();
    log(`Verified ${mainProcess}: ${appReport.targetNativeFiles.length} x64 native files; tar ${checksum.tarSize} bytes, SHA256 ${checksum.tarSha256}`);
    // Reports preserve the evidence. Do not retain duplicate runtime bundles
    // or large app archives on these deliberately small proof runners.
    rmSync(project, { recursive: true, force: true });
  }
  report.status = "passed";
}

try { await main(); } catch (error) {
  report.status = "failed";
  report.error = error.stack ?? String(error);
  log(report.error);
  process.exitCode = 1;
} finally {
  report.finishedAt = new Date().toISOString();
  saveReport();
}
