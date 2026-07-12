import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { desc, eq, sql } from 'drizzle-orm';
import { getConfig, type Config } from './config.js';
import { getDb, closeDb, type Db } from './db/client.js';
import { captures, worlds, type Job, type JobKind, type World } from './db/schema.js';
import {
  claimNextJob,
  completeJob,
  enqueue,
  failJob,
  parkJobDead,
  setProviderOperationId,
} from './queue.js';
import { reserveCredits, BudgetExceededError } from './budget.js';
import { createStorage, type StorageDriver } from './storage/index.js';
import {
  createProvider,
  ProviderError,
  ProviderTimeoutError,
  type WorldGenProvider,
  type WorldModel,
} from './provider/index.js';
import { sendPush, type SendPush } from './push.js';

// Stage 2 worker loop (spec §4 steps 1–6, §7 state machine, §14 credit safety).
// Entrypoint: `npm run worker`. Claims jobs of kinds [stitch, generate_draft,
// generate_hq, purge], processes each idempotently, and NEVER double-bills the
// money path — a resumed job with a persisted provider_operation_id skips
// straight to polling.

const WORKER_KINDS: JobKind[] = ['stitch', 'generate_draft', 'generate_hq', 'purge'];

const POLL_INTERVAL_MS = 5_000; // operation poll cadence.
const GENERATE_TIMEOUT_MS = 15 * 60 * 1000; // overall in-process poll ceiling.

/** Errors that must NOT be retried — the job is parked dead immediately. */
export class NonRetryableJobError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'NonRetryableJobError';
  }
}

// --- Storage key layout ------------------------------------------------------
const panoKeyFor = (worldId: string) => `worlds/${worldId}/pano.jpg`;
const panoPreviewKeyFor = (worldId: string) => `worlds/${worldId}/pano_preview.jpg`;
const assetKeyFor = (worldId: string, name: string) => `worlds/${worldId}/${name}`;
// Asset objects a world may own (used by purge).
const WORLD_ASSET_NAMES = [
  'pano.jpg',
  'pano_preview.jpg',
  'splat_100k.spz',
  'splat_500k.spz',
  'splat_full.spz',
  'thumbnail.jpg',
  'collider.glb',
];

/** Absolute path to the production Python stitcher, resolved relative to this
 * module so it works both under tsx (src/) and compiled (dist/) — the
 * `stitcher/` dir sits next to `src/` and `dist/`, and is COPYed into the
 * Docker image at the same relative location. */
function stitcherScriptPath(): string {
  return fileURLToPath(new URL('../stitcher/reproject.py', import.meta.url));
}

/** Keep only the trailing `max` chars of a (stderr) string for error messages. */
function tail(s: string, max = 800): string {
  const t = s.trim();
  return t.length > max ? `…${t.slice(-max)}` : t;
}

// =============================================================================
// Pure / injectable pieces (unit-testable without a DB or network).
// =============================================================================

export type StitchAction =
  | { type: 'passthrough' }
  | { type: 'stitch'; frameCount: number };

/**
 * Stitch decision (Phase 0.5 gate PASSED — the reprojection stitcher is live).
 * Exactly one frame is a passthrough (that single frame IS the pano — the
 * test-scan path, no real stitching or HEIC→JPEG transcode). More than one
 * frame runs the production Python reprojection stitcher (stitcher/reproject.py).
 */
export function stitchPlan(frameCount: number): StitchAction {
  if (frameCount === 1) return { type: 'passthrough' };
  return { type: 'stitch', frameCount };
}

// --- Stitcher subprocess plumbing (unit-testable) ----------------------------

/**
 * Serialize captures.poses_json into the poses.json payload the Python stitcher
 * consumes (the ARKit pose array verbatim). Throws if the row has no usable
 * pose array — callers only invoke this when poses are actually present.
 */
export function serializePoses(posesJson: unknown): string {
  if (!Array.isArray(posesJson) || posesJson.length === 0) {
    throw new Error('poses_json must be a non-empty array to stitch with poses');
  }
  return JSON.stringify(posesJson);
}

/** True when a captures row carries a usable ARKit pose array. */
export function posesPresent(posesJson: unknown): boolean {
  return Array.isArray(posesJson) && posesJson.length > 0;
}

export interface StitcherArgs {
  scriptPath: string;
  framesDir: string;
  outPath: string;
  width: number;
  previewPath?: string | null;
  posesPath?: string | null;
}

