import assert from "node:assert/strict";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

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

test("Electrobun bundles preserve legacy decorators and emitted metadata", () => {
  mkdirSync(scratchRoot, { recursive: true });
  const fixture = mkdtempSync(join(scratchRoot, "decorator-bundle-"));
  const output = join(fixture, "dist", "app.js");
  const cottontail = resolveCottontail();

  try {
    writeFileSync(join(fixture, "tsconfig.json"), JSON.stringify({
      compilerOptions: {
        experimentalDecorators: true,
        emitDecoratorMetadata: true,
      },
    }));
    writeFileSync(join(fixture, "app.ts"), `
const observed: string[] = [];
const reflection = Reflect as typeof Reflect & {
  metadata?: (key: string, value: unknown[]) => ClassDecorator;
};

reflection.metadata = (key, value) => (target) => {
  if (key === "design:paramtypes") {
    observed.push(\`metadata:\${String(target.name)}:\${value.map((item: any) => item.name).join(",")}\`);
  }
};

function service(): ClassDecorator {
  return (target) => {
    observed.push(\`class:\${String(target.name)}\`);
  };
}

function inject(token: Function): ParameterDecorator {
  return (target, _propertyKey, parameterIndex) => {
    observed.push(\`parameter:\${String((target as Function).name)}:\${parameterIndex}:\${token.name}\`);
  };
}

class Dependency {}

@service()
class Consumer {
  constructor(@inject(Dependency) readonly dependency: Dependency) {}
}

new Consumer(new Dependency());
const expected = [
  "class:Consumer",
  "metadata:Consumer:Dependency",
  "parameter:Consumer:0:Dependency",
];
if (JSON.stringify(observed.sort()) !== JSON.stringify(expected)) {
  throw new Error(\`Decorator behavior mismatch: \${JSON.stringify(observed)}\`);
}
`);
    writeFileSync(join(fixture, "build.json"), JSON.stringify({
      entryPoints: [join(fixture, "app.ts")],
      bundle: true,
      platform: "neutral",
      format: "esm",
      outfile: output,
    }));

    const build = run(cottontail, [buildHelper, join(fixture, "build.json")], fixture);
    assert.equal(build.status, 0, build.stderr || build.stdout);
    assert.ok(existsSync(output), `Expected bundle at ${output}`);

    const bundle = readFileSync(output, "utf8");
    assert.match(bundle, /design:paramtypes/);

    const execution = run(cottontail, [output], fixture);
    assert.equal(execution.status, 0, execution.stderr || execution.stdout);
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
});
