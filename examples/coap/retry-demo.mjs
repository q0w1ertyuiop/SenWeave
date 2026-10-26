import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtempSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { sendMeasurement } from './client.mjs';

const directory = mkdtempSync(join(tmpdir(), 'senweave-retry-demo-'));
const path = join(directory, 'measurements.sqlite');
const script = fileURLToPath(new URL('./collector.mjs', import.meta.url));
let server;

async function start(now) {
  const child = spawn(process.execPath, [script, '--port', '0', '--duration-ms', '10000', '--now', now, '--store', path]);
  server = child;
  const lines = createInterface({ input: child.stdout });
  let port;
  lines.on('line', line => { const event = JSON.parse(line); if (event.kind === 'listening') port = event.port; });
  child.stderr.resume();
  const deadline = Date.now() + 5000;
  while (!port) {
    if (child.exitCode !== null || Date.now() > deadline) throw new Error('Collector startup failed; build the bridge first');
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  return port;
}

async function stop() {
  if (!server || server.exitCode !== null || server.signalCode !== null) return;
  const exited = once(server, 'exit');
  server.kill(); await exited;
}

function snapshot() {
  const database = new DatabaseSync(path, { readOnly: true });
  try { return database.prepare('SELECT source, business_key, senml_json FROM measurements ORDER BY id').all(); }
  finally { database.close(); }
}

try {
  const payload = Buffer.from('[{"bn":"sensor:","bv":20},{"n":"temperature","v":2.5,"t":-3}]');
  let port = await start('1793000000');
  const first = await sendMeasurement({ port, payload, source: 'room-a', key: 'batch-1', mid: 10 });
  assert.equal(first.code, 68);
  const before = snapshot(); assert.equal(before.length, 1);
  console.log(JSON.stringify({ step: 'first-commit', response: '2.04', storedPacks: before.length }));
  await stop();
  port = await start('1793000600');
  const retried = await sendMeasurement({ port, payload, source: 'room-a', key: 'batch-1', mid: 20 });
  assert.equal(retried.code, 68); assert.deepEqual(snapshot(), before);
  console.log(JSON.stringify({ step: 'retry-after-restart', response: '2.04', storedPacks: 1, originalTimePreserved: true }));
  const changed = Buffer.from(payload.toString().replace('2.5', '3.5'));
  const conflict = await sendMeasurement({ port, payload: changed, source: 'room-a', key: 'batch-1', mid: 21 });
  assert.equal(conflict.code, 137); assert.deepEqual(snapshot(), before);
  console.log(JSON.stringify({ step: 'same-key-different-payload', response: '4.09', storedPacks: 1 }));
  const independent = await sendMeasurement({ port, payload, source: 'room-b', key: 'batch-1', mid: 22 });
  assert.equal(independent.code, 68); assert.equal(snapshot().length, 2);
  console.log(JSON.stringify({ step: 'different-source', response: '2.04', storedPacks: 2 }));
  console.log(JSON.stringify({ status: 'passed', requests: 4, restarts: 1, storedPacks: 2 }));
} finally {
  await stop();
  assert.equal(dirname(resolve(directory)), resolve(tmpdir()));
  rmSync(directory, { recursive: true, force: true });
}
