import { describe, it, expect, vi } from 'vitest';
import Fastify from 'fastify';
import { PgDialect } from 'drizzle-orm/pg-core';
import type { SQL } from 'drizzle-orm';

let currentDb: unknown;
vi.mock('../src/db/client.js', () => ({ getDb: () => currentDb }));

import { worldsRoutes } from '../src/routes/worlds.js';
import { worlds, captures, jobs, type World } from '../src/db/schema.js';
import { loadConfig } from '../src/config.js';
import type { StorageDriver } from '../src/storage/index.js';

// Room scan API contract (spec §5.3 item 3/4): one presigned bundle.zip PUT,
// frames:done checks the object's size, then uploading → reconstructing.

const config = loadConfig({
  DATABASE_URL: 'postgres://u:p@localhost:5432/db',
  DEV_AUTH_TOKEN: 't',
} as NodeJS.ProcessEnv);

const BUNDLE = 300 * 1024 * 1024;
const dialect = new PgDialect();

function world(over: Partial<World> = {}): World {
  return {
    id: 'w-1', ownerId: 'user-1', title: null, caption: null, lat: null, lng: null,
    placeName: null, captureType: 'room_scan', isPublic: false, status: 'uploading',
    phase: null, progress: null, clientRequestId: null, panoUrl: null, thumbnailUrl: null,
    spz100kUrl: null, spz500kUrl: null, spzFullUrl: null, colliderGlbUrl: null,
    floorplanUrl: null, assetVersion: 1, provider: null, draftWorldId: null, hqWorldId: null,
    draftModel: null, hqModel: null, creditsSpent: 0,
    createdAt: new Date('2026-11-23T10:00:00Z'), updatedAt: new Date('2026-11-23T10:00:00Z'),
    deletedAt: null,
    ...over,
  };
}

interface State {
  world: World | null;
  capture: Record<string, unknown> | null;
  inserts: { table: unknown; vals: Record<string, unknown> }[];
  quotaCharges: number;
}

function makeDb(state: State) {
  const db = {
    transaction: async <T>(fn: (tx: unknown) => Promise<T>) => fn(db),
    select: () => ({
      from: (table: unknown) => {
        const rows =
          table === worlds && state.world ? [state.world]
            : table === captures && state.capture ? [state.capture] : [];
        const chain = { where: () => chain, orderBy: () => chain, limit: async () => rows };
        return chain;
      },
    }),
    update: (table: unknown) => ({
      set: (patch: Record<string, unknown>) => ({
        where: (where: SQL) => {
          // Conditional world flips: apply only when the rendered WHERE names
          // the row's current status (same trick as frames-done.test.ts).
          let applies = true;
          if (table === worlds && state.world) {
            const { params } = dialect.sqlToQuery(where);
            applies = params.includes(state.world.status);
            if (applies) state.world = { ...state.world, ...patch } as World;
          }
          return Object.assign(Promise.resolve(), {
            returning: async () => (applies && state.world ? [state.world] : []),
          });
        },
      }),
    }),
    insert: (table: unknown) => ({
      values: (vals: Record<string, unknown>) => ({
        returning: async () => {
          state.inserts.push({ table, vals });
          if (table === worlds) {
            state.world = world({ captureType: (vals['captureType'] as string) ?? 'pano' });
            return [state.world];
          }
          if (table === captures) {
            state.capture = { id: 'cap-1', worldId: 'w-1', r2FramesPrefix: 'captures/cap-1', ...vals };
            return [state.capture];
          }
          return [{ id: 'job-1' }];
        },
      }),
    }),
    execute: async () => {
      state.quotaCharges += 1;
      return { rows: [{ user_id: 'user-1', new_count: 1, reset_at: new Date() }] };
    },
  };
  return db;
}

function makeStorage(objectSize: () => Promise<number> = async () => BUNDLE) {
  return {
    kind: 's3',
    presignUpload: vi.fn(async (key: string, contentType: string, _max: number, exact?: number) => ({
      url: `https://signed.example/${key}`,
      method: 'PUT' as const,
      headers: { 'content-type': contentType, ...(exact ? { 'content-length': String(exact) } : {}) },
    })),
    presignDownload: vi.fn(async (key: string) => `https://signed.example/${key}`),
    putObject: vi.fn(), getObject: vi.fn(), deleteObject: vi.fn(),
    objectSize: vi.fn(objectSize),
  } as unknown as StorageDriver & {
    presignUpload: ReturnType<typeof vi.fn>;
    objectSize: ReturnType<typeof vi.fn>;
  };
}

