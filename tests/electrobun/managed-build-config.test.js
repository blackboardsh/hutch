import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { pathToFileURL } from "node:url";

// Execute the exact helper embedded by native Hutch's loadConfig before build
// metadata and artifacts are prepared. Normalizer-only tests bypass this merge.
const helper = readFileSync(new URL("../../src/electrobun_cli/load_config_helper.js", import.meta.url), "utf8");
function loadBuildConfig(t, config) {
  const directory = mkdtempSync(join(tmpdir(), "hutch-managed-build-config-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const configPath = join(directory, "electrobun.config.mjs");
  const loaderPath = join(directory, "load-config.mjs");
  writeFileSync(configPath, `export default ${JSON.stringify(config)};\n`);
  writeFileSync(loaderPath, helper.replace("__MODULE_NAME__", JSON.stringify(pathToFileURL(configPath).href)));
  const result = spawnSync(process.execPath, [loaderPath], { cwd: directory, encoding: "utf8", timeout: 10_000 });
  assert.equal(result.error, undefined);
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
}

for (const apiUrl of [undefined, "http://127.0.0.1:8765", "https://api.example.test"]) {
  test(`managed build preparation keeps an omitted custom origin absent (${apiUrl || "default API"})`, t => {
    const managed = { appId: "app_build_test", ...(apiUrl ? { apiUrl } : {}) };
    const config = loadBuildConfig(t, {
      app: { name: "ManagedBuild", identifier: "dev.example.managed", version: "1.0.0" },
      build: { mainProcess: "bun" },
      release: { managed, generatePatch: true },
      insights: { ...managed, enabled: true },
    });
    assert.equal(Object.hasOwn(config.release, "baseUrl"), false,
      "Default merging must not invent a custom origin rejected by native artifact preparation");
    assert.deepEqual(config.release.managed, managed);
    assert.deepEqual(config.insights, { ...managed, enabled: true });
    assert.equal(config.release.generatePatch, true);
    assert.equal(config.build.artifactFolder, "artifacts");
  });
}

test("managed build preparation preserves explicitly selected origins for native validation", t => {
  for (const baseUrl of ["https://updates.example.test", "http://127.0.0.1:8765", "", "http://unsafe.example.test", "https://updates.example.test/folder"]) {
    const config = loadBuildConfig(t, { release: { managed: { appId: "app_build_test" }, baseUrl } });
    assert.equal(config.release.baseUrl, baseUrl, "Explicit invalid values must still reach the native validator");
  }
});

test("static-host build preparation retains the existing base URL default and arbitrary hosting folder", t => {
  assert.equal(loadBuildConfig(t, {}).release.baseUrl, "");
  const config = loadBuildConfig(t, { release: { baseUrl: "https://static.example.test/releases/" } });
  assert.equal(config.release.baseUrl, "https://static.example.test/releases/");
  assert.equal(Object.hasOwn(config.release, "managed"), false);
});