/**
 * Build reproject.py's argv. `--poses` is included ONLY when a poses path is
 * given (poses-driven reprojection); omitting it selects the nominal fallback.
 */
export function buildStitcherArgs(a: StitcherArgs): string[] {
  const args = [
    a.scriptPath,
    '--frames-dir', a.framesDir,
    '--out', a.outPath,
    '--width', String(a.width),
  ];
  if (a.posesPath) args.push('--poses', a.posesPath);
  if (a.previewPath) args.push('--preview-out', a.previewPath);
  return args;
}

export interface StitcherRun {
  code: number;
  stdout: string;
  stderr: string;
  timedOut: boolean;
}

/** Injectable stitcher runner (real impl spawns Python; tests mock it). */
export type StitcherSpawner = (
  bin: string,
  args: string[],
  timeoutMs: number,
) => Promise<StitcherRun>;

/** Real spawner: runs `bin args`, capturing stdout/stderr, SIGKILL on timeout. */
export const realStitcherSpawner: StitcherSpawner = (bin, args, timeoutMs) =>
  new Promise<StitcherRun>((resolve, reject) => {
    const child = spawn(bin, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill('SIGKILL');
    }, timeoutMs);
    child.stdout.on('data', (d) => {
      stdout += d.toString();
    });
    child.stderr.on('data', (d) => {
      stderr += d.toString();
    });
    child.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      resolve({ code: code ?? -1, stdout, stderr, timedOut });
    });
  });

export interface GenerationClock {
  now(): number;
  sleep(ms: number): Promise<void>;
}

const realClock: GenerationClock = {
  now: () => Date.now(),
  sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
};

export interface GenerationInput {
  model: WorldModel;
  displayName: string;
  cost: number;
  /** Persisted provider_operation_id — non-null means RESUME (never re-bill). */
  existingOperationId: string | null;
}

/** Side-effect surface runGeneration needs — real impl hits db + storage. */
export interface GenerationIO {
  reserveCredits(amount: number): Promise<void>;
  getPanoBytes(): Promise<Buffer>;
  saveOperationId(operationId: string): Promise<void>;
  /** Persist asset bytes; returns the storage key. */
  storeAsset(name: string, bytes: Buffer): Promise<string>;
}

export interface GenerationResult {
  worldId: string;
  caption?: string;
  assetKeys: {
    spz100kUrl?: string;
    spz500kUrl?: string;
    thumbnailUrl?: string;
    colliderGlbUrl?: string;
  };
}

/**
 * Credit-safe generation sequence (spec §14). The ONLY money-touching step is
 * generateWorld, and it runs exactly once per job: if an operation id already
 * exists we skip reserve+upload+generate entirely and resume at polling.
 */
export async function runGeneration(
  provider: WorldGenProvider,
  io: GenerationIO,
  input: GenerationInput,
  clock: GenerationClock = realClock,
  opts: { pollIntervalMs?: number; timeoutMs?: number } = {},
): Promise<GenerationResult> {
  const pollIntervalMs = opts.pollIntervalMs ?? POLL_INTERVAL_MS;
  const timeoutMs = opts.timeoutMs ?? GENERATE_TIMEOUT_MS;

  let operationId = input.existingOperationId;
  if (!operationId) {
    // (a→b→c→d→e) Reserve BEFORE spending; persist the op id IMMEDIATELY after
    // generate so a crash resumes via the id instead of re-billing.
    await io.reserveCredits(input.cost);
    const panoBytes = await io.getPanoBytes();
    const mediaAssetId = await provider.uploadPano(panoBytes, 'pano.jpg');
    operationId = await provider.generateWorld(mediaAssetId, input.model, input.displayName);
    await io.saveOperationId(operationId);
  }

  // (f) Poll until done — in-process loop; the job lease outlives this via
  // re-claim + operation_id resume (see queue.ts LEASE_SECONDS).
  const deadline = clock.now() + timeoutMs;
  let status = await provider.getOperation(operationId);
  while (!status.done) {
    if (clock.now() >= deadline) {
      throw new ProviderTimeoutError(
        `operation ${operationId} did not finish within ${timeoutMs}ms`,
      );
    }
    await clock.sleep(pollIntervalMs);
    status = await provider.getOperation(operationId);
  }
  if (status.error) throw new ProviderError(`operation failed: ${status.error}`);
  if (!status.worldId) throw new ProviderError('operation done but returned no world_id');

  // (g) Fetch + re-host every asset onto OUR storage (spec §14 asset ownership).
  const worldId = status.worldId;
  const assets = await provider.getWorld(worldId);
  const assetKeys: GenerationResult['assetKeys'] = {};
  if (assets.spzUrls.k500) {
    assetKeys.spz500kUrl = await io.storeAsset(
      'splat_500k.spz',
      await provider.downloadAsset(assets.spzUrls.k500),
    );
  }
  if (assets.spzUrls.k100) {
    assetKeys.spz100kUrl = await io.storeAsset(
      'splat_100k.spz',
      await provider.downloadAsset(assets.spzUrls.k100),
    );
  }
  if (assets.thumbnailUrl) {
    assetKeys.thumbnailUrl = await io.storeAsset(
      'thumbnail.jpg',
      await provider.downloadAsset(assets.thumbnailUrl),
    );
  }
  if (assets.colliderMeshUrl) {
    assetKeys.colliderGlbUrl = await io.storeAsset(
      'collider.glb',
      await provider.downloadAsset(assets.colliderMeshUrl),
    );
  }

  const result: GenerationResult = { worldId, assetKeys };
  if (assets.caption) result.caption = assets.caption;
  return result;
}

