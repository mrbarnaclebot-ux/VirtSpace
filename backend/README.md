# VirtSpace Backend

Fastify API + Postgres-backed job queue for VirtSpace (spec §3.2, §7, §14).
**Stage 1** is the API + schema + storage + credit-safe queue; **Stage 2** (this
build) adds the **worker loop**, the **World Labs provider** (live + mock), the
**daily credit budget guard**, and the **APNs push stub**. No external API / DB
calls happen at import or boot.

## Stack (locked — spec §3.2)

- **TypeScript** (strict, NodeNext), Node 24, ESM.
- **Fastify 5** + **zod** — HTTP + validation.
- **Drizzle ORM** over Postgres via the `pg` driver; migrations via **drizzle-kit**.
- **Vitest** — tests.
- Storage behind an **S3-compatible driver** interface: local disk for dev,
  Cloudflare R2 / S3 in production.

## Setup

```bash
npm install
cp .env.example .env      # fill in DATABASE_URL + DEV_AUTH_TOKEN at minimum
npm run db:generate       # (already committed) generate SQL from the schema
npm run db:migrate        # apply migrations to the DB in DATABASE_URL
npm run dev               # tsx watch + dotenv → http://localhost:8080/healthz
```

`npm run dev` loads `.env` via `--import dotenv/config`. The committed
`.env.example` documents every variable.

## Scripts

| Script | What it does |
|---|---|
| `dev` | `tsx watch` the server, loading `.env` via dotenv |
| `worker` | run the Stage-2 worker loop (`tsx src/worker.ts`), loading `.env` |
| `build` | `tsc` → `dist/` |
| `start` | run the compiled `dist/server.js` |
| `typecheck` | `tsc --noEmit` |
| `test` | `vitest run` (no DB required — pure/smoke tests) |
| `db:generate` | drizzle-kit: SQL migration from `src/db/schema.ts` (no DB) |
| `db:migrate` | drizzle-kit: apply migrations (connects to `DATABASE_URL`) |

## Architecture map

```
src/
  config.ts          zod-validated env loader (loadConfig / getConfig, memoized)
  server.ts          buildServer() + main(); lazy DB, boots without Postgres
  auth.ts            dev-token + Sign in with Apple (jose/JWKS) preHandler
  queue.ts           enqueue / claimNextJob (SKIP LOCKED + lease expiry) / complete / fail / parkDead
  quota.ts           pure daily-scan-quota logic (evaluateQuota)
  budget.ts          daily credit budget guard (reserveCredits, BudgetExceededError)
  worker.ts          Stage-2 loop: claims stitch/generate/purge jobs; credit-safe generation
  push.ts            APNs sendPush STUB (logs in dev; real APNs is a later phase)
  provider/
    types.ts         WorldGenProvider interface + WorldModel/credits + typed errors
    worldlabs.ts     LIVE World Labs Marble client (ported from tools/spike/spike.py)
    mock.ts          offline zero-credit provider (PROVIDER_MODE=mock)
    index.ts         createProvider(config) factory (mock | live)
  db/
    schema.ts        Drizzle tables — users, worlds, captures, jobs, devices, credit_events, share_slugs
    client.ts        LAZY pg Pool + drizzle db (created on first query, not at boot)
    users.ts         upsertUserBySub (idempotent identity upsert)
  storage/
    index.ts         StorageDriver interface + createStorage(config) factory
    local.ts         disk driver + dev-only /dev-storage/* Fastify routes
    s3.ts            @aws-sdk/client-s3 + presigner, endpoint-configurable (R2)
  routes/
    index.ts         registers health (open) + authed scope (worlds/devices/account)
    health.ts        GET /healthz — no auth, no DB
    worlds.ts        POST/GET/DELETE /v1/worlds*, frames:done, enhance
    devices.ts       POST /v1/devices
    account.ts       DELETE /v1/account
drizzle/             generated SQL migrations + meta
test/                vitest: config, storage, auth, quota/backoff
```

### API surface (spec §7.1)

- `GET  /healthz` — liveness, no auth, no DB.
- `POST /v1/worlds` — create world (`status=uploading`) + capture; returns N
  presigned frame upload URLs (`captures/{captureId}/frame_{i}.heic`). Enforces
  the daily scan quota.
