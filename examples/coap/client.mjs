import { createSocket } from 'node:dgram';
import { createRequire } from 'node:module';
import { randomBytes, randomInt } from 'node:crypto';
import { performance } from 'node:perf_hooks';

function failure(code, message) { return Object.assign(new Error(message), { code }); }

// Single-upload loopback host. MoonBit/MoonCoAP own packet validation,
// correlation and retries; the host supplies sockets, monotonic time and entropy.
export async function sendMeasurement({ port, payload, source, key, format = 110, mid = randomInt(65536), timeout = 10000, signal }) {
  const identifier = value => typeof value === 'string' && /^[A-Za-z0-9._-]{1,64}$/.test(value);
  if (!Number.isInteger(port) || port < 1 || port > 65535 || !Buffer.isBuffer(payload) || payload.length > 8192 ||
      ![110, 112].includes(format) || !Number.isInteger(mid) || mid < 0 || mid > 65535 ||
      !Number.isInteger(timeout) || timeout < 1 || timeout > 10000 ||
      (signal !== undefined && !(signal instanceof AbortSignal)) ||
      ((source !== undefined || key !== undefined) && (!identifier(source) || !identifier(key)))) throw failure('InvalidRequest', 'Invalid request');
  const aborted = () => failure('ABORT_ERR', 'CoAP upload cancelled');
  if (signal?.aborted) throw aborted();
  let core;
  try { core = createRequire(import.meta.url)('../../_build/js/release/build/cmd/coapbridge/coapbridge.js'); }
  catch { throw failure('BuildRequired', 'Build the CoAP bridge before running the client'); }
  if (['new_sender', 'sender_start', 'sender_receive', 'sender_poll', 'sender_cancel', 'sender_deadline'].some(name => typeof core[name] !== 'function')) {
    throw failure('BuildRequired', 'Rebuild the CoAP bridge for this client version');
  }
  const seed = (randomBytes(8).readBigUInt64BE() & 0x7ffffffffffffffen).toString(16);
  const sender = core.new_sender(mid, seed, Math.max(2000, timeout));
  if (!sender) throw failure('InvalidConfig', 'Could not create the CoAP sender');
  const socket = createSocket('udp4');
  const now = () => Math.floor(performance.now());
  let deadlineTimer, retryTimer, abort, settled = false, terminal, pending = 0;
  let emptyAck = false, attempts = 0;
  try {
    return await new Promise((resolve, reject) => {
      function finish(error, result) {
        if (settled) return;
        clearTimeout(deadlineTimer); clearTimeout(retryTimer);
        if (error) {
          settled = true;
          error.attempts = attempts; error.emptyAck = emptyAck;
          reject(error);
        } else {
          terminal ??= result;
          if (pending === 0) { settled = true; resolve(terminal); }
        }
      }
      function schedule() {
        clearTimeout(retryTimer);
        const deadline = core.sender_deadline(sender);
        if (!settled && !terminal && deadline >= 0 && Number.isFinite(deadline)) {
          retryTimer = setTimeout(() => handle(core.sender_poll(sender, now())), Math.max(1, deadline - now()));
        }
      }
      function handle(encoded, response) {
        if (settled || terminal) return;
        for (const event of JSON.parse(encoded)) {
          if (event.kind === 'send') {
            const wire = Buffer.from(event.hex, 'hex');
            if (wire[1] === 2) attempts++;
            pending++;
            socket.send(wire, port, '127.0.0.1', error => {
              pending--;
              if (settled) return;
              if (error) finish(failure('CoapTransport', 'Could not send the CoAP datagram'));
              else if (terminal) finish(undefined, terminal);
            });
          } else if (event.kind === 'acknowledged') emptyAck = true;
          else if (event.kind === 'received') finish(undefined, { code: event.code, emptyAck, attempts, responseHex: response.toString('hex') });
          else if (event.kind === 'failed') finish(failure(event.code === 'TimedOut' ? 'CoapTimeout' : event.code, 'CoAP upload failed'));
          if (settled || terminal) break;
        }
        schedule();
      }
      abort = () => {
        core.sender_cancel(sender, now());
        finish(aborted());
      };
      socket.on('error', () => finish(failure('CoapTransport', 'CoAP socket failed')));
      socket.on('message', (message, remote) => {
        if (remote.address === '127.0.0.1' && remote.port === port && !settled && !terminal && message.length <= 9000) {
          handle(core.sender_receive(sender, message.toString('hex'), now()), message);
        }
      });
      signal?.addEventListener('abort', abort, { once: true });
      if (signal?.aborted) { abort(); return; }
      socket.bind(0, '127.0.0.1', () => {
        if (settled) return;
        deadlineTimer = setTimeout(() => {
          core.sender_cancel(sender, now());
          finish(failure('CoapTimeout', 'CoAP response timeout'));
        }, timeout);
        handle(core.sender_start(sender, payload.toString('hex'), format, source ?? '', key ?? '', now(), randomInt(1000001)));
      });
    });
  } finally {
    clearTimeout(deadlineTimer); clearTimeout(retryTimer);
    if (abort) signal?.removeEventListener('abort', abort);
    try { socket.close(); } catch { /* Binding may have failed or been cancelled. */ }
  }
}
