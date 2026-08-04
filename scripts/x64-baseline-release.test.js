import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const buildConfig = readFileSync(new URL("../build.zig", import.meta.url), "utf8");
const releaseWorkflow = readFileSync(
  new URL("../.github/workflows/release.yml", import.meta.url),
  "utf8",
);

test("Hutch defaults to a baseline CPU model", () => {
  assert.match(
    buildConfig,
    /default_target\s*=\s*\.\{\s*\.cpu_model\s*=\s*\.baseline\s*\}/,
  );
});

test("every Hutch release build explicitly targets the baseline CPU", () => {
  const releaseCommands = releaseWorkflow.match(
    /[^\r\n]*zig(?:\.exe)?\s+build\s+-Doptimize=ReleaseSmall[^\r\n]*/g,
  ) ?? [];

  assert.equal(releaseCommands.length, 2, releaseCommands.join("\n"));
  for (const command of releaseCommands) {
    assert.match(command, /(?:^|\s)-Dcpu=baseline(?:\s|$)/);
    assert.doesNotMatch(command, /(?:^|\s)-Dcpu=native(?:\s|$)/);
  }

  const windowsCommand = releaseCommands.find((command) => command.includes("zig.exe"));
  assert.ok(windowsCommand);
  assert.match(windowsCommand, /-Dtarget=x86_64-windows-msvc/);
});

test("Linux Hutch releases target the Electrobun glibc baseline", () => {
  assert.match(
    releaseWorkflow,
    /platform: linux-x64\s+runner: ubuntu-24\.04\s+os: linux\s+target: x86_64-linux-gnu\.2\.35/,
  );
  assert.match(
    releaseWorkflow,
    /platform: linux-arm64\s+runner: ubuntu-24\.04-arm\s+os: linux\s+target: aarch64-linux-gnu\.2\.35/,
  );
  assert.match(
    releaseWorkflow,
    /target_arg=\("-Dtarget=\$target"\)/,
  );
  assert.match(
    releaseWorkflow,
    /verify-linux-glibc\.js zig-out\/bin\/hutch-engine 2\.35/,
  );
});