- `POST /v1/worlds/:id/frames:done` — verify ownership, set `status=stitching`,
  enqueue a `stitch` job. Optionally accepts
  `{ poses: [{ index, timestamp, transform[16], intrinsics[9], exposureLocked }] }`
  (max 64 per-frame ARKit poses), stored verbatim into `captures.poses_json`.
  No/empty body keeps the old behavior; an invalid shape 400s before any state
  change (no status update, no job).
- `GET  /v1/worlds/:id` — status/phase + signed download URLs for any asset
  columns that are set.
- `GET  /v1/worlds` — owner's library, paginated (`limit`/`offset`), excludes
  soft-deleted. Each item carries `assets` with ONLY a presigned
  `thumbnail_url` (when set) for the iOS Library grid — heavy asset URLs are
  signed exclusively by the detail route. Response:
  `{ worlds: [{ ...world, assets: { thumbnail_url? } }], has_more, next_offset }`.
- `POST /v1/worlds/:id/enhance` — enqueue `generate_hq` if `status=draft_ready`
  (else 409).
- `DELETE /v1/worlds/:id` — soft delete + enqueue `purge`.
- `POST /v1/devices` — upsert an APNs token.
- `DELETE /v1/account` — soft-delete the user's worlds (+ enqueue purges), delete
  devices, mark the user deleted.

## Auth

- **dev** (`AUTH_MODE=dev`): send `Authorization: Bearer <DEV_AUTH_TOKEN>` **and**
  `x-dev-user: <email-ish id>`. The id upserts a user and is attached as
  `request.userId`. Header validation is a pure function (`parseDevAuth`) so
  rejection never touches the DB.
- **apple** (`AUTH_MODE=apple`): the `Authorization: Bearer` value is a Sign in
  with Apple identity token, verified with `jose` against Apple's JWKS
  (`https://appleid.apple.com/auth/keys`), issuer `https://appleid.apple.com`,
  audience `APPLE_BUNDLE_ID`. The `sub` upserts a user.

## Migrations

Drizzle-kit is schema-first: edit `src/db/schema.ts`, then `npm run db:generate`
writes a timestamped SQL file + snapshot into `drizzle/`. `generate` needs **no**
database connection. `npm run db:migrate` applies pending files to
`DATABASE_URL`. Committed migrations: `0000_*.sql` (initial schema) and
`0001_*.sql` (the `credit_events` ledger for the Stage-2 budget guard).

## Dev storage (`STORAGE_DRIVER=local`)

The local driver mimics presigned object storage without any cloud dependency:

- `presignUpload(key)` returns a plain `http://<PUBLIC_BASE_URL>/dev-storage/<key>`
  URL with method `PUT`; the client `PUT`s the bytes there.
- `presignDownload(key)` returns the same URL for `GET`.
- The `/dev-storage/*` routes (registered **only** when the driver is local) write
  to / read from `LOCAL_STORAGE_DIR`. Keys are path-traversal-checked.

Swap to `STORAGE_DRIVER=s3` for real presigned R2/S3 URLs — the route is not
registered and the driver signs URLs directly against the bucket. The rest of the
app only ever calls the `StorageDriver` interface, so nothing else changes.

## Job queue (spec §14)

`queue.ts` implements a Postgres-backed queue:

- `enqueue(kind, worldId, payload?)` inserts a `jobs` row.
- `claimNextJob(kinds, workerId)` uses
  `UPDATE ... WHERE id = (SELECT ... FOR UPDATE SKIP LOCKED) RETURNING`, takes a
  lease (`locked_at`/`locked_by`) and increments `attempts`.
- **Lease expiry (`LEASE_SECONDS = 600`)** — a job is claimable when it is
  unlocked **OR** its lease is older than 10 minutes. This fixes a QA defect: a
  worker that crashes mid-job previously left `locked_at` set forever, stranding
  the job. `isJobClaimable()` is the pure mirror of that WHERE clause (tested).
