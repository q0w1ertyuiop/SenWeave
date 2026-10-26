import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { createSocket } from 'node:dgram';
import { createInterface } from 'node:readline';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { DatabaseSync } from 'node:sqlite';

const script = fileURLToPath(new URL('../examples/coap/collector.mjs', import.meta.url));

async function start(t, duration = '3000', extra = []) {
  const child = spawn(process.execPath, [script, '--duration-ms', duration, '--now', '1793000000', ...extra]);
  const events = [];
  const lines = createInterface({ input: child.stdout });
  let errors = '';
  child.stderr.setEncoding('utf8').on('data', text => { errors += text; });
  lines.on('line', line => events.push(JSON.parse(line)));
  t.after(() => { if (child.exitCode === null) child.kill(); lines.close(); });
  const deadline = Date.now() + 5000;
  while (!events.some(event => event.kind === 'listening')) {
    if (child.exitCode !== null || Date.now() > deadline) throw new Error(`Collector startup failed: ${errors}`);
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  return { child, events, port: events.find(event => event.kind === 'listening').port };
}

// Independent, fixed-shape test packets: CON POST, one-byte token, URI-Path,
// optional one-byte Content-Format and payload. MoonCoAP builds the replies.
function packet(mid, payload, format = 110, path = 'ingest', method = 2) {
  const header = Buffer.from([0x41, method, mid >> 8, mid & 255, 1]);
  const pathOption = Buffer.concat([Buffer.from([0xb0 + path.length]), Buffer.from(path)]);
  const content = format === null ? Buffer.alloc(0) : Buffer.from([0x11, format]);
  const bytes = Buffer.isBuffer(payload) ? payload : Buffer.from(payload);
  return Buffer.concat([header, pathOption, content, ...(bytes.length ? [Buffer.from([255]), bytes] : [])]);
}

async function client(t) {
  const socket = createSocket('udp4');
  socket.bind(0, '127.0.0.1');
  await once(socket, 'listening');
  t.after(() => socket.close());
  return socket;
}

function exchange(socket, port, wire) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { socket.off('message', received); reject(new Error('No CoAP reply')); }, 2000);
    function received(message) { clearTimeout(timer); resolve(message); }
    socket.once('message', received);
    socket.send(wire, port, '127.0.0.1', error => {
      if (error) { clearTimeout(timer); socket.off('message', received); reject(error); }
    });
  });
}

test('loopback UDP accepts JSON and CBOR and deduplicates retransmission', async t => {
  const server = await start(t);
  const socket = await client(t);
  const json = packet(10, '[{"bn":"sensor:","bv":20},{"n":"t","v":2.5,"t":-3}]');
  const first = await exchange(socket, server.port, json);
  assert.deepEqual(first, Buffer.from([0x61, 68, 0, 10, 1]));
  assert.deepEqual(await exchange(socket, server.port, json), first);
  const cbor = packet(11, Buffer.from('81a20064626c6f62084200ff', 'hex'), 112);
  assert.equal((await exchange(socket, server.port, cbor))[1], 68);
  const deadline = Date.now() + 1000;
  while (server.events.filter(event => event.kind === 'accepted').length < 2 && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 10));
  const accepted = server.events.filter(event => event.kind === 'accepted');
  assert.equal(accepted.length, 2);
  assert.deepEqual(JSON.parse(accepted[0].json), [{ n: 'sensor:t', t: 1792999997, v: 22.5 }]);
  assert.deepEqual(JSON.parse(accepted[1].json), [{ n: 'blob', t: 1793000000, vd: 'AP8' }]);
});

async function stop(child) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const exited = once(child, 'exit');
  child.kill();
  await exited;
}

function temporaryLedger() {
  const directory = mkdtempSync(join(tmpdir(), 'senweave-coap-'));
  return {
    path: join(directory, 'measurements.sqlite'),
    cleanup() {
      assert.equal(dirname(resolve(directory)), resolve(tmpdir()));
      rmSync(directory, { recursive: true, force: true });
    },
  };
}

async function separateExchange(socket, port, wire) {
  const messages = [];
  function collect(message) { messages.push(message); }
  socket.on('message', collect);
  try {
    socket.send(wire, port, '127.0.0.1');
    const deadline = Date.now() + 2000;
    while (!messages.some(message => message[1] !== 0)) {
      if (Date.now() >= deadline) throw new Error('No separate response');
      await new Promise(resolve => setTimeout(resolve, 5));
    }
    const reply = messages.find(message => message[1] !== 0);
    // ACK the separate CON response using its own MID, not the request MID.
    socket.send(Buffer.from([0x60, 0, reply[2], reply[3]]), port, '127.0.0.1');
    assert.deepEqual(messages[0], Buffer.from([0x60, 0, wire[2], wire[3]]));
    assert.equal(reply[0] >> 4 & 3, 0);
    assert.equal(reply[4], wire[4]);
    return reply;
  } finally { socket.off('message', collect); }
}

