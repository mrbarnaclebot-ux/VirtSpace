import { drizzle, type NodePgDatabase } from 'drizzle-orm/node-postgres';
import pg from 'pg';
import { getConfig } from '../config.js';
import * as schema from './schema.js';

// Lazy pool — the pool is created on first getDb() call, NOT at import or
// server boot. This lets /healthz and the process start without a live
// Postgres (spec §14 / task requirement 10).

let pool: pg.Pool | undefined;
let db: NodePgDatabase<typeof schema> | undefined;

export function getPool(): pg.Pool {
  if (!pool) {
    pool = new pg.Pool({ connectionString: getConfig().DATABASE_URL });
  }
  return pool;
}

export function getDb(): NodePgDatabase<typeof schema> {
  if (!db) {
    db = drizzle(getPool(), { schema });
  }
  return db;
}

export type Db = NodePgDatabase<typeof schema>;

export async function closeDb(): Promise<void> {
  if (pool) {
    await pool.end();
    pool = undefined;
    db = undefined;
  }
}
