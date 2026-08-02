import assert from "node:assert/strict";
import {
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const hutchRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

function executableName(name) {
  return process.platform === "win32" ? `${name}.exe` : name;
}

test("hutch electrobun init scaffolds a project and reports complete next steps", () => {
  const hutch = join(hutchRoot, "zig-out", "bin", executableName("hutch"));
  assert.ok(existsSync(hutch), `Hutch must be built before this test: ${hutch}`);

  const fixture = mkdtempSync(join(tmpdir(), "hutch-electrobun-init-"));
  const packageRoot = join(fixture, "electrobun");
  const templateRoot = join(packageRoot, "templates", "hello-world");
  const workspace = join(fixture, "workspace");
  const projectName = "sample-app";
  const projectRoot = join(workspace, projectName);

  try {
    mkdirSync(join(templateRoot, "src"), { recursive: true });
    mkdirSync(workspace, { recursive: true });
    writeFileSync(join(packageRoot, "package.json"), '{"name":"electrobun"}\n');
    writeFileSync(join(templateRoot, "package.json"), '{"name":"hello-world"}\n');
    writeFileSync(join(templateRoot, "src", "index.ts"), 'console.log("hello");\n');

    const result = spawnSync(
      hutch,
      ["electrobun", "init", projectName, "--template=hello-world"],
      {
        cwd: workspace,
        encoding: "utf8",
        env: {
          ...process.env,
          COTTONTAIL_ELECTROBUN_PACKAGE: packageRoot,
        },
      },
    );

    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.equal(result.stderr, "");
    assert.equal(
      result.stdout,
      `Created Electrobun project at ${projectRoot}\n` +
        "Next steps:\n" +
        `  cd ${projectName}\n` +
        "  hutch run dev\n",
    );
    assert.equal(
      readFileSync(join(projectRoot, "package.json"), "utf8"),
      '{"name":"hello-world"}\n',
    );
    assert.equal(
      readFileSync(join(projectRoot, "src", "index.ts"), "utf8"),
      'console.log("hello");\n',
    );
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
});
