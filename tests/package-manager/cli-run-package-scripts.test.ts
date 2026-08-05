import { afterAll, expect, test } from "bun:test";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";

const scratchRoot = process.env.COTTONTAIL_CLI_RUN_TEST_ROOT ?? join(process.cwd(), ".cottontail-tmp");
mkdirSync(scratchRoot, { recursive: true });
const scratch = mkdtempSync(join(scratchRoot, "cli-run-"));

afterAll(() => {
  rmSync(scratch, { recursive: true, force: true });
});

function run(cwd: string, args: string[]) {
  const result = Bun.spawnSync({
    cmd: [process.execPath, ...args],
    cwd,
    env: {
      ...process.env,
      NO_COLOR: "1",
      PATH: join(cwd, "missing-bin"),
    },
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });
  return {
    exitCode: result.exitCode,
    stdout: new TextDecoder().decode(result.stdout),
    stderr: new TextDecoder().decode(result.stderr),
  };
}

test("multi-run rewrites nested package-manager commands and exposes lifecycle metadata", () => {
  const directory = join(scratch, "nested-run");
  mkdirSync(directory, { recursive: true });
  const packageJson = `{
      // Package scripts are loaded with Bun's JSONC rules.
      "name": "run-fixture",
      "version": "1.2.3",
      "config": { "flavor": "stock-jsc" },
      "scripts": {
        "inner": "bun probe.js \\"two words\\" 'quoted value'",
        "outer": "npm run inner",
      },
    }`;
  writeFileSync(
    join(directory, "package.json"),
    packageJson,
  );
  writeFileSync(
    join(directory, "probe.js"),
    `console.log(JSON.stringify({
      packageName: process.env.npm_package_name,
      packageVersion: process.env.npm_package_version,
      packageJson: process.env.npm_package_json,
      lifecycleEvent: process.env.npm_lifecycle_event,
      lifecycleScript: process.env.npm_lifecycle_script,
      initCwd: process.env.INIT_CWD,
      localPrefix: process.env.npm_config_local_prefix,
      userAgent: process.env.npm_config_user_agent,
      configFlavor: process.env.npm_package_config_flavor,
      bun: process.env.BUN,
      execPath: process.execPath,
      args: process.argv.slice(2),
    }));\n`,
  );

  const result = run(directory, ["run", "--parallel", "outer"]);
  expect(result.exitCode, `${result.stdout}\n${result.stderr}`).toBe(0);
  const outputLine = result.stdout.split(/\r?\n/).find(line => line.includes('"packageName"'));
  expect(outputLine).toBeDefined();
  const metadata = JSON.parse(outputLine!.slice(outputLine!.indexOf("{")));
  const realDirectory = realpathSync(directory);
  expect(metadata).toMatchObject({
    packageName: "run-fixture",
    packageVersion: "1.2.3",
    packageJson: join(realDirectory, "package.json"),
    lifecycleEvent: "inner",
    lifecycleScript: `bun probe.js "two words" 'quoted value'`,
    initCwd: realDirectory,
    localPrefix: realDirectory,
    configFlavor: "stock-jsc",
    args: ["two words", "quoted value"],
  });
  expect(metadata.userAgent).toStartWith("bun/1.3.10 ");
  expect(metadata.bun).toBe(metadata.execPath);
  expect(result.stderr).toMatch(/^outer\s+\| Done/m);
  expect(readFileSync(join(directory, "package.json"), "utf8")).toBe(packageJson);
  expect(existsSync(join(directory, "node_modules", "bun"))).toBe(false);
});

test("workspace multi-run honors JSONC patterns and sorts packages by name", () => {
  const directory = join(scratch, "workspace-order");
  const firstByPath = join(directory, "packages", "a-dir");
  const firstByName = join(directory, "packages", "z-dir");
  const ignored = join(directory, "ignored");
  mkdirSync(firstByPath, { recursive: true });
  mkdirSync(firstByName, { recursive: true });
  mkdirSync(ignored, { recursive: true });
  writeFileSync(
    join(directory, "package.json"),
    `{
      // This package must not make the workspace parser fall back to a tree walk.
      "private": true,
      "workspaces": ["packages/*",],
    }`,
  );

  for (const [packageDirectory, name] of [
    [firstByPath, "omega"],
    [firstByName, "alpha"],
    [ignored, "ignored"],
  ] as const) {
    writeFileSync(
      join(packageDirectory, "package.json"),
      JSON.stringify({ name, scripts: { order: "bun probe.js" } }),
    );
    writeFileSync(join(packageDirectory, "probe.js"), "console.log(process.env.npm_package_name);\n");
  }

  const result = run(directory, ["run", "--sequential", "--filter", "*", "order"]);
  expect(result.exitCode, `${result.stdout}\n${result.stderr}`).toBe(0);
  const alpha = result.stdout.indexOf("alpha:order | alpha");
  const omega = result.stdout.indexOf("omega:order | omega");
  expect(alpha).toBeGreaterThanOrEqual(0);
  expect(omega).toBeGreaterThan(alpha);
  expect(result.stdout).not.toContain("ignored");
});

