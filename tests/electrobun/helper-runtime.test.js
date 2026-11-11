import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  constants,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, delimiter, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { runInNewContext } from "node:vm";
import test from "node:test";
import { createCoreFixture, executableName, hostContract, writeFixtureFile } from "./v2-devkit-fixture.js";

const hutchRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const helperRoot = join(hutchRoot, "src", "electrobun_cli");
const hutch = resolve(process.env.HUTCH_LOCAL_TEST_BINARY ?? join(hutchRoot, "zig-out", "bin", executableName("hutch")));
const engine = resolve(process.env.HUTCH_LOCAL_TEST_ENGINE ?? join(hutchRoot, "zig-out", "bin", executableName("hutch-engine")));
const runtimes = {
  bun: process.env.HUTCH_LOCAL_TEST_BUN ?? process.env.HUTCH_BUN_BINARY ?? process.env.BUN_BINARY,
  cottontail: process.env.HUTCH_LOCAL_TEST_COTTONTAIL ?? process.env.COTTONTAIL_BINARY ?? process.env.DASH_COTTONTAIL,
};

// Provision only the runtime requested by a test, using the built engine's
// normal managed store. Default-path assertions below use a fresh offline home.
function runtimeFixture(kind) {
  if (runtimes[kind]) return resolve(runtimes[kind]);
  assert.ok(existsSync(engine), `build the Hutch engine before running this test: ${engine}`);
  const directory = mkdtempSync(join(tmpdir(), "hutch-helper-runtime-"));
  const environment = { ...process.env, HUTCH_ENGINE_BINARY: engine, HUTCH_NO_UPDATE_CHECK: "1" };
  for (const name of ["HUTCH_RUNTIME", "HUTCH_DEFAULT_CLI", "HUTCH_ACTIVE_CHANNEL", "DASH_COTTONTAIL", "COTTONTAIL_BINARY", "DASH_USE_LOCAL_COTTONTAIL", "DASH_LOCAL_COTTONTAIL_ROOT", "COTTONTAIL_ROOT", "DASH_COTTONTAIL_SELECTOR", "DASH_RELEASE_OFFLINE", "BUN_OPTIONS", "NODE_OPTIONS"]) delete environment[name];
  if (kind === "bun") environment.HUTCH_RUNTIME = "bun";
  try {
    const result = spawnSync(engine, kind === "bun" ? ["-p", "process.execPath"] : ["cottontail", "path"], {
      cwd: directory, env: environment, encoding: "utf8", timeout: 180_000,
    });
    expectSuccess(result);
    runtimes[kind] = result.stdout.trim();
    assert.ok(existsSync(runtimes[kind]), `the engine must return an existing ${kind} executable`);
    return resolve(runtimes[kind]);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

function run(runtime, args, directory, environment = {}) {
  const result = spawnSync(runtime, args, {
    cwd: directory,
    env: { ...process.env, ...environment },
    encoding: "utf8",
    timeout: 30_000,
  });
  assert.ifError(result.error);
  return result;
}

function expectSuccess(result) {
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr || result.stdout);
}

function fixture(t) {
  const directory = realpathSync(mkdtempSync(join(tmpdir(), "hutch-electrobun-helper-")));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  return directory;
}

function runtimeIdentity(runtime, directory, kind) {
  const result = run(runtime, ["-e", "console.log(JSON.stringify({bun:process.versions.bun,cottontail:process.versions.cottontail}))"], directory);
  expectSuccess(result);
  const identity = JSON.parse(result.stdout);
  assert.equal(typeof identity.bun, "string");
  if (kind === "bun") assert.equal(identity.cottontail, undefined);
  else assert.equal(typeof identity.cottontail, "string");
  return identity;
}

function checkHelpers(t, runtime, kind) {
  const directory = fixture(t);
  const identity = runtimeIdentity(runtime, directory, kind);
  const config = join(directory, "electrobun.config.ts");
  writeFileSync(config, `
const identity: string = ${JSON.stringify(kind)};
export default {
  app: { name: "Config " + identity },
  observedRuntime: { bun: process.versions.bun, cottontail: process.versions.cottontail },
  observedStartupEnvironment: process.env.HUTCH_HELPER_STARTUP_ENV,
  build: { bun: { entrypoint: "source/main.ts" } },
};
`);
  const configWrapper = join(directory, "config-loader.mjs");
  // Config imports must occur after the launcher restores the environment
  // that user code sees, rather than being hoisted ahead of this prefix.
  writeFileSync(configWrapper, 'process.env.HUTCH_HELPER_STARTUP_ENV = "restored-before-config";\n' +
    readFileSync(join(helperRoot, "load_config_helper.js"), "utf8")
      .replace("__MODULE_NAME__", JSON.stringify(config)));
  const loaded = run(runtime, [configWrapper], directory);
  expectSuccess(loaded);
  const resolved = JSON.parse(loaded.stdout);
  assert.equal(resolved.app.name, `Config ${kind}`);
  assert.equal(resolved.build.mainProcess, "bun", "helper runtime does not select the app main process");
  assert.equal(resolved.build.bun.entrypoint, "source/main.ts");
  assert.deepEqual(resolved.observedRuntime, identity);
  assert.equal(resolved.observedStartupEnvironment, "restored-before-config");

  // Explicit app opt-in remains distinct from the runtime loading its config.
  writeFileSync(config, 'export default { build: { mainProcess: "cottontail", cottontail: { entrypoint: "experimental.ts" } } };');
  const experimental = run(runtime, [configWrapper], directory);
  expectSuccess(experimental);
  assert.equal(JSON.parse(experimental.stdout).build.mainProcess, "cottontail");

  const hook = join(directory, "hook.ts");
  const hookMarker = join(directory, "hook-result.json");
  writeFileSync(hook, `
export default async function hook() {
  await new Promise(resolve => setTimeout(resolve, 5));
  await Bun.write(${JSON.stringify(hookMarker)}, JSON.stringify({
    bun: process.versions.bun, cottontail: process.versions.cottontail,
    environment: process.env.ELECTROBUN_BUILD_ENV,
  }));
}
`);
  const hookWrapper = join(directory, "hook-loader.ts");
  writeFileSync(hookWrapper, readFileSync(join(helperRoot, "run_hook_helper.js"), "utf8")
    .replace('"./__MODULE_NAME__"', JSON.stringify(hook)));
  expectSuccess(run(runtime, [hookWrapper], directory, { ELECTROBUN_BUILD_ENV: "canary" }));
  assert.deepEqual(JSON.parse(readFileSync(hookMarker, "utf8")), { ...identity, environment: "canary" });

  const source = join(directory, "source");
  mkdirSync(source);
  writeFileSync(join(directory, "tsconfig.json"), JSON.stringify({
    compilerOptions: { baseUrl: ".", paths: { "@helper/*": ["source/*"] } },
  }));
  writeFileSync(join(source, "shared.ts"), 'export const marker: string = "bundled-helper-marker";');
  const sdk = join(source, "sdk.ts");
  writeFileSync(sdk, 'export const sdkMarker: string = "manifest-sdk-alias";');
  const entrypoint = join(source, "custom-entry.ts");
  writeFileSync(entrypoint, `
import { marker } from "@helper/shared";
import { marker as prefixMarker } from ${JSON.stringify(kind === "bun" ? "helper-package/shared" : "@helper/shared")};
import { sdkMarker } from "electrobun/main/ui";
import { basename } from ${JSON.stringify(kind === "bun" ? "helper-path" : "node:path")};
console.log(JSON.stringify({ marker, prefixMarker, sdkMarker, name: basename("/fixture/entry"), defined: HELPER_DEFINE }));
`);
  const output = join(directory, "dist", "renamed-main.mjs");
  const spec = join(directory, "build.json");
  const buildHelper = join(helperRoot, "build_helper.js");
  writeFileSync(spec, JSON.stringify({
    entryPoints: [entrypoint], bundle: true, platform: "node", format: "esm",
    outfile: output, sourcemap: "linked", target: ["es2022"],
    define: { HELPER_DEFINE: JSON.stringify("defined-by-build") },
    alias: kind === "bun"
      ? { "helper-package": "./source", "helper-path": "node:path", "electrobun": join(source, "unused-root.ts"), "electrobun/main/ui": sdk }
      : { "electrobun/main/ui": sdk },
  }));
  expectSuccess(run(runtime, [buildHelper, spec], directory));
  const main = run(runtime, [output], directory);
  expectSuccess(main);
  assert.deepEqual(JSON.parse(main.stdout), {
    marker: "bundled-helper-marker", prefixMarker: "bundled-helper-marker", sdkMarker: "manifest-sdk-alias", name: "entry", defined: "defined-by-build",
  });
  const code = readFileSync(output, "utf8");
  const sourceMapName = code.match(/\/\/# sourceMappingURL=([^\r\n]+)/)?.[1];
  assert.equal(sourceMapName, `${basename(output)}.map`);
  const sourceMap = JSON.parse(readFileSync(join(dirname(output), sourceMapName), "utf8"));
  assert.equal(sourceMap.version, 3);
  assert.ok(sourceMap.sources.some(source => source.endsWith("custom-entry.ts")));
  assert.ok(sourceMap.sourcesContent.some(source => source.includes("HELPER_DEFINE")));

  // Browser output must run without Bun, Node globals, or filesystem modules.
  writeFileSync(entrypoint, `
import { marker } from "@helper/shared";
import { sdkMarker } from "electrobun/view";
(globalThis as any).helperResult = { marker, sdkMarker, defined: HELPER_DEFINE };
`);
  const view = join(directory, "dist", "view.js");
  writeFileSync(spec, JSON.stringify({
    entrypoints: [entrypoint], bundle: true, platform: "browser", format: "iife",
    outfile: view, sourcemap: "external", minify: true,
    define: { HELPER_DEFINE: JSON.stringify("browser-build") },
    alias: { "electrobun/view": sdk },
  }));
  expectSuccess(run(runtime, [buildHelper, spec], directory));
  const sandbox = {};
  runInNewContext(readFileSync(view, "utf8"), sandbox);
  assert.equal(sandbox.helperResult.marker, "bundled-helper-marker");
  assert.equal(sandbox.helperResult.sdkMarker, "manifest-sdk-alias");
  assert.equal(sandbox.helperResult.defined, "browser-build");
  assert.ok(existsSync(`${view}.map`));
  assert.equal(JSON.parse(readFileSync(`${view}.map`, "utf8")).version, 3);
}

test("real Bun executes Electrobun config, async hooks, main and browser bundling", { timeout: 300_000 }, t => {
  checkHelpers(t, runtimeFixture("bun"), "bun");
});

test("explicit Cottontail remains compatible with Electrobun helpers", { timeout: 300_000 }, t => {
  checkHelpers(t, runtimeFixture("cottontail"), "cottontail");
});

test("Bun aliases resolve package exports using the bundle target", { timeout: 300_000 }, t => {
  const bun = runtimeFixture("bun");
  const directory = fixture(t);
  const startupLog = join(directory, "startup.log");
  const preload = join(directory, "preload.cjs");
  writeFixtureFile(preload, `require("node:fs").appendFileSync(${JSON.stringify(startupLog)}, "helper startup\\n");`);
  const packageRoot = join(directory, "node_modules", "conditional-target");
  const conditions = Object.fromEntries(["bun", "browser", "node", "default"].map(condition => [condition, `./${condition}.js`]));
  writeFixtureFile(join(packageRoot, "package.json"), JSON.stringify({
    name: "conditional-target", type: "module", exports: { ".": conditions, "./feature": conditions },
  }));
  for (const condition of Object.keys(conditions)) {
    writeFixtureFile(join(packageRoot, `${condition}.js`), `export const selected = ${JSON.stringify(condition)};`);
  }
  const entrypoint = join(directory, "entry.ts");
  writeFixtureFile(entrypoint, `
import { selected as root } from "condition-alias";
import { selected as feature } from "condition-alias/feature";
globalThis.aliasConditions = { root, feature };
`);
  for (const [index, target] of ["browser", "node", "bun"].entries()) {
    const outfile = join(directory, `${target}.js`);
    const spec = join(directory, "build.json");
    writeFixtureFile(spec, JSON.stringify({
      entrypoints: [entrypoint], target, outfile, format: "iife",
      alias: { "condition-alias": "conditional-target" },
    }));
    expectSuccess(run(bun, [join(helperRoot, "build_helper.js"), spec], directory, { BUN_OPTIONS: "--preload=./preload.cjs" }));
    assert.equal(readFileSync(startupLog, "utf8").trim().split("\n").length, index + 1, "resolver probes must not rerun runtime startup preloads");
    const sandbox = {};
    runInNewContext(readFileSync(outfile, "utf8"), sandbox);
    assert.equal(sandbox.aliasConditions.root, target);
    assert.equal(sandbox.aliasConditions.feature, target);
  }
});

test("Bun browser aliases preserve builtin polyfills and disabled packages", { timeout: 300_000 }, t => {
  const bun = runtimeFixture("bun");
  const directory = fixture(t);
  const packageRoot = join(directory, "node_modules", "disabled-target");
  writeFixtureFile(join(packageRoot, "package.json"), JSON.stringify({
    name: "disabled-target", main: "./node.js", browser: { "./node.js": false },
  }));
  writeFixtureFile(join(packageRoot, "node.js"), 'module.exports = { hello: "SHOULD_NOT_LOAD" };');
  const results = [];
  for (const aliases of [false, true]) {
    const builtin = aliases ? "aliased-path" : "node:path";
    const disabled = aliases ? "aliased-disabled" : "disabled-target";
    const entrypoint = join(directory, "entry.ts");
    writeFixtureFile(entrypoint, `
import path, { basename } from ${JSON.stringify(builtin)};
import value, { hello } from ${JSON.stringify(disabled)};
const requiredPath = require(${JSON.stringify(builtin)});
const requiredDisabled = require(${JSON.stringify(disabled)});
globalThis.aliasNonFiles = {
  names: [basename("/a/b"), path.basename("/c/d"), requiredPath.basename("/e/f")],
  disabled: [typeof hello, typeof value, value == null ? null : Object.keys(value).length, typeof requiredDisabled?.hello, requiredDisabled == null ? null : Object.keys(requiredDisabled).length],
};
`);
    const outfile = join(directory, "bundle.js");
    const spec = join(directory, "build.json");
    writeFixtureFile(spec, JSON.stringify({
      entrypoints: [entrypoint], target: "browser", outfile, format: "iife",
      ...(aliases ? { alias: { "aliased-path": "node:path", "aliased-disabled": "disabled-target" } } : {}),
    }));
    expectSuccess(run(bun, [join(helperRoot, "build_helper.js"), spec], directory));
    const sandbox = {};
    const code = readFileSync(outfile, "utf8");
    assert.doesNotMatch(code, /SHOULD_NOT_LOAD/);
    runInNewContext(code, sandbox);
    results.push(JSON.parse(JSON.stringify(sandbox.aliasNonFiles)));
  }
  assert.deepEqual(results[0].names, ["b", "d", "f"]);
  assert.deepEqual(results[1], results[0]);
});

test("Electrobun CLI defaults to Bun for config, hooks and bundles without resolving Cottontail", { timeout: 300_000 }, t => {
  const bun = runtimeFixture("bun");
  const directory = fixture(t);
  const project = join(directory, "project");
  const core = join(directory, "core");
  const home = join(directory, "hutch-home");
  const host = hostContract();
  assert.ok(existsSync(hutch), `build Hutch before running this test: ${hutch}`);
  assert.ok(existsSync(engine), `build the Hutch engine before running this test: ${engine}`);
  const bunProbe = run(bun, ["-e", "console.log(JSON.stringify({executable:process.execPath,version:process.versions.bun}))"], directory);
  expectSuccess(bunProbe);
  const actualBun = JSON.parse(bunProbe.stdout);
  const version = "2.0.0-test.1";
  const manifest = createCoreFixture(core, version, host);
  // Seed the app's pinned managed Bun with the real executable so packaging
  // remains offline and cannot hide eager Cottontail resolution behind a download.
  manifest.toolchains.bun.defaultVersion = actualBun.version;
  const managedBun = join(home, "toolchains", "bun", actualBun.version, host.key);
  mkdirSync(managedBun, { recursive: true });
  copyFileSync(actualBun.executable, join(managedBun, executableName("bun")), constants.COPYFILE_FICLONE);
  writeFixtureFile(join(managedBun, ".hutch-toolchain"), actualBun.version);
  writeFixtureFile(join(core, "native-devkit.json"), JSON.stringify(manifest));
  writeFixtureFile(join(project, "hutch.config.ts"), `export default { electrobun: { version: ${JSON.stringify(version)} } };`);
  writeFixtureFile(join(project, "electrobun.config.ts"), `
import { statSync } from "node:fs";
import { join } from "node:path";
if (!process.versions.bun || process.versions.cottontail) throw new Error("config did not use Bun");
export default {
  app: { name: "BunHelpers", identifier: "dev.hutch.bun-helpers", version: "0.0.0" },
  observed: {
    bun: process.versions.bun, cottontail: process.versions.cottontail,
    argv: process.argv.slice(1), bunOptions: process.env.BUN_OPTIONS,
    execArgv: process.execArgv,
    loaderMode: process.platform === "win32" ? null : statSync(join(process.cwd(), "electrobun-config.loader.mjs")).mode & 0o777,
    nodeOptions: process.env.NODE_OPTIONS, dotenv: process.env.HUTCH_HELPER_DOTENV,
  },
  scripts: { preBuild: "prebuild.ts" },
  build: {
    bun: { entrypoint: "src/main.ts" },
    views: { mainview: { entrypoint: "src/view.ts" } },
    mac: { icons: null, codesign: false, notarize: false, bundleCEF: false, bundleWGPU: false },
    win: { bundleCEF: false, bundleWGPU: false },
    linux: { bundleCEF: false, bundleWGPU: false },
  },
};
`);
  writeFixtureFile(join(project, "prebuild.ts"), `
export default async () => {
  if (!process.versions.bun || process.versions.cottontail) throw new Error("hook did not use Bun");
  await Bun.write("hook-result.json", JSON.stringify({ bun: process.versions.bun, environment: process.env.ELECTROBUN_BUILD_ENV }));
};
`);
  writeFixtureFile(join(project, "src", "main.ts"), 'import { devkitMarker } from "electrobun/main"; console.log(JSON.stringify({ marker: devkitMarker, bun: !!process.versions.bun }));');
  writeFixtureFile(join(project, "src", "view.ts"), 'import { viewMarker } from "electrobun/view"; (globalThis as any).viewMarker = viewMarker;');

  const environment = { ...process.env };
  for (const name of ["HUTCH_RUNTIME", "DASH_COTTONTAIL", "COTTONTAIL_BINARY", "DASH_USE_LOCAL_COTTONTAIL", "DASH_LOCAL_COTTONTAIL_ROOT", "COTTONTAIL_ROOT", "HUTCH_ELECTROBUN_COTTONTAIL_BINARY", "BUN_OPTIONS", "NODE_OPTIONS", "HUTCH_HELPER_DOTENV"]) delete environment[name];
  const pathKey = Object.keys(environment).find(key => key.toLowerCase() === "path") ?? "PATH";
  environment[pathKey] = dirname(actualBun.executable) + delimiter + (environment[pathKey] ?? "");
  Object.assign(environment, {
    HUTCH_HOME: home,
    HUTCH_ENGINE_BINARY: engine,
    HUTCH_ELECTROBUN_DEVKIT_ROOT: core,
    HUTCH_NO_UPDATE_CHECK: "1",
    DASH_RELEASE_OFFLINE: "1",
    // This must remain unused without an explicit Cottontail selection.
    DASH_COTTONTAIL_SELECTOR: "not-a-valid-cottontail-version",
  });
  const command = (args, extra = {}) => spawnSync(hutch, ["electrobun", ...args], {
    cwd: project, env: { ...environment, ...extra }, encoding: "utf8", timeout: 60_000,
  });
  const defaults = command(["config", "--env=dev"]);
  expectSuccess(defaults);
  const defaultConfig = JSON.parse(defaults.stdout);
  assert.equal(defaultConfig.build.mainProcess, "bun");
  assert.equal(defaultConfig.observed.bun, actualBun.version);
  assert.equal(defaultConfig.observed.cottontail, undefined);
  assert.deepEqual(defaultConfig.observed.argv, [join(project, "electrobun.config.ts"), "--env=dev"]);
  assert.deepEqual(defaultConfig.observed.execArgv, []);
  if (process.platform !== "win32") assert.equal(defaultConfig.observed.loaderMode, 0o600);

  const toolsDirectory = join(project, "tools");
  mkdirSync(toolsDirectory);
  copyFileSync(actualBun.executable, join(toolsDirectory, executableName("bun")), constants.COPYFILE_FICLONE);
  const relativePath = spawnSync(engine, ["electrobun", "config", "--env=dev"], {
    cwd: project, env: { ...environment, [pathKey]: "./tools" }, encoding: "utf8", timeout: 60_000,
  });
  expectSuccess(relativePath);
  const relativePathConfig = JSON.parse(relativePath.stdout);
  assert.equal(relativePathConfig.observed.bun, actualBun.version);
  assert.deepEqual(relativePathConfig.observed.argv, defaultConfig.observed.argv);
  assert.deepEqual(relativePathConfig.observed.execArgv, []);
  if (process.platform !== "win32") assert.equal(relativePathConfig.observed.loaderMode, 0o600);

  const sentinel = join(directory, "startup-preload-ran");
  const preload = join(directory, "preload.cjs");
  writeFixtureFile(preload, `require("node:fs").writeFileSync(${JSON.stringify(sentinel)}, JSON.stringify(process.argv));`);
  writeFixtureFile(join(project, "bunfig.toml"), `preload = [${JSON.stringify(preload)}]\n`);
  writeFixtureFile(join(project, ".env"), "HUTCH_HELPER_DOTENV=unexpected\n");
  const startupOptions = { BUN_OPTIONS: `--preload=${JSON.stringify(preload)}`, NODE_OPTIONS: `--require=${JSON.stringify(preload)}` };
  const isolated = command(["config", "--env=canary"], {
    ...startupOptions,
    HUTCH_RUNTIME: "bun",
    COTTONTAIL_BINARY: join(directory, "must-not-resolve-cottontail"),
  });
  expectSuccess(isolated);
  const isolatedConfig = JSON.parse(isolated.stdout);
  assert.equal(existsSync(sentinel), false, "private config loaders must run before ambient preloads");
  assert.equal(isolatedConfig.observed.bunOptions, startupOptions.BUN_OPTIONS);
  assert.equal(isolatedConfig.observed.nodeOptions, startupOptions.NODE_OPTIONS);
  assert.equal(isolatedConfig.observed.dotenv, undefined);
  assert.deepEqual(isolatedConfig.observed.argv, [join(project, "electrobun.config.ts"), "--env=canary"]);
  assert.deepEqual(isolatedConfig.observed.execArgv, []);
  if (process.platform !== "win32") assert.equal(isolatedConfig.observed.loaderMode, 0o600);
  rmSync(join(project, "bunfig.toml"));
  rmSync(join(project, ".env"));

  const build = command(["build", "--env=dev"]);
  expectSuccess(build);
  assert.deepEqual(JSON.parse(readFileSync(join(project, "hook-result.json"), "utf8")), { bun: actualBun.version, environment: "dev" });
  const bundle = join(project, "build", `dev-${host.os}-${host.arch}`);
  const resources = process.platform === "darwin"
    ? join(bundle, "BunHelpers-dev.app", "Contents", "Resources")
    : join(bundle, "BunHelpers-dev", "Resources");
  const main = run(actualBun.executable, [join(resources, "app", "bun", "index.js")], project);
  expectSuccess(main);
  assert.deepEqual(JSON.parse(main.stdout), { marker: "V2_DEVKIT_ALIAS", bun: true });
  const sandbox = {};
  runInNewContext(readFileSync(join(resources, "app", "views", "mainview", "index.js"), "utf8"), sandbox);
  assert.equal(sandbox.viewMarker, "V2_VIEW_ALIAS");
  assert.equal(existsSync(join(home, "releases", "cottontail")), false);

  {
    const cottontail = runtimeFixture("cottontail");
    writeFixtureFile(join(project, "electrobun.config.ts"), `
export default { observed: { cottontail: process.versions.cottontail } };
`);
    const experimental = command(["config"], { HUTCH_RUNTIME: "cottontail", COTTONTAIL_BINARY: resolve(cottontail) });
    expectSuccess(experimental);
    const experimentalConfig = JSON.parse(experimental.stdout);
    assert.equal(typeof experimentalConfig.observed.cottontail, "string");
    assert.equal(experimentalConfig.build.mainProcess, "bun", "explicit helper selection must not change the app runtime");
  }
});
