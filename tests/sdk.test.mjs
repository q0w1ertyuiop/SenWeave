import { test } from 'node:test';
import assert from 'node:assert/strict';
import { check, resolve, SenWeaveError } from '../js/index.mjs';

const source = '[{"bn":"sensor:","bt":1793000000},{"n":"counter","v":18446744073709551615},{"n":"door","vb":false}]';
const rejected = code => error => error instanceof SenWeaveError && error.code === code && error.diagnostic.code === code;

test('SDK validates complete resolution and returns explicit metadata', () => {
  assert.deepEqual(check(source), { valid: true, stage: 'resolved', rawRecords: 3, measurements: 2, ignoredExtensions: 0 });
  assert.throws(() => check('[{"n":"x","v":1}]'), rejected('MissingReferenceTime'));
  assert.throws(() => check('[{"n":"x","bv":1e308,"v":1e308}]', { referenceTime: 1793000000 }), rejected('ArithmeticOverflow'));
  assert.equal(check('[{"n":"x","v":1}]', { referenceTime: '1793000000' }).measurements, 1);
});

test('SDK preserves exact numeric text while filtering and crossing CBOR', () => {
  const selected = resolve(source, { name: 'sensor:counter' });
  assert.equal(selected.format, 'json');
  assert.equal(selected.data, '[{"n":"sensor:counter","t":1793000000,"v":18446744073709551615}]');
  const cbor = resolve(source, { name: 'sensor:counter', to: 'cbor' });
  assert.equal(cbor.data instanceof Uint8Array, true);
  assert.equal(resolve(cbor.data, { from: 'cbor' }).data, selected.data);
  assert.equal(resolve(source, { name: 'missing' }).data, '[]');
});

test('SDK respects byte slices and validates UTF-8 and host UTF-16 strings', () => {
  const bytes = Buffer.concat([Buffer.from([255]), Buffer.from(source), Buffer.from([255])]);
  assert.deepEqual(check(bytes.subarray(1, bytes.length - 1)), check(source));
  assert.throws(() => check(new Uint8Array([255])), rejected('InvalidUtf8'));
  assert.throws(() => check(new Uint8Array([0xef, 0xbb, 0xbf, 91, 93])), rejected('InvalidJson'));
  for (const invalid of [String.fromCharCode(0xd800), String.fromCharCode(0xdc00), String.fromCharCode(0xd800) + 'x']) {
    assert.throws(() => check('[{"n":"x","vs":"' + invalid + '","t":1793000000}]'), rejected('InvalidJson'));
    assert.throws(() => resolve(source, { name: invalid }), rejected('InvalidArguments'));
  }
  assert.equal(resolve('[{"n":"x","vs":"😀","t":1793000000}]').data.includes('😀'), true);
  const binary = resolve('[{"n":"blob","vd":"----____","t":1793000000}]', { to: 'cbor' });
  const padded = Buffer.concat([Buffer.from([255]), binary.data, Buffer.from([255])]);
  assert.equal(resolve(padded.subarray(1, padded.length - 1), { from: 'cbor' }).data.includes('----____'), true);
});

test('SDK surfaces extension loss and offers strict rejection', () => {
  const input = '[{"bn":"s:","vendor":true},{"n":"x","v":1}]';
  const result = resolve(input, { referenceTime: 1793000000 });
  assert.equal(result.ignoredExtensions, 1);
  assert.equal(result.data.includes('vendor'), false);
  assert.throws(() => resolve(input, { referenceTime: 1793000000, rejectExtensions: true }), rejected('IgnoredExtensions'));
});

test('SDK checks byte limits before decoding and validates options without coercion', () => {
  assert.throws(() => check(new Uint8Array(1_048_577).fill(255)), rejected('InputLimit'));
  assert.throws(() => check('中'.repeat(350000)), rejected('InputLimit'));
  for (const [input, options] of [[[], {}], ['[]', null], ['[]', { from: 'cbor' }], ['[]', { extra: true }],
    ['[]', { from: null }], ['[]', { rejectExtensions: 'true' }], ['[]', { referenceTime: {} }], ['[]', { to: 'cbor' }]]) {
    assert.throws(() => check(input, options), rejected('InvalidArguments'));
  }
  assert.throws(() => resolve(source, { name: '' }), rejected('InvalidArguments'));
  assert.throws(() => check('[]', { referenceTime: Infinity }), rejected('InvalidReferenceTime'));
});

test('SDK diagnostics keep locations without echoing rejected measurement content', () => {
  try { resolve('[{"n":"secret-device","v":"private-value"}]'); assert.fail('expected error'); }
  catch (error) {
    assert.equal(error instanceof SenWeaveError, true);
    assert.equal(error.code, 'WrongType');
    assert.equal(error.diagnostic.record_index, 0);
    assert.equal(error.diagnostic.field, 'v');
    assert.equal(Object.isFrozen(error.diagnostic), true);
    assert.equal(JSON.stringify(error.diagnostic).includes('private-value'), false);
    assert.equal(JSON.stringify(error.diagnostic).includes('secret-device'), false);
  }
});
