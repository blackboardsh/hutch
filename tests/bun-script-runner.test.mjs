import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';
const suffix = process.platform === 'win32' ? '.exe' : '';
const engine = resolve('zig-out/bin/hutch-engine' + suffix);
const launcher = resolve('zig-out/bin/hutch' + suffix);
const cottontailVersion = readFileSync('src/version.zig', 'utf8').match(/paired_cottontail_version = "([^"]+)"/)[1];
test('default Bun scripts, shell arguments, tests, exit status and explicit Cottontail', () => {
 const root = mkdtempSync(join(tmpdir(), 'hutch-bun-runner-'));
 const env = { ...process.env, HUTCH_ENGINE_BINARY: engine, HUTCH_LAUNCHER_PATH: launcher };
 for (const key of ['HUTCH_RUNTIME', 'COTTONTAIL_BINARY', 'DASH_COTTONTAIL', 'DASH_USE_LOCAL_COTTONTAIL']) delete env[key];
 const run = (args, extra = {}) => spawnSync(engine, args, { cwd: root, env: {...env, ...extra}, encoding: 'utf8', timeout: 30000 });
 try {
  writeFileSync(join(root, 'identity.ts'), 'console.log(JSON.stringify({bun:process.versions.bun,cottontail:process.versions.cottontail,args:process.argv.slice(2)}));');
  writeFileSync(join(root, 'hutch.config.ts'), `// @hutch cottontail=${cottontailVersion}
export default { scripts: { identity: 'hutch identity.ts', argv: ['hutch', 'identity.ts'], fail: 'exit 23', input: 'cat' } };`);
  for (const args of [['identity.ts'], ['run','identity.ts'], ['identity'], ['run','identity'], ['argv']]) {
   const result = run([...args, 'a b', '$(not-executed)', '"quoted"']);
   assert.equal(result.status, 0, result.stderr);
   const value = JSON.parse(result.stdout.trim());
   assert.equal(typeof value.bun, 'string');
   assert.equal(value.cottontail, undefined);
   assert.deepEqual(value.args, ['a b', '$(not-executed)', '"quoted"']);
  }
  assert.equal(run(['fail']).status, 23);
  const input = spawnSync(engine, ['input'], {cwd:root,env,encoding:'utf8',input:'stdin survives\n',timeout:30000});
  assert.equal(input.status, 0, input.stderr);
  assert.equal(input.stdout, 'stdin survives\n');
  writeFileSync(join(root, 'runtime.test.ts'), `import {test,expect} from 'bun:test'; test('real Bun',()=>expect(process.versions.cottontail).toBeUndefined());`);
  assert.equal(run(['test','runtime.test.ts']).status, 0);
  const experimental = run(['identity.ts'], {HUTCH_RUNTIME:'cottontail'});
  assert.equal(experimental.status, 0, experimental.stderr);
  assert.equal(typeof JSON.parse(experimental.stdout.trim()).cottontail, 'string');
 } finally { rmSync(root, {recursive:true,force:true}); }
});
