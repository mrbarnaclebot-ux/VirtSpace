import { describe, it, expect, afterEach } from 'vitest';
import { getPool, closeDb, POOL_OPTIONS } from '../src/db/client.js';
import { resetConfigCache } from '../src/config.js';

// Spec §10 R28. Creating the pool does not connect, so no database is needed.

describe('getPool', () => {
  afterEach(async () => {
    await closeDb();
    resetConfigCache();
  });

  it('has an idle-error listener and the timeout options', () => {
    process.env['DATABASE_URL'] = 'postgres://u:p@localhost:5432/db';
    process.env['DEV_AUTH_TOKEN'] ??= 't';
    resetConfigCache();
    const pool = getPool();
    expect(pool.listenerCount('error')).toBe(1);
    expect(pool.options).toMatchObject(POOL_OPTIONS);
    // Emitting must not throw (it would, with no listener).
    expect(() => pool.emit('error', new Error('idle drop'))).not.toThrow();
  });
});
