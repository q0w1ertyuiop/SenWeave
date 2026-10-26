import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createSocket } from 'node:dgram';
import { once } from 'node:events';
import { mkdtempSync, mkdirSync, copyFileSync, writeFileSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { pathToFileURL } from 'node:url';
import { sendMeasurement } from '../examples/coap/client.mjs';

async function peer(t) {
  const socket = createSocket('udp4');
  socket.bind(0, '127.0.0.1');
  await once(socket, 'listening');
  t.after(() => socket.close());
  return socket;
}

function reply(wire, code = 68, separate = false) {
  const token = wire.subarray(4, 4 + (wire[0] & 15));
  return Buffer.concat([Buffer.from([ (separate ? 0x40 : 0x60) | token.length, code,
    separate ? 1 : wire[2], separate ? 244 : wire[3] ]), token]);
}

test('upload retries a dropped request with identical bytes and default CoAP timing', { timeout: 10000 }, async t => {
  const server = await peer(t), requests = [];
  server.on('message', (wire, remote) => {
    requests.push(Buffer.from(wire));
    if (requests.length === 2) server.send(reply(wire), remote.port, remote.address);
  });
  const result = await sendMeasurement({ port: server.address().port, payload: Buffer.from('[]'), timeout: 8000 });
  assert.equal(result.code, 68);
  assert.equal(result.attempts, 2);
  assert.equal(requests.length, 2);
  assert.deepEqual(requests[1], requests[0]);
  assert.equal(requests[0][0] & 15, 8);
});

test('upload ignores malformed responses wrong tokens and foreign peers', async t => {
  const server = await peer(t), foreign = await peer(t);
  server.once('message', (wire, remote) => {
    const valid = reply(wire), wrongToken = Buffer.from(valid);
    wrongToken[4] ^= 1;
    foreign.send(reply(wire, 137), remote.port, remote.address);
    server.send(reply(wire, 2), remote.port, remote.address);
    server.send(wrongToken, remote.port, remote.address);
    server.send(Buffer.from([0x69, 68, 0, 10]), remote.port, remote.address);
    setImmediate(() => server.send(valid, remote.port, remote.address));
  });
  const result = await sendMeasurement({ port: server.address().port, payload: Buffer.from('[]') });
  assert.equal(result.code, 68);
  assert.equal(result.attempts, 1);
});

test('upload distinguishes an empty ACK and acknowledges a separate response MID', async t => {
  const server = await peer(t);
  let acknowledge;
  const acknowledged = new Promise(resolve => { acknowledge = resolve; });
  server.on('message', (wire, remote) => {
    if (wire[1] === 0) { acknowledge(wire); return; }
    server.send(Buffer.from([0x60, 0, wire[2], wire[3]]), remote.port, remote.address);
    server.send(reply(wire, 68, true), remote.port, remote.address);
  });
  const result = await sendMeasurement({ port: server.address().port, payload: Buffer.from('[]') });
  assert.equal(result.code, 68);
  assert.equal(result.emptyAck, true);
  const controller = new AbortController();
  const limit = setTimeout(() => controller.abort(), 1000);
  t.after(() => clearTimeout(limit));
  const ack = await Promise.race([acknowledged, once(controller.signal, 'abort').then(() => { throw new Error('No response ACK'); })]);
  assert.deepEqual(ack, Buffer.from([0x60, 0, 1, 244]));
});

test('timeout preserves whether transport was acknowledged and never reports storage success', async t => {
  const server = await peer(t);
  server.on('message', (wire, remote) => server.send(Buffer.from([0x60, 0, wire[2], wire[3]]), remote.port, remote.address));
  await assert.rejects(sendMeasurement({ port: server.address().port, payload: Buffer.from('[]'), timeout: 1000 }), error => {
    assert.equal(error.code, 'CoapTimeout');
    assert.equal(error.emptyAck, true);
    assert.equal(error.attempts, 1);
    return true;
  });
});

test('abort before binding and during an upload cancels without echoing the reason', async t => {
  const server = await peer(t), controller = new AbortController();
  let received = 0;
  server.on('message', () => { received++; controller.abort('private-cancellation-reason'); });
  await assert.rejects(sendMeasurement({ port: server.address().port, payload: Buffer.from('[]'), signal: controller.signal }), error => {
    assert.equal(error.code, 'ABORT_ERR');
    assert.equal(error.message.includes('private-cancellation-reason'), false);
    return true;
  });
  await assert.rejects(sendMeasurement({ port: server.address().port, payload: Buffer.from('[]'), signal: controller.signal }), { code: 'ABORT_ERR' });
  assert.equal(received, 1);
});

test('invalid payload and arguments are rejected without putting packets on the wire', async t => {
  const server = await peer(t);
  let received = 0;
  server.on('message', () => { received++; });
  await assert.rejects(sendMeasurement({ port: server.address().port, payload: Buffer.from('[{}]') }), { code: 'InvalidPayload', attempts: 0 });
  await assert.rejects(sendMeasurement({ port: server.address().port, payload: Buffer.from('[]'), signal: {} }), { code: 'InvalidRequest' });
  assert.equal(received, 0);
});

test('source client reports BuildRequired for a stale compiled bridge', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'senweave-stale-bridge-'));
  try {
    const example = join(directory, 'examples/coap');
    const compiled = join(directory, '_build/js/release/build/cmd/coapbridge');
    mkdirSync(example, { recursive: true }); mkdirSync(compiled, { recursive: true });
    copyFileSync(new URL('../examples/coap/client.mjs', import.meta.url), join(example, 'client.mjs'));
    writeFileSync(join(compiled, 'coapbridge.js'), 'module.exports = {};\n');
    const { sendMeasurement: stale } = await import(pathToFileURL(join(example, 'client.mjs')).href);
    await assert.rejects(stale({ port: 1, payload: Buffer.from('[]') }), { code: 'BuildRequired' });
  } finally {
    assert.equal(dirname(resolve(directory)), resolve(tmpdir()));
    rmSync(directory, { recursive: true, force: true });
  }
});
