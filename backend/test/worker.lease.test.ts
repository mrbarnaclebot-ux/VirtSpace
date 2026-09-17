import { describe, it, expect, vi } from 'vitest';
import { PgDialect } from 'drizzle-orm/pg-core';
import type { SQL } from 'drizzle-orm';
import { heartbeatJob } from '../src/queue.js';
import {
  handleStitch,
  processJob,
  handleJobError,
  LeaseLostError,
  type WorkerDeps,
  type StitcherSpawner,
} from '../src/worker.js';
import { loadConfig } from '../src/config.js';
import { worlds, captures, type World, type Job } from '../src/db/schema.js';
import type { Db } from '../src/db/client.js';
import type { StorageDriver } from '../src/storage/index.js';
import type { WorldGenProvider } from '../src/provider/index.js';

// spec §10 R6 — the job lease (600 s) is shorter than the generate timeout
// (900 s) and nothing refreshed it, so a second worker could re-claim a job that
// was still running. Long phases now heartbeat the lease, a worker that LOST the
// lease aborts instead of finalizing, and finalize is idempotent so credits and
// the push can never double-apply.

const config = loadConfig({
  DATABASE_URL: 'postgres://u:p@localhost:5432/db',
  DEV_AUTH_TOKEN: 't',
  STITCHER_WIDTH: '4096',
} as NodeJS.ProcessEnv);

// --- heartbeatJob SQL --------------------------------------------------------

describe('heartbeatJob', () => {
  const dialect = new PgDialect();

  async function render(workerId?: string) {
    let captured: SQL | undefined;
    const db = {
      execute: async (q: SQL) => {
        captured = q;
        return { rows: [{ id: 'job-1' }] };
      },
    } as unknown as Db;
    const held = await heartbeatJob(db, 'job-1', workerId);
    return { held, ...dialect.sqlToQuery(captured!) };
  }

  it('refreshes locked_at only for a running job this worker still holds', async () => {
    const { held, sql: text, params } = await render('worker-A');
    expect(held).toBe(true);
    expect(text).toContain('locked_at = now()');
    expect(text).toContain("phase = 'running'");
    expect(text).toMatch(/locked_by = \$\d+/);
    expect(text).toContain('RETURNING id');
    expect(params).toContain('worker-A');
    expect(params).toContain('job-1');
  });

  it('omits the owner check when no worker id is supplied', async () => {
    const { sql: text, params } = await render();
    expect(text).not.toContain('locked_by =');
    expect(params).toEqual(['job-1']);
  });

  it('reports the lease LOST when the conditional update matches no row', async () => {
    const db = {
      execute: async () => ({ rows: [] }),
    } as unknown as Db;
    expect(await heartbeatJob(db, 'job-1', 'worker-A')).toBe(false);
  });
});

// --- shared fakes ------------------------------------------------------------

function fakeWorld(overrides: Partial<World> = {}): World {
  return {
    id: 'w-1', ownerId: 'user-1', title: null, caption: null, lat: null, lng: null,
    placeName: null, isPublic: false, status: 'stitching', phase: null, progress: null,
    panoUrl: null, thumbnailUrl: null, spz100kUrl: null, spz500kUrl: null,
    spzFullUrl: null, colliderGlbUrl: null, assetVersion: 1, provider: null,
    draftWorldId: null, hqWorldId: null, draftModel: null, hqModel: null,
    creditsSpent: 0,
    createdAt: new Date('2026-07-12T10:00:00Z'),
    updatedAt: new Date('2026-07-12T10:00:00Z'), deletedAt: null,
    ...overrides,
  };
}

interface Sink {
  updates: { table: unknown; patch: Record<string, unknown> }[];
  inserts: { table: unknown; vals: Record<string, unknown> }[];
  executes: string[];
  pushes: string[];
}

function newSink(): Sink {
  return { updates: [], inserts: [], executes: [], pushes: [] };
}

/**
 * In-memory db double. `heartbeatRows` decides what every raw `execute`
 * returns: heartbeatJob reads `rows.length`, so an empty array is "lease lost".
 */
