import { closeSync, lstatSync, openSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';

const applicationId = 0x53574c31;

// An example sink, separate from the MoonBit protocol/semantic library.
// JSON is bound as TEXT so the host never rounds measurement numbers.
export function openStore(path) {
  if (!path || path === ':memory:') throw new Error('A persistent file is required');
  let fresh = false;
  try { closeSync(openSync(path, 'wx', 0o600)); fresh = true; }
  catch (error) { if (error.code !== 'EEXIST') throw error; }
  const file = lstatSync(path);
  if (!file.isFile() || file.isSymbolicLink()) throw new Error('Expected a regular ledger file');
  const database = new DatabaseSync(path, { timeout: 0 });
  try {
    if (!fresh && (database.prepare('PRAGMA application_id').get().application_id !== applicationId ||
        database.prepare('PRAGMA user_version').get().user_version !== 1)) throw new Error('Unrecognized ledger');
    if (fresh) database.exec('PRAGMA page_size = 4096');
    if (database.prepare('PRAGMA page_size').get().page_size !== 4096) throw new Error('Unexpected page size');
    database.exec('PRAGMA journal_mode = DELETE; PRAGMA synchronous = FULL; PRAGMA max_page_count = 4096');
    if (database.prepare('PRAGMA synchronous').get().synchronous !== 2 ||
        database.prepare('PRAGMA max_page_count').get().max_page_count !== 4096) throw new Error('Storage limits unavailable');
    if (fresh) database.exec(`
      BEGIN IMMEDIATE;
      PRAGMA application_id = ${applicationId};
      PRAGMA user_version = 1;
      CREATE TABLE measurements (
        id INTEGER PRIMARY KEY,
        peer TEXT NOT NULL,
        received_at REAL NOT NULL,
        senml_json TEXT NOT NULL
      ) STRICT;
      COMMIT;
    `);
    const insert = database.prepare(`INSERT INTO measurements(peer, received_at, senml_json)
      SELECT ?, ?, ? WHERE (SELECT count(*) FROM measurements) < 4096`);
    return {
      append(peer, receivedAt, json) {
        database.exec('BEGIN IMMEDIATE');
        try {
          if (insert.run(peer, receivedAt, json).changes !== 1) throw new Error('Ledger row limit');
          database.exec('COMMIT');
        } catch (error) {
          try { database.exec('ROLLBACK'); } catch { /* SQLite may already have rolled back. */ }
          throw error;
        }
      },
      close() { database.close(); },
    };
  } catch (error) {
    database.close();
    throw error;
  }
}