async function app(state: State, storage = makeStorage()) {
  currentDb = makeDb(state);
  const a = Fastify();
  a.addHook('preHandler', async (req) => {
    (req as { userId?: string }).userId = 'user-1';
  });
  worldsRoutes(a, { config, storage });
  await a.ready();
  return a;
}

const fresh = (): State => ({ world: null, capture: null, inserts: [], quotaCharges: 0 });
const uploaded = (over: Partial<World> = {}): State => ({
  world: world(over),
  capture: { id: 'cap-1', worldId: 'w-1', frameCount: 720, r2FramesPrefix: 'captures/cap-1', bundleBytes: BUNDLE },
  inserts: [],
  quotaCharges: 0,
});

describe('POST /v1/worlds capture_type=room_scan', () => {
  const body = { capture_type: 'room_scan', frame_count: 720, bundle_bytes: BUNDLE, title: 'Kitchen' };

  it('201 with ONE signed bundle.zip PUT, max_frames, and no uploads[]', async () => {
    const state = fresh();
    const storage = makeStorage();
    const res = await (await app(state, storage)).inject({ method: 'POST', url: '/v1/worlds', payload: body });

    expect(res.statusCode).toBe(201);
    const json = res.json();
    expect(Object.keys(json).sort()).toEqual(['bundle_upload', 'capture_id', 'max_frames', 'world']);
    expect(json.bundle_upload).toEqual({
      url: 'https://signed.example/captures/cap-1/bundle.zip',
      method: 'PUT',
      headers: { 'content-type': 'application/zip', 'content-length': String(BUNDLE) },
      key: 'captures/cap-1/bundle.zip',
    });
    expect(json.max_frames).toBe(5000);
    expect(json.world.capture_type).toBe('room_scan');
    expect(storage.presignUpload).toHaveBeenCalledOnce();
    expect(storage.presignUpload).toHaveBeenCalledWith(
      'captures/cap-1/bundle.zip', 'application/zip', 4 * 1024 ** 3 - 1, BUNDLE,
    );
    const cap = state.inserts.find((i) => i.table === captures)!.vals;
    expect(cap).toMatchObject({ frameCount: 720, bundleBytes: BUNDLE });
    expect(state.quotaCharges).toBe(1); // same scan quota as a pano create.
  });

  it.each([
    ['frame_count over ROOM_SCAN_MAX_FRAMES', { ...body, frame_count: 5001 }],
    ['frame_count 0', { ...body, frame_count: 0 }],
    ['bundle_bytes over 4 GiB − 1', { ...body, bundle_bytes: 4 * 1024 ** 3 }],
    ['bundle_bytes missing', { capture_type: 'room_scan', frame_count: 10 }],
    ['unknown capture_type', { capture_type: 'video', frame_count: 4 }],
  ])('400 invalid_body: %s', async (_name, payload) => {
    const state = fresh();
    const res = await (await app(state)).inject({ method: 'POST', url: '/v1/worlds', payload });
    expect(res.statusCode).toBe(400);
    expect(res.json().error).toBe('invalid_body');
    expect(state.inserts).toHaveLength(0);
  });

  it('pano: absent and explicit capture_type give the identical response, no room-scan keys', async () => {
    const bodies = [{ frame_count: 2 }, { capture_type: 'pano', frame_count: 2 }];
    const out = [];
    for (const payload of bodies) {
      const state = fresh();
      const res = await (await app(state)).inject({ method: 'POST', url: '/v1/worlds', payload });
      expect(res.statusCode).toBe(201);
      // Pano inserts don't name the new columns (DB defaults apply).
      expect(state.inserts.find((i) => i.table === worlds)!.vals).not.toHaveProperty('captureType');
      expect(state.inserts.find((i) => i.table === captures)!.vals).not.toHaveProperty('bundleBytes');
      out.push(res.body);
    }
    expect(out[0]).toBe(out[1]);
    const json = JSON.parse(out[0]!);
    expect(Object.keys(json).sort()).toEqual(['capture_id', 'uploads', 'world']);
    expect(json.world).not.toHaveProperty('capture_type');
  });
});