function makeDb(opts: {
  world: World;
  capture?: unknown;
  sink: Sink;
  heartbeatRows?: () => unknown[];
  finalizeRows?: () => unknown[];
}) {
  const { world, capture, sink } = opts;
  return {
    select: () => ({
      from: (table: unknown) => {
        const rows = table === worlds ? [world] : table === captures && capture ? [capture] : [];
        const chain = {
          where: () => chain,
          orderBy: () => chain,
          limit: async () => rows,
          then: (res: (v: unknown) => void) => res(rows),
        };
        return chain;
      },
    }),
    update: (table: unknown) => ({
      set: (patch: Record<string, unknown>) => ({
        where: () => {
          sink.updates.push({ table, patch });
          const rows = opts.finalizeRows ? opts.finalizeRows() : [{ id: 'w-1' }];
          const p = Promise.resolve(rows);
          return Object.assign(p, { returning: async () => rows });
        },
      }),
    }),
    insert: (table: unknown) => ({
      values: (vals: Record<string, unknown>) => ({
        returning: async () => {
          sink.inserts.push({ table, vals });
          return [{ id: 'job-x' }];
        },
      }),
    }),
    transaction: async (cb: (tx: unknown) => Promise<void>) => {
      await cb({
        execute: async () => ({ rows: [{ total: 0 }] }),
        insert: () => ({ values: async () => undefined }),
      });
    },
    execute: async (q: SQL) => {
      sink.executes.push(new PgDialect().sqlToQuery(q).sql);
      return { rows: opts.heartbeatRows ? opts.heartbeatRows() : [{ id: 'job-1' }] };
    },
  } as unknown as Db;
}

function fakeStorage(puts: string[] = []): StorageDriver {
  return {
    kind: 'local',
    presignUpload: vi.fn(),
    presignDownload: vi.fn(),
    putObject: vi.fn(async (key: string) => {
      puts.push(key);
    }),
    getObject: vi.fn(async (key: string) => Buffer.from(`bytes:${key}`)),
    deleteObject: vi.fn(),
    objectSize: vi.fn(async () => 1024),
  } as unknown as StorageDriver;
}

function fakeProvider(): WorldGenProvider {
  return {
    mode: 'mock',
    creditsForModel: () => 150,
    uploadPano: vi.fn(async () => 'media-1'),
    generateWorld: vi.fn(async () => 'op-1'),
    getOperation: vi
      .fn()
      .mockResolvedValueOnce({ done: false })
      .mockResolvedValue({ done: true, worldId: 'provider-world-1' }),
    getWorld: vi.fn(async () => ({ spzUrls: { k500: 'u500' } })),
    downloadAsset: vi.fn(async () => Buffer.from('bytes')),
    findWorldByDisplayName: vi.fn(async () => null),
  } as unknown as WorldGenProvider;
}

const clock = { now: () => 0, sleep: async () => undefined };

function deps(db: Db, sink: Sink, extra: Partial<WorkerDeps> = {}): WorkerDeps {
  return {
    db,
    storage: fakeStorage(),
    provider: fakeProvider(),
    config,
    push: (async (_userId: string, title: string) => {
      sink.pushes.push(title);
    }) as unknown as WorkerDeps['push'],
    clock,
    workerId: 'worker-A',
    ...extra,
  };
}

const generateJob = {
  id: 'job-1',
  kind: 'generate_draft',
  worldId: 'w-1',
  providerOperationId: null,
} as unknown as Job;

// --- generation: heartbeat from the poll tick --------------------------------

describe('generate job lease', () => {
  it('heartbeats the lease on every poll tick', async () => {
    const sink = newSink();
    const db = makeDb({ world: fakeWorld({ status: 'generating_draft', panoUrl: 'worlds/w-1/pano.jpg' }), sink });

    await processJob(deps(db, sink), generateJob);

    expect(sink.executes.some((s) => s.includes('locked_at = now()'))).toBe(true);
  });

  it('aborts WITHOUT finalizing when the lease was lost mid-generation', async () => {
    const sink = newSink();
    const db = makeDb({
      world: fakeWorld({ status: 'generating_draft', panoUrl: 'worlds/w-1/pano.jpg' }),
      sink,
      heartbeatRows: () => [], // another worker owns the job now
    });

    await expect(processJob(deps(db, sink), generateJob)).rejects.toBeInstanceOf(
      LeaseLostError,
    );

    // No draft_ready flip, no credits, no push — the new owner will finish it.
    expect(sink.updates.some((u) => u.patch['status'] === 'draft_ready')).toBe(false);
    expect(sink.pushes).toEqual([]);
  });
});

// --- generation: idempotent finalize ----------------------------------------

