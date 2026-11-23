import { describe, it, expect, vi } from 'vitest';
import { PgDialect } from 'drizzle-orm/pg-core';
import type { SQL } from 'drizzle-orm';
import {
  startReconstruction,
  processJob,
  handleJobError,
  generationDisplayName,
  NonRetryableJobError,
  FLOORPLAN_WAIT_MS,
  type ReconstructIO,
  type WorkerDeps,
} from '../src/worker.js';
import { rescheduleJob } from '../src/queue.js';
import { BudgetExceededError, creditsSpentToday } from '../src/budget.js';
import { ProviderError, ProviderTimeoutError } from '../src/provider/types.js';
import { createSpaitialMockClient, type SpaitialClient } from '../src/provider/spaitial.js';
import { worlds, captures, jobs, creditEvents, type World, type Job } from '../src/db/schema.js';
import type { Db } from '../src/db/client.js';
import { loadConfig } from '../src/config.js';
import type { StorageDriver } from '../src/storage/index.js';

// Room scan `reconstruct` job (spec §5.3 item 5, §14): POST /v1/worlds goes out
// at most once per job; an unresolved marker reconciles by title; polls
// re-schedule the job without consuming attempts.

const dialect = new PgDialect();
const sqlText = (q: unknown) => dialect.sqlToQuery(q as SQL).sql;
const JOB = 'job-rs-1';
const TITLE = generationDisplayName(JOB);

function client(over: Partial<SpaitialClient> = {}): SpaitialClient {
  return {
    mode: 'live',
    quote: vi.fn(async () => ({ requiredCredits: 1620, hasEnough: true, estimatedDurationSeconds: 1860 })),
    createWorld: vi.fn(async () => 'req_1'),
    findRequestByTitle: vi.fn(async () => null),
    getStatus: vi.fn(async () => ({ status: 'COMPLETED', progress: 1, estimatedDurationSeconds: null })),
    getResult: vi.fn(async () => ({
      splatUrl: 'https://api.spaitial.ai/v1/worlds/requests/req_1/splat',
      thumbnailUrl: 'https://img.spaitial.ai/t.webp',
      completedAt: new Date().toISOString(),
    })),
    getFloorplan: vi.fn(async () => ({ status: 'READY', downloadUrl: 'https://api.spaitial.ai/fp?download=1' })),
    download: vi.fn(async (url: string) => Buffer.from(`bytes:${url}`)),
    ...over,
  };
}

function io(over: Partial<ReconstructIO> = {}) {
  const log: string[] = [];
  let persisted: string | null = null;
  const fake = {
    log,
    persisted: () => persisted,
    reserveCredits: vi.fn(async (n: number) => void log.push(`reserve:${n}`)),
    releaseCredits: vi.fn(async (n: number) => void log.push(`release:${n}`)),
    saveMarker: vi.fn(async (m: string) => {
      persisted = m;
      log.push(`marker:${m}`);
    }),
    saveOperationId: vi.fn(async (id: string) => {
      persisted = id;
      log.push(`save:${id}`);
    }),
    clearPendingMarker: vi.fn(async () => {
      persisted = null;
      log.push('clear');
    }),
    presignBundle: vi.fn(async () => 'https://r2.example/bundle.zip?sig'),
    ...over,
  };
  return fake;
}

const input = (existingOperationId: string | null) => ({
  jobId: JOB, frameCount: 720, title: TITLE, existingOperationId,
});

