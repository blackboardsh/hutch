import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, constants, copyFileSync, existsSync, linkSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

// Optional HUTCH_LOCAL_TEST_* runtime paths bypass fixture provisioning.
// Otherwise fixture setup resolves each runtime in the ordinary managed store;
// every project assertion uses a separate new offline home. Cottontail is only
// resolved once the explicit opt-in cases begin.
const repository = dirname(dirname(fileURLToPath(import.meta.url)));
const suffix = process.platform === 'win32' ? '.exe' : '';
const engine = resolve(process.env.HUTCH_LOCAL_TEST_ENGINE ?? join(repository, 'zig-out', 'bin', `hutch-engine${suffix}`));
const launcher = resolve(process.env.HUTCH_LOCAL_TEST_BINARY ?? join(repository, 'zig-out', 'bin', `hutch${suffix}`));
const bunVersion = readFileSync(join(repository, 'src', 'toolchain_store.zig'), 'utf8').match(/default_bun_version = "([^"]+)"/)?.[1];
assert.ok(bunVersion, 'Hutch must declare its pinned Bun version');

function baseEnvironment() {
  const env = { ...process.env };
  for (const key of [
    'HUTCH_RUNTIME', 'HUTCH_DEFAULT_CLI', 'HUTCH_ACTIVE_CHANNEL',
    'COTTONTAIL_BINARY', 'DASH_COTTONTAIL', 'DASH_USE_LOCAL_COTTONTAIL',
    'DASH_LOCAL_COTTONTAIL_ROOT', 'COTTONTAIL_ROOT', 'DASH_COTTONTAIL_SELECTOR',
    'DASH_RELEASE_REFRESH', 'DASH_ARTIFACTS_BASE_URL', 'BUN_OPTIONS', 'NODE_OPTIONS',
    'BUN_INSTALL_CACHE_DIR', 'HUTCH_INSTALL_CACHE_DIR', 'XDG_CACHE_HOME',
    'npm_config_cache', 'NPM_CONFIG_CACHE', 'npm_config_registry', 'NPM_CONFIG_REGISTRY',
  ]) delete env[key];
  return {
    ...env,
    HUTCH_ENGINE_BINARY: engine,
    HUTCH_LAUNCHER_PATH: launcher,
    HUTCH_NO_UPDATE_CHECK: '1',
    DASH_RELEASE_OFFLINE: '1',
    CI: '1',
    NO_COLOR: '1',
  };
}

function run(binary, args, cwd, env, extra = {}) {
  assert.ok(existsSync(binary), `Missing executable ${binary}; build Hutch or set HUTCH_LOCAL_TEST_BINARY/HUTCH_LOCAL_TEST_ENGINE`);
  const result = spawnSync(binary, args, { cwd, env, encoding: 'utf8', timeout: 60_000, ...extra });
  assert.ifError(result.error);
  return result;
}

function success(result, label) {
  assert.equal(result.status, 0, `${label}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`);
  return result.stdout.trim();
}

function writeJSON(path, value) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
}

function assertNoRuntimeInstall(home) {
  assert.equal(existsSync(join(home, 'toolchains', 'bun')), false, 'this workflow must not provision Bun');
  assert.equal(existsSync(join(home, 'releases', 'cottontail')), false, 'this workflow must not provision Cottontail');
}

function isolatedEnvironment(root, home, path) {
  const userHome = join(root, 'user-home');
  const temporary = join(root, 'temporary');
  mkdirSync(userHome, { recursive: true });
  mkdirSync(temporary, { recursive: true });
  const env = {
    ...baseEnvironment(),
    HUTCH_HOME: home,
    HOME: userHome,
    USERPROFILE: userHome,
    XDG_CONFIG_HOME: join(userHome, 'config'),
    HUTCH_INSTALL_CACHE_DIR: join(root, 'install-cache'),
    TMPDIR: temporary,
    TEMP: temporary,
    TMP: temporary,
    BUN_TMPDIR: temporary,
  };
  for (const key of Object.keys(env)) {
    if (key.toLowerCase() === 'path') delete env[key];
  }
  env.PATH = path;
  return env;
}

