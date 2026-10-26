import { createSocket } from 'node:dgram';
import { createRequire } from 'node:module';
import { performance } from 'node:perf_hooks';

// This finite loopback demonstration has no external service or credentials.
const args = process.argv.slice(2);
let port = 0, duration = 10_000, reference;
try {
  const seen = new Set();
  for (let i = 0; i < args.length; i += 2) {
    const flag = args[i], text = args[i + 1];
    if (!['--port', '--duration-ms', '--now'].includes(flag) || seen.has(flag) || !text || !/^\d+(?:\.\d+)?$/.test(text)) throw new Error('options');
    seen.add(flag);
    const value = Number(text);
    if (!Number.isFinite(value)) throw new Error('number');
    if (flag === '--port') { if (!Number.isInteger(value) || value > 65535) throw new Error('port'); port = value; }
    if (flag === '--duration-ms') { if (!Number.isInteger(value) || value < 100 || value > 60_000) throw new Error('duration'); duration = value; }
    if (flag === '--now') { if (value < 268435456) throw new Error('clock'); reference = value; }
  }
} catch {
  process.stderr.write('Usage: node examples/coap/collector.mjs [--port 0..65535] [--duration-ms 100..60000] [--now POSIX_SECONDS]\n');
  process.exit(2);
}

let core;
try { core = createRequire(import.meta.url)('../../_build/js/release/build/cmd/coapbridge/coapbridge.js'); }
catch { process.stderr.write('Build first: moon build cmd/coapbridge --target js --release\n'); process.exit(2); }
const collector = core.new_collector();
const socket = createSocket('udp4');
let closed = false, pending = 0;
let pollTimer, stopTimer;
function stop() {
  if (closed) return;
  closed = true; clearInterval(pollTimer); clearTimeout(stopTimer);
  try { socket.close(); } catch { /* The socket may have failed before binding. */ }
}
function emit(event) {
  const line = JSON.stringify(event) + '\n';
  if (process.stdout.writableLength + Buffer.byteLength(line) > 1_048_576) { process.exitCode = 1; stop(); return; }
  process.stdout.write(line);
}
function handle(events) {
  for (const event of events) {
    if (closed) break;
    if (event.kind !== 'send') { emit(event); continue; }
    if (pending >= 32) { process.exitCode = 1; stop(); break; }
    const separator = event.peer.lastIndexOf(':');
    const address = event.peer.slice(0, separator), target = Number(event.peer.slice(separator + 1));
    if (separator < 0 || !address.startsWith('127.') || !Number.isInteger(target) || target < 1 || target > 65535) { process.exitCode = 1; stop(); break; }
    pending++;
    socket.send(Buffer.from(event.hex, 'hex'), target, address, error => {
      pending--; if (error && !closed) { process.exitCode = 1; stop(); }
    });
  }
}
socket.on('error', () => { process.exitCode = 1; stop(); });
process.stdout.on('error', () => { process.exitCode = 1; stop(); });
socket.on('message', (wire, remote) => {
  if (closed) return;
  const mono = Math.floor(performance.now());
  const receivedAt = reference ?? Date.now() / 1000;
  handle(JSON.parse(core.receive(collector, `${remote.address}:${remote.port}`, wire.toString('hex'), mono, receivedAt)));
});
socket.bind(port, '127.0.0.1', () => {
  emit({ kind: 'listening', address: '127.0.0.1', port: socket.address().port });
  if (closed) return;
  pollTimer = setInterval(() => handle(JSON.parse(core.poll(collector, Math.floor(performance.now())))), 100);
  stopTimer = setTimeout(stop, duration);
});
process.on('SIGINT', stop);
process.on('SIGTERM', stop);