describe('startReconstruction money path', () => {
  it('fresh: quote → marker → reserve → presign → ONE create (Idempotency-Key = job id) → request id', async () => {
    const c = client();
    const f = io();
    expect(await startReconstruction(c, f, input(null))).toBe('req_1');
    expect(c.quote).toHaveBeenCalledWith(720);
    expect(f.log).toEqual([`marker:pending:${JOB}`, 'reserve:1620', 'save:req_1']);
    expect(f.saveMarker).toHaveBeenCalledWith(`pending:${JOB}`, { credits: 1620, etaSeconds: 1860 });
    expect(c.createWorld).toHaveBeenCalledOnce();
    expect(c.createWorld).toHaveBeenCalledWith({
      zipUrl: 'https://r2.example/bundle.zip?sig', title: TITLE, idempotencyKey: JOB,
    });
  });

  it('has_enough=false → non-retryable, nothing reserved, nothing sent', async () => {
    const c = client({ quote: vi.fn(async () => ({ requiredCredits: 1620, hasEnough: false, estimatedDurationSeconds: null })) });
    const f = io();
    await expect(startReconstruction(c, f, input(null))).rejects.toBeInstanceOf(NonRetryableJobError);
    expect(f.log).toEqual([]);
    expect(c.createWorld).not.toHaveBeenCalled();
  });

  it('budget refusal → BudgetExceededError (parks), marker cleared, no create', async () => {
    const c = client();
    const f = io({ reserveCredits: vi.fn(async () => { throw new BudgetExceededError(1620, 900, 2000); }) });
    await expect(startReconstruction(c, f, input(null))).rejects.toBeInstanceOf(BudgetExceededError);
    expect(c.createWorld).not.toHaveBeenCalled();
    expect(f.releaseCredits).not.toHaveBeenCalled();
    expect(f.persisted()).toBeNull();
  });

  it('presign failure → reservation released, marker cleared, original (retryable) error', async () => {
    const boom = new Error('R2 blip');
    const f = io({ presignBundle: vi.fn(async () => { throw boom; }) });
    const c = client();
    await expect(startReconstruction(c, f, input(null))).rejects.toBe(boom);
    expect(f.log).toEqual([`marker:pending:${JOB}`, 'reserve:1620', 'release:1620', 'clear']);
    expect(c.createWorld).not.toHaveBeenCalled();
  });

  it('create failure is non-retryable and LEAVES the marker (no unwind, no release)', async () => {
    const c = client({ createWorld: vi.fn(async () => { throw new ProviderTimeoutError('slow'); }) });
    const f = io();
    await expect(startReconstruction(c, f, input(null))).rejects.toBeInstanceOf(NonRetryableJobError);
    expect(f.persisted()).toBe(`pending:${JOB}`);
    expect(f.releaseCredits).not.toHaveBeenCalled();
    expect(f.clearPendingMarker).not.toHaveBeenCalled();
  });

  it('job retry after a create timeout reconciles by title — never a second create', async () => {
    const createWorld = vi.fn(async () => { throw new ProviderTimeoutError('slow'); });
    const findRequestByTitle = vi.fn(async (t: string) => (t === TITLE ? 'req_late' : null));
    const c = client({ createWorld, findRequestByTitle });
    const f = io();
    await expect(startReconstruction(c, f, input(null))).rejects.toBeInstanceOf(NonRetryableJobError);
    // A manual re-queue resumes with the marker that was left behind.
    expect(await startReconstruction(c, f, input(f.persisted()))).toBe('req_late');
    expect(createWorld).toHaveBeenCalledOnce();
    expect(c.quote).toHaveBeenCalledOnce();
    expect(f.reserveCredits).toHaveBeenCalledOnce();
    expect(f.persisted()).toBe('req_late');
  });

  it('marker + no matching title → non-retryable park, no create', async () => {
    const c = client();
    await expect(startReconstruction(c, io(), input(`pending:${JOB}`))).rejects.toBeInstanceOf(NonRetryableJobError);
    expect(c.findRequestByTitle).toHaveBeenCalledWith(TITLE);
    expect(c.createWorld).not.toHaveBeenCalled();
  });

  it('marker + listing error → propagates as retryable ("could not determine"), money untouched', async () => {
    const err = new ProviderError('list 503', { status: 503 });
    const c = client({ findRequestByTitle: vi.fn(async () => { throw err; }) });
    const f = io();
    await expect(startReconstruction(c, f, input(`pending:${JOB}`))).rejects.toBe(err);
    expect(f.log).toEqual([]);
    expect(c.createWorld).not.toHaveBeenCalled();
    expect(c.quote).not.toHaveBeenCalled();
  });

  it('persisted request id → resumes polling: no quote, reserve, or create', async () => {
    const c = client();
    const f = io();
    expect(await startReconstruction(c, f, input('req_9'))).toBe('req_9');
    expect(c.quote).not.toHaveBeenCalled();
    expect(c.createWorld).not.toHaveBeenCalled();
    expect(f.log).toEqual([]);
  });
});