describe('POST /v1/worlds/:id/uploads:refresh (room scan)', () => {
  it('re-signs bundle_upload with the stored size', async () => {
    const storage = makeStorage();
    const res = await (await app(uploaded(), storage)).inject({
      method: 'POST', url: '/v1/worlds/w-1/uploads:refresh',
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().bundle_upload.key).toBe('captures/cap-1/bundle.zip');
    expect(res.json()).not.toHaveProperty('uploads');
    expect(storage.presignUpload).toHaveBeenCalledWith(
      'captures/cap-1/bundle.zip', 'application/zip', expect.any(Number), BUNDLE,
    );
  });
});

describe('POST /v1/worlds/:id/frames:done (room scan)', () => {
  it('bundle present at the declared size → reconstructing + one reconstruct job', async () => {
    const state = uploaded();
    const res = await (await app(state)).inject({ method: 'POST', url: '/v1/worlds/w-1/frames:done' });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ world: { status: 'reconstructing' }, job_id: 'job-1' });
    const enq = state.inserts.filter((i) => i.table === jobs);
    expect(enq).toHaveLength(1);
    expect(enq[0]!.vals).toMatchObject({ kind: 'reconstruct', worldId: 'w-1' });
  });

  it('missing bundle object → 409 bundle_not_uploaded, nothing flipped', async () => {
    const state = uploaded();
    const storage = makeStorage(async () => {
      throw new Error('NotFound');
    });
    const res = await (await app(state, storage)).inject({ method: 'POST', url: '/v1/worlds/w-1/frames:done' });
    expect(res.statusCode).toBe(409);
    expect(res.json()).toEqual({ error: 'bundle_not_uploaded' });
    expect(state.world!.status).toBe('uploading');
    expect(state.inserts).toHaveLength(0);
  });

  it('size mismatch → 409 bundle_size_mismatch, nothing flipped', async () => {
    const state = uploaded();
    const storage = makeStorage(async () => BUNDLE - 1);
    const res = await (await app(state, storage)).inject({ method: 'POST', url: '/v1/worlds/w-1/frames:done' });
    expect(res.statusCode).toBe(409);
    expect(res.json()).toEqual({
      error: 'bundle_size_mismatch', expected_bytes: BUNDLE, actual_bytes: BUNDLE - 1,
    });
    expect(state.world!.status).toBe('uploading');
    expect(state.inserts).toHaveLength(0);
  });

  it('replay after the flip → 200 job_id null, no second job', async () => {
    const state = uploaded({ status: 'reconstructing' });
    const storage = makeStorage();
    const res = await (await app(state, storage)).inject({ method: 'POST', url: '/v1/worlds/w-1/frames:done' });
    expect(res.json()).toMatchObject({ job_id: null, world: { status: 'reconstructing' } });
    expect(state.inserts).toHaveLength(0);
    expect(storage.objectSize).not.toHaveBeenCalled();
  });
});

describe(':enhance / :retry (room scan)', () => {
  it(':enhance is 409 not_enhanceable', async () => {
    const res = await (await app(uploaded({ status: 'complete' }))).inject({
      method: 'POST', url: '/v1/worlds/w-1:enhance',
    });
    expect(res.statusCode).toBe(409);
    expect(res.json()).toEqual({ error: 'not_enhanceable', status: 'complete' });
  });

  it(':retry failed_reconstructing → reconstructing + reconstruct, charging one scan', async () => {
    const state = uploaded({ status: 'failed_reconstructing' });
    const res = await (await app(state)).inject({ method: 'POST', url: '/v1/worlds/w-1:retry' });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ world: { status: 'reconstructing' }, job_id: 'job-1' });
    expect(state.inserts.filter((i) => i.table === jobs)[0]!.vals).toMatchObject({ kind: 'reconstruct' });
    expect(state.quotaCharges).toBe(1);
  });

  it(':retry while reconstructing is a replay (job_id null)', async () => {
    const state = uploaded({ status: 'reconstructing' });
    const res = await (await app(state)).inject({ method: 'POST', url: '/v1/worlds/w-1:retry' });
    expect(res.json()).toMatchObject({ job_id: null });
    expect(state.inserts).toHaveLength(0);
  });
});
