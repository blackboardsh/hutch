import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  compareVersions,
  glibcVersions,
  verifyLinuxGlibc,
} from "./verify-linux-glibc.js";

test("glibc versions are extracted, deduplicated, and numerically sorted", () => {
  const binary = Buffer.from(
    "GLIBC_2.9\0GLIBC_2.35\0GLIBC_2.10\0GLIBC_2.9\0GLIBC_ABI_DT_RELR",
    "latin1",
  );
  assert.deepEqual(glibcVersions(binary), ["2.9", "2.10", "2.35"]);
  assert.equal(compareVersions("2.35", "2.9"), 1);
  assert.equal(compareVersions("2.35.0", "2.35"), 0);
});

test("the verifier rejects an ELF above the configured glibc baseline", () => {
  const directory = mkdtempSync(join(tmpdir(), "hutch-glibc-"));
  const binaryPath = join(directory, "hutch-engine");
  writeFileSync(binaryPath, Buffer.from("GLIBC_2.34\0GLIBC_2.36", "latin1"));

  assert.throws(
    () => verifyLinuxGlibc(binaryPath, "2.35"),
    /requires GLIBC_2\.36, above GLIBC_2\.35/,
  );
});