// --- DB-bound handler ---------------------------------------------------------

const config = loadConfig({
  DATABASE_URL: 'postgres://u:p@localhost:5432/db',
  DEV_AUTH_TOKEN: 't',
} as NodeJS.ProcessEnv);

function fakeWorld(over: Partial<World> = {}): World {
  return {
    id: 'w-1', ownerId: 'user-1', title: null, caption: null, lat: null, lng: null,
    placeName: null, captureType: 'room_scan', isPublic: false, status: 'reconstructing',
    phase: null, progress: null, clientRequestId: null, panoUrl: null, thumbnailUrl: null,
    spz100kUrl: null, spz500kUrl: null, spzFullUrl: null, colliderGlbUrl: null,
    floorplanUrl: null, assetVersion: 1, provider: null, draftWorldId: null, hqWorldId: null,
    draftModel: null, hqModel: null, creditsSpent: 0,
    createdAt: new Date(), updatedAt: new Date(), deletedAt: null,
    ...over,
  };
}

interface Sink {
  updates: { table: unknown; patch: Record<string, unknown> }[];
  sql: string[];
  ledger: Record<string, unknown>[];
  pushes: string[];
}

function makeDb(sink: Sink, w = fakeWorld()): Db {
  const capture = { id: 'cap-1', worldId: w.id, frameCount: 720, r2FramesPrefix: 'captures/cap-1', bundleBytes: 1000 };
  return {
    select: () => ({
      from: (table: unknown) => {
        const rows = table === worlds ? [w] : table === captures ? [capture] : [];
        const chain = { where: () => chain, orderBy: () => chain, limit: async () => rows, then: (r: (v: unknown) => void) => r(rows) };
        return chain;
      },
    }),
    update: (table: unknown) => ({
      set: (patch: Record<string, unknown>) => ({
        where: () => {
          sink.updates.push({ table, patch });
          const rows = [{ id: w.id }];
          return Object.assign(Promise.resolve(rows), { returning: async () => rows });
        },
      }),
    }),
    transaction: async (cb: (tx: unknown) => Promise<void>) =>
      cb({
        execute: async () => ({ rows: [{ total: 0 }] }),
        insert: (table: unknown) => ({
          values: async (v: Record<string, unknown>) => {
            if (table === creditEvents) sink.ledger.push(v);
          },
        }),
      }),
    execute: async (q: unknown) => {
      sink.sql.push(sqlText(q));
      return { rows: [{ id: JOB }] };
    },
  } as unknown as Db;
}

function deps(db: Db, sink: Sink, spaitial: SpaitialClient): WorkerDeps & { storage: { putObject: ReturnType<typeof vi.fn> } } {
  return {
    db,
    spaitial,
    config,
    storage: {
      kind: 'local',
      presignDownload: vi.fn(async (key: string) => `https://r2.example/${key}`),
      putObject: vi.fn(async () => undefined),
    } as unknown as StorageDriver,
    provider: {} as never,
    push: vi.fn(async (_u: string, title: string) => void sink.pushes.push(title)),
    workerId: 'host:1',
  } as never;
}

const job = (over: Partial<Job> = {}): Job => ({
  id: JOB, worldId: 'w-1', kind: 'reconstruct', phase: 'running', attempts: 1, lastError: null,
  payload: null, providerOperationId: null, runAfter: new Date(), lockedAt: new Date(),
  lockedBy: 'host:1', createdAt: new Date(), updatedAt: new Date(), ...over,
});

const newSink = (): Sink => ({ updates: [], sql: [], ledger: [], pushes: [] });
const worldPatches = (s: Sink) => s.updates.filter((u) => u.table === worlds).map((u) => u.patch);