// =============================================================================
// DB-bound job handlers.
// =============================================================================

export interface WorkerDeps {
  db: Db;
  storage: StorageDriver;
  provider: WorldGenProvider;
  config: Config;
  push: SendPush;
  clock?: GenerationClock;
  /** Injectable stitcher runner — defaults to spawning real Python. */
  stitcher?: StitcherSpawner;
}

async function loadWorld(db: Db, worldId: string): Promise<World> {
  const [world] = await db.select().from(worlds).where(eq(worlds.id, worldId)).limit(1);
  if (!world) throw new NonRetryableJobError(`world not found: ${worldId}`);
  return world;
}

/** Update the world row + enqueue draft generation after a pano lands. */
async function finalizeStitch(db: Db, worldId: string, panoKey: string): Promise<void> {
  await db
    .update(worlds)
    .set({ panoUrl: panoKey, status: 'generating_draft', phase: null })
    .where(eq(worlds.id, worldId));
  await enqueue(db, 'generate_draft', worldId);
}

/**
 * stitch (Phase 0.5 — production reprojection stitcher).
 *
 * frame_count == 1 → PASSTHROUGH (the test-scan path): the lone frame IS the
 * pano, copied verbatim to pano.jpg. v0 caveat: no HEIC→JPEG transcode, so this
 * assumes the single frame is already an equirect-usable image.
 *
 * frame_count > 1 → real stitch: download every frame to a temp dir, write
 * poses.json when captures.poses_json is present, then spawn
 * stitcher/reproject.py (5-min timeout). On success upload pano.jpg (+ optional
 * pano_preview.jpg) and advance to generating_draft. On Python failure the job
 * fails RETRYABLE (transient disk/memory pressure is real). Temp dir is always
 * cleaned in finally.
 *
 * NOTE (documented gap, shared with the passthrough path): frames are written
 * to the temp dir as frame_<i>.jpg from the stored bytes. The winning pipeline
 * assumes JPEG-decodable frames; a true HEIC→JPEG transcode is a follow-up.
 */
