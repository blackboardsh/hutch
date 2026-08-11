import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
} from "node:fs";
import os from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import {
  createCoreFixture,
  executableName,
  hostContract,
  writeFixtureFile,
} from "./v2-devkit-fixture.js";

const hutchRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

function resolveCottontail() {
  const configured = process.env.COTTONTAIL_BINARY ?? process.env.DASH_COTTONTAIL;
  if (configured) return resolve(configured);
  const hutch = join(hutchRoot, "zig-out", "bin", executableName("hutch"));
  const result = spawnSync(hutch, ["cottontail", "path", "production"], {
    cwd: hutchRoot,
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  return result.stdout.trim();
}

function resourcesRoot(project, host) {
  const bundle = join(project, "build", `dev-${host.os}-${host.arch}`);
  if (process.platform === "darwin") {
    return join(bundle, "SdkSubpaths-dev.app", "Contents", "Resources");
  }
  return join(bundle, "SdkSubpaths-dev", "Resources");
}

test("package-free builds resolve every JavaScript SDK subpath from the devkit manifest", { timeout: 120_000 }, () => {
  const fixture = mkdtempSync(join(os.tmpdir(), "hutch-js-sdk-subpaths-"));
  const project = join(fixture, "project");
  const coreRoot = join(fixture, "core");
  const dashHome = join(fixture, "dash-home");
  const host = hostContract();
  const version = "2.0.0-test.1";
  const hutch = join(hutchRoot, "zig-out", "bin", executableName("hutch"));
  const engine = join(hutchRoot, "zig-out", "bin", executableName("hutch-engine"));
  const cottontail = resolveCottontail();

  try {
    assert.ok(existsSync(hutch), `Hutch must be built before this test: ${hutch}`);
    assert.ok(existsSync(engine), `Hutch engine must be built before this test: ${engine}`);

    const manifest = createCoreFixture(coreRoot, version, host);
    manifest.layout.sdks.javascript.exports["./main/ui"] = "api/sdks/main/entries/ui.ts";
    manifest.layout.sdks.javascript.exports["./browser/ui"] = "api/browser/ui/index.ts";
    writeFixtureFile(
      join(coreRoot, "api", "sdks", "main", "entries", "ui.ts"),
      "export const mainUiMarker = 'V2_MAIN_UI_SUBPATH';\n",
    );
    writeFixtureFile(
      join(coreRoot, "api", "browser", "ui", "index.ts"),
      "export const browserUiMarker = 'V2_BROWSER_UI_SUBPATH';\n",
    );
    writeFixtureFile(join(coreRoot, "native-devkit.json"), `${JSON.stringify(manifest, null, 2)}\n`);

    writeFixtureFile(
      join(project, "src", "bun", "index.ts"),
      "import { mainUiMarker } from 'electrobun/main/ui';\nconsole.log(mainUiMarker);\n",
    );
    writeFixtureFile(
      join(project, "src", "mainview", "index.ts"),
      "import { browserUiMarker } from 'electrobun/browser/ui';\nconsole.log(browserUiMarker);\n",
    );
    writeFixtureFile(join(project, "electrobun.config.ts"), `
import { existsSync } from "node:fs";
if (!process.env.HUTCH_EXPECT_PROJECT_SDK || !existsSync(process.env.HUTCH_EXPECT_PROJECT_SDK)) {
  throw new Error("project devkit was not projected before electrobun.config.ts loaded");
}
export default {
  app: { name: "SdkSubpaths", identifier: "dev.electrobun.sdk-subpaths", version: "0.0.0" },
  build: {
    mainProcess: "cottontail",
    cottontail: { entrypoint: "src/bun/index.ts" },
    views: { mainview: { entrypoint: "src/mainview/index.ts" } },
    mac: { icons: null, codesign: false, notarize: false, bundleCEF: false, bundleWGPU: false },
    win: { bundleCEF: false, bundleWGPU: false },
    linux: { bundleCEF: false, bundleWGPU: false },
  },
};
`);
    writeFixtureFile(
      join(project, "hutch.config.ts"),
      `export default { electrobun: { version: "${version}" } };\n`,
    );

    assert.equal(existsSync(join(project, "package.json")), false);
    assert.equal(existsSync(join(project, "node_modules")), false);

    const build = spawnSync(hutch, ["electrobun", "build", "--env=dev"], {
      cwd: project,
      encoding: "utf8",
      env: {
        ...process.env,
        COTTONTAIL_BINARY: cottontail,
        DASH_COTTONTAIL: cottontail,
        DASH_HOME: dashHome,
        HUTCH_ELECTROBUN_DEVKIT_ROOT: coreRoot,
        HUTCH_ENGINE_BINARY: engine,
        HUTCH_EXPECT_PROJECT_SDK: join(project, ".hutch", "devkit", "api", "sdks", "main", "entries", "ui.ts"),
        HUTCH_NO_UPDATE_CHECK: "1",
      },
    });
    assert.equal(build.status, 0, build.stderr || build.stdout);

    const resources = resourcesRoot(project, host);
    const mainBundle = readFileSync(join(resources, "app", "bun", "index.js"), "utf8");
    const viewBundle = readFileSync(join(resources, "app", "views", "mainview", "index.js"), "utf8");
    assert.match(mainBundle, /V2_MAIN_UI_SUBPATH/);
    assert.match(viewBundle, /V2_BROWSER_UI_SUBPATH/);
    assert.doesNotMatch(mainBundle, /electrobun\/main\/ui/);
    assert.doesNotMatch(viewBundle, /electrobun\/browser\/ui/);
    assert.equal(existsSync(join(project, "package.json")), false);
    assert.equal(existsSync(join(project, "node_modules")), false);
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
});
