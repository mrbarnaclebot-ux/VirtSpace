import { describe, it, expect, vi } from 'vitest';
import { writeFile } from 'node:fs/promises';
import {
  stitchPlan,
  serializePoses,
  posesPresent,
  buildStitcherArgs,
  handleStitch,
  runGeneration,
  type GenerationIO,
  type GenerationClock,
  type WorkerDeps,
  type StitcherSpawner,
} from '../src/worker.js';
import { MODEL_CREDITS, type WorldGenProvider } from '../src/provider/index.js';
import { createMockProvider } from '../src/provider/mock.js';
import { worlds, captures, type World, type Capture, type Job } from '../src/db/schema.js';
import { loadConfig } from '../src/config.js';
import type { StorageDriver } from '../src/storage/index.js';

// --- stitch decision (pure) --------------------------------------------------
describe('stitchPlan', () => {
  it('single frame → passthrough (the frame IS the pano)', () => {
    expect(stitchPlan(1)).toEqual({ type: 'passthrough' });
  });

  it('multi-frame → stitch (production reprojection)', () => {
    expect(stitchPlan(16)).toEqual({ type: 'stitch', frameCount: 16 });
    expect(stitchPlan(2).type).toBe('stitch');
  });
});

// --- poses.json serialization from a captures row shape ----------------------
describe('serializePoses / posesPresent', () => {
  // Mirrors captures.poses_json: array of ARKit pose objects (spec §schema).
  const row = [
    {
      index: 0,
      timestamp: 0.0,
      transform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
      intrinsics: [1600, 0, 960, 0, 1600, 720, 0, 0, 1],
      exposureLocked: true,
    },
    {
      index: 1,
      timestamp: 0.1,
      transform: [0, 0, 1, 0, 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 0, 1],
      intrinsics: [1600, 0, 960, 0, 1600, 720, 0, 0, 1],
      exposureLocked: true,
    },
  ];

  it('serializes the pose array verbatim (round-trips)', () => {
    const json = serializePoses(row);
    expect(JSON.parse(json)).toEqual(row);
  });

  it('posesPresent is true for a non-empty array, false otherwise', () => {
    expect(posesPresent(row)).toBe(true);
    expect(posesPresent(null)).toBe(false);
    expect(posesPresent([])).toBe(false);
    expect(posesPresent(undefined)).toBe(false);
  });

  it('serializePoses rejects a null / empty poses column', () => {
    expect(() => serializePoses(null)).toThrow();
    expect(() => serializePoses([])).toThrow();
  });
});

// --- stitcher argv construction ---------------------------------------------
describe('buildStitcherArgs', () => {
  const base = {
    scriptPath: '/app/stitcher/reproject.py',
    framesDir: '/tmp/w/frames',
    outPath: '/tmp/w/pano.jpg',
    width: 8192,
  };

  it('includes --poses when a poses path is provided', () => {
    const args = buildStitcherArgs({ ...base, posesPath: '/tmp/w/poses.json' });
    expect(args).toContain('--poses');
    expect(args[args.indexOf('--poses') + 1]).toBe('/tmp/w/poses.json');
    expect(args).toEqual(
      expect.arrayContaining(['--frames-dir', '/tmp/w/frames', '--out', '/tmp/w/pano.jpg', '--width', '8192']),
    );
  });

  it('omits --poses when no poses path (nominal fallback)', () => {
    const args = buildStitcherArgs({ ...base, posesPath: null });
    expect(args).not.toContain('--poses');
  });

  it('includes --preview-out only when a preview path is given', () => {
    expect(buildStitcherArgs({ ...base, previewPath: '/tmp/w/prev.jpg' })).toContain('--preview-out');
    expect(buildStitcherArgs({ ...base })).not.toContain('--preview-out');
  });
});

// --- credit-safe generation (spec §14) --------------------------------------
const instantClock: GenerationClock = { now: () => 0, sleep: async () => undefined };

function fakeProvider(overrides: Partial<WorldGenProvider> = {}): WorldGenProvider {
  return {
    mode: 'mock',
    creditsForModel: () => 150,
    uploadPano: vi.fn(async () => 'media-1'),
    generateWorld: vi.fn(async () => 'op-1'),
    getOperation: vi.fn(async () => ({ done: true, worldId: 'world-1' })),
    getWorld: vi.fn(async () => ({ spzUrls: { k500: 'u500' }, caption: 'cap' })),
    downloadAsset: vi.fn(async () => Buffer.from('bytes')),
    findWorldByDisplayName: vi.fn(async () => null),
    ...overrides,
  } as WorldGenProvider;
}

