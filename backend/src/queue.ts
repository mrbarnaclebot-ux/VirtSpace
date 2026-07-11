import { sql } from 'drizzle-orm';
import type { Db } from './db/client.js';
import { jobs, type Job, type JobKind } from './db/schema.js';

// Postgres-backed job queue (spec §7 / §14). No worker loop yet — Stage 2.
// Uses FOR UPDATE SKIP LOCKED so multiple workers can claim jobs concurrently
// without contention.

const MAX_ATTEMPTS = 5;
const BASE_BACKOFF_SECONDS = 30;
const MAX_BACKOFF_SECONDS = 60 * 60; // 1 hour cap.

/**
 * Exponential backoff in seconds for a given attempt count:
 * min(2^attempts * 30s, 1h). Pure — exported for testing.
 */
export function backoffSeconds(attempts: number): number {
  const raw = 2 ** attempts * BASE_BACKOFF_SECONDS;
  return Math.min(raw, MAX_BACKOFF_SECONDS);
}

/** Insert a job row. Returns the created job id. */
export async function enqueue(
  db: Db,
  kind: JobKind,
  worldId: string,
  payload?: unknown,
): Promise<string> {
  const [row] = await db
    .insert(jobs)
    .values({
      kind,
      worldId,
      payload: payload === undefined ? null : (payload as object),
    })
    .returning({ id: jobs.id });
  return row!.id;
}

/**
 * Atomically claim the next runnable job of one of `kinds`. Uses
 * `UPDATE ... WHERE id = (SELECT ... FOR UPDATE SKIP LOCKED) RETURNING`,
 * increments attempts, and takes a lease (locked_at/locked_by). Returns the
 * claimed job or null when the queue is empty.
 */
export async function claimNextJob(
  db: Db,
  kinds: JobKind[],
  workerId: string,
): Promise<Job | null> {
  if (kinds.length === 0) return null;
  const result = await db.execute<Job>(sql`
    UPDATE jobs
    SET locked_at = now(),
        locked_by = ${workerId},
        attempts = attempts + 1,
        phase = 'running',
        updated_at = now()
    WHERE id = (
      SELECT id FROM jobs
      WHERE kind = ANY(${kinds})
        AND phase IN ('queued', 'running')
        AND locked_at IS NULL
        AND run_after <= now()
      ORDER BY run_after ASC
      FOR UPDATE SKIP LOCKED
      LIMIT 1
    )
    RETURNING *
  `);
  const rows = (result as unknown as { rows: Job[] }).rows;
  return rows[0] ?? null;
}

/** Mark a job done and release its lease. */
export async function completeJob(db: Db, jobId: string): Promise<void> {
  await db.execute(sql`
    UPDATE jobs
    SET phase = 'done', locked_at = NULL, locked_by = NULL, updated_at = now()
    WHERE id = ${jobId}
  `);
}

/**
 * Fail a job: record the error, release the lease, and schedule a retry with
 * exponential backoff. Once attempts reach MAX_ATTEMPTS the job is parked as
 * 'dead' (DLQ-equivalent, spec §14).
 */
export async function failJob(
  db: Db,
  jobId: string,
  error: string,
): Promise<void> {
  await db.execute(sql`
    UPDATE jobs
    SET last_error = ${error},
        locked_at = NULL,
        locked_by = NULL,
        phase = CASE WHEN attempts >= ${MAX_ATTEMPTS} THEN 'dead' ELSE 'queued' END,
        run_after = now() + (LEAST(POWER(2, attempts) * ${BASE_BACKOFF_SECONDS}, ${MAX_BACKOFF_SECONDS}) * interval '1 second'),
        updated_at = now()
    WHERE id = ${jobId}
  `);
}

/**
 * Persist the provider operation id atomically (spec §14) so a resumed worker
 * never blind-resubmits a credit-spending worlds:generate call.
 */
export async function setProviderOperationId(
  db: Db,
  jobId: string,
  operationId: string,
): Promise<void> {
  await db.execute(sql`
    UPDATE jobs
    SET provider_operation_id = ${operationId}, updated_at = now()
    WHERE id = ${jobId}
  `);
}
