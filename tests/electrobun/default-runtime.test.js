import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
import test from "node:test";

const helper = readFileSync(new URL("../../src/electrobun_cli/load_config_helper.js", import.meta.url), "utf8")
  .replace("import * as loadedConfigModule from __MODULE_NAME__;", "");
function load(config) {
  let result;
  runInNewContext(helper, { loadedConfigModule: { default: config }, console: {
    log(value) { result = JSON.parse(value); },
  } });
  return result;
}
test("omitted runtime resolves to Bun and retains custom Bun settings", () => {
  assert.equal(load({}).build.mainProcess, "bun");
  assert.equal(load({ build: {} }).build.mainProcess, "bun");
  assert.equal(load({ build: {bun: {entrypoint:"bun.ts"}, cottontail: {entrypoint:"experimental.ts"}} }).build.bun.entrypoint, "bun.ts");
  assert.equal(load({ build: { bun: { entrypoint: "src/custom.ts", minify: true } } }).build.bun.entrypoint, "src/custom.ts");
});
test("explicit experimental Cottontail and native backends remain selectable", () => {
  for (const mainProcess of ["bun", "cottontail", "zig", "rust", "go", "odin"]) {
    assert.equal(load({ build: { mainProcess } }).build.mainProcess, mainProcess);
  }
});
test("legacy implicit Cottontail settings require an explicit migration", () => {
  for (const key of ["cottontail", "main"]) {
    assert.throws(() => load({ build: { [key]: { entrypoint: "custom.ts" } } }), /Bun is now the default/);
  }
});