function resolveRuntimeFixture(kind, cwd) {
  const variable = kind === 'bun' ? 'HUTCH_LOCAL_TEST_BUN' : 'HUTCH_LOCAL_TEST_COTTONTAIL';
  if (process.env[variable]) {
    const path = resolve(process.env[variable]);
    assert.ok(existsSync(path), `${variable} must name an existing runtime: ${path}`);
    return path;
  }
  const env = baseEnvironment();
  delete env.DASH_RELEASE_OFFLINE;
  const args = kind === 'bun' ? ['-p', 'process.execPath'] : ['cottontail', 'path'];
  if (kind === 'bun') env.HUTCH_RUNTIME = 'bun';
  const result = run(engine, args, cwd, env, { timeout: 180_000 });
  assert.equal(result.status, 0,
    `Could not provision the ${kind} fixture. Set ${variable} to an existing executable${kind === 'bun' ? ` for Bun ${bunVersion}` : ''}, or make its download available.\n${result.stderr}`);
  const path = result.stdout.trim();
  assert.ok(existsSync(path), `${variable} resolution must return an executable path: ${JSON.stringify(path)}`);
  return path;
}

function runtimeFixtures(root) {
  const binaryDirectory = join(root, 'runtime binaries with spaces');
  mkdirSync(binaryDirectory);
  const bun = join(binaryDirectory, `bun${suffix}`);
  const existingBun = resolveRuntimeFixture('bun', root);
  try {
    linkSync(existingBun, bun);
  } catch {
    // Cross-volume temporary directories cannot hardlink. Prefer a filesystem
    // clone when available, and never change the original runtime's permissions.
    copyFileSync(existingBun, bun, constants.COPYFILE_FICLONE);
    chmodSync(bun, 0o755);
  }
  assert.equal(success(run(bun, ['--version'], root, baseEnvironment()), 'Bun fixture version'), bunVersion,
    `HUTCH_LOCAL_TEST_BUN must match the pinned Bun ${bunVersion}`);
  let cottontail;
  return {
    binaryDirectory, bun,
    cottontail() {
      if (cottontail) return cottontail;
      cottontail = resolveRuntimeFixture('cottontail', root);
      const identity = JSON.parse(success(run(cottontail, ['-p', 'JSON.stringify({cottontail:process.versions.cottontail})'], root, baseEnvironment()), 'Cottontail fixture identity'));
      assert.equal(typeof identity.cottontail, 'string', 'HUTCH_LOCAL_TEST_COTTONTAIL must be a real Cottontail executable');
      return cottontail;
    },
  };
}

