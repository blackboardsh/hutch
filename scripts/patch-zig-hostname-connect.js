#!/usr/bin/env node

import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const scriptPath = fileURLToPath(import.meta.url);
const hutchRoot = path.resolve(path.dirname(scriptPath), "..");
const zigVersion = "0.17.0";
const patchPath = path.join(hutchRoot, "patches", "zig-0.17.0-hostname-connect.patch");

export const knownFiles = Object.freeze([
  Object.freeze({
    path: "vendors/zig/lib/std/Io/net/HostName.zig",
    pristineSha256: "af3c45a3357afa0746744d73e891e456cf63c47db38507e8cc0a319698979275",
    patchedSha256: "a4ac2caa2169bb203c89e525f9b0c2f90e2d3803a40d81555c4926291170337f",
  }),
  Object.freeze({
    path: "vendors/zig/lib/std/Io/Threaded.zig",
    pristineSha256: "1a770001e309f24c8c58a9fdb3c095994c454cbfa9dba9d4f1dede2f134eeac7",
    patchedSha256: "1c87690c305e6b31808a9d6fab851a7ba8c3ca2cef2c9967a19cceba4acfc919",
  }),
]);

export function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function runGitApply(args, root, selectedPatchPath) {
  const result = spawnSync("git", [
    "-c",
    "core.autocrlf=false",
    "apply",
    "--unidiff-zero",
    ...args,
    selectedPatchPath,
  ], {
    cwd: root,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    const detail = [result.stdout, result.stderr].filter(Boolean).join("").trim();
    throw new Error(`git apply ${args.join(" ")} failed${detail ? `:\n${detail}` : ""}`);
  }
}

async function readState(root) {
  const stampPath = path.join(root, "vendors", "zig", ".zig-version");
  const installedVersion = (await readFile(stampPath, "utf8")).trim();
  if (installedVersion !== zigVersion) {
    throw new Error(`expected vendored Zig ${zigVersion}, found ${JSON.stringify(installedVersion)}`);
  }

  return Promise.all(knownFiles.map(async (file) => {
    const bytes = await readFile(path.join(root, file.path));
    return { ...file, actualSha256: sha256(bytes) };
  }));
}

function classify(state) {
  if (state.every((file) => file.actualSha256 === file.pristineSha256)) return "pristine";
  if (state.every((file) => file.actualSha256 === file.patchedSha256)) return "patched";

  const detail = state.map((file) =>
    `  ${file.path}\n` +
    `    actual:   ${file.actualSha256}\n` +
    `    pristine: ${file.pristineSha256}\n` +
    `    patched:  ${file.patchedSha256}`,
  ).join("\n");
  throw new Error(`vendored Zig source drift; refusing to apply the hostname-connect patch:\n${detail}`);
}

async function normalizeKnownFileLineEndings(root) {
  await Promise.all(knownFiles.map(async (file) => {
    const filePath = path.join(root, file.path);
    const bytes = await readFile(filePath);
    const normalized = Buffer.from(bytes.toString("utf8").replace(/\r\n/g, "\n"));
    if (!bytes.equals(normalized)) await writeFile(filePath, normalized);
  }));
}

export async function ensureZigHostNameConnectPatch({ checkOnly = false, root = hutchRoot } = {}) {
  const selectedPatchPath = root === hutchRoot ?
    patchPath : path.join(root, "patches", path.basename(patchPath));
  // Git for Windows can honor core.autocrlf while applying a patch to the
  // untracked vendored tree. Canonicalize these known UTF-8 Zig sources so the
  // byte hashes and reverse-check remain identical on every host.
  await normalizeKnownFileLineEndings(root);
  const initialState = await readState(root);
  const initialKind = classify(initialState);

  if (initialKind === "patched") {
    // The hash is the primary proof. Reverse-checking also proves the checked-in
    // patch still describes exactly the installed transformation.
    runGitApply(["--reverse", "--check"], root, selectedPatchPath);
    return { changed: false, state: initialState };
  }
  if (checkOnly) {
    throw new Error("vendored Zig hostname-connect patch is not applied");
  }

  runGitApply(["--check"], root, selectedPatchPath);
  runGitApply([], root, selectedPatchPath);
  await normalizeKnownFileLineEndings(root);

  const finalState = await readState(root);
  if (classify(finalState) !== "patched") throw new Error("hostname-connect patch verification failed");
  return { changed: true, state: finalState };
}

async function main() {
  const args = process.argv.slice(2);
  if (args.some((arg) => arg !== "--check")) {
    throw new Error(`usage: node ${path.relative(hutchRoot, scriptPath)} [--check]`);
  }
  const result = await ensureZigHostNameConnectPatch({ checkOnly: args.includes("--check") });
  const action = result.changed ? "patched" : "verified";
  process.stdout.write(`OK Zig ${zigVersion} HostName.connect ${action}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === scriptPath) {
  main().catch((error) => {
    process.stderr.write(`hutch setup: ${error.message}\n`);
    process.exitCode = 1;
  });
}