test('SQLite commits exact measurement text before 2.04, deduplicates live requests and reopens its ledger', async t => {
  const ledger = temporaryLedger();
  let server;
  try {
    server = await start(t, '5000', ['--store', ledger.path]);
    const socket = await client(t);
    const wire = packet(40, '[{"n":"counter","v":9007199254740993}]');
    assert.equal((await separateExchange(socket, server.port, wire))[1], 68);
    let database = new DatabaseSync(ledger.path, { readOnly: true });
    assert.equal(database.prepare('SELECT senml_json FROM measurements').get().senml_json,
      '[{"n":"counter","t":1793000000,"v":9007199254740993}]');
    database.close();
    assert.equal((await exchange(socket, server.port, wire))[1], 0);
    await stop(server.child);
    server = await start(t, '5000', ['--store', ledger.path]);
    assert.equal((await separateExchange(socket, server.port, packet(41, '[{"n":"second","v":2}]')))[1], 68);
    database = new DatabaseSync(ledger.path, { readOnly: true });
    assert.equal(database.prepare('SELECT count(*) AS count FROM measurements').get().count, 2);
    database.close();
  } finally { if (server) await stop(server.child); ledger.cleanup(); }
});

test('SQLite lock failure returns 5.00 without data and a later new request succeeds', async t => {
  const ledger = temporaryLedger();
  let server, database;
  try {
    server = await start(t, '5000', ['--store', ledger.path]);
    const socket = await client(t);
    database = new DatabaseSync(ledger.path);
    database.exec('BEGIN IMMEDIATE');
    assert.equal((await separateExchange(socket, server.port, packet(50, '[{"n":"locked","v":1}]')))[1], 160);
    assert.equal(database.prepare('SELECT count(*) AS count FROM measurements').get().count, 0);
    database.exec('ROLLBACK');
    assert.equal((await separateExchange(socket, server.port, packet(51, '[{"n":"ready","v":1}]')))[1], 68);
    assert.equal(database.prepare('SELECT count(*) AS count FROM measurements').get().count, 1);
  } finally { database?.close(); if (server) await stop(server.child); ledger.cleanup(); }
});

test('storage mode refuses unrelated databases and in-memory paths before binding', () => {
  const ledger = temporaryLedger();
  try {
    const database = new DatabaseSync(ledger.path);
    database.exec('CREATE TABLE unrelated(value TEXT); INSERT INTO unrelated VALUES (\'keep\')');
    database.close();
    const original = readFileSync(ledger.path);
    for (const path of [ledger.path, ':memory:']) {
      const result = spawnSync(process.execPath, [script, '--store', path], { encoding: 'utf8', timeout: 3000 });
      assert.equal(result.status, 2);
      assert.equal(result.stdout, '');
      assert.match(result.stderr, /StorageOpen/);
    }
    assert.deepEqual(readFileSync(ledger.path), original);
  } finally { ledger.cleanup(); }
});

test('SQLite row quota rejects new storage with 5.00 and preserves existing measurements', async t => {
  const ledger = temporaryLedger();
  let server, database;
  try {
    server = await start(t, '5000', ['--store', ledger.path]);
    database = new DatabaseSync(ledger.path);
    database.exec(`WITH RECURSIVE numbers(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM numbers WHERE n < 4096)
      INSERT INTO measurements(peer, received_at, senml_json) SELECT 'seed', 1793000000, '[]' FROM numbers`);
    const socket = await client(t);
    assert.equal((await separateExchange(socket, server.port, packet(60, '[{"n":"full","v":1}]')))[1], 160);
    assert.equal(database.prepare('SELECT count(*) AS count FROM measurements').get().count, 4096);
  } finally { database?.close(); if (server) await stop(server.child); ledger.cleanup(); }
});

test('loopback UDP rejects wrong metadata invalid UTF-8 and extension loss', async t => {
  const server = await start(t);
  const socket = await client(t);
  const cases = [
    [packet(20, '[]', null), 143], [packet(21, '[]', 50), 143],
    [packet(22, '[]', 110, 'other'), 132], [packet(23, '', 110, 'ingest', 1), 133],
    [packet(24, Buffer.from([255])), 128],
    [packet(25, '[{"n":"x","v":1,"secret":true}]'), 128],
  ];
  for (const [wire, code] of cases) assert.equal((await exchange(socket, server.port, wire))[1], code);
  assert.equal(server.events.some(event => event.kind === 'accepted'), false);
});

test('finite demo closes itself and invalid arguments fail before opening a port', async t => {
  const server = await start(t, '150');
  const [code] = await once(server.child, 'exit');
  assert.equal(code, 0);
  for (const args of [['--port', '65536'], ['--now', 'NaN'], ['--duration-ms', '0'], ['--port', '0', '--port', '1']]) {
    const result = spawnSync(process.execPath, [script, ...args], { encoding: 'utf8', timeout: 3000 });
    assert.equal(result.status, 2);
    assert.equal(result.stdout, '');
  }
});
