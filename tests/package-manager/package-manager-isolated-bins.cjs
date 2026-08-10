"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const hutch = path.resolve(process.argv[2] || "zig-out/bin/hutch");
const root = fs.mkdtempSync(path.join(os.tmpdir(), "hutch-isolated-bins-"));
const tool = path.join(root, "packages", "ordinary-bin-tool");

function writeJson(filename, value) {
  fs.mkdirSync(path.dirname(filename), { recursive: true });
  fs.writeFileSync(filename, `${JSON.stringify(value, null, 2)}\n`);
}

function run(args) {
  return spawnSync(hutch, args, {
    cwd: root,
    encoding: "utf8",
    timeout: 30_000,
  });
}

function expectSuccess(label, result) {
  assert.equal(
    result.status,
    0,
    `${label} failed\nerror:\n${result.error?.stack || result.error || ""}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`,
  );
}

function binPath(name) {
  return path.join(root, "node_modules", ".bin", process.platform === "win32" ? `${name}.cmd` : name);
}

try {
  fs.writeFileSync(path.join(root, "bunfig.toml"), '[install]\nlinker = "isolated"\n');
  writeJson(path.join(tool, "package.json"), {
    name: "ordinary-bin-tool",
    version: "1.0.0",
    bin: {
      "direct-one": "one.js",
      "direct-two": "two.js",
    },
  });
  fs.writeFileSync(
    path.join(tool, "one.js"),
    '#!/usr/bin/env node\nconsole.log(`direct-one:${process.argv.slice(2).join(",")}`);\n',
  );
  fs.writeFileSync(
    path.join(tool, "two.js"),
    '#!/usr/bin/env node\nconsole.log(`direct-two:${process.argv.slice(2).join(",")}`);\n',
  );
  writeJson(path.join(root, "package.json"), {
    name: "isolated-bin-root",
    version: "1.0.0",
    dependencies: {
      "ordinary-bin-tool": "file:./packages/ordinary-bin-tool",
    },
  });

  for (const installLabel of ["initial isolated install", "unchanged isolated reinstall"]) {
    const installed = run(["install", "--ignore-scripts", "--silent"]);
    expectSuccess(installLabel, installed);

    for (const name of ["direct-one", "direct-two"]) {
      assert.ok(fs.existsSync(binPath(name)), `${name} bin was pruned during ${installLabel}`);
    }

    const first = run(["run", "--silent", "direct-one", "alpha"]);
    expectSuccess(`${installLabel} direct-one execution`, first);
    assert.equal(first.stdout.trim(), "direct-one:alpha");

    const second = run(["run", "--silent", "direct-two", "beta", "gamma"]);
    expectSuccess(`${installLabel} direct-two execution`, second);
    assert.equal(second.stdout.trim(), "direct-two:beta,gamma");
  }

  console.log("package-manager isolated bins: pass");
} finally {
  fs.rmSync(root, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
}
