import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, realpathSync, writeFileSync, readFileSync, existsSync, readdirSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const cli = fileURLToPath(new URL('../bin/senweave.mjs', import.meta.url));
const parent = realpathSync(tmpdir());
const directory = mkdtempSync(join(parent, 'senweave-cli-'));
after(() => {
  assert.equal(dirname(realpathSync(directory)), parent);
  rmSync(directory, { recursive: true, force: true });
});

function run(args, input = undefined) {
  const result = spawnSync(process.execPath, [cli, ...args], {
    cwd: directory, input, timeout: 15_000, maxBuffer: 8_388_608,
  });
  assert.equal(result.error, undefined);
  return { status: result.status, out: result.stdout, err: result.stderr.toString('utf8') };
}

const absolute = '[{"n":"x","v":1,"t":1793000000}]';
const gateway = '[{"bn":"dev:","bv":20},{"n":"temp","v":2.5,"t":-2},{"n":"door","vb":false}]';

test('stdin resolution, exact-name filtering and complete validation', () => {
  const result = run(['resolve', '--now', '1793000000', '--name', 'dev:temp'], gateway);
  assert.equal(result.status, 0);
  assert.deepEqual(JSON.parse(result.out), [{ n: 'dev:temp', t: 1792999998, v: 22.5 }]);
  assert.equal(result.err, '');
  const check = run(['check'], absolute);
  assert.equal(check.status, 0);
  assert.deepEqual(JSON.parse(check.out), { valid: true, stage: 'resolved', raw_records: 1, measurements: 1, ignored_extensions: 0 });
});

test('files with spaces and Unicode work outside the repository working directory', () => {
  const input = join(directory, '传感器 input.json');
  const output = join(directory, '测量 output.json');
  writeFileSync(input, absolute);
  const result = run(['resolve', input, '--output', output]);
  assert.equal(result.status, 0);
  assert.equal(result.out.length, 0);
  assert.deepEqual(JSON.parse(readFileSync(output)), [{ n: 'x', t: 1793000000, v: 1 }]);
  assert.equal(readFileSync(input, 'utf8'), absolute);
  assert.equal(readdirSync(directory).some(name => name.startsWith('.senweave-')), false);
});

test('existing outputs and the input itself are preserved', () => {
  const input = join(directory, 'original.json');
  const output = join(directory, 'existing.json');
  writeFileSync(input, absolute);
  writeFileSync(output, 'keep me');
  for (const destination of [input, output]) {
    const result = run(['resolve', input, '--output', destination]);
    assert.equal(result.status, 2);
    assert.equal(JSON.parse(result.err).code, 'OutputExists');
    assert.equal(result.out.length, 0);
  }
  assert.equal(readFileSync(input, 'utf8'), absolute);
  assert.equal(readFileSync(output, 'utf8'), 'keep me');
  assert.equal(readdirSync(directory).some(name => name.startsWith('.senweave-')), false);
});

test('invalid or unresolved data creates no output file and emits a structured diagnostic', () => {
  const output = join(directory, 'must-not-exist.json');
  const result = run(['resolve', '--output', output], '[{"bn":"dev:"},{"n":"x","v":1}]');
  assert.equal(result.status, 1);
  assert.equal(result.out.length, 0);
  assert.equal(existsSync(output), false);
  const diagnostic = JSON.parse(result.err);
  assert.equal(diagnostic.code, 'MissingReferenceTime');
  assert.equal(diagnostic.record_index, 1);
  assert.equal(diagnostic.field, 't');
  const duplicate = run(['check'], '[{"n":"x","v":12345,"v":67890}]');
  assert.equal(duplicate.status, 1);
  assert.equal(JSON.parse(duplicate.err).code, 'DuplicateKey');
  assert.equal(duplicate.err.includes('12345'), false);
});

test('strict UTF-8 admission rejects invalid sequences and retains a BOM for JSON validation', () => {
  const malformed = run(['check'], Buffer.from([0xff]));
  assert.equal(malformed.status, 1);
  assert.equal(JSON.parse(malformed.err).code, 'InvalidUtf8');
  const bom = run(['check'], Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from(absolute)]));
  assert.equal(bom.status, 1);
  assert.equal(JSON.parse(bom.err).code, 'InvalidJson');
});

