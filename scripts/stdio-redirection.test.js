import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { closeSync, mkdtempSync, openSync, readFileSync, rmSync, writeSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
// Run the built engine directly so a project/global launcher pin cannot select
// a different published implementation while this fixture uses a temp cwd.
const binary = resolve(process.env.HUTCH_TEST_BINARY || join(root, "zig-out/bin", process.platform === "win32" ? "hutch-engine.exe" : "hutch-engine"));

for (const { name, args, stream, status, marker } of [
  { name: "native CLI stdout", args: ["--version"], stream: 1, status: 0, marker: /\d+\.\d+\.\d+/ },
  { name: "Electrobun stdout", args: ["electrobun", "--help"], stream: 1, status: 0, marker: /electrobun/i },
  { name: "Electrobun stderr", args: ["electrobun", "invalid-stdio-fixture-command"], stream: 2, status: 1, marker: /invalid-stdio-fixture-command/ },
]) {
  test(`${name} preserves inherited regular-file offsets`, () => {
    const directory = mkdtempSync(join(tmpdir(), "hutch-stdio-"));
    try {
      const piped = spawnSync(binary, args, { cwd: directory, encoding: "utf8", timeout: 30_000 });
      assert.ifError(piped.error);
      assert.equal(piped.status, status, piped.stderr || piped.stdout);
      const expected = stream === 1 ? piped.stdout : piped.stderr;
      assert.match(expected, marker);
      const output = join(directory, "redirected.log");
      const fd = openSync(output, "w", 0o600);
      let redirected;
      try {
        writeSync(fd, "parent-before\n");
        const stdio = ["ignore", "pipe", "pipe"];
        stdio[stream] = fd;
        redirected = spawnSync(binary, args, { cwd: directory, stdio, encoding: "utf8", timeout: 30_000 });
        writeSync(fd, "parent-after\n");
      } finally {
        closeSync(fd);
      }
      assert.ifError(redirected.error);
      assert.equal(redirected.status, status);
      assert.equal(readFileSync(output, "utf8"), `parent-before\n${expected}parent-after\n`);
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });
}