describe('idempotent generate finalize', () => {
  it('skips credits and the push when the conditional finalize matches no row', async () => {
    const sink = newSink();
    const db = makeDb({
      world: fakeWorld({ status: 'generating_draft', panoUrl: 'worlds/w-1/pano.jpg' }),
      sink,
      finalizeRows: () => [], // already finalized by a previous attempt
    });

    await processJob(deps(db, sink), generateJob);

    // The UPDATE was attempted (conditionally) but applied to nothing…
    expect(sink.updates.some((u) => u.table === worlds)).toBe(true);
    // …so the push did not re-fire, and the job still completes cleanly.
    expect(sink.pushes).toEqual([]);
    expect(sink.executes.some((s) => s.includes("phase = 'done'"))).toBe(true);
  });

  it('applies credits + push exactly once when the finalize does match', async () => {
    const sink = newSink();
    const db = makeDb({
      world: fakeWorld({ status: 'generating_draft', panoUrl: 'worlds/w-1/pano.jpg' }),
      sink,
    });

    await processJob(deps(db, sink), generateJob);

    const finalize = sink.updates.filter(
      (u) => u.table === worlds && u.patch['status'] === 'draft_ready',
    );
    expect(finalize).toHaveLength(1);
    expect(sink.pushes).toHaveLength(1);
  });
});

// --- stitch: heartbeat from the progress stream ------------------------------

function stitchSpawner(emitProgress: boolean): StitcherSpawner {
  return (async (_bin: string, args: string[], _t: number, onStdout?: (c: string) => void) => {
    if (emitProgress) onStdout?.('PROGRESS 10\nPROGRESS 60\n');
    // Give the async heartbeat callbacks a turn before the run resolves.
    await new Promise((r) => setImmediate(r));
    const { writeFile } = await import('node:fs/promises');
    await writeFile(args[args.indexOf('--out') + 1]!, Buffer.from('PANO'));
    return { code: 0, stdout: '', stderr: '', timedOut: false };
  }) as StitcherSpawner;
}

const stitchJob = { id: 'job-2', kind: 'stitch', worldId: 'w-1' } as unknown as Job;
const capture = {
  id: 'cap-1',
  worldId: 'w-1',
  frameCount: 2,
  posesJson: null,
  r2FramesPrefix: 'captures/cap-1',
  createdAt: new Date(),
};

describe('stitch job lease', () => {
  it('heartbeats the lease from the stitcher progress stream', async () => {
    const sink = newSink();
    const db = makeDb({ world: fakeWorld(), capture, sink });

    await handleStitch(deps(db, sink, { stitcher: stitchSpawner(true) }), stitchJob);

    expect(sink.executes.some((s) => s.includes('locked_at = now()'))).toBe(true);
    expect(sink.updates.some((u) => u.patch['status'] === 'generating_draft')).toBe(true);
  });

  it('aborts without publishing the pano when the lease was lost mid-stitch', async () => {
    const sink = newSink();
    const puts: string[] = [];
    const db = makeDb({ world: fakeWorld(), capture, sink, heartbeatRows: () => [] });

    await expect(
      handleStitch(
        deps(db, sink, { stitcher: stitchSpawner(true), storage: fakeStorage(puts) }),
        stitchJob,
      ),
    ).rejects.toBeInstanceOf(LeaseLostError);

    expect(puts).not.toContain('worlds/w-1/pano.jpg');
    expect(sink.updates.some((u) => u.patch['status'] === 'generating_draft')).toBe(false);
    expect(sink.inserts.some((i) => i.vals['kind'] === 'generate_draft')).toBe(false);
  });
});

// --- a lost lease must not touch the job row ---------------------------------

describe('handleJobError with a lost lease', () => {
  it('neither fails nor parks the job — the new owner holds it', async () => {
    const sink = newSink();
    const db = makeDb({ world: fakeWorld(), sink });

    await handleJobError(db, stitchJob, new LeaseLostError('lease lost'));

    expect(sink.executes).toEqual([]); // no failJob / parkJobDead UPDATE
    expect(sink.updates).toEqual([]); // no failed_<phase> world status
  });

  it('still parks a genuinely non-retryable error', async () => {
    const sink = newSink();
    const db = makeDb({ world: fakeWorld(), sink });
    const { NonRetryableJobError } = await import('../src/worker.js');

    await handleJobError(db, stitchJob, new NonRetryableJobError('boom'));

    expect(sink.executes.some((s) => s.includes("phase = 'dead'"))).toBe(true);
    expect(sink.updates.some((u) => u.patch['status'] === 'failed_stitch')).toBe(true);
  });
});
