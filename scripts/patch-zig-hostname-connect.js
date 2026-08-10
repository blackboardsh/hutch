#!/usr/bin/env node

import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const scriptPath = fileURLToPath(import.meta.url);
const hutchRoot = path.resolve(path.dirname(scriptPath), "..");
const zigVersion = "0.16.0";
const patchPath = path.join(hutchRoot, "patches", "zig-0.16.0-hostname-connect.patch");

export const knownFiles = Object.freeze([
  Object.freeze({
    path: "vendors/zig/lib/std/Io/net/HostName.zig",
    pristineSha256: "ec7ba989492b0f0e227faf468b7f8ade808ba51c34ccddf971959e289d58c27a",
    patchedSha256: "f481a322a39e131951f55f526fe879ac3f999a7101bb86db82ce47c5bcd6fff4",
  }),
  Object.freeze({
    path: "vendors/zig/lib/std/Io/Threaded.zig",
    pristineSha256: "eb7bbb4ddf590ec3d0d2a1ee5c3845ef4984d9e440965a3e7c920cd0c906df94",
    patchedSha256: "c4c97fbd8ba658fd9f68a978d519d15bbe9f7d02d8f6a2809652e8696581505e",
  }),
]);

export function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function runGitApply(args, root, selectedPatchPath) {
  const result = spawnSync("git", ["apply", "--unidiff-zero", ...args, selectedPatchPath], {
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

export async function ensureZigHostNameConnectPatch({ checkOnly = false, root = hutchRoot } = {}) {
  const selectedPatchPath = root === hutchRoot ?
    patchPath : path.join(root, "patches", path.basename(patchPath));
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
