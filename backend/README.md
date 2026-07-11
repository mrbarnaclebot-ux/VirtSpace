# VirtSpace Backend

Fastify API + Postgres-backed job queue for VirtSpace (spec §3.2, §7, §14). This
is the **Stage 1 skeleton**: schema, storage drivers, auth, the REST surface, and
a credit-safe queue. There is **no worker loop yet** (Stage 2) and no external
API / DB calls happen on boot.

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
  queue.ts           enqueue / claimNextJob (SKIP LOCKED) / complete / fail + backoff
  quota.ts           pure daily-scan-quota logic (evaluateQuota)
  db/
    schema.ts        Drizzle tables — users, worlds, captures, jobs, devices, share_slugs
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
  enqueue a `stitch` job.
- `GET  /v1/worlds/:id` — status/phase + signed download URLs for any asset
  columns that are set.
- `GET  /v1/worlds` — owner's library, paginated (`limit`/`offset`), excludes
  soft-deleted.
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
`DATABASE_URL`. The initial migration (`drizzle/0000_*.sql`) is committed.

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

`queue.ts` implements a Postgres-backed queue (no worker loop yet):

- `enqueue(kind, worldId, payload?)` inserts a `jobs` row.
- `claimNextJob(kinds, workerId)` uses
  `UPDATE ... WHERE id = (SELECT ... FOR UPDATE SKIP LOCKED) RETURNING`, takes a
  lease (`locked_at`/`locked_by`) and increments `attempts`.
- `failJob` sets `run_after = now + min(2^attempts · 30s, 1h)` and parks the job
  as `phase='dead'` after 5 attempts (DLQ-equivalent).
- `setProviderOperationId` persists the provider op id atomically so a resumed
  worker never blind-resubmits a credit-spending `worlds:generate` call.

## Notes / Stage-1 boundaries

- No DB connection is made on boot — the `pg` pool is created lazily on the first
  query, so the process and `/healthz` come up without Postgres.
- No World Labs / external calls; `PROVIDER_MODE` defaults to `mock`.
- The worker loop, provider client, stitching, and APNs delivery are Stage 2.