test("single package scripts do not install the public bun package", () => {
  const directory = join(scratch, "single-run");
  mkdirSync(directory, { recursive: true });
  const packageJson = JSON.stringify({
    name: "single-run",
    version: "1.0.0",
    scripts: {
      probe: "printf 'single-run\\n'",
    },
  }, null, 2);
  writeFileSync(join(directory, "package.json"), packageJson);

  const result = run(directory, ["run", "probe"]);
  expect(result.exitCode, `${result.stdout}\n${result.stderr}`).toBe(0);
  expect(result.stdout).toContain("single-run\n");
  expect(readFileSync(join(directory, "package.json"), "utf8")).toBe(packageJson);
  expect(existsSync(join(directory, "node_modules", "bun"))).toBe(false);
});

test("single-run diagnostics render rewritten commands and appended arguments", () => {
  const directory = join(scratch, "single-run-display");
  mkdirSync(directory, { recursive: true });
  writeFileSync(
    join(directory, "package.json"),
    JSON.stringify({
      scripts: {
        inner: "bun probe.js",
        outer: "   npm run inner   ",
      },
    }),
  );
  writeFileSync(
    join(directory, "probe.js"),
    "console.log(JSON.stringify(process.argv.slice(2)));\n",
  );

  const nested = run(directory, ["run", "outer"]);
  expect(nested.exitCode, `${nested.stdout}\n${nested.stderr}`).toBe(0);
  expect(nested.stderr).toBe("$    bun run inner   \n$ bun probe.js\n");

  const withArguments = run(directory, ["run", "inner", "$HOME (!)", "argument two"]);
  expect(withArguments.exitCode, `${withArguments.stdout}\n${withArguments.stderr}`).toBe(0);
  expect(withArguments.stderr).toBe('$ bun probe.js "\\$HOME (!)" "argument two"\n');
  expect(withArguments.stdout).toBe('["$HOME (!)","argument two"]\n');
});

test("single-run failures retain diagnostics when command echoing is disabled", () => {
  const directory = join(scratch, "single-run-failure");
  mkdirSync(directory, { recursive: true });
  writeFileSync(join(directory, "package.json"), JSON.stringify({ scripts: { fail: "bun missing.js" } }));

  const script = run(directory, ["run", "fail"]);
  expect(script.exitCode).toBe(1);
  expect(script.stderr).toBe(
    '$ bun missing.js\nerror: Module not found "missing.js"\nerror: script "fail" exited with code 1\n',
  );
});

test("ordinary run applies --cwd exactly once", () => {
  const directory = join(scratch, "single-run-cwd");
  mkdirSync(join(directory, "subdir"), { recursive: true });
  writeFileSync(join(directory, "subdir", "probe.js"), "console.log(process.cwd());\n");

  const result = run(directory, ["run", "--cwd", "subdir", "probe.js"]);
  expect(result.exitCode, `${result.stdout}\n${result.stderr}`).toBe(0);
  expect(result.stdout).toContain(join(directory, "subdir"));
});

test("package scripts repair an incomplete node_modules tree", () => {
  const directory = join(scratch, "partial-install");
  const dependency = join(scratch, "local-dependency");
  mkdirSync(join(directory, "node_modules", "unrelated"), { recursive: true });
  mkdirSync(dependency, { recursive: true });
  writeFileSync(
    join(directory, "package.json"),
    JSON.stringify({
      name: "partial-install",
      version: "1.0.0",
      dependencies: { "local-dependency": "file:../local-dependency" },
      scripts: { probe: "bun probe.js" },
    }, null, 2),
  );
  writeFileSync(
    join(directory, "node_modules", "unrelated", "package.json"),
    '{"name":"unrelated","version":"1.0.0"}\n',
  );
  writeFileSync(
    join(dependency, "package.json"),
    '{"name":"local-dependency","version":"1.0.0","main":"index.js"}\n',
  );
  writeFileSync(join(dependency, "index.js"), "module.exports = 42;\n");
  writeFileSync(
    join(directory, "probe.js"),
    'console.log(require("local-dependency"));\n',
  );

  const first = run(directory, ["run", "probe"]);
  expect(first.exitCode, `${first.stdout}\n${first.stderr}`).toBe(0);
  expect(first.stdout).toContain("42\n");
  expect(first.stderr).toContain("hutch: installing package dependencies...");
  expect(existsSync(join(directory, "node_modules", "local-dependency", "package.json"))).toBe(true);

  const second = run(directory, ["run", "probe"]);
  expect(second.exitCode, `${second.stdout}\n${second.stderr}`).toBe(0);
  expect(second.stdout).toContain("42\n");
  expect(second.stderr).not.toContain("hutch: installing package dependencies...");
});