function fakeIO(): GenerationIO & { saved: string[]; reserved: number[] } {
  const saved: string[] = [];
  const reserved: number[] = [];
  return {
    saved,
    reserved,
    reserveCredits: vi.fn(async (amount: number) => {
      reserved.push(amount);
    }),
    getPanoBytes: vi.fn(async () => Buffer.from('pano')),
    saveOperationId: vi.fn(async (opId: string) => {
      saved.push(opId);
    }),
    storeAsset: vi.fn(async (name: string) => `worlds/world-1/${name}`),
  };
}

describe('runGeneration credit safety', () => {
  it('fresh job: reserves credits, uploads, generates once, persists op id', async () => {
    const provider = fakeProvider();
    const io = fakeIO();

    const result = await runGeneration(
      provider,
      io,
      { jobId: 'job-1', model: 'marble-1.0-draft', displayName: 'W', cost: 150, existingOperationId: null },
      instantClock,
    );

    expect(io.reserveCredits).toHaveBeenCalledWith(150);
    expect(provider.uploadPano).toHaveBeenCalledOnce();
    expect(provider.generateWorld).toHaveBeenCalledOnce();
    // Intent marker first, then the real operation id (spec §10 R1).
    expect(io.saved).toEqual(['pending:job-1', 'op-1']);
    expect(result.worldId).toBe('world-1');
    expect(result.assetKeys.spz500kUrl).toBe('worlds/world-1/splat_500k.spz');
    expect(result.caption).toBe('cap');
  });

  it('RESUME (op id already set): NEVER re-bills — no reserve, no generate', async () => {
    const provider = fakeProvider();
    const io = fakeIO();

    await runGeneration(
      provider,
      io,
      { jobId: 'job-1', model: 'marble-1.0-draft', displayName: 'W', cost: 150, existingOperationId: 'op-existing' },
      instantClock,
    );

    // The money path is entirely skipped on resume.
    expect(io.reserveCredits).not.toHaveBeenCalled();
    expect(provider.uploadPano).not.toHaveBeenCalled();
    expect(provider.generateWorld).not.toHaveBeenCalled();
    expect(io.saveOperationId).not.toHaveBeenCalled();
    // But it still polls the existing operation and fetches the world.
    expect(provider.getOperation).toHaveBeenCalledWith('op-existing');
    expect(provider.getWorld).toHaveBeenCalledWith('world-1');
  });

  it('polls until done, then fetches the world', async () => {
    const getOperation = vi
      .fn()
      .mockResolvedValueOnce({ done: false })
      .mockResolvedValueOnce({ done: true, worldId: 'world-1' });
    const provider = fakeProvider({ getOperation });
    const io = fakeIO();

    await runGeneration(
      provider,
      io,
      { jobId: 'job-1', model: 'marble-1.1', displayName: 'W', cost: 1500, existingOperationId: null },
      instantClock,
    );
    expect(getOperation).toHaveBeenCalledTimes(2);
  });

  it('throws ProviderTimeoutError if the operation never completes', async () => {
    const provider = fakeProvider({ getOperation: vi.fn(async () => ({ done: false })) });
    const io = fakeIO();
    // Clock advances past the deadline on the first check.
    let t = 0;
    const clock: GenerationClock = {
      now: () => (t += 1_000_000),
      sleep: async () => undefined,
    };

    await expect(
      runGeneration(
        provider,
        io,
        { jobId: 'job-1', model: 'marble-1.0-draft', displayName: 'W', cost: 150, existingOperationId: null },
        clock,
        { timeoutMs: 1 },
      ),
    ).rejects.toMatchObject({ name: 'ProviderTimeoutError' });
  });
});