export async function handleStitch(deps: WorkerDeps, job: Job): Promise<void> {
  const { db, storage, config } = deps;
  const world = await loadWorld(db, job.worldId);

  const [capture] = await db
    .select()
    .from(captures)
    .where(eq(captures.worldId, job.worldId))
    .orderBy(desc(captures.createdAt))
    .limit(1);
  if (!capture) throw new NonRetryableJobError(`no capture row for world ${job.worldId}`);

  const framePrefix = capture.r2FramesPrefix ?? `captures/${capture.id}`;
  const panoKey = panoKeyFor(world.id);
  const plan = stitchPlan(capture.frameCount);

  if (plan.type === 'passthrough') {
    // Passthrough: the lone frame IS the pano. NOTE v0 limitation — no transcode.
    const frameBytes = await storage.getObject(`${framePrefix}/frame_0.heic`);
    await storage.putObject(panoKey, frameBytes);
    await finalizeStitch(db, world.id, panoKey);
    await completeJob(db, job.id);
    return;
  }

  // Multi-frame reprojection stitch.
  const spawner = deps.stitcher ?? realStitcherSpawner;
  const workDir = await mkdtemp(path.join(os.tmpdir(), `virtspace-stitch-${world.id}-`));
  try {
    const framesDir = path.join(workDir, 'frames');
    await mkdir(framesDir, { recursive: true });
    for (let i = 0; i < capture.frameCount; i++) {
      const bytes = await storage.getObject(`${framePrefix}/frame_${i}.heic`);
      await writeFile(path.join(framesDir, `frame_${i}.jpg`), bytes);
    }

    let posesPath: string | null = null;
    if (posesPresent(capture.posesJson)) {
      posesPath = path.join(workDir, 'poses.json');
      await writeFile(posesPath, serializePoses(capture.posesJson));
    }

    const outPath = path.join(workDir, 'pano.jpg');
    const previewPath = path.join(workDir, 'pano_preview.jpg');
    const args = buildStitcherArgs({
      scriptPath: stitcherScriptPath(),
      framesDir,
      outPath,
      width: config.STITCHER_WIDTH,
      previewPath,
      posesPath,
    });

    const run = await spawner(config.PYTHON_BIN, args, config.STITCHER_TIMEOUT_MS);
    if (run.timedOut) {
      throw new Error(`stitcher timed out after ${config.STITCHER_TIMEOUT_MS}ms`);
    }
    if (run.code !== 0) {
      // Retryable: transient disk/memory issues can clear on a re-run.
      throw new Error(`stitcher exited ${run.code}: ${tail(run.stderr)}`);
    }

    const panoBytes = await readFile(outPath);
    await storage.putObject(panoKey, panoBytes);

    // Optional preview (2000x1000) — best-effort, not referenced by any DB
    // column (thumbnail comes from Marble later). Purge cleans it via
    // WORLD_ASSET_NAMES.
    try {
      const previewBytes = await readFile(previewPath);
      await storage.putObject(panoPreviewKeyFor(world.id), previewBytes);
    } catch {
      // preview is optional; ignore if the stitcher didn't emit one.
    }

    await finalizeStitch(db, world.id, panoKey);
    await completeJob(db, job.id);
  } finally {
    await rm(workDir, { recursive: true, force: true }).catch(() => undefined);
  }
}

async function handleGenerate(
  deps: WorkerDeps,
  job: Job,
  model: WorldModel,
): Promise<void> {
  const { db, storage, provider, config, push } = deps;
  const clock = deps.clock ?? realClock;
  const world = await loadWorld(db, job.worldId);
  if (!world.panoUrl) {
    throw new NonRetryableJobError(`world ${world.id} has no pano to generate from`);
  }

  const isDraft = model === 'marble-1.0-draft';
  const cost = provider.creditsForModel(model);
  const panoKey = world.panoUrl;

  const io: GenerationIO = {
    reserveCredits: (amount) =>
      reserveCredits(db, amount, config.DAILY_CREDIT_BUDGET, world.id),
    getPanoBytes: () => storage.getObject(panoKey),
    saveOperationId: (opId) => setProviderOperationId(db, job.id, opId),
    storeAsset: async (name, bytes) => {
      const key = assetKeyFor(world.id, name);
      await storage.putObject(key, bytes);
      return key;
    },
  };

  const result = await runGeneration(
    provider,
    io,
    {
      model,
      displayName: world.title ?? `VirtSpace world ${world.id}`,
      cost,
      existingOperationId: job.providerOperationId,
    },
    clock,
  );

  // Finalize the world row: asset keys, provider world id, credits, status.
  // credits_spent is bumped once per successful job (never on resume before
  // finalize, since a resumed job crashed *before* this write ran).
  await db
    .update(worlds)
    .set({
      status: isDraft ? 'draft_ready' : 'complete',
      phase: null,
      provider: provider.mode === 'mock' ? 'mock' : 'worldlabs',
      creditsSpent: sql`${worlds.creditsSpent} + ${cost}`,
      ...result.assetKeys,
      ...(result.caption ? { caption: result.caption } : {}),
      ...(isDraft
        ? { draftWorldId: result.worldId, draftModel: model }
        : { hqWorldId: result.worldId, hqModel: model }),
    })
    .where(eq(worlds.id, world.id));
  await completeJob(db, job.id);

  // APNs push on draft_ready / complete (spec §4 "world ready").
  await push(
    world.ownerId,
    isDraft ? 'Your draft world is ready' : 'Your world is complete',
    isDraft
      ? 'Tap to explore your new 3D world.'
      : 'Your high-quality world finished generating.',
  );
}

/**
 * purge — delete storage objects under the world + its captures' frame
 * prefixes. The DB row is KEPT (soft-deleted) so history/analytics survive.
 */