test('file and pipe inputs are bounded before parsing', () => {
  const tooLarge = Buffer.alloc(1_048_577, 32);
  writeFileSync(join(directory, 'large.json'), tooLarge);
  for (const result of [run(['check', 'large.json']), run(['check'], tooLarge)]) {
    assert.equal(result.status, 1);
    assert.equal(result.out.length, 0);
    assert.equal(JSON.parse(result.err).code, 'InputLimit');
  }
});

test('JSON CBOR JSON conversion preserves binary data and 64-bit integer text', () => {
  const input = '[{"bn":"dev:","bt":1793000000},{"n":"counter","v":18446744073709551615},{"n":"blob","vd":"----____"}]';
  const encoded = run(['resolve', '--to', 'cbor'], input);
  assert.equal(encoded.status, 0);
  assert.equal(encoded.out[0], 0x82);
  const decoded = run(['resolve', '--from', 'cbor'], encoded.out);
  assert.equal(decoded.status, 0);
  assert.match(decoded.out.toString(), /18446744073709551615/);
  assert.match(decoded.out.toString(), /"vd":"----____"/);
  const file = join(directory, 'measurements.cbor');
  const written = run(['resolve', '--to', 'cbor', '--output', file], input);
  assert.equal(written.status, 0);
  assert.deepEqual(readFileSync(file), encoded.out);
});

test('extension loss is reported and can be rejected before output creation', () => {
  const input = '[{"n":"x","v":1,"t":1793000000,"vendor":true}]';
  const normal = run(['resolve'], input);
  assert.equal(normal.status, 0);
  assert.equal(JSON.parse(normal.err).code, 'IgnoredExtensions');
  assert.equal(JSON.parse(normal.err).count, 1);
  assert.equal(normal.out.includes('vendor'), false);
  const output = join(directory, 'strict.json');
  const strict = run(['resolve', '--reject-extensions', '--output', output], input);
  assert.equal(strict.status, 1);
  assert.equal(JSON.parse(strict.err).code, 'IgnoredExtensions');
  assert.equal(existsSync(output), false);
});

test('bad options are usage errors and help is available without reading input', () => {
  for (const args of [[], ['bad'], ['check', '--from', 'xml'], ['resolve', '--now'], ['resolve', '--now', 'NaN'], ['resolve', '--name', ''], ['check', '--to', 'cbor'], ['resolve', '--from', 'json', '--from', 'cbor']]) {
    const result = run(args);
    assert.equal(result.status, 2);
    assert.equal(JSON.parse(result.err).code, 'Usage');
    assert.equal(result.out.length, 0);
  }
  assert.match(run(['--help']).out.toString(), /SenWeave/);
});

test('literal option-like filenames and explicit stdout are supported', () => {
  writeFileSync(join(directory, '--help'), absolute);
  const result = run(['resolve', '--output', '-', '--', '--help']);
  assert.equal(result.status, 0);
  assert.deepEqual(JSON.parse(result.out), [{ n: 'x', t: 1793000000, v: 1 }]);
  assert.equal(existsSync(join(directory, '-')), false);
});

test('missing files and missing output directories are I/O failures', () => {
  assert.equal(JSON.parse(run(['check', 'absent.json']).err).code, 'InputIO');
  const result = run(['resolve', '--output', join(directory, 'absent', 'result.json')], absolute);
  assert.equal(result.status, 2);
  assert.equal(JSON.parse(result.err).code, 'OutputIO');
});

test('concurrent writers publish one complete output without replacing it', async () => {
  const output = join(directory, 'exclusive.json');
  function writer(value) {
    return new Promise((resolve, reject) => {
      const child = spawn(process.execPath, [cli, 'resolve', '--output', output], { cwd: directory });
      let errorText = '';
      child.stderr.setEncoding('utf8').on('data', chunk => { errorText += chunk; });
      child.stdout.resume();
      child.on('error', reject);
      child.on('close', status => resolve({ status, errorText }));
      child.stdin.end(`[{"n":"x","v":${value},"t":1793000000}]`);
    });
  }
  const results = await Promise.all([writer(1), writer(2)]);
  assert.deepEqual(results.map(result => result.status).sort(), [0, 2]);
  assert.equal(JSON.parse(results.find(result => result.status === 2).errorText).code, 'OutputExists');
  const final = JSON.parse(readFileSync(output));
  assert.equal(final.length, 1);
  assert.ok([1, 2].includes(final[0].v));
  assert.equal(final[0].t, 1793000000);
  assert.equal(readdirSync(directory).some(name => name.startsWith('.senweave-')), false);
});
