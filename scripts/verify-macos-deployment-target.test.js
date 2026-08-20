import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  compareVersions,
  deploymentTargets,
  verifyOtoolOutput,
} from "./verify-macos-deployment-target.js";

const releaseWorkflow = readFileSync(
  new URL("../.github/workflows/release.yml", import.meta.url),
  "utf8",
);

const modernOutput = `
Load command 8
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform MACOS
    minos 14.0
      sdk 26.0
   ntools 1
`;

test("otool deployment targets are parsed and compared numerically", () => {
  const legacyOutput = `
Load command 4
      cmd LC_VERSION_MIN_MACOSX
  cmdsize 16
  version 10.13
      sdk 14.5
`;

  assert.deepEqual(deploymentTargets(`${modernOutput}\n${legacyOutput}`), [
    "14.0",
    "10.13",
  ]);
  assert.equal(compareVersions("14.0", "13.6.9"), 1);
  assert.equal(compareVersions("14.0.0", "14"), 0);
});

test("the verifier rejects a deployment target above macOS 14", () => {
  assert.equal(verifyOtoolOutput("hutch", modernOutput, "14.0"), "14.0");
  assert.throws(
    () => verifyOtoolOutput("hutch", modernOutput.replace("14.0", "14.8.3"), "14.0"),
    /requires macOS 14\.8\.3, above macOS 14\.0/,
  );
  assert.throws(
    () => verifyOtoolOutput("hutch", "not a Mach-O load-command listing", "14.0"),
    /does not declare a macOS deployment target/,
  );
});

test("macOS releases use and verify the supported deployment target", () => {
  assert.match(
    releaseWorkflow,
    /platform: macos-arm64\s+runner: macos-26\s+os: macos\s+target: aarch64-macos\.14\.0/,
  );
  assert.match(
    releaseWorkflow,
    /verify-macos-deployment-target\.js zig-out\/bin\/hutch 14\.0/,
  );
  assert.match(
    releaseWorkflow,
    /verify-macos-deployment-target\.js zig-out\/bin\/hutch-engine 14\.0/,
  );
});

test("release CI runs the built-in package-manager E2E suite", () => {
	assert.match(
		releaseWorkflow,
		/if \[\[ '\$\{\{ matrix\.platform \}\}' == 'linux-x64' \]\]; then[\s\S]*?run-local-package-manager-tests\.js --all/,
	);
});