test('Windows native bin install defers runtime selection to the configured launcher', {
  skip: process.platform !== 'win32', timeout: 480_000,
}, () => {
  const root = mkdtempSync(join(tmpdir(), 'hutch-native-bin-runtime-'));
  try {
    const project = join(root, 'project with spaces');
    const dependency = join(root, 'local-bin');
    const home = join(root, 'empty-managed-home');
    const emptyPath = join(root, 'empty-path');
    const launcherDirectory = join(root, 'custom launcher directory');
    mkdirSync(emptyPath);
    mkdirSync(launcherDirectory);
    const configuredLauncher = join(launcherDirectory, 'hutch.exe');
    copyFileSync(launcher, configuredLauncher);
    const lifecycle = 'node -e "require(\'node:fs\').writeFileSync(process.env.HUTCH_LIFECYCLE_SENTINEL,\'ran\')"';
    writeJSON(join(dependency, 'package.json'), {
      name: 'local-bin', version: '1.0.0', bin: { 'selected-runtime-bin': 'bin.cjs' },
      scripts: { postinstall: lifecycle },
    });
    writeFileSync(join(dependency, 'bin.cjs'), '#!/usr/bin/env bun\nconsole.log(JSON.stringify({bun:process.versions.bun,cottontail:process.versions.cottontail,args:process.argv.slice(2)}));\n');
    writeJSON(join(project, 'package.json'), {
      name: 'native-bin-project', version: '1.0.0',
      dependencies: { 'local-bin': 'file:../local-bin' },
      trustedDependencies: ['local-bin'], scripts: { postinstall: lifecycle },
    });
    const sentinel = join(root, 'lifecycle-must-not-run');
    const environment = {
      ...isolatedEnvironment(root, home, emptyPath),
      HUTCH_LAUNCHER_PATH: configuredLauncher,
      HUTCH_LIFECYCLE_SENTINEL: sentinel,
    };
    // No runtime fixture has been resolved yet, and no executable is on PATH.
    success(run(engine, ['install', '--silent'], project, environment), 'native file dependency install without either runtime');
    assertNoRuntimeInstall(home);
    assert.equal(existsSync(sentinel), false, 'the native installer must continue skipping even trusted lifecycle scripts');
    const shim = join(project, 'node_modules', '.bin', 'selected-runtime-bin.cmd');
    const source = readFileSync(shim, 'utf8');
    assert.ok(source.startsWith(`@"${configuredLauncher}" `), `bin shim must invoke HUTCH_LAUNCHER_PATH: ${source}`);

    const fixtures = runtimeFixtures(root);
    const args = ['two words', '', '$literal', 'a&b', '工作-🚀'];
    // /s consumes the outer quotes; each argument stays quoted when %* is
    // forwarded by the generated .cmd, including the empty argument.
    const command = `""${shim}" ${args.map(value => `"${value}"`).join(' ')}"`;
    for (const kind of ['bun', 'cottontail']) {
      const overrides = kind === 'bun' ? {} : {
        HUTCH_RUNTIME: 'cottontail', COTTONTAIL_BINARY: fixtures.cottontail(),
      };
      const result = run(process.env.ComSpec ?? join(process.env.SystemRoot, 'System32', 'cmd.exe'),
        ['/d', '/s', '/c', command], project,
        { ...environment, PATH: fixtures.binaryDirectory, ...overrides }, { windowsVerbatimArguments: true });
      const identity = JSON.parse(success(result, `${kind} bin shim invocation`));
      assert.deepEqual(identity.args, args, 'the installed shim must preserve arguments');
      if (kind === 'bun') {
        assert.equal(identity.bun, bunVersion);
        assert.equal(identity.cottontail, undefined);
      } else assert.equal(typeof identity.cottontail, 'string');
      assertNoRuntimeInstall(home);
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('native install runs a configured scanner in Bun by default and preserves Cottontail opt-in', { timeout: 600_000 }, () => {
  const root = mkdtempSync(join(tmpdir(), 'hutch-scanner-runtime-'));
  try {
    const fixtures = runtimeFixtures(root);
    const dependency = join(root, 'local-dependency');
    writeJSON(join(dependency, 'package.json'), { name: 'local-dependency', version: '1.0.0' });
    for (const [name, binary, runtimeOverrides, expectedRuntime] of [
      ['default-engine', engine, () => ({}), 'bun'],
      ['default-launcher', launcher, () => ({}), 'bun'],
      ['forced-bun', engine, () => ({ HUTCH_RUNTIME: 'bun', COTTONTAIL_BINARY: join(root, 'missing-cottontail' + suffix) }), 'bun'],
      ['explicit-cottontail', launcher, () => ({ HUTCH_RUNTIME: 'cottontail', COTTONTAIL_BINARY: fixtures.cottontail() }), 'cottontail'],
      ['local-cottontail-override', engine, () => ({ COTTONTAIL_BINARY: fixtures.cottontail() }), 'cottontail'],
    ]) {
      const project = join(root, name);
      const home = join(root, `${name}-home`);
      const observation = join(project, 'scanner-observation.json');
      writeJSON(join(project, 'package.json'), {
        name: 'scanner-project', version: '1.0.0', dependencies: { 'local-dependency': 'file:../local-dependency' },
      });
      writeFileSync(join(project, 'bunfig.toml'), '[install.security]\nscanner = "./scanner.mjs"\n');
      writeFileSync(join(project, 'scanner.mjs'), `
import { writeFileSync } from 'node:fs';
export const scanner = {
  version: '1',
  async scan({ packages }) {
    if (!Array.isArray(packages)) throw new Error('scanner packages payload is missing');
    writeFileSync(process.env.HUTCH_SCANNER_OBSERVATION, JSON.stringify({
      bun: process.versions.bun, cottontail: process.versions.cottontail,
      cwd: process.cwd(), inherited: process.env.HUTCH_SCANNER_INHERITED, packages,
    }));
    return [];
  },
};
`);
      const env = {
        ...isolatedEnvironment(root, home, fixtures.binaryDirectory),
        HUTCH_SCANNER_OBSERVATION: observation,
        HUTCH_SCANNER_INHERITED: 'scanner environment survives',
        ...runtimeOverrides(),
      };
      success(run(binary, ['install', '--silent'], project, env), `${name} scanner-backed native install`);
      const value = JSON.parse(readFileSync(observation, 'utf8'));
      if (expectedRuntime === 'bun') {
        assert.equal(value.bun, bunVersion, 'the actual scanner must run in pinned Bun');
        assert.equal(value.cottontail, undefined);
      } else assert.equal(typeof value.cottontail, 'string', 'the actual scanner must honor explicit Cottontail selection');
      assert.equal(realpathSync.native(value.cwd), realpathSync.native(project));
      assert.equal(value.inherited, 'scanner environment survives');
      // Local file dependencies are intentionally absent from the npm security
      // matrix; the scanner must still execute and return its result normally.
      assert.deepEqual(value.packages, []);
      assert.ok(existsSync(join(project, 'node_modules', 'local-dependency', 'package.json')),
        'a successful scanner response must allow the native install to finish');
      assertNoRuntimeInstall(home);
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
