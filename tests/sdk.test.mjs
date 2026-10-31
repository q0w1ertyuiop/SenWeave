import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { spawnSync } from 'node:child_process';
import { check, resolve, SenWeaveError } from '../js/index.mjs';

const require = createRequire(import.meta.url);
const commonjs = require('../js/index.cjs');

const source = '[{"bn":"sensor:","bt":1793000000},{"n":"counter","v":18446744073709551615},{"n":"door","vb":false}]';
const rejected = code => error => error instanceof SenWeaveError && error.code === code && error.diagnostic.code === code;

test('SDK exchanges XML JSON and CBOR without changing exact measurement values', () => {
  const xml = resolve(source, { to: 'xml' });
  assert.equal(xml.format, 'xml');
  assert.equal(typeof xml.data, 'string');
  assert.ok(xml.data.includes('18446744073709551615'));
  assert.equal(check(xml.data, { from: 'xml' }).measurements, 2);
  const padded = Buffer.concat([Buffer.from([255]), Buffer.from(xml.data), Buffer.from([255])]);
  assert.equal(resolve(padded.subarray(1, padded.length - 1), { from: 'xml' }).data, resolve(source).data);
  const cbor = resolve(xml.data, { from: 'xml', to: 'cbor' });
  assert.equal(resolve(cbor.data, { from: 'cbor', to: 'xml' }).data, xml.data);
  const text = '[{"n":"text","vs":"\\t\\r\\n<&>门🚪","t":1793000000}]';
  assert.equal(resolve(resolve(text, { to: 'xml' }).data, { from: 'xml' }).data, resolve(text).data);
});

test('SDK XML ingress applies UTF-8 quotas extension policy and private diagnostics', () => {
  const xml = '<sensml xmlns="urn:ietf:params:xml:ns:senml"><senml n="x" v="1" vendor="extra"/></sensml>';
  assert.equal(resolve(xml, { from: 'xml', referenceTime: 1793000000 }).ignoredExtensions, 1);
  assert.throws(() => resolve(xml, { from: 'xml', rejectExtensions: true }), rejected('IgnoredExtensions'));
  assert.throws(() => check(xml, { from: 'xml', limits: { maxDepth: 1 } }), rejected('NestingLimit'));
  assert.throws(() => check(xml, { from: 'xml', limits: { maxInputBytes: 8 } }), rejected('InputLimit'));
  assert.throws(() => check(new Uint8Array([255]), { from: 'xml' }), rejected('InvalidUtf8'));
  assert.throws(() => check(String.fromCharCode(0xd800), { from: 'xml' }), rejected('InvalidXml'));
  const bad = '<sensml xmlns="urn:ietf:params:xml:ns:senml"><senml n="private-device" vs="private-value" secret_="yes"/></sensml>';
  assert.throws(() => check(bad, { from: 'xml' }), error => {
    assert.equal(error.code, 'UnsupportedExtension');
    assert.equal(error.diagnostic.field, undefined);
    assert.doesNotMatch(JSON.stringify(error.diagnostic), /private-device|private-value|secret_/);
    return true;
  });
});

test('SDK XML output refuses invalid XML characters and conservative output overruns', () => {
  assert.throws(() => resolve('[{"n":"x","vs":"\\u0000","t":1793000000}]', { to: 'xml' }), rejected('InvalidXml'));
  assert.throws(() => resolve(source, { to: 'xml', limits: { maxOutputBytes: 60 } }), rejected('OutputLimit'));
  const xml = resolve(source, { to: 'xml', name: 'sensor:counter' }).data;
  assert.equal(check(xml, { from: 'xml' }).measurements, 1);
});

test('SDK accepts CBOR variants and preserves wide negative integer text across formats', () => {
  for (const [hex, literal] of [
    ['81bf0061780201ff', '1'],
    ['9801b802180078017818021801', '1'],
    ['81a2006178023b8000000000000000', '-9223372036854775809'],
    ['81a2006178023bfffffffffffffffe', '-18446744073709551615'],
    ['81a2006178023bffffffffffffffff', '-18446744073709551616'],
  ]) {
    const input = Uint8Array.from(Buffer.from(hex, 'hex'));
    const options = { from: 'cbor', referenceTime: 1793000000 };
    assert.equal(check(input, options).measurements, 1);
    const json = resolve(input, options).data;
    assert.ok(json.includes(`"v":${literal}`));
    const cbor = resolve(input, { ...options, to: 'cbor' }).data;
    assert.equal(resolve(cbor, { from: 'cbor' }).data, json);
  }
});