async function handlePurge(deps: WorkerDeps, job: Job): Promise<void> {
  const { db, storage } = deps;
  const worldId = job.worldId;

  for (const name of WORLD_ASSET_NAMES) {
    await storage.deleteObject(assetKeyFor(worldId, name)).catch(() => undefined);
  }

  const caps = await db.select().from(captures).where(eq(captures.worldId, worldId));
  for (const cap of caps) {
    const prefix = cap.r2FramesPrefix ?? `captures/${cap.id}`;
    for (let i = 0; i < cap.frameCount; i++) {
      await storage.deleteObject(`${prefix}/frame_${i}.heic`).catch(() => undefined);
    }
  }

  await completeJob(db, job.id);
}

export async function processJob(deps: WorkerDeps, job: Job): Promise<void> {
  switch (job.kind as JobKind) {
    case 'stitch':
      return handleStitch(deps, job);
    case 'generate_draft':
      return handleGenerate(deps, job, 'marble-1.0-draft');
    case 'generate_hq':
      return handleGenerate(deps, job, 'marble-1.1');
    case 'purge':
      return handlePurge(deps, job);
    default:
      throw new NonRetryableJobError(`unknown job kind: ${job.kind}`);
  }
}

/** Map a job kind to its failed_<phase> world status (spec §7), or null. */
function failedStatusFor(kind: string): string | null {
  switch (kind) {
    case 'stitch':
      return 'failed_stitch';
    case 'generate_draft':
      return 'failed_generating_draft';
    case 'generate_hq':
      return 'failed_generating_hq';
    default:
      return null;
  }
}

async function handleJobError(db: Db, job: Job, err: unknown): Promise<void> {
  const message = err instanceof Error ? err.message : String(err);
  const nonRetryable =
    err instanceof BudgetExceededError || err instanceof NonRetryableJobError;

  if (nonRetryable) {
    console.error(`[worker] job ${job.id} (${job.kind}) parked DEAD: ${message}`);
    await parkJobDead(db, job.id, message);
    const failed = failedStatusFor(job.kind);
    if (failed) {
      await db
        .update(worlds)
        .set({ status: failed })
        .where(eq(worlds.id, job.worldId))
        .catch(() => undefined);
    }
  } else {
    console.error(`[worker] job ${job.id} (${job.kind}) failed (retryable): ${message}`);
    await failJob(db, job.id, message);
  }
}

// =============================================================================
// Loop + entrypoint.
// =============================================================================

export function makeWorkerId(): string {
  return `${os.hostname()}:${process.pid}`;
}

export interface WorkerHandle {
  stop(): void;
  done: Promise<void>;
}

/**
 * Start the claim loop. Non-blocking: returns a handle with `stop()` and a
 * `done` promise. Claim errors (e.g. an unreachable dummy DB) are logged and
 * the loop backs off and stays alive (task requirement 10).
 */
export function startWorker(deps: WorkerDeps): WorkerHandle {
  const workerId = makeWorkerId();
  const pollMs = deps.config.WORKER_POLL_MS;
  const sleep = (deps.clock ?? realClock).sleep;
  let running = true;

  const done = (async () => {
    console.log(`[worker] ${workerId} started; kinds=${WORKER_KINDS.join(',')} poll=${pollMs}ms`);
    while (running) {
      let job: Job | null = null;
      try {
        job = await claimNextJob(deps.db, WORKER_KINDS, workerId);
      } catch (err) {
        console.error(`[worker] claim error (staying alive): ${String(err)}`);
        await sleep(pollMs);
        continue;
      }
      if (!job) {
        await sleep(pollMs);
        continue;
      }
      try {
        await processJob(deps, job);
      } catch (err) {
        await handleJobError(deps.db, job, err).catch((e) =>
          console.error(`[worker] error-handler failed: ${String(e)}`),
        );
      }
    }
    console.log(`[worker] ${workerId} stopped`);
  })();

  return { stop: () => (running = false), done };
}

async function main(): Promise<void> {
  const config = getConfig();
  const deps: WorkerDeps = {
    db: getDb(),
    storage: createStorage(config),
    provider: createProvider(config),
    config,
    push: sendPush,
  };
  const handle = startWorker(deps);

  const shutdown = (sig: string) => {
    console.log(`[worker] received ${sig}, draining...`);
    handle.stop();
    handle.done.then(() => closeDb()).finally(() => process.exit(0));
  };
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));

  await handle.done;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
