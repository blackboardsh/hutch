import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const nativeArm64 = process.platform === "win32" && process.arch === "arm64";

test("Windows ARM64 installer chooses the requested release's available architecture", {
  skip: !nativeArm64,
  timeout: 120_000,
}, async (t) => {
  const temporary = mkdtempSync(join(tmpdir(), "hutch-installer-architecture-"));
  let platforms;
  let requestedArchives;
  const server = createServer((request, response) => {
    const base = `http://127.0.0.1:${server.address().port}`;
    if (request.url.startsWith("/hutch/channels/")) {
      response.setHeader("content-type", "application/json");
      response.end(JSON.stringify({ release: { url: `${base}/manifest.json` } }));
    } else if (request.url === "/manifest.json") {
      response.setHeader("content-type", "application/json");
      response.end(JSON.stringify({ version: "9.0.0", revision: "a".repeat(40), platforms: platforms(base) }));
    } else {
      requestedArchives.push(request.url);
      // Stop before extraction: this test exercises real CPU detection and
      // manifest selection without installing a fabricated release binary.
      response.writeHead(404);
      response.end("architecture selection probe");
    }
  });
  try {
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", resolve);
    });
    const archive = (base, architecture) => ({ archive: {
      url: `${base}/${architecture}/hutch.tar.gz`, sha256: "b".repeat(64), size: 1,
    } });
    for (const fixture of [
      { name: "native canary is preferred", channel: "canary", entries: base => ({ "windows-arm64": archive(base, "arm64"), "windows-x64": archive(base, "x64") }), expected: ["/arm64/hutch.tar.gz"] },
      { name: "x64-only production keeps working under emulation", channel: "production", entries: base => ({ "windows-x64": archive(base, "x64") }), expected: ["/x64/hutch.tar.gz"] },
      { name: "incomplete native artifacts fail without downgrading", channel: "canary", entries: base => ({ "windows-arm64": {}, "windows-x64": archive(base, "x64") }), expected: [] },
      { name: "missing Windows artifacts fail before downloading", channel: "production", entries: () => ({}), expected: [] },
    ]) {
      await t.test(fixture.name, async () => {
        platforms = fixture.entries;
        requestedArchives = [];
        const result = await new Promise((resolve, reject) => {
          const child = spawn("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", join(root, "scripts", "install.ps1"),
            "-Channel", fixture.channel, "-HutchHome", join(temporary, "home"), "-NoModifyPath",
            "-ArtifactsBaseUrl", `http://127.0.0.1:${server.address().port}`], { windowsHide: true, timeout: 30_000 });
          let output = "";
          child.stdout.on("data", data => { output += data; });
          child.stderr.on("data", data => { output += data; });
          child.once("error", reject);
          child.once("exit", code => resolve({ code, output }));
        });
        assert.notEqual(result.code, 0, result.output);
        assert.deepEqual(requestedArchives, fixture.expected, result.output);
        assert.match(result.output, fixture.expected.length ? /404/ : /release manifest is incomplete/);
      });
    }
  } finally {
    await new Promise(resolve => server.close(resolve));
    rmSync(temporary, { recursive: true, force: true });
  }
});
