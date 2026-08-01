import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const hutchRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const buildHelper = join(hutchRoot, "src/electrobun_cli/build_helper.js");
const scratchRoot = join(hutchRoot, ".cottontail-tmp", "tests");

function executableName(name) {
  return process.platform === "win32" ? `${name}.exe` : name;
}

function resolveCottontail() {
  const configured = process.env.COTTONTAIL_BINARY ?? process.env.DASH_COTTONTAIL;
  if (configured) return resolve(configured);

  const hutch = join(hutchRoot, "zig-out", "bin", executableName("hutch"));
  assert.ok(existsSync(hutch), `Hutch must be built before this test: ${hutch}`);

  const result = spawnSync(hutch, ["cottontail", "path", "production"], {
    cwd: hutchRoot,
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  return result.stdout.trim();
}

function run(cottontail, args, cwd) {
  return spawnSync(cottontail, args, {
    cwd,
    encoding: "utf8",
    env: {
      ...process.env,
      COTTONTAIL_BINARY: cottontail,
      DASH_COTTONTAIL: cottontail,
    },
  });
}

test("Electrobun bundles resolve tsconfig path aliases", () => {
  mkdirSync(scratchRoot, { recursive: true });
  const fixture = mkdtempSync(join(scratchRoot, "tsconfig-path-alias-bundle-"));
  const entrypoint = join(fixture, "src", "bun", "rpc", "index.ts");
  const output = join(fixture, "dist", "main.js");
  const cottontail = resolveCottontail();

  try {
    mkdirSync(dirname(entrypoint), { recursive: true });
    mkdirSync(join(fixture, "src", "shared"), { recursive: true });
    writeFileSync(
      join(fixture, "tsconfig.json"),
      JSON.stringify({
        compilerOptions: {
          baseUrl: ".",
          paths: {
            "@/*": ["src/*"],
          },
        },
      }),
    );
    writeFileSync(
      join(fixture, "src", "shared", "constants.ts"),
      'export const CFG = { marker: "tsconfig-alias-resolved" };\n',
    );
    writeFileSync(
      entrypoint,
      `import { CFG } from "@/shared/constants";

if (CFG.marker !== "tsconfig-alias-resolved") {
  throw new Error(\`Unexpected alias value: \${CFG.marker}\`);
}
console.log(CFG.marker);
`,
    );
    writeFileSync(
      join(fixture, "build.json"),
      JSON.stringify({
        entryPoints: [entrypoint],
        bundle: true,
        platform: "neutral",
        format: "esm",
        outfile: output,
      }),
    );

    const build = run(cottontail, [buildHelper, join(fixture, "build.json")], fixture);
    assert.equal(build.status, 0, build.stderr || build.stdout);
    assert.ok(existsSync(output), `Expected bundle at ${output}`);

    const bundle = readFileSync(output, "utf8");
    assert.doesNotMatch(bundle, /from\s+["']@\/shared\/constants["']/);

    const execution = run(cottontail, [output], fixture);
    assert.equal(execution.status, 0, execution.stderr || execution.stdout);
    assert.equal(execution.stdout.trim(), "tsconfig-alias-resolved");
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
});
