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
for (const path of paths) assert.ok(['package.json', 'README.md', 'LICENSE', 'js/index.mjs', 'js/index.cjs', 'dist/index.d.mts', 'dist/index.d.cts', 'dist/bridge.cjs'].includes(path) || /^docs\/[A-Za-z0-9_-]+\.(md|svg)$/.test(path) || /^dist\/third-party\/(?:core-LICENSE|core-NOTICE|cbor-LICENSE)\.txt$/.test(path), `Unexpected packed entry: ${path}`);
for (const path of ['js/index.mjs', 'js/index.cjs', 'dist/index.d.mts', 'dist/index.d.cts', 'dist/bridge.cjs', 'dist/third-party/core-NOTICE.txt', 'dist/third-party/core-LICENSE.txt', 'dist/third-party/cbor-LICENSE.txt']) assert.ok(paths.includes(path), `Missing ${path}`);
const directory = mkdtempSync(join(tmpdir(), 'senweave-npm-consumer-'));
try {
  writeFileSync(join(directory, 'package.json'), JSON.stringify({ private: true, type: 'module' }));
  run(process.execPath, [npm, 'install', '--offline', '--ignore-scripts', '--no-audit', '--no-fund', '--package-lock=false', join(output, packed.filename)], directory);
  for (const path of paths) {
    const text = readFileSync(join(directory, 'node_modules', manifest.name, path), 'utf8').replace(/https?:\/\/[^\s<>"']+/g, '');
    assert.equal(/(?<![A-Za-z])[A-Za-z]:[\\/]+[^\\/"\s]|file:\/\/|\/(?:Users|home)\/|AppData[\\/]/.test(text), false, `Local path in packed file: ${path}`);
  }
  const installed = join(directory, 'node_modules', manifest.name);
  const installedManifest = JSON.parse(readFileSync(join(installed, 'package.json'), 'utf8'));
  assert.deepEqual(installedManifest.exports, { '.': {
    import: { types: './dist/index.d.mts', default: './js/index.mjs' },
    require: { types: './dist/index.d.cts', default: './js/index.cjs' },
  } });
  assert.equal(installedManifest.main, './js/index.cjs');
  assert.equal(installedManifest.types, './dist/index.d.cts');
  const declarations = readFileSync(join(root, 'js/index.d.ts'), 'utf8');
  for (const path of ['dist/index.d.mts', 'dist/index.d.cts']) assert.equal(readFileSync(join(installed, path), 'utf8'), declarations);
  const consumer = `const input='[{"bn":"x:","bt":1793000000},{"n":"counter","v":9007199254740993}]';
assert.equal(check(input).measurements,1);
const cbor=resolve(input,{to:'cbor'});
assert.ok(cbor.data instanceof Uint8Array);
assert.equal(check(Uint8Array.from(Buffer.from('81bf0061780201ff','hex')),{from:'cbor',referenceTime:1793000000}).measurements,1);
const negativeInput=Uint8Array.from(Buffer.from('81a2006178023bffffffffffffffff','hex'));
const negativeJson=resolve(negativeInput,{from:'cbor',referenceTime:1793000000}).data;
assert.ok(negativeJson.includes('-18446744073709551616'));
const negativeWire=resolve(negativeInput,{from:'cbor',to:'cbor',referenceTime:1793000000}).data;
assert.equal(resolve(negativeWire,{from:'cbor'}).data,negativeJson);
assert.ok(resolve(cbor.data,{from:'cbor'}).data.includes('9007199254740993'));
assert.throws(()=>check('[{"n":"x","v":1}]'),e=>e instanceof SenWeaveError && e.code==='MissingReferenceTime');
assert.throws(()=>check(input,{limits:{maxRecords:1}}),e=>e.code==='RecordLimit');
assert.throws(()=>resolve(input,{limits:{maxOutputBytes:1}}),e=>e.code==='OutputLimit');
assert.throws(()=>check('[{"n":"x","v":1,"vendor":true}]',{rejectExtensions:true}),e=>e.code==='IgnoredExtensions');
assert.throws(()=>check('[{"n":"x","v":1,"private-key_":true}]'),e=>e.code==='UnsupportedExtension' && !Object.hasOwn(e.diagnostic,'field'));
console.log('installed-consumer: passed');`;
  writeFileSync(join(directory, 'consumer.mjs'), `import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {check, resolve, SenWeaveError} from '${manifest.name}';
const commonjs=createRequire(import.meta.url)('${manifest.name}');
assert.equal(commonjs.check,check);
assert.equal(commonjs.resolve,resolve);
assert.equal(commonjs.SenWeaveError,SenWeaveError);
assert.throws(()=>commonjs.check('[{"n":"x","v":1}]'),e=>e instanceof SenWeaveError);
${consumer}`);
  run(process.execPath, ['consumer.mjs'], directory);
  const legacy = join(directory, 'legacy');
  mkdirSync(legacy);
  writeFileSync(join(legacy, 'package.json'), JSON.stringify({ private: true, type: 'commonjs' }));
  writeFileSync(join(legacy, 'consumer.js'), `const assert=require('node:assert/strict');
const {check, resolve, SenWeaveError}=require('${manifest.name}');
${consumer}
import('${manifest.name}').then(module=>{
  assert.equal(module.check,check);
  assert.equal(module.SenWeaveError,SenWeaveError);
  assert.throws(()=>module.check('[{"n":"x","v":1}]'),e=>e instanceof SenWeaveError);
}).catch(error=>{console.error(error);process.exitCode=1;});`);
  run(process.execPath, ['--no-experimental-require-module', 'consumer.js'], legacy);
  const typing = `const input='[]';
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
void [json,binary,count,wrong,errorCode];`;
  writeFileSync(join(directory, 'consumer.mts'), `import {check, resolve, type ResolveOptions, type ResourceLimits, SenWeaveError} from '${manifest.name}';\n${typing}`);
  writeFileSync(join(legacy, 'consumer.cts'), `import sdk = require('${manifest.name}');
const {check, resolve, SenWeaveError}=sdk;
type ResolveOptions=sdk.ResolveOptions;
type ResourceLimits=sdk.ResourceLimits;
${typing}`);
  const tsc = join(root, 'node_modules/typescript/bin/tsc');
  const listing = run(process.execPath, [tsc, '--noEmit', '--strict', '--module', 'NodeNext', '--target', 'ES2022', '--listFiles', 'consumer.mts', 'legacy/consumer.cts'], directory).replaceAll('\\', '/');
  for (const path of ['dist/index.d.mts', 'dist/index.d.cts']) assert.ok(listing.includes(path), `TypeScript did not select ${path}`);
  run(process.execPath, [tsc, '--noEmit', '--strict', '--module', 'CommonJS', '--moduleResolution', 'Node', '--target', 'ES2022', 'consumer.cts'], legacy);
  console.log(JSON.stringify({ package: manifest.name, version: manifest.version, files: paths.length,
    runtimeConsumers: ['esm', 'commonjs', 'mixed-identity'], typescriptConsumers: ['NodeNext ESM', 'NodeNext CommonJS', 'CommonJS Node resolution'],
    status: 'passed', integrity: packed.integrity, archive: `_build/npm/${packed.filename}` }));
} finally {
  assert.equal(dirname(resolve(directory)), resolve(tmpdir()));
  rmSync(directory, { recursive: true, force: true });
}
