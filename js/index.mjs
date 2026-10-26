import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const DEFAULT_LIMITS = Object.freeze({
  maxInputBytes: 1_048_576, maxRecords: 4096, maxDepth: 32, maxFieldsPerRecord: 64,
  maxStringCodeUnits: 65_536, maxNumberCodeUnits: 128,
  maxExpandedCodeUnits: 4_194_304, maxOutputBytes: 4_194_304,
});
let bridge;

export class SenWeaveError extends Error {
  constructor(diagnostic) {
    super(diagnostic.message);
    this.name = 'SenWeaveError';
    this.code = diagnostic.code;
    this.diagnostic = Object.freeze({ ...diagnostic });
  }
}

function fail(code, message) { throw new SenWeaveError({ code, message }); }

function ownData(value, allowed, code) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) fail(code, 'Settings must be an object.');
  const result = Object.create(null);
  for (const key of Reflect.ownKeys(value)) {
    if (!allowed.includes(key)) fail(code, 'Unknown setting.');
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (!Object.hasOwn(descriptor, 'value')) fail(code, 'Settings must contain data properties.');
    result[key] = descriptor.value;
  }
  return result;
}

function limitsFor(limits = {}) {
  const values = ownData(limits, Object.keys(DEFAULT_LIMITS), 'InvalidLimits');
  const result = { ...DEFAULT_LIMITS };
  for (const [key, value] of Object.entries(values)) {
    if (value === undefined) continue;
    if (!Number.isSafeInteger(value) || value < 1 || value > DEFAULT_LIMITS[key]) fail('InvalidLimits', 'Quotas must be positive integers no larger than their defaults.');
    result[key] = value;
  }
  return result;
}

function optionsFor(options, resolve) {
  const allowed = ['from', 'referenceTime', 'rejectExtensions', 'limits', ...(resolve ? ['to', 'name'] : [])];
  options = ownData(options, allowed, 'InvalidArguments');
  const from = options.from === undefined ? 'json' : options.from;
  const to = options.to === undefined ? 'json' : options.to;
  if (!['json', 'cbor'].includes(from) || !['json', 'cbor'].includes(to)) fail('InvalidArguments', 'Formats must be json or cbor.');
  if (options.rejectExtensions !== undefined && typeof options.rejectExtensions !== 'boolean') fail('InvalidArguments', 'rejectExtensions must be boolean.');
  let reference = '';
  if (options.referenceTime !== undefined) {
    const value = options.referenceTime;
    if (!['string', 'number'].includes(typeof value)) fail('InvalidArguments', 'referenceTime must be a number or decimal string.');
    reference = String(value);
    if (reference.length > 128 || !/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$/.test(reference)) fail('InvalidReferenceTime', 'Reference time must be finite POSIX seconds.');
  }
  if (options.name !== undefined && (typeof options.name !== 'string' || !options.name || options.name.length > 65536 || !options.name.isWellFormed())) fail('InvalidArguments', 'name must be a nonempty bounded Unicode string.');
  return { from, to, reference, name: options.name ?? '',
    policy: { ...limitsFor(options.limits), rejectExtensions: options.rejectExtensions ?? false } };
}

function inputText(input, from, maxInput) {
  if (typeof input === 'string') {
    if (from !== 'json') fail('InvalidArguments', 'CBOR input must be Uint8Array bytes.');
    if (input.length > maxInput || Buffer.byteLength(input, 'utf8') > maxInput) fail('InputLimit', 'Input exceeds the configured byte limit.');
    if (!input.isWellFormed()) fail('InvalidJson', 'Input is not valid Unicode JSON text.');
    return input;
  }
  if (!(input instanceof Uint8Array)) fail('InvalidArguments', 'Input must be JSON text or Uint8Array bytes.');
  if (input.byteLength > maxInput) fail('InputLimit', 'Input exceeds the configured byte limit.');
  if (from === 'cbor') return Buffer.from(input.buffer, input.byteOffset, input.byteLength).toString('hex');
  try { return new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(input); }
  catch { fail('InvalidUtf8', 'Input is not valid UTF-8.'); }
}

function invoke(input, options, resolving) {
  const settings = optionsFor(options, resolving);
  const text = inputText(input, settings.from, settings.policy.maxInputBytes);
  if (!bridge) {
    try { bridge = require('../dist/bridge.cjs'); }
    catch { fail('BuildRequired', 'Build the SDK before importing source, or install the packed distribution.'); }
  }
  if (typeof bridge.process_input_with_policy !== 'function') fail('BuildRequired', 'Rebuild the SDK semantic core for this version.');
  let result;
  try { result = JSON.parse(bridge.process_input_with_policy(text, settings.from, resolving ? 'resolve' : 'check', settings.to, settings.reference, settings.name, JSON.stringify(settings.policy))); }
  catch { fail('CoreFailure', 'The semantic core did not return a valid response.'); }
  if (!result.ok) throw new SenWeaveError(result.error);
  return { result, settings };
}

export function check(input, options = {}) {
  const { result } = invoke(input, options, false);
  const summary = JSON.parse(result.data);
  return { valid: true, stage: 'resolved', rawRecords: summary.raw_records,
    measurements: summary.measurements, ignoredExtensions: summary.ignored_extensions };
}

export function resolve(input, options = {}) {
  const { result, settings } = invoke(input, options, true);
  const length = settings.to === 'json' ? Buffer.byteLength(result.data, 'utf8') : result.data.length / 2;
  if (length > settings.policy.maxOutputBytes) fail('OutputLimit', 'Output exceeds the configured byte limit.');
  return { format: settings.to, data: settings.to === 'json' ? result.data : Uint8Array.from(Buffer.from(result.data, 'hex')),
    ignoredExtensions: result.ignored_extensions };
}