test('ESM and CommonJS share functions and error identity in one process', () => {
  assert.equal(commonjs.check, check);
  assert.equal(commonjs.resolve, resolve);
  assert.equal(commonjs.SenWeaveError, SenWeaveError);
  assert.equal(Object.isFrozen(commonjs), true);
  assert.throws(() => commonjs.check('[{"n":"x","v":1}]'), rejected('MissingReferenceTime'));
  assert.throws(() => check('[{"n":"x","v":1}]'), error => error instanceof commonjs.SenWeaveError);
  assert.equal(commonjs.resolve(source, { to: 'cbor' }).data instanceof Uint8Array, true);
});

test('package conditional exports route both consumers to the shared SDK', async () => {
  const imported = await import('@q0w1ertyuiop/senweave');
  const required = require('@q0w1ertyuiop/senweave');
  assert.equal(imported.check, required.check);
  assert.equal(imported.SenWeaveError, required.SenWeaveError);
  assert.deepEqual(required.check(source), check(source));
});

test('CommonJS SDK does not rely on loading ESM through require', () => {
  const runtime = spawnSync(process.execPath, ['--no-experimental-require-module', '-e',
    'const sdk=require("@q0w1ertyuiop/senweave"); if(sdk.check("[]").valid!==true)process.exit(1);'],
  { cwd: new URL('../', import.meta.url), encoding: 'utf8' });
  assert.equal(runtime.status, 0, runtime.stderr);
});

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

test('SDK retains binary content metadata through every format and independent filtering', () => {
  const input = JSON.stringify([{ bct: '60', bt: 1793000000 },
    { n: 'blob', vd: 'AP8' }, { n: 'temp', v: 7 },
    { n: 'photo', vd: 'AA', ct: 'image/png' }]);
  const expected = [{ n: 'blob', t: 1793000000, vd: 'AP8', ct: '60' },
    { n: 'temp', t: 1793000000, v: 7 },
    { n: 'photo', t: 1793000000, vd: 'AA', ct: 'image/png' }];
  for (const to of ['json', 'cbor', 'xml']) {
    const wire = resolve(input, { to, rejectExtensions: true });
    assert.equal(wire.ignoredExtensions, 0);
    assert.equal(check(wire.data, { from: to, rejectExtensions: true }).measurements, 3);
    assert.deepEqual(JSON.parse(resolve(wire.data, { from: to }).data), expected);
    assert.deepEqual(JSON.parse(resolve(wire.data, { from: to, name: 'blob' }).data), [expected[0]]);
  }
});

