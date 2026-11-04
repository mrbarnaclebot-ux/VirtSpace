# VirtSpace — Session Handoff (2026-09-18)

Read this first next session, then `CLAUDE.md` and `spec-doc.md` §10 (hardening ledger **R1–R19** is the authoritative status). Repo: `~/Developer/VirtSpace` (not iCloud). Tip of `origin/main` at time of writing: see `git log` (last session commit: this handoff).

## State in one paragraph

Everything through **R18 is on `main` and deployed** to Railway (api `0b13dc16`, worker `76ddb6db`, 2026-09-18 00:37 IST). The owner's Mac/Xcode/iPhone are on **macOS/Xcode 27 / iOS 27**. The first real-device 28-shot capture worked end-to-end but exposed three bugs, all fixed: an iOS 27 crash at shot 28 (R16), mirrored panoramas (R17) and a dead "Enhance to HQ" button (R18). **None of the three fixes has been exercised by the owner on the phone yet** — that is the next step.

## Owner's next steps (device)

1. Run the current build on the iPhone, do a full 28-shot capture **in a lit room**. Expect: no crash at shot 28; upload overlay over the still-painted sphere; camera feed appears normally at capture start (session attach is now deferred by one main-actor hop — report any black flash). Also still to watch from R14: first-shot exposure lock (shot 0 was **unlocked** on the 09-17 capture — real issue, unfixed) and ring-completion haptics at shots 11/19/25.
2. That capture will be the first **un-mirrored** world. Check text/signage reads correctly in the pano preview and the world.
3. Tap **Enhance to HQ** on a `draft_ready` world (1500 credits ≈ $1.20; `DAILY_CREDIT_BUDGET=2000` ⇒ one per UTC day). Expect `generating_hq` → `complete`, `asset_version` 1→2, and the app refetching the splat. If it fails there is **no retry path** (see Open items).
4. If the app crashes: `xcrun devicectl device info files --device <udid> --domain-type systemCrashLogs`, then `device copy from … --source <name>.ips`.

## What landed 2026-09-17 → 18 (after the R1–R14 batch below)

| Ledger | What / where |
|---|---|
| R16 | iOS 27 crash at shot 28 (`92fbdf4`, `7f9bb86`). `.finished` rebuilt the `ARSCNView` while the engine paused the `ARSession`; iOS 27 ARKit delivers the preview rotation angle synchronously under `-[ARSession setViewLayer:]`'s unfair lock → layout → SwiftUI re-entry → second `makeUIView` → recursive-lock abort. Fix: one camera-layer identity across ready→finished (`CaptureEngineState.isFinished`), and `CameraPreviewHost` attaches the session on a guarded main-actor hop, never inside make/update. Frames were already on disk; launch-time resume uploaded them. |
| R17 | Stitcher produced **mirrored** panos on the pose path (`8ffa6b7`): ray-grid longitude ran toward +X; an inside-viewed right-handed +Y-up sphere needs −X. `ARKIT_TO_PROJ` was right; the pose-less fallback was accidentally right and stays bit-identical (`FLIP_RIGHT`). `stitcher.orientation.test.ts` fails on the old code. Verified on the real capture: text reads correctly, output == `fliplr(old)`. `PanoPreviewView`'s `scale(-1,1,1)` is the inside-sphere UV correction — leave it. **Every world generated before 2026-09-18 came from a mirrored pano.** |
| R18 | "Enhance to HQ" never worked (`545efd1`, `f0881f2`): backend served `/:id/enhance`, spec + iOS use `{id}:enhance`. Working Fastify route is `'/v1/worlds/:id(^[^:]+)::enhance'` (a bare `:id::enhance` swallows the suffix into the param name); slash form kept as alias. Also: atomic `draft_ready→generating_hq` flip (double tap could have queued two 1500-credit jobs), own `enhance:<user>` rate-limit key, malformed world id → 404 not 500, HQ finalize bumps `asset_version` (was never incremented ⇒ clients would keep the cached draft splat). |
| R19 | **Open.** `CaptureView` (627 lines) is a second god object — screen state machine + upload orchestration + quota policy + thermal/idle-timer + DEBUG test-scan tooling calling the API from the view. Plan: `CaptureScreenModel` (`@Observable`) + DEBUG-only tools view + layout-only view; do with R15 after the R16 device re-run. |
| deploy | `3309fd5` base image → `node:24-trixie-slim`; `df1114d` `railway.json`; `1b3e21d` `.graphifyignore`; `e60b266` graphify rule in `CLAUDE.md`. |