// --- mock generations are FREE ------------------------------------------------
// PROVIDER_MODE=mock must not eat the daily budget or inflate spend metrics.
// The worker derives BOTH the reserveCredits amount and the world's
// credits_spent increment from provider.creditsForModel(model), so asserting
// the mock reports 0 (and that reserve is still called, with 0) covers both.
describe('mock provider billing', () => {
  it('creditsForModel returns 0 for every model (draft and hq)', () => {
    const provider = createMockProvider();
    expect(provider.creditsForModel('marble-1.0-draft')).toBe(0);
    expect(provider.creditsForModel('marble-1.1')).toBe(0);
  });

  it('mock generation still exercises the budget path: reserveCredits(0)', async () => {
    const provider = createMockProvider();
    const io = fakeIO();
    // Exactly how handleGenerate derives the cost it reserves AND increments
    // credits_spent by — 0 on the mock, so the world's spend stays 0.
    const cost = provider.creditsForModel('marble-1.0-draft');

    const result = await runGeneration(
      provider,
      io,
      { jobId: 'job-1', model: 'marble-1.0-draft', displayName: 'W', cost, existingOperationId: null },
      instantClock,
    );

    expect(io.reserveCredits).toHaveBeenCalledTimes(1);
    expect(io.reserveCredits).toHaveBeenCalledWith(0); // ledger row of amount 0.
    expect(cost).toBe(0); // → worlds.credits_spent += 0.
    // The pipeline itself still completes end to end offline.
    expect(result.worldId).toMatch(/^mock-world-/);
    expect(result.assetKeys.spz500kUrl).toBe('worlds/world-1/splat_500k.spz');
  });

  it('real provider costs are unchanged (draft 150 / hq 1500)', () => {
    // MODEL_CREDITS is what the live provider returns verbatim.
    expect(MODEL_CREDITS['marble-1.0-draft']).toBe(150);
    expect(MODEL_CREDITS['marble-1.1']).toBe(1500);
  });
});

// --- stitch dispatch (handleStitch) -----------------------------------------
// Exercises the branch decision + subprocess wiring with a MOCKED spawner and
// an in-memory db/storage. No Python, no DB, no network.
const stitchConfig = loadConfig({
  DATABASE_URL: 'postgres://u:p@localhost:5432/db',
  DEV_AUTH_TOKEN: 't',
  STITCHER_WIDTH: '4096',
} as NodeJS.ProcessEnv);

function fakeWorld(): World {
  return {
    id: 'w-1', ownerId: 'user-1', title: null, caption: null, lat: null, lng: null,
    placeName: null, isPublic: false, status: 'stitching', phase: null, progress: null,
    panoUrl: null,
    thumbnailUrl: null, spz100kUrl: null, spz500kUrl: null, spzFullUrl: null,
    colliderGlbUrl: null, assetVersion: 1, provider: null, draftWorldId: null,
    hqWorldId: null, draftModel: null, hqModel: null, creditsSpent: 0,
    createdAt: new Date('2026-07-12T10:00:00Z'),
    updatedAt: new Date('2026-07-12T10:00:00Z'), deletedAt: null,
  };
}

function fakeCapture(frameCount: number, posesJson: unknown): Capture {
  return {
    id: 'cap-1', worldId: 'w-1', frameCount, posesJson,
    r2FramesPrefix: 'captures/cap-1', createdAt: new Date('2026-07-12T10:00:00Z'),
  } as Capture;
}

interface Sink {
  updates: { table: unknown; patch: Record<string, unknown> }[];
  inserts: { table: unknown; vals: Record<string, unknown> }[];
  executes: number;
}

function makeStitchDb(world: World, capture: Capture, sink: Sink) {
  return {
    select: () => ({
      from: (table: unknown) => {
        const rows = table === worlds ? [world] : table === captures ? [capture] : [];
        const chain = { where: () => chain, orderBy: () => chain, limit: async () => rows };
        return chain;
      },
    }),
    update: (table: unknown) => ({
      set: (patch: Record<string, unknown>) => ({
        // `where()` is awaited directly by some call sites and chained with
        // `.returning()` by the conditional (idempotent) finalizes — support both.
        where: () => {
          sink.updates.push({ table, patch });
          const rows = [{ id: 'w-1' }];
          return Object.assign(Promise.resolve(rows), { returning: async () => rows });
        },
      }),
    }),
    insert: (table: unknown) => ({
      values: (vals: Record<string, unknown>) => ({
        returning: async () => { sink.inserts.push({ table, vals }); return [{ id: 'job-x' }]; },
      }),
    }),
    execute: async () => { sink.executes += 1; },
  };
}

function fakeStorage() {
  const puts: string[] = [];
  const gets: string[] = [];
  const storage = {
    kind: 'local',
    presignUpload: vi.fn(),
    presignDownload: vi.fn(),
    putObject: vi.fn(async (key: string) => { puts.push(key); }),
    getObject: vi.fn(async (key: string) => { gets.push(key); return Buffer.from(`bytes:${key}`); }),
    deleteObject: vi.fn(),
    objectSize: vi.fn(async () => 1024),
  } as unknown as StorageDriver;
  return { storage, puts, gets };
}