describe('reconstruct handler', () => {
  it('mock happy path: 0-credit spaitial ledger entry, assets re-hosted, world complete', async () => {
    const sink = newSink();
    const d = deps(makeDb(sink), sink, createSpaitialMockClient());
    await processJob(d, job());

    expect(sink.ledger).toEqual([{ amount: 0, worldId: 'w-1', provider: 'spaitial' }]);
    const keys = d.storage.putObject.mock.calls.map((c) => c[0]);
    expect(keys).toEqual(['worlds/w-1/splat_full.spz', 'worlds/w-1/floorplan.png', 'worlds/w-1/thumbnail.jpg']);
    const final = worldPatches(sink).find((p) => p['status'] === 'complete')!;
    expect(final).toMatchObject({
      spzFullUrl: 'worlds/w-1/splat_full.spz',
      spz500kUrl: 'worlds/w-1/splat_full.spz',
      floorplanUrl: 'worlds/w-1/floorplan.png',
      thumbnailUrl: 'worlds/w-1/thumbnail.jpg',
      provider: 'mock',
      draftModel: 'echo-3',
    });
    expect(String(final['draftWorldId'])).toMatch(/^mock-req-/);
    // The marker landed before the create; then the request id; then done.
    const jobPatch = sink.updates.find((u) => u.table === jobs)!.patch;
    expect(jobPatch['providerOperationId']).toBe(`pending:${JOB}`);
    expect(sink.sql.some((s) => s.includes("phase = 'done'"))).toBe(true);
    expect(sink.pushes).toEqual(['Your room scan is ready']);
  });

  it('world deleted before the job ran → completes without quoting or creating', async () => {
    const sink = newSink();
    const c = client();
    await processJob(deps(makeDb(sink, fakeWorld({ deletedAt: new Date() })), sink, c), job());
    expect(c.quote).not.toHaveBeenCalled();
    expect(c.createWorld).not.toHaveBeenCalled();
    expect(sink.ledger).toEqual([]);
    expect(sink.sql.some((s) => s.includes("phase = 'done'"))).toBe(true);
  });

  it('still PROCESSING → provider progress written, job re-scheduled (attempt given back), not failed or completed', async () => {
    const sink = newSink();
    const c = client({ getStatus: vi.fn(async () => ({ status: 'PROCESSING', progress: 0.42, estimatedDurationSeconds: 1800 })) });
    await processJob(deps(makeDb(sink), sink, c), job({ providerOperationId: 'req_1' }));

    expect(worldPatches(sink)).toEqual([expect.objectContaining({ progress: 42 })]);
    const resched = sink.sql.filter((s) => s.includes('GREATEST(attempts - 1, 0)'));
    expect(resched).toHaveLength(1);
    expect(sink.sql.some((s) => s.includes("phase = 'done'"))).toBe(false);
    expect(c.createWorld).not.toHaveBeenCalled();
    expect(c.getResult).not.toHaveBeenCalled();
  });

  it('null provider progress → pseudo-progress over the ETA', async () => {
    const sink = newSink();
    const c = client({ getStatus: vi.fn(async () => ({ status: 'PENDING', progress: null, estimatedDurationSeconds: 3600 })) });
    const clock = { now: () => Date.parse('2026-11-23T10:30:00Z'), sleep: async () => undefined };
    await processJob(
      { ...deps(makeDb(sink), sink, c), clock },
      job({ providerOperationId: 'req_1', createdAt: new Date('2026-11-23T10:00:00Z') }),
    );
    expect(worldPatches(sink)[0]).toMatchObject({ progress: 50 });
  });

  it('transient status failure (5xx/network) → polls again instead of burning an attempt', async () => {
    const sink = newSink();
    const c = client({ getStatus: vi.fn(async () => { throw new ProviderError('bad gateway', { status: 502 }); }) });
    await processJob(deps(makeDb(sink), sink, c), job({ providerOperationId: 'req_1' }));
    expect(sink.sql.filter((s) => s.includes('GREATEST(attempts - 1, 0)'))).toHaveLength(1);
  });

  it('FAILED → non-retryable; handleJobError parks it and fails the world as failed_reconstructing', async () => {
    const sink = newSink();
    const db = makeDb(sink);
    const c = client({ getStatus: vi.fn(async () => ({ status: 'FAILED', progress: null, estimatedDurationSeconds: null, error: 'IMAGES_MISSING' })) });
    const err = await processJob(deps(db, sink, c), job({ providerOperationId: 'req_1' })).catch((e) => e);
    expect(err).toBeInstanceOf(NonRetryableJobError);
    expect(err.message).toContain('IMAGES_MISSING');
    await handleJobError(db, job(), err);
    expect(sink.sql.some((s) => s.includes("phase = 'dead'"))).toBe(true);
    expect(worldPatches(sink).at(-1)).toMatchObject({ status: 'failed_reconstructing' });
  });

  it('completed but floorplan still rendering → waits (re-schedules) without downloading the splat', async () => {
    const sink = newSink();
    const c = client({ getFloorplan: vi.fn(async () => ({ status: 'PROCESSING' })) });
    const d = deps(makeDb(sink), sink, c);
    await processJob(d, job({ providerOperationId: 'req_1' }));
    expect(c.download).not.toHaveBeenCalled();
    expect(sink.sql.filter((s) => s.includes('GREATEST(attempts - 1, 0)'))).toHaveLength(1);
  });

  it('floorplan still not ready past the wait window → finalizes without it', async () => {
    const sink = newSink();
    const c = client({
      getFloorplan: vi.fn(async () => ({ status: 'PROCESSING' })),
      getResult: vi.fn(async () => ({
        splatUrl: 'https://api.spaitial.ai/s',
        completedAt: new Date(Date.now() - FLOORPLAN_WAIT_MS - 1000).toISOString(),
      })),
    });
    await processJob(deps(makeDb(sink), sink, c), job({ providerOperationId: 'req_1', payload: { credits: 1620 } }));
    const final = worldPatches(sink).find((p) => p['status'] === 'complete')!;
    expect(final).not.toHaveProperty('floorplanUrl');
    expect(final['spzFullUrl']).toBe('worlds/w-1/splat_full.spz');
    expect(final['provider']).toBe('spaitial');
  });
});

