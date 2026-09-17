import { and, desc, eq, isNull } from 'drizzle-orm';
import { z } from 'zod';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { getDb } from '../db/client.js';
import { captures, users, worlds, type World } from '../db/schema.js';
import { enqueue } from '../queue.js';
import { evaluateQuota } from '../quota.js';
import { MAX_FRAME_BYTES, type StorageDriver } from '../storage/index.js';
import type { RouteDeps } from './deps.js';

const DOWNLOAD_TTL_SECONDS = 3600;

// Asset columns that hold a storage key → the JSON field name we sign into.
const ASSET_FIELDS = [
  ['panoUrl', 'pano_url'],
  ['thumbnailUrl', 'thumbnail_url'],
  ['spz100kUrl', 'spz_100k_url'],
  ['spz500kUrl', 'spz_500k_url'],
  ['spzFullUrl', 'spz_full_url'],
  ['colliderGlbUrl', 'collider_glb_url'],
] as const;

/**
 * Optional per-frame size declaration (spec §10 R7). The capture app knows each
 * frame's exact byte length at create time (the files are already on disk), so
 * declaring it lets the backend SIGN Content-Length into that frame's presigned
 * URL — the object store then rejects anything larger. The field is optional so
 * the shipped client keeps working; the worker-side guard covers it either way.
 */
const frameSizeSchema = z.object({
  index: z.number().int().min(0).max(63),
  bytes: z.number().int().positive().max(MAX_FRAME_BYTES),
});

const createBody = z.object({
  title: z.string().max(200).optional(),
  lat: z.number().min(-90).max(90).optional(),
  lng: z.number().min(-180).max(180).optional(),
  frame_count: z.number().int().min(1).max(64),
  frames: z.array(frameSizeSchema).max(64).optional(),
});

/** Same optional declaration on the resume path. Body may be absent entirely. */
export const refreshUploadsBody = z
  .object({ frames: z.array(frameSizeSchema).max(64).optional() })
  .optional()
  .nullable();

/** index → exact byte size, from an optional `frames` declaration. */
export function frameSizeMap(
  frames?: { index: number; bytes: number }[],
): Map<number, number> {
  return new Map((frames ?? []).map((f) => [f.index, f.bytes]));
}

// Per-frame ARKit pose sent by the capture app on frames:done. `.passthrough()`
// keeps unknown extra fields so poses_json stores what the client sent
// verbatim (forward-compatible with future ARKit metadata).
const poseSchema = z
  .object({
    index: z.number().int().min(0),
    timestamp: z.number(),
    transform: z.array(z.number()).length(16), // 4x4 row-major.
    intrinsics: z.array(z.number()).length(9), // 3x3 camera intrinsics.
    exposureLocked: z.boolean(),
  })
  .passthrough();

// frames:done body is OPTIONAL — the current app version sends nothing, and
// absent/empty body must keep behaving exactly as before.
export const framesDoneBody = z
  .object({ poses: z.array(poseSchema).max(64).optional() })
  .optional()
  .nullable();

// Generous ceiling for 64 poses (~25 numbers each); Fastify rejects anything
// larger with a clean 413 instead of buffering unbounded JSON.
const FRAMES_DONE_BODY_LIMIT = 256 * 1024;

function requireUserId(req: FastifyRequest, reply: FastifyReply): string | null {
  if (!req.userId) {
    reply.code(401).send({ error: 'unauthenticated' });
    return null;
  }
  return req.userId;
}

export function serializeWorld(w: World): Record<string, unknown> {
  return {
    id: w.id,
    title: w.title,
    caption: w.caption,
    lat: w.lat,
    lng: w.lng,
    place_name: w.placeName,
    is_public: w.isPublic,
    status: w.status,
    phase: w.phase,
    // Within-status completion 0–100 (null between phases) + the heartbeat
    // (worlds.updated_at, touched on every pipeline write) so clients can
    // render a progress bar and flag a stalled job.
    progress: w.progress,
    heartbeat_at: w.updatedAt,
    asset_version: w.assetVersion,
    provider: w.provider,
    credits_spent: w.creditsSpent,
    created_at: w.createdAt,
  };
}

