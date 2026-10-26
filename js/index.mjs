import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const MAX_INPUT = 1_048_576, MAX_OUTPUT = 4_194_304;
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

function optionsFor(options, resolve) {
  if (options === null || typeof options !== 'object' || Array.isArray(options)) fail('InvalidArguments', 'Options must be an object.');
  const allowed = ['from', 'referenceTime', 'rejectExtensions', ...(resolve ? ['to', 'name'] : [])];
  if (Reflect.ownKeys(options).some(key => !allowed.includes(key))) fail('InvalidArguments', 'Unknown option.');
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
  return { from, to, reference, name: options.name ?? '', strict: options.rejectExtensions ?? false };
}

function inputText(input, from) {
  if (typeof input === 'string') {
    if (from !== 'json') fail('InvalidArguments', 'CBOR input must be Uint8Array bytes.');
    if (input.length > MAX_INPUT || Buffer.byteLength(input, 'utf8') > MAX_INPUT) fail('InputLimit', 'Input exceeds the 1 MiB byte limit.');
    if (!input.isWellFormed()) fail('InvalidJson', 'Input is not valid Unicode JSON text.');
    return input;
  }
  if (!(input instanceof Uint8Array)) fail('InvalidArguments', 'Input must be JSON text or Uint8Array bytes.');
  if (input.byteLength > MAX_INPUT) fail('InputLimit', 'Input exceeds the 1 MiB byte limit.');
  if (from === 'cbor') return Buffer.from(input.buffer, input.byteOffset, input.byteLength).toString('hex');
  try { return new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(input); }
  catch { fail('InvalidUtf8', 'Input is not valid UTF-8.'); }
}

function invoke(input, options, resolving) {
  const settings = optionsFor(options, resolving);
  const text = inputText(input, settings.from);
  if (!bridge) {
    try { bridge = require('../dist/bridge.cjs'); }
    catch { fail('BuildRequired', 'Build the SDK before importing source, or install the packed distribution.'); }
  }
  let result;
  try { result = JSON.parse(bridge.process_input(text, settings.from, resolving ? 'resolve' : 'check', settings.to, settings.reference, settings.name)); }
  catch { fail('CoreFailure', 'The semantic core did not return a valid response.'); }
  if (!result.ok) throw new SenWeaveError(result.error);
  if (settings.strict && result.ignored_extensions > 0) fail('IgnoredExtensions', 'Optional extensions are rejected by the ingress policy.');
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
  if (length > MAX_OUTPUT) fail('OutputLimit', 'Output exceeds the 4 MiB byte limit.');
  return { format: settings.to, data: settings.to === 'json' ? result.data : Uint8Array.from(Buffer.from(result.data, 'hex')),
    ignoredExtensions: result.ignored_extensions };
}