test('SDK rejects content format errors and counts inherited metadata before filtering', () => {
  assert.throws(() => check('[{"n":"x","vd":"AA","ct":"private-format"}]'), error => {
    assert.equal(error.code, 'InvalidContentFormat');
    assert.equal(error.diagnostic.field, 'ct');
    assert.doesNotMatch(JSON.stringify(error.diagnostic), /private-format/);
    return true;
  });
  assert.throws(() => check('[{"n":"x","v":1,"ct":"60"}]'), rejected('InvalidRecord'));
  const input = JSON.stringify([{ bct: 'application/' + 'a'.repeat(100) }, { n: 'x', vd: 'AA' }]);
  assert.throws(() => resolve(input, { referenceTime: 1793000000, name: 'missing',
    limits: { maxExpandedCodeUnits: 300 } }), rejected('ExpansionLimit'));
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

test('SDK enforces smaller application quotas in both representations before filtering', () => {
  const binary = resolve(source, { to: 'cbor' }).data;
  for (const [input, from] of [[source, 'json'], [binary, 'cbor']]) {
    for (const [limits, code] of [
      [{ maxRecords: 1 }, 'RecordLimit'], [{ maxInputBytes: 1 }, 'InputLimit'],
      [{ maxFieldsPerRecord: 1 }, 'FieldLimit'], [{ maxStringCodeUnits: 3 }, 'StringLimit'],
      [{ maxNumberCodeUnits: 3 }, 'NumberLimit'], [{ maxExpandedCodeUnits: 2 }, 'ExpansionLimit'],
    ]) assert.throws(() => resolve(input, { from, name: 'missing', limits }), rejected(code));
    assert.equal(check(input, { from, limits: { maxRecords: 3 } }).measurements, 2);
  }
  assert.throws(() => check('[{"n":"x","v":1,"vendor":[[[]]]}]', { limits: { maxDepth: 3 } }), rejected('NestingLimit'));
  assert.throws(() => check(new Uint8Array([255, 255]), { limits: { maxInputBytes: 1 } }), rejected('InputLimit'));
});

test('SDK output quotas count UTF-8 bytes and keep empty format boundaries', () => {
  const input = '[{"n":"x","vs":"😀中","t":1793000000}]';
  const baseline = resolve(input).data, bytes = Buffer.byteLength(baseline);
  assert.equal(resolve(input, { limits: { maxOutputBytes: bytes } }).data, baseline);
  assert.throws(() => resolve(input, { limits: { maxOutputBytes: bytes - 1 } }), rejected('OutputLimit'));
  assert.equal(resolve('[]', { limits: { maxOutputBytes: 2, maxExpandedCodeUnits: 2 } }).data, '[]');
  assert.throws(() => resolve('[]', { limits: { maxOutputBytes: 1 } }), rejected('OutputLimit'));
  assert.deepEqual(resolve('[]', { to: 'cbor', limits: { maxOutputBytes: 1 } }).data, new Uint8Array([128]));
  assert.throws(() => resolve(source, { to: 'cbor', limits: { maxOutputBytes: 1 } }), rejected('OutputLimit'));
  assert.equal(check(source, { limits: { maxOutputBytes: 1 } }).valid, true);
});

test('SDK rejects invalid quotas and never inherits settings or invokes settings accessors', () => {
  for (const limits of [null, [], { extra: 1 }, { maxRecords: '1' }, { maxRecords: 0 },
    { maxRecords: -1 }, { maxRecords: 1.5 }, { maxRecords: 4097 }, { maxDepth: 33 },
    { maxInputBytes: Infinity }, { maxOutputBytes: NaN }, { [Symbol('quota')]: 1 }]) {
    assert.throws(() => check('[]', { limits }), rejected('InvalidLimits'));
  }
  let called = false;
  const accessor = { get maxRecords() { called = true; return 1; } };
  assert.throws(() => check('[]', { limits: accessor }), rejected('InvalidLimits'));
  assert.throws(() => check('[]', { get from() { called = true; return 'json'; } }), rejected('InvalidArguments'));
  assert.equal(called, false);
  assert.equal(check(source, Object.create({ from: 'cbor', limits: { maxRecords: 1 } })).measurements, 2);
  assert.equal(check(source, { limits: Object.create({ maxRecords: 1 }) }).measurements, 2);
  assert.equal(check(source, { limits: { maxRecords: undefined } }).measurements, 2);
});

test('SDK strict extension admission runs before expansion for JSON and CBOR', () => {
  const input = '[{"n":"x","v":1e308,"bv":1e308,"vendor":true}]';
  assert.throws(() => check(input, { rejectExtensions: true }), rejected('IgnoredExtensions'));
  const binary = Buffer.from('81a30061780201617af5', 'hex');
  assert.throws(() => check(binary, { from: 'cbor', rejectExtensions: true }), rejected('IgnoredExtensions'));
  assert.throws(() => check('[{"n":"x","v":1}]'), rejected('MissingReferenceTime'));
});

test('SDK diagnostics omit application-defined names in JSON and CBOR errors', () => {
  const inputs = [
    ['[{"n":"x","v":1,"private-key_":true}]', 'json'],
    ['[{"n":"x","v":1,"vendor":{"private-key":1,"private-key":2}}]', 'json'],
    [Buffer.from('81a300617802016c707269766174652d6b65795ff5', 'hex'), 'cbor'],
  ];
  for (const [input, from] of inputs) {
    assert.throws(() => check(input, { from }), error => {
      assert.equal(error instanceof SenWeaveError, true);
      assert.equal(error.diagnostic.field, undefined);
      assert.equal(JSON.stringify(error.diagnostic).includes('private-key'), false);
      return true;
    });
  }
});