/**
 * List-item shape for GET /v1/worlds (iOS Library screen contract): the
 * serializeWorld fields plus an `assets` object carrying ONLY a presigned
 * `thumbnail_url` (when the key column is set). Deliberately does NOT presign
 * the heavy asset fields (spz/pano/collider) in list context — presigning is
 * per-item crypto and the Library only renders thumbnails; the detail route
 * keeps signing everything. Exported for tests.
 */
export async function serializeWorldListItem(
  w: World,
  storage: StorageDriver,
): Promise<Record<string, unknown>> {
  const assets: { thumbnail_url?: string } = {};
  if (w.thumbnailUrl) {
    assets.thumbnail_url = await storage.presignDownload(
      w.thumbnailUrl,
      DOWNLOAD_TTL_SECONDS,
    );
  }
  return { ...serializeWorld(w), assets };
}

export function worldsRoutes(app: FastifyInstance, deps: RouteDeps): void {
  const { config, storage } = deps;

  // POST /v1/worlds — create world shell + capture, return presigned frame URLs.
  app.post('/v1/worlds', async (req, reply) => {
    const userId = requireUserId(req, reply);
    if (!userId) return;

    const parsed = createBody.safeParse(req.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: 'invalid_body', issues: parsed.error.issues });
    }
    const body = parsed.data;
    const db = getDb();

    // Daily scan quota check (spec §7).
    const [user] = await db.select().from(users).where(eq(users.id, userId)).limit(1);
    if (!user) return reply.code(401).send({ error: 'unknown_user' });

    const decision = evaluateQuota(
      { dailyScanCount: user.dailyScanCount, quotaResetAt: user.quotaResetAt },
      config.DAILY_SCAN_QUOTA,
    );
    if (!decision.allowed) {
      return reply.code(429).send({
        error: 'daily_scan_quota_exceeded',
        retry_at: decision.retryAt,
      });
    }
    await db
      .update(users)
      .set({ dailyScanCount: decision.newCount, quotaResetAt: decision.newResetAt })
      .where(eq(users.id, userId));

    // Create the world shell in the uploading state.
    const [world] = await db
      .insert(worlds)
      .values({
        ownerId: userId,
        title: body.title ?? null,
        lat: body.lat ?? null,
        lng: body.lng ?? null,
        status: 'uploading',
      })
      .returning();

    // Create the capture row and its frame-key prefix.
    const [capture] = await db
      .insert(captures)
      .values({ worldId: world!.id, frameCount: body.frame_count })
      .returning();
    const prefix = `captures/${capture!.id}`;
    await db
      .update(captures)
      .set({ r2FramesPrefix: prefix })
      .where(eq(captures.id, capture!.id));

    // Presign one upload URL per frame, binding Content-Length for every frame
    // whose exact size the client declared (spec §10 R7).
    const uploads = await presignFrameUploads(
      storage,
      prefix,
      body.frame_count,
      frameSizeMap(body.frames),
    );

    return reply.code(201).send({
      world: serializeWorld(world!),
      capture_id: capture!.id,
      uploads,
    });
  });

  // POST /v1/worlds/:id/uploads:refresh — re-issue presigned frame PUT URLs so a
  // client that lost its original (short-TTL) URLs mid-upload can resume without
  // creating a duplicate world. Same keys, content-type and per-frame ceiling as
  // create, so the client PUTs the remaining frames to the identical R2 objects.
  // Owner-checked; a world with no capture row (or no frame prefix) is 404.
  app.post<{ Params: { id: string } }>(
    '/v1/worlds/:id/uploads:refresh',
    async (req, reply) => {
      const userId = requireUserId(req, reply);
      if (!userId) return;

      // Optional per-frame size declaration, same contract as create (§10 R7).
      const parsedBody = refreshUploadsBody.safeParse(req.body ?? undefined);
      if (!parsedBody.success) {
        return reply
          .code(400)
          .send({ error: 'invalid_body', issues: parsedBody.error.issues });
      }

      const db = getDb();
      const world = await findOwnedWorld(db, req.params.id, userId);
      if (!world) return reply.code(404).send({ error: 'world_not_found' });

      // Latest capture row carries the frame-key prefix + count minted at create.
      const [capture] = await db
        .select()
        .from(captures)
        .where(eq(captures.worldId, world.id))
        .orderBy(desc(captures.createdAt))
        .limit(1);
      if (!capture || !capture.r2FramesPrefix) {
        return reply.code(404).send({ error: 'capture_not_found' });
      }

      const uploads = await presignFrameUploads(
        storage,
        capture.r2FramesPrefix,
        capture.frameCount,
        frameSizeMap(parsedBody.data?.frames),
      );
      return reply.send({
        world: serializeWorld(world),
        capture_id: capture.id,
        uploads,
      });
    },
  );

  // POST /v1/worlds/:id/frames:done — all frames uploaded → enqueue stitch.
  // Optionally accepts { poses: [...] } (per-frame ARKit poses) which is stored
  // verbatim into captures.poses_json. No body / empty body = old behavior.
  app.post<{ Params: { id: string } }>(
    '/v1/worlds/:id/frames:done',
    { bodyLimit: FRAMES_DONE_BODY_LIMIT },
    async (req, reply) => {
      const userId = requireUserId(req, reply);
      if (!userId) return;

      // Validate BEFORE any DB write: an invalid poses shape 400s without
      // touching world status or enqueuing a job.
      const parsed = framesDoneBody.safeParse(req.body ?? undefined);
      if (!parsed.success) {
        return reply
          .code(400)
          .send({ error: 'invalid_body', issues: parsed.error.issues });
      }
      const poses = parsed.data?.poses;

      const db = getDb();
      const world = await findOwnedWorld(db, req.params.id, userId);
      if (!world) return reply.code(404).send({ error: 'world_not_found' });

      // Store poses on the world's (latest) capture row when provided.
      if (poses && poses.length > 0) {
        const [capture] = await db
          .select()
          .from(captures)
          .where(eq(captures.worldId, world.id))
          .orderBy(desc(captures.createdAt))
          .limit(1);
        if (capture) {
          await db
            .update(captures)
            .set({ posesJson: poses })
            .where(eq(captures.id, capture.id));
        }
      }

      // Entering a new status → progress resets; updated_at is the heartbeat.
      await db
        .update(worlds)
        .set({ status: 'stitching', progress: null, updatedAt: new Date() })
        .where(eq(worlds.id, world.id));
      const jobId = await enqueue(db, 'stitch', world.id);

      const [updated] = await db.select().from(worlds).where(eq(worlds.id, world.id)).limit(1);
      return reply.send({ world: serializeWorld(updated!), job_id: jobId });
    },
  );

  // GET /v1/worlds/:id — status/phase + signed asset URLs.
  app.get<{ Params: { id: string } }>('/v1/worlds/:id', async (req, reply) => {
    const userId = requireUserId(req, reply);
    if (!userId) return;
    const db = getDb();
    const world = await findOwnedWorld(db, req.params.id, userId);
    if (!world) return reply.code(404).send({ error: 'world_not_found' });

    const assets: Record<string, string> = {};
    for (const [field, out] of ASSET_FIELDS) {
      const key = world[field];
      if (key) assets[out] = await storage.presignDownload(key, DOWNLOAD_TTL_SECONDS);
    }
    return reply.send({ world: serializeWorld(world), assets });
  });

  // GET /v1/worlds — owner's library, paginated, excluding soft-deleted.
  app.get('/v1/worlds', async (req, reply) => {
    const userId = requireUserId(req, reply);
    if (!userId) return;
    const q = z
      .object({
        limit: z.coerce.number().int().min(1).max(100).default(20),
        offset: z.coerce.number().int().min(0).default(0),
      })
      .parse(req.query);
    const db = getDb();
    const rows = await db
      .select()
      .from(worlds)
      .where(and(eq(worlds.ownerId, userId), isNull(worlds.deletedAt)))
      .orderBy(desc(worlds.createdAt))
      .limit(q.limit + 1)
      .offset(q.offset);

    const hasMore = rows.length > q.limit;
    const page = hasMore ? rows.slice(0, q.limit) : rows;
    // Each list item carries assets.thumbnail_url (only) — see
    // serializeWorldListItem. Presigning is pure crypto (no I/O), so the
    // per-item Promise.all is cheap.
    const items = await Promise.all(
      page.map((w) => serializeWorldListItem(w, storage)),
    );
    return reply.send({
      worlds: items,
      has_more: hasMore,
      // Kept alongside has_more for existing pagination consumers.
      next_offset: hasMore ? q.offset + q.limit : null,
    });
  });

  // POST /v1/worlds/:id/enhance — trigger HQ generation if draft is ready.
  app.post<{ Params: { id: string } }>('/v1/worlds/:id/enhance', async (req, reply) => {
    const userId = requireUserId(req, reply);
    if (!userId) return;
    const db = getDb();
    const world = await findOwnedWorld(db, req.params.id, userId);
    if (!world) return reply.code(404).send({ error: 'world_not_found' });
    if (world.status !== 'draft_ready') {
      return reply
        .code(409)
        .send({ error: 'not_enhanceable', status: world.status });
    }
    await db
      .update(worlds)
      .set({ status: 'generating_hq', progress: null, updatedAt: new Date() })
      .where(eq(worlds.id, world.id));
    const jobId = await enqueue(db, 'generate_hq', world.id);
    const [updated] = await db.select().from(worlds).where(eq(worlds.id, world.id)).limit(1);
    return reply.send({ world: serializeWorld(updated!), job_id: jobId });
  });

  // DELETE /v1/worlds/:id — soft delete + enqueue purge.
  app.delete<{ Params: { id: string } }>('/v1/worlds/:id', async (req, reply) => {
    const userId = requireUserId(req, reply);
    if (!userId) return;
    const db = getDb();
    const world = await findOwnedWorld(db, req.params.id, userId);
    if (!world) return reply.code(404).send({ error: 'world_not_found' });

    await db
      .update(worlds)
      .set({ deletedAt: new Date(), updatedAt: new Date() })
      .where(eq(worlds.id, world.id));
    const jobId = await enqueue(db, 'purge', world.id);
    return reply.send({ ok: true, job_id: jobId });
  });
}

/**
 * Presign one PUT upload URL per frame under `prefix`. Shared by world create
 * and uploads:refresh so both mint byte-identical keys (`frame_<i>.heic`),
 * content-type and per-frame ceiling — the resume path must land on the exact
 * same R2 objects the original upload targeted.
 */
async function presignFrameUploads(
  storage: StorageDriver,
  prefix: string,
  frameCount: number,
  sizes: Map<number, number> = new Map(),
): Promise<
  Array<{ index: number; key: string } & Awaited<ReturnType<StorageDriver['presignUpload']>>>
> {
  return Promise.all(
    Array.from({ length: frameCount }, async (_v, i) => {
      const key = `${prefix}/frame_${i}.heic`;
      const presigned = await storage.presignUpload(
        key,
        'image/heic',
        MAX_FRAME_BYTES,
        sizes.get(i),
      );
      return { index: i, key, ...presigned };
    }),
  );
}

async function findOwnedWorld(
  db: ReturnType<typeof getDb>,
  id: string,
  userId: string,
): Promise<World | undefined> {
  const [world] = await db
    .select()
    .from(worlds)
    .where(and(eq(worlds.id, id), eq(worlds.ownerId, userId), isNull(worlds.deletedAt)))
    .limit(1);
  return world;
}