**Verified test state (2026-09-18):** backend `tsc` clean, vitest **310 passed / 11 skipped** with `STITCHER_TEST_PYTHON` pointing at a venv with the pinned numpy/opencv (the 11 skipped are the Postgres integration suites). iOS: generic-device build 0 warnings; unit tests **TEST SUCCEEDED** on the iOS 27 simulator (iPhone 18 Pro — there is no "iPhone 17" device in Xcode 27), 0 failures:
`xcodebuild test -project VirtSpace/VirtSpace.xcodeproj -scheme VirtSpace -destination 'platform=iOS Simulator,name=iPhone 18 Pro'`

## The 2026-09-17 device capture (world `2e3d5479`)

28 frames, stitch + `generate_draft` first attempt, 150 credits, all assets in R2. Ring angles within ~2° of nominal (the Swift 6 `ShotPipeline` works on device). Exposure locked on 27/28. Up to **52 cm translation drift** → parallax ghosting on near objects (stitcher is rotation-only; coach the user to pivot the phone, not the body). Very dark room — a poor quality test. Its pano and world are mirrored (pre-R17).

## Deploy (Railway) — how it actually works

- Services are **not** GitHub-linked; pushing does not deploy. The repo dir is not `railway link`ed; deploy from the repo root with:
  `railway up -p 1690518b-f063-41df-8839-19c0b00a33a1 -e production -s api --ci` (then `-s worker`). Deploy api first.
- `ALLOW_DEV_AUTH=1` is set on api + worker (production still runs dev auth). Worker is `PROVIDER_MODE=live`, `DAILY_CREDIT_BUDGET=2000`.
- **Base image must stay `node:24-trixie-slim`**: plain `node:24-slim` is bookworm/python 3.11 and the pinned numpy 2.5.x needs ≥3.12 (first-ever image build failed on this).
- **Migrations: the pre-deploy step does NOT run.** Railway CLI 5.57.7 silently ignores `deploy.preDeployCommand` edits and the committed `railway.json` had no visible effect. `0003`+`0004` were applied by hand: `cd backend && DATABASE_URL=… AUTH_MODE=dev DEV_AUTH_TOKEN=x npx tsx src/migrate.ts`. **Before the next migration-bearing deploy**, set the api service's Pre-deploy Command (`node dist/migrate.js`) in the Railway dashboard, or apply by hand *before* `railway up`.
- Post-deploy checks: `/healthz`; authed `GET /v1/worlds`; worker log shows `started; kinds=…` and no `claim error`.
- Optional env vars (all defaulted): `RATE_LIMIT_WINDOW_MS`, `RATE_LIMIT_MAX`, `RATE_LIMIT_IP_MAX`, `RATE_LIMIT_CREATE_MAX`, `AUTH_FAIL_MAX`, `SHUTDOWN_GRACE_MS`, `WORLDLABS_ASSET_MAX_BYTES`, `WORLDLABS_ASSET_HOSTS`, `TRUST_PROXY_HOPS` (default 1; confirm against production `req.ips`) — see `backend/.env.example`.

### Incident 2026-09-17 23:35 → 09-18 00:12 IST (orchestrator error, no data lost)

