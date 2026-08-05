import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import test from "node:test";

const root = new URL("..", import.meta.url);
const workflowPath = new URL("../.github/workflows/bun-compat.yml", import.meta.url);
const cottontailManifestPath = new URL(
  "../compat/upstream/cottontail.json",
  import.meta.url,
);
const cottontailSetupPath = new URL("./setup-upstream-cottontail.js", import.meta.url);
const suiteManifestPath = new URL(
  "../compat/upstream/bun/v1.3.10/manifest.json",
  import.meta.url,
);
const workflow = readFileSync(workflowPath, "utf8").replace(/\r\n/g, "\n");
const cottontailManifest = JSON.parse(readFileSync(cottontailManifestPath, "utf8"));
const cottontailSetup = readFileSync(cottontailSetupPath, "utf8").replace(/\r\n/g, "\n");
const suiteManifest = JSON.parse(readFileSync(suiteManifestPath, "utf8"));

function workflowTriggers(source) {
  const end = source.indexOf("\npermissions:");
  assert.notEqual(end, -1, "workflow must declare permissions after its triggers");
  return source.slice(0, end);
}

test("runs only for compat branches and manual dispatch", () => {
  const triggers = workflowTriggers(workflow);
  assert.match(
    triggers,
    /^on:\n  push:\n    branches:\n      - "compat\/\*\*"\n  workflow_dispatch:\s*$/m,
  );
  assert.doesNotMatch(triggers, /\btags:|\bpull_request:|\bschedule:/);
});

test("builds Hutch and runs the complete owned corpus without publishing", () => {
  for (const platform of ["macos-arm64", "linux-x64", "linux-arm64", "windows-x64"]) {
    assert.match(workflow, new RegExp(`platform: ${platform}`));
  }
  assert.match(workflow, /runner: macos-26/);
  assert.match(workflow, /runner: ubuntu-24\.04/);
  assert.match(workflow, /runner: ubuntu-24\.04-arm/);
  assert.match(workflow, /runner: windows-2025/);
  assert.match(workflow, /fail-fast: false/);
  assert.match(
    workflow,
    /run: \.\/vendors\/zig\/zig build -Doptimize=ReleaseSmall -Dcpu=baseline/,
  );
  assert.match(
    workflow,
    /zig\.exe build -Doptimize=ReleaseSmall -Dtarget=x86_64-windows-msvc -Dcpu=baseline/,
  );
  assert.match(workflow, /HUTCH_COMPAT_COTTONTAIL: \$\{\{ steps\.cottontail\.outputs\.binary \}\}/);
  assert.match(workflow, /run: node scripts\/run-bun-package-manager-tests\.js --all/);
  assert.match(workflow, /run: node scripts\/run-bun-package-manager-tests\.js --check/);
  assert.doesNotMatch(
    workflow,
    /continue-on-error:|upload-artifact|upload-release-r2|publish|secrets\.|pull_request:/i,
  );

  const checkOutput = execFileSync(
    process.execPath,
    ["scripts/run-bun-package-manager-tests.js", "--check"],
    { cwd: root, encoding: "utf8" },
  );
  assert.match(
    checkOutput,
    new RegExp(
      `Hutch Bun package-manager compatibility: ${suiteManifest.ownedRunnableFiles}/` +
        `${suiteManifest.canonicalRunnableFiles} canonical files owned by Hutch`,
    ),
  );
  assert.match(checkOutput, /ownership and copied-inventory checks passed/);
});

test("builds an exact Cottontail source revision", () => {
  assert.equal(cottontailManifest.schema, 1);
  assert.equal(cottontailManifest.bunCompatibilityVersion, suiteManifest.version);
  assert.match(
    cottontailManifest.repository,
    /^https:\/\/github\.com\/[^/]+\/cottontail\.git$/,
  );
  assert.match(cottontailManifest.commit, /^[0-9a-f]{40}$/);

  assert.match(
    workflow,
    /cottontail="\$\(node scripts\/setup-upstream-cottontail\.js\)"/,
  );
  assert.match(
    workflow,
    /hashFiles\('compat\/upstream\/cottontail\.json', 'scripts\/setup-upstream-cottontail\.js'\)/,
  );
  assert.match(cottontailSetup, /git", \["fetch", "--quiet", "--depth", "1", "origin", manifest\.commit\]/);
  assert.match(cottontailSetup, /checkedOutCommit !== manifest\.commit/);
  assert.match(cottontailSetup, /"scripts\/setup\.js"/);
  assert.match(cottontailSetup, /"scripts\/setup-zig-html-rewriter\.js"/);
  assert.match(cottontailSetup, /"scripts\/setup-jsc\.js"/);
  assert.match(cottontailSetup, /"-Doptimize=ReleaseSmall"/);
  assert.match(cottontailSetup, /process\.platform === "win32" \? \["-Dtarget=x86_64-windows-msvc"\] : \[\]/);
  assert.match(cottontailSetup, /"-Dcpu=baseline"/);
  assert.doesNotMatch(cottontailSetup, /command -v|which\(|["']PATH["']/);
});
