import assert from "node:assert/strict";
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  ensureZigHostNameConnectPatch,
  knownFiles,
  sha256,
} from "./patch-zig-hostname-connect.js";

const scriptsDir = path.dirname(fileURLToPath(import.meta.url));
const hutchRoot = path.resolve(scriptsDir, "..");
const patchName = "zig-0.16.0-hostname-connect.patch";

async function makePatchedFixture(t) {
  const root = await mkdtemp(path.join(tmpdir(), "hutch-zig-connect-patch-"));
  t.after(() => rm(root, { force: true, recursive: true }));

  await mkdir(path.join(root, "vendors", "zig"), { recursive: true });
  await mkdir(path.join(root, "patches"), { recursive: true });
  await writeFile(path.join(root, "vendors", "zig", ".zig-version"), "0.16.0\n");
  await copyFile(path.join(hutchRoot, "patches", patchName), path.join(root, "patches", patchName));
  for (const file of knownFiles) {
    const destination = path.join(root, file.path);
    await mkdir(path.dirname(destination), { recursive: true });
    await copyFile(path.join(hutchRoot, file.path), destination);
  }
  return root;
}

async function expectHashes(root, field) {
  for (const file of knownFiles) {
    const actual = sha256(await readFile(path.join(root, file.path)));
    assert.equal(actual, file[field], `${file.path} ${field}`);
  }
}

test("Zig HostName.connect patch is deterministic and idempotent", async (t) => {
  const root = await makePatchedFixture(t);

  const alreadyPatched = await ensureZigHostNameConnectPatch({ root });
  assert.equal(alreadyPatched.changed, false);
  await expectHashes(root, "patchedSha256");

  const { spawnSync } = await import("node:child_process");
  const reversed = spawnSync(
    "git",
    ["apply", "--unidiff-zero", "--reverse", path.join(root, "patches", patchName)],
    { cwd: root, encoding: "utf8" },
  );
  assert.equal(reversed.status, 0, reversed.stderr);
  await expectHashes(root, "pristineSha256");

  const applied = await ensureZigHostNameConnectPatch({ root });
  assert.equal(applied.changed, true);
  await expectHashes(root, "patchedSha256");

  const verified = await ensureZigHostNameConnectPatch({ root, checkOnly: true });
  assert.equal(verified.changed, false);
});

test("Zig HostName.connect patch refuses source drift", async (t) => {
  const root = await makePatchedFixture(t);
  const target = path.join(root, knownFiles[0].path);
  const source = await readFile(target, "utf8");
  await writeFile(target, source.replace("const connect_worker_count = 4;", "const connect_worker_count = 5;"));

  await assert.rejects(
    ensureZigHostNameConnectPatch({ root }),
    /vendored Zig source drift/,
  );
});

test("setup always verifies the patch after vendoring", async () => {
  const setup = await readFile(path.join(scriptsDir, "setup.sh"), "utf8");
  assert.match(setup, /vendor_zig\s+node "\$SCRIPT_DIR\/patch-zig-hostname-connect\.js"/);
});

test("workflow Zig cache keys include every patch input", async () => {
  const hashFiles = /hashFiles\('scripts\/setup\.sh', 'scripts\/patch-zig-hostname-connect\.js', 'patches\/zig-0\.16\.0-hostname-connect\.patch'\)/g;
  const compatWorkflow = await readFile(path.join(hutchRoot, ".github", "workflows", "bun-compat.yml"), "utf8");
  const releaseWorkflow = await readFile(path.join(hutchRoot, ".github", "workflows", "release.yml"), "utf8");
  assert.equal(compatWorkflow.match(hashFiles)?.length, 2);
  assert.equal(releaseWorkflow.match(hashFiles)?.length, 1);
});
