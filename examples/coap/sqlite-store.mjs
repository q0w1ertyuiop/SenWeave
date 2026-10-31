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
    const version = database.prepare('PRAGMA user_version').get().user_version;
    if (!fresh && (database.prepare('PRAGMA application_id').get().application_id !== applicationId ||
        ![1, 2].includes(version))) throw new Error('Unrecognized ledger');
    if (fresh) database.exec('PRAGMA page_size = 4096');
    if (database.prepare('PRAGMA page_size').get().page_size !== 4096) throw new Error('Unexpected page size');
    database.exec('PRAGMA journal_mode = DELETE; PRAGMA synchronous = FULL; PRAGMA max_page_count = 4096');
    if (database.prepare('PRAGMA synchronous').get().synchronous !== 2 ||
        database.prepare('PRAGMA max_page_count').get().max_page_count !== 4096) throw new Error('Storage limits unavailable');
    if (fresh || version === 1) {
      database.exec('BEGIN IMMEDIATE');
      try {
        if (fresh) database.exec(`
          PRAGMA application_id = ${applicationId};
          CREATE TABLE measurements (
            id INTEGER PRIMARY KEY, peer TEXT NOT NULL,
            received_at REAL NOT NULL, senml_json TEXT NOT NULL
          ) STRICT;
        `);
        database.exec(`
          ALTER TABLE measurements ADD COLUMN source TEXT;
          ALTER TABLE measurements ADD COLUMN business_key TEXT;
          ALTER TABLE measurements ADD COLUMN format INTEGER;
          ALTER TABLE measurements ADD COLUMN payload BLOB;
          CREATE UNIQUE INDEX measurement_business_key ON measurements(source, business_key)
            WHERE source IS NOT NULL AND business_key IS NOT NULL;
          PRAGMA user_version = 2;
          COMMIT;
        `);
      } catch (error) {
        try { database.exec('ROLLBACK'); } catch { /* The transaction may already be closed. */ }
        throw error;
      }
    }
    const lookup = database.prepare('SELECT format, payload FROM measurements WHERE source = ? AND business_key = ?');
    const insert = database.prepare(`INSERT INTO measurements(peer, received_at, senml_json, source, business_key, format, payload)
      SELECT ?, ?, ?, ?, ?, ?, ? WHERE (SELECT count(*) FROM measurements) < 4096`);
    return {
      append(peer, receivedAt, json, identity = null) {
        if (identity !== null && (typeof identity.source !== 'string' || typeof identity.key !== 'string' ||
            !/^[A-Za-z0-9._-]{1,64}$/.test(identity.source) || !/^[A-Za-z0-9._-]{1,64}$/.test(identity.key) || ![110, 112, 310].includes(identity.format) ||
            !Buffer.isBuffer(identity.payload) || identity.payload.length > 8192)) throw new Error('Invalid business identity');
        database.exec('BEGIN IMMEDIATE');
        try {
          if (identity !== null) {
            const previous = lookup.get(identity.source, identity.key);
            if (previous) {
              const same = previous.format === identity.format && Buffer.from(previous.payload).equals(identity.payload);
              database.exec('COMMIT');
              return same ? 'duplicate' : 'conflict';
            }
          }
          if (insert.run(peer, receivedAt, json, identity?.source ?? null, identity?.key ?? null,
              identity?.format ?? null, identity?.payload ?? null).changes !== 1) throw new Error('Ledger row limit');
          database.exec('COMMIT');
          return 'stored';
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
