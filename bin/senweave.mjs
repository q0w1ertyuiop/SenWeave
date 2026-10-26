#!/usr/bin/env node
import { open, link, unlink } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { createRequire } from 'node:module';
import { randomUUID } from 'node:crypto';

const MAX_INPUT = 1_048_576;
const MAX_OUTPUT = 4_194_304;
const help = `SenWeave — check and resolve SenML files
Usage: node bin/senweave.mjs <check|resolve> [FILE|-] [options]
  --from json|cbor     Input format (default: json)
  --to json|cbor       Resolved output format (default: json)
  --now SECONDS        Explicit reference for relative times
  --name FULL_NAME     Select an exact resolved measurement name
  --output FILE       Create a new file; existing files are never overwritten
  --reject-extensions Reject ignored optional extensions
  --help              Show this help
Input defaults to stdin. Both commands validate resolution before output.
Exit: 0 success; 1 invalid data; 2 usage, build or I/O failure.
`;

class Failure extends Error {
  constructor(code, message, exit = 2) { super(message); this.code = code; this.exit = exit; }
}

function argumentsFor(argv) {
  const options = { action: argv[0], from: 'json', to: 'json', now: '', name: '', file: '-', output: null, strict: false };
  if (!['check', 'resolve'].includes(options.action)) throw new Failure('Usage', 'Expected check or resolve.');
  const names = new Map([['--from', 'from'], ['--to', 'to'], ['--now', 'now'], ['--name', 'name'], ['--output', 'output']]);
  const seen = new Set();
  let positional = false, literal = false;
  for (let i = 1; i < argv.length; i++) {
    const arg = argv[i];
    if (!literal && arg === '--') { literal = true; continue; }
    if (!literal && arg === '--reject-extensions') {
      if (seen.has(arg)) throw new Failure('Usage', 'Repeated option.');
      seen.add(arg); options.strict = true; continue;
    }
    if (!literal && names.has(arg)) {
      if (seen.has(arg) || i + 1 >= argv.length || argv[i + 1].startsWith('--')) throw new Failure('Usage', 'Missing value or repeated option.');
      seen.add(arg); options[names.get(arg)] = argv[++i]; continue;
    }
    if ((!literal && arg.startsWith('-') && arg !== '-') || positional) throw new Failure('Usage', 'Unknown option or extra input file.');
    positional = true; options.file = arg;
  }
  if (!['json', 'cbor'].includes(options.from) || !['json', 'cbor'].includes(options.to)) throw new Failure('Usage', 'Formats must be json or cbor.');
  if (seen.has('--now') && !/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$/.test(options.now)) throw new Failure('Usage', '--now requires a decimal timestamp.');
  if (seen.has('--name') && !options.name) throw new Failure('Usage', '--name cannot be empty.');
  if (options.output === '') throw new Failure('Usage', '--output cannot be empty.');
  if (options.action === 'check' && (seen.has('--name') || seen.has('--to'))) throw new Failure('Usage', '--name and --to apply to resolve.');
  return options;
}

async function readInput(file) {
  let handle;
  try {
    if (file !== '-') {
      handle = await open(file, 'r');
      const stat = await handle.stat();
      if (!stat.isFile()) throw new Failure('InputIO', 'Input must be a regular file.');
      if (stat.size > MAX_INPUT) throw new Failure('InputLimit', 'Input exceeds the 1 MiB byte limit.', 1);
    }
    const chunks = [];
    let length = 0;
    const stream = handle ? handle.createReadStream({ autoClose: false, highWaterMark: 65536 }) : process.stdin;
    for await (const chunk of stream) {
      length += chunk.length;
      if (length > MAX_INPUT) throw new Failure('InputLimit', 'Input exceeds the 1 MiB byte limit.', 1);
      chunks.push(chunk);
    }
    return Buffer.concat(chunks, length);
  } catch (error) {
    if (error instanceof Failure) throw error;
    throw new Failure('InputIO', 'Unable to read the input.');
  } finally { if (handle) await handle.close(); }
}

async function writeNewFile(file, data) {
  // A same-directory temporary inode is fully written before exclusive linking.
  // link fails if the destination exists, including a symlink or the input file.
  const temporary = join(dirname(file), `.senweave-${randomUUID()}.tmp`);
  let created = false;
  try {
    const handle = await open(temporary, 'wx', 0o600);
    created = true;
    try { await handle.writeFile(data); } finally { await handle.close(); }
    await link(temporary, file);
  } catch (error) {
    if (error.code === 'EEXIST') throw new Failure('OutputExists', 'Output already exists; choose a new filename.');
    throw new Failure('OutputIO', 'Unable to create the output file.');
  } finally { if (created) await unlink(temporary); }
}

async function main() {
  const args = process.argv.slice(2);
  const terminator = args.indexOf('--');
  if ((terminator < 0 ? args : args.slice(0, terminator)).includes('--help')) { process.stdout.write(help); return; }
  const options = argumentsFor(args);
  let core;
  try {
    core = createRequire(import.meta.url)('../_build/js/release/build/cmd/bridge/bridge.js');
  } catch {
    throw new Failure('BuildRequired', 'Build first: moon build cmd/bridge --target js --release');
  }
  const bytes = await readInput(options.file);
  let input;
  if (options.from === 'cbor') input = bytes.toString('hex');
  else {
    try { input = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes); }
    catch { throw new Failure('InvalidUtf8', 'Input is not valid UTF-8.', 1); }
  }
  const result = JSON.parse(core.process_input(input, options.from, options.action, options.to, options.now, options.name));
  if (!result.ok) {
    process.stderr.write(`${JSON.stringify(result.error)}\n`);
    process.exitCode = 1; return;
  }
  if (options.strict && result.ignored_extensions) throw new Failure('IgnoredExtensions', 'Optional extensions would be discarded.', 1);
  const output = options.action === 'resolve' && options.to === 'cbor'
    ? Buffer.from(result.data, 'hex') : Buffer.from(result.data + '\n', 'utf8');
  if (output.length > MAX_OUTPUT) throw new Failure('OutputLimit', 'Output exceeds the 4 MiB byte limit.', 1);
  if (options.output && options.output !== '-') await writeNewFile(options.output, output);
  else await new Promise((resolve, reject) => process.stdout.write(output, error => error ? reject(error) : resolve()));
  if (result.ignored_extensions) process.stderr.write(`${JSON.stringify({ code: 'IgnoredExtensions', count: result.ignored_extensions, message: 'Optional extension fields were discarded.' })}\n`);
}

process.stdout.on('error', () => {});
main().catch(error => {
  const failure = error instanceof Failure ? error : new Failure('HostFailure', 'The host operation failed.');
  process.stderr.write(`${JSON.stringify({ code: failure.code, message: failure.message })}\n`);
  process.exitCode = failure.exit;
});
