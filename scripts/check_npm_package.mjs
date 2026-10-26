import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const npm = process.env.npm_execpath;
assert.ok(npm, 'Run npm run verify:package so the npm CLI path is explicit');
const output = join(root, '_build/npm');
mkdirSync(output, { recursive: true });
function run(executable, args, cwd) {
  const result = spawnSync(executable, args, { cwd, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, result.stderr + result.stdout);
  return result.stdout;
}
run(process.execPath, [join(root, 'scripts/build_sdk.mjs')], root);
const packed = JSON.parse(run(process.execPath, [npm, 'pack', '--json', '--ignore-scripts', '--pack-destination', output], root))[0];
const manifest = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
const paths = packed.files.map(file => file.path);
for (const path of paths) assert.ok(['package.json', 'README.md', 'LICENSE', 'js/index.mjs', 'js/index.d.ts', 'dist/bridge.cjs'].includes(path) || /^docs\/[A-Za-z0-9_-]+\.(md|svg)$/.test(path) || /^dist\/third-party\/(?:core-LICENSE|core-NOTICE|cbor-LICENSE)\.txt$/.test(path), `Unexpected packed entry: ${path}`);
for (const path of ['js/index.mjs', 'js/index.d.ts', 'dist/bridge.cjs', 'dist/third-party/core-NOTICE.txt', 'dist/third-party/core-LICENSE.txt', 'dist/third-party/cbor-LICENSE.txt']) assert.ok(paths.includes(path), `Missing ${path}`);
const directory = mkdtempSync(join(tmpdir(), 'senweave-npm-consumer-'));
try {
  writeFileSync(join(directory, 'package.json'), JSON.stringify({ private: true, type: 'module' }));
  run(process.execPath, [npm, 'install', '--offline', '--ignore-scripts', '--no-audit', '--no-fund', '--package-lock=false', join(output, packed.filename)], directory);
  for (const path of paths) {
    const text = readFileSync(join(directory, 'node_modules', manifest.name, path), 'utf8').replace(/https?:\/\/[^\s<>"']+/g, '');
    assert.equal(/(?<![A-Za-z])[A-Za-z]:[\\/]+[^\\/"\s]|file:\/\/|\/(?:Users|home)\/|AppData[\\/]/.test(text), false, `Local path in packed file: ${path}`);
  }
  const consumer = `import assert from 'node:assert/strict';
import {check, resolve, SenWeaveError} from '${manifest.name}';
const input='[{"bn":"x:","bt":1793000000},{"n":"counter","v":9007199254740993}]';
assert.equal(check(input).measurements,1);
const cbor=resolve(input,{to:'cbor'});
assert.ok(cbor.data instanceof Uint8Array);
assert.ok(resolve(cbor.data,{from:'cbor'}).data.includes('9007199254740993'));
assert.throws(()=>check('[{"n":"x","v":1}]'),e=>e instanceof SenWeaveError && e.code==='MissingReferenceTime');
assert.throws(()=>check(input,{limits:{maxRecords:1}}),e=>e.code==='RecordLimit');
assert.throws(()=>resolve(input,{limits:{maxOutputBytes:1}}),e=>e.code==='OutputLimit');
assert.throws(()=>check('[{"n":"x","v":1,"vendor":true}]',{rejectExtensions:true}),e=>e.code==='IgnoredExtensions');
assert.throws(()=>check('[{"n":"x","v":1,"private-key_":true}]'),e=>e.code==='UnsupportedExtension' && !Object.hasOwn(e.diagnostic,'field'));
console.log('installed-consumer: passed');`;
  writeFileSync(join(directory, 'consumer.mjs'), consumer);
  run(process.execPath, ['consumer.mjs'], directory);
  writeFileSync(join(directory, 'consumer.mts'), `import {check, resolve, type ResolveOptions, type ResourceLimits, SenWeaveError} from '${manifest.name}';
const input='[]';
const json: string=resolve(input).data;
const binary: Uint8Array=resolve(input,{to:'cbor'}).data;
const count: number=check(input).measurements;
const quotas: ResourceLimits={maxRecords:16,maxInputBytes:8192};
check(input,{limits:quotas});
const options: ResolveOptions={to:Math.random()>0.5?'json':'cbor'};
const union=resolve(input,options);
if(union.format==='json'){const text: string=union.data; void text;}
// @ts-expect-error binary output cannot be assigned to text
const wrong: string=resolve(input,{to:'cbor'}).data;
// @ts-expect-error input objects would lose numeric source spelling
check([{n:'x',v:1}]);
// @ts-expect-error unknown options are rejected
check(input,{extra:true});
// @ts-expect-error quota values must be numeric
check(input,{limits:{maxRecords:'16'}});
// @ts-expect-error unknown quotas are rejected
check(input,{limits:{recordCount:16}});
const errorCode: string=new SenWeaveError({code:'Example',message:'example'}).code;
void [json,binary,count,wrong,errorCode];`);
  run(process.execPath, [join(root, 'node_modules/typescript/bin/tsc'), '--noEmit', '--strict', '--module', 'NodeNext', '--target', 'ES2022', 'consumer.mts'], directory);
  console.log(JSON.stringify({ package: manifest.name, version: manifest.version, files: paths.length,
    runtimeConsumer: 'passed', typescriptConsumer: 'passed', integrity: packed.integrity, archive: `_build/npm/${packed.filename}` }));
} finally {
  assert.equal(dirname(resolve(directory)), resolve(tmpdir()));
  rmSync(directory, { recursive: true, force: true });
}