describe('rescheduleJob', () => {
  it('re-queues with a run_after delay, releases the lease, gives the attempt back, only if still ours', async () => {
    const seen: { sql: string; params: unknown[] }[] = [];
    const db = {
      execute: async (q: unknown) => {
        seen.push(dialect.sqlToQuery(q as SQL));
        return { rows: [] };
      },
    } as unknown as Db;
    expect(await rescheduleJob(db, 'j', 60, 'host:1')).toBe(false); // no row → lease lost.
    const { sql, params } = seen[0]!;
    expect(sql).toContain("phase = 'queued'");
    expect(sql).toContain('locked_at = NULL');
    expect(sql).toContain('attempts = GREATEST(attempts - 1, 0)');
    expect(sql).toContain("phase = 'running' AND locked_by = $");
    expect(params).toEqual(expect.arrayContaining([60, 'j', 'host:1']));
  });
});

describe('purge (room scan)', () => {
  it('deletes bundle.zip and the floorplan, and skips the per-frame loop', async () => {
    const deleted: string[] = [];
    const db = {
      select: () => ({
        from: (table: unknown) => ({
          where: async () =>
            table === captures
              ? [{ id: 'cap-1', worldId: 'w-1', frameCount: 5000, r2FramesPrefix: 'captures/cap-1', bundleBytes: 9 }]
              : [],
        }),
      }),
      update: () => ({ set: () => ({ where: async () => undefined }) }),
      execute: async () => ({ rows: [] }),
    } as unknown as Db;
    const storage = { deleteObject: vi.fn(async (k: string) => void deleted.push(k)) } as unknown as StorageDriver;
    await processJob({ db, storage } as never, job({ kind: 'purge', payload: null }));
    expect(deleted).toContain('captures/cap-1/bundle.zip');
    expect(deleted).toContain('worlds/w-1/floorplan.png');
    expect(deleted.some((k) => k.includes('frame_'))).toBe(false);
  });
});

describe('separate SpAItial ledger', () => {
  it('the daily sum is scoped per provider (World Labs by default)', async () => {
    const params: unknown[][] = [];
    const db = {
      execute: async (q: unknown) => {
        params.push(dialect.sqlToQuery(q as SQL).params);
        return { rows: [{ total: 0 }] };
      },
    } as unknown as Db;
    await creditsSpentToday(db);
    await creditsSpentToday(db, 'spaitial');
    expect(params).toEqual([['worldlabs'], ['spaitial']]);
  });
});
