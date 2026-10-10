import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import test from "node:test";

const setup = readFileSync(new URL("./setup.sh", import.meta.url), "utf8");
const definitions = setup.slice(setup.indexOf("host_arch()"), setup.indexOf("vendor_zig()"));
for (const [name, os, machine, native, processArch, expected] of [
  ["native Windows ARM64", "MINGW64_NT", "aarch64", "", "ARM64", "aarch64"],
  ["x64 Git Bash on Windows ARM64", "MINGW64_NT", "x86_64", "ARM64", "AMD64", "aarch64"],
  ["MSYS reports the native ARM64 OS with an x64 process environment", "MSYS_NT-10.0-26200-ARM64", "x86_64", "", "AMD64", "aarch64"],
  ["Windows x64", "MINGW64_NT", "x86_64", "", "AMD64", "x86_64"],
  ["Linux ARM64 ignores Windows environment", "Linux", "aarch64", "AMD64", "AMD64", "aarch64"],
  ["macOS ARM64", "Darwin", "arm64", "", "", "aarch64"],
  ["Linux x64", "Linux", "x86_64", "", "", "x86_64"],
]) {
  test(name, () => {
    const result = spawnSync("bash", ["-c", `${definitions}
uname() { if [[ "$1" == "-s" ]]; then printf '%s' '${os}'; else printf '%s' '${machine}'; fi; }
PROCESSOR_ARCHITEW6432='${native}'
PROCESSOR_ARCHITECTURE='${processArch}'
host_arch
`], {
      encoding: "utf8", windowsHide: true, timeout: 10_000,
      env: { ...process.env, PROCESSOR_ARCHITEW6432: native, PROCESSOR_ARCHITECTURE: processArch },
    });
    assert.ifError(result.error);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim(), expected);
  });
}
test("vendored compiler cache distinguishes same-version host architectures", () => {
  assert.match(setup, /local platform="\$os-\$arch"/);
  assert.match(setup, /platform_stamp="\$zig_dir\/\.zig-platform"/);
  assert.match(setup, /"\$platform_stamp"\).*== "\$platform"/);
  assert.match(setup, /printf '%s\\n' "\$platform" > "\$platform_stamp"/);
});