`DATABASE_URL` is Neon's **pgbouncer pooler** (`…-pooler…`), shared by local `.env` and production. An ad-hoc inspection script ran `SET default_transaction_read_only = on` "for safety"; the session setting stuck to the shared pooled backend, so production writes failed (old worker logged 27 `claim error`s; nothing was queued, nothing lost). Fixed with `RESET default_transaction_read_only`. **Rules:** never issue session-level `SET` through the pooler — use `BEGIN READ ONLY … ROLLBACK` or the direct (non-`-pooler`) host; `migrate.ts`'s session-scoped advisory lock is likewise only reliable over the direct host. Production is the owner's data: read-only inspection of DB/R2 was done at the owner's request; agents still never touch it.

## Open items

- **Device verification of R16 / R17 / R18** (above) — nothing here has been seen working on the phone.
- **R18 follow-ups:** no retry path after `failed_generating_hq` (`canEnhance` requires `draft_ready`; iOS shows the raw status string "failed generating hq"); default `DAILY_CREDIT_BUDGET` (500) cannot fit one HQ run (prod is 2000); the 429 copy conflates scan quota and credit budget; the conditional flip and `22P02`→404 were tested against fakes, not real Postgres; first real HQ run unverified end-to-end.
- **R15:** upload flows inherit `@MainActor` from `UploadManager` ⇒ `CaptureStore` manifest I/O is synchronous main-thread disk I/O during uploads. Do with **R19** and device testing.
- **First-shot exposure lock** (shot 0 unlocked) and **capture drift coaching** (52 cm) — both observed on device, neither addressed.
- Cosmetic: `PanoPreviewView` opens facing lon ≈ 180° (behind the first shot).
- **Mirrored legacy worlds:** regenerate any that matter (150 credits each) — owner's call.
- **R1 live verification:** `findWorldByDisplayName` (`GET /marble/v1/worlds?page_size=100`) is a best-guess API shape; wrong guess ⇒ parked job, never a double bill. Verify once (a list call costs nothing).
- **Postgres integration suites** are written but skipped (need `TEST_DATABASE_URL` — use a Neon branch, never the production DB): quota race, `heartbeatJob`.
- **R5 simulator guard** has still never been seen firing.
- `frames:done` / `uploads:refresh` routes hand their handlers a spurious extra param (behaviour correct, params untidy).
- Deferred on purpose: vitest/zod/TypeScript majors; `worlds.spz_full_url` dead column (iOS also decodes-but-never-reads `spz_100k_url`, `spz_full_url`, `collider_glb_url`); iOS frames are JPEG bytes under `.heic` keys.
- Pre-existing spec §10 items (World Labs deletion API, training-data ToS, marble-1.1 latency, …) unchanged.

## Knowledge graph (graphify)

`graphify-out/` (gitignored) was rebuilt in the new repo location: ~1,970 nodes / ~4,270 edges / 87 communities, including nodes for R1–R19, the deploy and the pooler incident. A **post-commit/post-checkout hook** rebuilds the code graph on every commit (per clone: `graphify hook install`). The hook ignores docs — run `/graphify . --update` at the end of any session that changed spec/handoff/README/`CLAUDE.md` (one ~100k-token extraction agent). `.graphifyignore` keeps the vendored three.js/Spark bundles, `video-example.mp4` and `virtspace-logs.txt` out. Health caveat from the full build: 82 dangling-endpoint edges, 25 self-loops, 380 collapsed duplicate edges; tree-sitter reports a syntax error in `CaptureView.swift` (~line 333) so that file is only partly extracted, though it compiles. `faster-whisper` + `tree-sitter-sql` live in the pipx `graphifyy` venv.

## Earlier this session: full review + R1–R14 (all landed, all deployed)

Two Opus reviewers (iOS, backend), orchestrator-verified; findings in `spec-doc.md` §10; §14 credit-safety claim corrected.