/** Spawner mock that writes dummy pano/preview files so the handler can read them. */
function fakeSpawner(): StitcherSpawner & { calls: string[][] } {
  const calls: string[][] = [];
  const fn = (async (_bin: string, args: string[]) => {
    calls.push(args);
    const out = args[args.indexOf('--out') + 1]!;
    await writeFile(out, Buffer.from('PANOBYTES'));
    const pv = args.indexOf('--preview-out');
    if (pv >= 0) await writeFile(args[pv + 1]!, Buffer.from('PREVIEWBYTES'));
    return { code: 0, stdout: 'coverage 90%', stderr: '', timedOut: false };
  }) as StitcherSpawner & { calls: string[][] };
  fn.calls = calls;
  return fn;
}

const stitchJob = { id: 'job-1', kind: 'stitch', worldId: 'w-1' } as unknown as Job;

function deps(db: unknown, storage: StorageDriver, stitcher: StitcherSpawner): WorkerDeps {
  return {
    db: db as WorkerDeps['db'],
    storage,
    provider: {} as WorkerDeps['provider'],
    config: stitchConfig,
    push: (async () => undefined) as unknown as WorkerDeps['push'],
    stitcher,
  };
}

describe('handleStitch dispatch', () => {
  it('frame_count 1 → passthrough: copies the frame, never spawns Python', async () => {
    const sink: Sink = { updates: [], inserts: [], executes: 0 };
    const db = makeStitchDb(fakeWorld(), fakeCapture(1, null), sink);
    const { storage, puts, gets } = fakeStorage();
    const spawner = fakeSpawner();

    await handleStitch(deps(db, storage, spawner), stitchJob);

    expect(spawner.calls).toHaveLength(0); // no stitcher subprocess
    expect(gets).toEqual(['captures/cap-1/frame_0.heic']);
    expect(puts).toEqual(['worlds/w-1/pano.jpg']);
    // Advanced to generating_draft + enqueued generate_draft + completed.
    expect(sink.updates.some((u) => u.patch['status'] === 'generating_draft')).toBe(true);
    expect(sink.inserts.some((i) => i.vals['kind'] === 'generate_draft')).toBe(true);
    expect(sink.executes).toBe(1);
  });

  it('multi-frame WITH poses → spawns with --poses, uploads pano + preview', async () => {
    const sink: Sink = { updates: [], inserts: [], executes: 0 };
    const poses = [
      { index: 0, transform: Array(16).fill(0), intrinsics: Array(9).fill(1) },
      { index: 1, transform: Array(16).fill(0), intrinsics: Array(9).fill(1) },
    ];
    const db = makeStitchDb(fakeWorld(), fakeCapture(3, poses), sink);
    const { storage, puts, gets } = fakeStorage();
    const spawner = fakeSpawner();

    await handleStitch(deps(db, storage, spawner), stitchJob);

    expect(spawner.calls).toHaveLength(1);
    const args = spawner.calls[0]!;
    expect(args).toContain('--poses');
    expect(args).toContain('--frames-dir');
    expect(args[args.indexOf('--width') + 1]).toBe('4096');
    // Downloaded all 3 frames.
    expect(gets).toEqual([
      'captures/cap-1/frame_0.heic',
      'captures/cap-1/frame_1.heic',
      'captures/cap-1/frame_2.heic',
    ]);
    // Uploaded pano and preview.
    expect(puts).toContain('worlds/w-1/pano.jpg');
    expect(puts).toContain('worlds/w-1/pano_preview.jpg');
    expect(sink.updates.some((u) => u.patch['status'] === 'generating_draft')).toBe(true);
    expect(sink.inserts.some((i) => i.vals['kind'] === 'generate_draft')).toBe(true);
  });

  it('multi-frame WITHOUT poses → spawns WITHOUT --poses (nominal fallback)', async () => {
    const sink: Sink = { updates: [], inserts: [], executes: 0 };
    const db = makeStitchDb(fakeWorld(), fakeCapture(2, null), sink);
    const { storage } = fakeStorage();
    const spawner = fakeSpawner();

    await handleStitch(deps(db, storage, spawner), stitchJob);

    expect(spawner.calls).toHaveLength(1);
    expect(spawner.calls[0]).not.toContain('--poses');
  });

  it('stitcher non-zero exit → throws retryable (does not advance the world)', async () => {
    const sink: Sink = { updates: [], inserts: [], executes: 0 };
    const db = makeStitchDb(fakeWorld(), fakeCapture(2, null), sink);
    const { storage } = fakeStorage();
    const failing: StitcherSpawner = async () => ({
      code: 1, stdout: '', stderr: 'boom: out of memory', timedOut: false,
    });

    await expect(handleStitch(deps(db, storage, failing), stitchJob)).rejects.toThrow(/boom/);
    // Not a NonRetryableJobError → the loop's handleJobError will retry it.
    expect(sink.updates.some((u) => u.patch['status'] === 'generating_draft')).toBe(false);
  });
});