- `failJob` sets `run_after = now + min(2^attempts · 30s, 1h)` and parks the job
  as `phase='dead'` after 5 attempts (DLQ-equivalent).
- `parkJobDead` parks a job dead **immediately**, bypassing retry — used for
  non-retryable failures (budget exceeded, un-implemented stitch).
- `setProviderOperationId` persists the provider op id atomically so a resumed
  worker never blind-resubmits a credit-spending `worlds:generate` call.

## Worker (Stage 2) — `npm run worker`

A long-running loop (`workerId = hostname:pid`) that claims jobs of kinds
`stitch | generate_draft | generate_hq | purge` every `WORKER_POLL_MS` (default
2000). Handlers:

- **stitch** — *v0 passthrough* (Phase 0.5 gate pending). Exactly **1** capture
  frame is copied verbatim to `worlds/{id}/pano.jpg` (no real stitch/transcode),
  then `status=generating_draft` and a `generate_draft` job is enqueued. **>1
  frame fails** with `stitching not yet implemented (Phase 0.5 gate pending)`.
- **generate_draft / generate_hq** — the credit-safe money path (see below);
  `marble-1.0-draft` (150 credits) → `draft_ready`, `marble-1.1` (1500 credits)
  → `complete`. Fires the APNs push stub on success.
- **purge** — deletes storage objects under the world prefix + captures' frame
  prefixes; **keeps** the DB row (soft-deleted).

Boot is crash-safe: the DB pool is lazy, so with a dummy `DATABASE_URL` the
worker starts, logs claim errors, and idles instead of exiting.

### Credit safety (spec §14) — the money-touching path

`worlds:generate` is the only step that spends credits, and it runs **exactly
once** per job:

1. If the job already has a `provider_operation_id`, the worker **resumes at
   polling** — no reserve, no upload, no second `generateWorld`, no re-bill.
2. Otherwise it (a) `reserveCredits(cost)` against the **daily budget**, (b)
   uploads the pano, (c) calls `generateWorld`, and (d) **persists the
   operation id immediately** — so a crash between generate and completion
   resumes via step 1.
3. `reserveCredits` (`budget.ts`) sums today's `credit_events.amount` inside a
   transaction (with a `pg_advisory_xact_lock` so parallel workers can't both
   slip past) and inserts a new event iff `sum + cost <= DAILY_CREDIT_BUDGET`;
   else it throws `BudgetExceededError` and the job is **parked dead (no
   retry)**.

Provider CDN URLs are never exposed: every asset (SPZ 500k/100k, thumbnail,
collider) is downloaded and re-hosted on **our** storage under `worlds/{id}/`.

### Mock mode walkthrough (offline, zero credits)

`PROVIDER_MODE=mock` (the default) runs the whole pipeline with **no network and
no credits** via `provider/mock.ts` (instant operations, fixture asset bytes
served from an in-memory map). Cost is a property of the provider: the mock's
`creditsForModel` returns **0**, so dev runs reserve 0 against
`DAILY_CREDIT_BUDGET` (a 0-amount `credit_events` row keeps the ledger path
exercised) and `worlds.credits_spent` stays 0 — spend metrics reflect only real
generations. End to end offline:

```bash
cp .env.example .env         # defaults are mock + local storage
# start Postgres + apply migrations
npm run db:migrate
# terminal 1 — API
npm run dev
# terminal 2 — worker
npm run worker
```

Then drive the API (`POST /v1/worlds` with `frame_count: 1` → PUT the frame →
`POST /v1/worlds/{id}/frames:done`). The worker stitches (passthrough),
"generates" a mock world, re-hosts fixture assets into local storage, and the
world reaches `draft_ready` — all with zero World Labs calls.

## Notes / boundaries

- No DB connection is made on boot — the `pg` pool is created lazily on the first
  query, so the process and `/healthz` come up without Postgres.
- `worldlabs.ts` is a faithful port of `tools/spike/spike.py` (the live-verified
  contract), incl. `media_asset.media_asset_id`, the `WLT-Api-Key` header, and
  the `is_pano: true` generate body. It is exercised only when `PROVIDER_MODE=live`.
- Real APNs delivery and multi-frame stitching remain future phases.