| Ledger | What landed |
|---|---|
| R1 | `pending:<jobId>` intent marker before `worlds:generate`; reconcile by unique `display_name`; generate-call failure is non-retryable; marker + reservation unwound when a *pre*-generate step fails (compensating `-amount` `credit_events` row) |
| R2 | Boot refuses `AUTH_MODE=dev` under `NODE_ENV=production` unless `ALLOW_DEV_AUTH=1`; timing-safe token compare |
| R3 | Deleted users get `403 account_deleted`; purge nulls `captures.poses_json` |
| R4 | `Idempotency-Key` on `POST /v1/worlds` (migration `0003`, `worlds.client_request_id`); iOS sends session UUID, persists a fresh key *before* minting a replacement world; retries backoff (1m/5m/30m/2h) and **park after 5** with Retry/Discard UI; quota/offline failures don't count |
| R5 | `Secrets.swift.example` defaults to localhost; DEBUG **simulator** builds `fatalError` on the production host unless `VIRTSPACE_ALLOW_PROD=1`; device builds unaffected; app starts inert + pinned to localhost under XCTest |
| R6 | `heartbeatJob` refreshes `locked_at` (poll tick + stitch progress); lost lease aborts without finalizing; finalize idempotent |
| R7 | Optional signed `content-length` per frame; worker always HEADs a frame and refuses >12 MB |
| R8 | Stitcher reprojects in row bands: peak RSS **4.5 GB → ~400 MB** at 8192 wide, byte-identical output; distinct exit codes (input vs internal); OOM/timeout non-retryable after 2 attempts; magic-byte format sniffing |
| R9 | Quota check-and-increment is one atomic statement |
| R10 | `dist/migrate.js` pre-deploy migrator (advisory-locked), drizzle folder in the image; SIGTERM drain; generic error handler + `safeParse`; `@fastify/rate-limit`; asset-download host allowlist + byte cap, API key only sent to the API host; UTC budget window; `captures(world_id, created_at)` index (migration `0004`); non-root Docker user |
| R11 | jose 6, `node:24-trixie-slim` (see Deploy), fastify/drizzle-kit/pg/aws-sdk bumps, numpy 2.5.3 + opencv 4.14 (needed for cp313 wheels on the Node 24 image). `npm audit --omit=dev` = 0 |
| R12 | Ring haptics derived from `TargetLayout`; per-session upload claims + 10-min resource timeout; `URLSession` download tasks; SPZ mapped once; WKWebView navigation allowlist; resume errors no longer swallowed |
| R13 | `VirtSpaceTests` Swift Testing target + shared scheme |
| R14 | `CaptureEngine` split (`HUDPublishThrottle`, `ThermalGovernor`, `ShotPipeline`, `CaptureHUDState`; 704→479 lines); **Swift 6 language mode**, 0 warnings; deployment target unified at 26.0; fixed a racy `lazy var` background `URLSession` (real crash) |

## Environment

- Repo moved out of iCloud on 2026-09-17 (`~/Documents` is a file-provider domain; caused NUL-byte reads, 30–670 s git commands, corrupted `node_modules`). Fresh clone at `~/Developer/VirtSpace` with the gitignored local files copied and byte-verified (`.env`, `Secrets.swift`, `.claude/settings.local.json`, `xcuserdata`, `tools/spike/state.json`, `tools/spike/world.spz`). The old iCloud folder is gone; GitHub Desktop has been repointed.
- Installed deps live in the **repo-root** `node_modules` (`backend/node_modules` is partial); no `psql`, no Docker on this Mac. A stitcher venv has to be created per session (`python3 -m venv … && pip install -r backend/stitcher/requirements.txt`) and passed as `STITCHER_TEST_PYTHON`.
- iOS 27.0 simulator runtime is installed (the iOS 26.x ones are gone). Disk: ~21 GB free at last check — low disk caused the earlier runtime purge, keep an eye on it.
- MCP servers that failed to connect this session: `magic`, `MCP_DOCKER`, `plugin:github` (use the `gh` CLI).

## Working agreements (unchanged, from CLAUDE.md)

Fable orchestrates/reviews/QA/commits; all implementation goes to Opus subagents (atomic commits, orchestrator re-runs tests before pushing). Agents never touch production, never launch the sim against prod, never call `worlds:generate`. Note: worktree isolation does not work for iOS builds — `Secrets.swift` is gitignored, so a worktree won't compile.
