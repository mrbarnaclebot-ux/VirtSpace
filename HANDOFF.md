# VirtSpace — Session Handoff (2026-11-05)

Read this first next session, then `CLAUDE.md` and `spec-doc.md` §10 (ledger **R1–R41** is the authoritative status) and §5.2 (capture v2 contract). Repo: `~/Developer/VirtSpace` (not iCloud). `AGENTS.md` is a generic template; where it disagrees, `CLAUDE.md` and `spec-doc.md` win.

## State in one paragraph

Everything is on `main` (`2f3ddf2`+) and the backend is **deployed** (api + worker, 2026-11-05). Migrations now run automatically before each api deploy (`preDeploy: node dist/migrate.js` over `MIGRATE_DATABASE_URL`, the direct Neon host). The full UI redesign (WP1-WP5 from `docs/design/ui-spec.md`) is merged and a Debug build of `main` with production Secrets is installed on the owner's iPhone 17 Pro; nothing in the redesign has been walked through on the device yet. Login (R24) is deliberately deferred until the main features work as intended.

## Resume here: capture direction (paused 2026-11-05, owner will continue)

**Product goal (owner):** brokers and agents scan a room, then a whole house or floor, and buyers or renters walk it in 3D on a future web listings page. **Room first:** a clean 3D room you can walk around. Multi-room comes after.

**Finding:**
- World Labs Marble *generates* from one pano: invented outside the spot, one viewpoint, not faithful enough for listings.
- Faithful tours need **reconstruction** from a walk-through capture (frames plus ARKit poses, plus depth).
- The renderer does not fix this.
- Full write-up with sources: `docs/research/reconstruction-vs-generation.md` (builds on `docs/research/live-mapping.md`).

**PlayCanvas** (MIT engine, SuperSplat, supersplat-viewer, splat-transform):
- Display only; no reconstruction.
- Candidate for the web listings viewer later: walk mode, hotspots, collision, streamed SOG LOD.
- Keep Spark in the app; first trial Spark's own LoD/paging (about 1 day).

**SpAItial (Echo-3)** is the leading capture provider:
- **Keys:** the owner's API key and webhook secret are in local `.env` as `spAItial_api_key` / `spAItial_api_secret`. The format is `key = value` with spaces, so parse accordingly. They are not on Railway yet.
- **What our key has:** `echo-2` and `echo-hq` only. Both are generative from a single image or pano.
- **Capture API:**
  - flow: `POST /v1/captures` → `upload-urls` → `complete` → `process`;
  - inputs: an iOS frame bundle (`images/Image_NNNNNN.jpg` plus `cameras/camera_trajectory.json`, `camera_intrinsics.json`, `orientation.json`, up to 5,000 frames) or an unposed video (5-600 s);
  - price: 300 credits/min, 900 minimum (about $9 for a room);
  - outputs: SPZ/SOG/PLY plus collision mesh plus floorplan.
- **Blocked:** it is **not enabled** for our key (`process-quote` says "Contact support"). The bundle JSON schemas are not public.
- **Spend so far:** 0 credits. Only free GET calls were made; the OpenAPI spec is at `https://api.spaitial.ai/v1/openapi.json`.

**Proposed plan (awaiting owner answers):**
1. **Owner:** scan one room for 3+ minutes in SpAItial's own iPhone app (about $9-16 of credits; the free 800 doesn't cover the 900 minimum) and judge the walk-around quality.
2. **Owner:** email SpAItial support to enable Echo-3 for the API, and ask for:
   - the price;
   - the bundle schemas;
   - the frame rate and resolution;
   - whether LiDAR depth is accepted;
   - data terms for private homes.

   The orchestrator offered to draft this email.
3. **Agents**, in mock mode with no credits:
   - **iOS:** a "Room scan" capture mode: walk the room edge for about 3 minutes, keyframes plus ARKit poses plus intrinsics, with coverage guidance.
   - **Backend:** an `echo-3` capture provider behind `WorldGenProvider`. Quote first, persist `capture_id`/request id before `process`, use Idempotency-Keys, never retry blind, and verify webhooks with HMAC.
   - **Viewer:** load the SPZ. Its RDF y-down orientation takes the same flip as Marble. Use the `mesh-simplified` export as the walk collider.
4. **Fallbacks:** Varjo Teleport API (about $16 a house), or a self-hosted gsplat/Brush on a GPU. Both are Apache-2.0; avoid the INRIA license. The same room-scan bundle feeds either.
5. Whole house later: one longer capture per floor.

**Open questions to the owner:**
- Do the SpAItial-app room test first?
- Draft the support email?
- Start Room scan in mock mode now, or wait for the test?
- Accept that Marble becomes "staging only", never the listing tour?
- What per-house price can a broker carry: about $16 (Teleport) or $30-60 (Echo-3)?

## Owner's next steps (device)

1. Fresh-launch walkthrough of the redesign: onboarding (Welcome, 3 how-to pages, Terms with Agree), Library (states, cards, Retry on a failed space, Improve quality sheet, delete), Scan (camera priming, start banners, first-scan coaching, direction prompts, upload overlay "Finishing up...", landing on the new space), Explorer (one loading screen, smooth 500k splat by default; Settings > 3D viewer > Maximum detail loads full-res), 360 photo (Save to Photos), Settings (storage sizes, Clear downloads, How to scan, Terms, Privacy).
2. One capture to confirm background uploads (lock the phone mid-upload) and the end-to-end flow on the new UI (150 credits).
3. Re-check world `b936c74a` in 3D now that its full-res splat is backfilled.
4. Crash logs: `xcrun devicectl device info files --device <udid> --domain-type systemCrashLogs`, then `device copy from ... --source <name>.ips`.

## Landed 2026-11-05

| Item | Deployed? |
|---|---|
| Capture v2 iOS + R19/R15; display_name 422 fix; full-res splats (worker + iOS) | yes / on phone |
| Backend hardening: R26 CI (GitHub Actions, green) + migrate URL + preDeploy, R28 pool/timeouts/crash handlers, R29 redirect SSRF, R30 audit 0 (zod 4), R33 storage guard + multi-stage Dockerfile (node PID 1) + sslmode | **yes** |
| Backend state + retry: R27 atomic flip+enqueue + claim attempts cap, `POST /v1/worlds/{id}:retry` (R42), distinct 429 codes (`scan_quota_exceeded`, `credit_budget_exceeded`), budget default 2000 | **yes** |
| iOS robustness: R25 background uploads, R31 WebGL reload + Caches, R32 privacy manifest + fixture.spz out of Release, CaptureEngine split | on phone |
| UI redesign WP1-WP5 (172 iOS tests): Theme tokens, ToastCenter, typed APIError, WorldStore + AppRouter, Library/Detail, onboarding + versioned consent gate, scan flow, viewers, Settings | on phone |
| Docs: `docs/design/ui-spec.md`, `docs/research/live-mapping.md`, `docs/research/reconstruction-vs-generation.md` | - |
| Full-res splats made opt-in (Settings > 3D viewer > Maximum detail, off by default): full-res made movement choppy on the iPhone 17 Pro | on phone |

**Pending owner decisions:** (1) whether a draft `:retry` charges a scan (currently yes); (2) viewer walk-radius limit; (3) the ~550-credit multi-station experiment (live-mapping research, option A); (4) raw-frame retention: keep until delete (current, stated in the terms) vs purge after N days (spec §13 promised purge-after-stitch, never implemented); (5) review the draft terms text in `Features/Onboarding/TermsView.swift` (`TermsOfUseView`); "only you can see your spaces" becomes true only with R24.

**Orchestrator notes:** agents pick their own branch names; always read `git -C <worktree> branch --show-current` before merging. The owner's uncommitted Xcode 27 edits in `project.pbxproj`/`VirtSpace.xcscheme` must survive merges: copy them aside, `git stash push -m <tag> -- <files>`, fast-forward, `git stash apply <sha>`, drop by tag. Usage limits stop background agents mid-task; resume them with SendMessage after the reset. Known flaky test: `CaptureUploaderDepthTests.depthUploadsAlongsideFrames`.

## What landed 2026-11-04

| Item | What |
|---|---|
| Reviews | Three code reviews + two capture reviews → ledger rows **R20–R41** in `spec-doc.md` §10 |
| R15, R19 | `PendingSessionStore` actor (manifest I/O off the main actor); `CaptureView` 627 → 177 lines via `CaptureScreenModel`, `CaptureStartView`, DEBUG-only `CaptureDebugToolsView`. Merged 2026-11-05. |
| R20 | `frames:done` is a conditional flip in a transaction (only `uploading`/`failed_stitch` → `stitching`); replay returns the current world with `job_id: null`. Deployed. |
| R21 | Fastify `trustProxy` as a hop-count function (`TRUST_PROXY_HOPS`; **production api = 2**, measured — with 1 the logged client is a CDN77 edge IP). Spoofed `X-Forwarded-For` verified ignored. Deployed. |
| R22 | `failJob` returns the phase; a job going `dead` applies the failed world status. Deployed. |
| R23 | Root workspace + root lockfile deleted; `backend/package-lock.json` is the only app lockfile. Run commands inside `backend/`. |
| R26 (part) | `railway.json` (deprecated, cutoff 2026-12-01, never read) replaced by IaC `.railway/railway.ts`; see Deploy. |
| Capture v2 backend | Stitcher split into `geom/poses/warp/depth/fill/bench.py`; translation-aware reprojection about the camera centroid with a depth proxy (LiDAR when sent, else 2 m), gain compensation, GraphCut seams, banded multi-band blend, nadir body mask, width 4096. Depth API: `"depth": true` + `depth_frames` on create/`uploads:refresh`, response `depth_uploads`; worker stages `depth_<i>.png` best-effort. 09-17 benchmark: overlap error 11.43 → 9.06, edge-doubling 0.076 → 0.048, 4.8 s. Deployed. |
| Capture v2 iOS | AE/AWB lock before shot 0 (AF continuous), low-light card, centroid drift + `PivotIndicatorView` (15 cm soft gate after 3 s), column order 12/6/8, relocalization + restart after 10 s, iOS 26.0 shot-0 guard, per-frame LiDAR depth PNG uploaded best-effort. Merged 2026-11-05. |

**Verified test state (2026-11-04):** backend `tsc` clean, vitest **348 passed / 12 skipped** (skips = Postgres integration suites) with `STITCHER_TEST_PYTHON` set. iOS `feat/capture-v2`: **80/80** on a freshly erased iPhone 18 Pro simulator (iOS 27):
`xcodebuild test -project VirtSpace/VirtSpace.xcodeproj -scheme VirtSpace -destination 'platform=iOS Simulator,name=iPhone 18 Pro'`

## 2026-11-05: first capture-v2 device run (world `b936c74a`)

Upload worked: 28 frames + 28 LiDAR depth maps (~22 KB each) in R2, stitch v2 ran with real depth. Draft generation then failed with a World Labs **422: `display_name` max 64 chars** (ours was 90; the limit is new since 09-17, so every capture was failing). Fixed in `2cf8506` (`VirtSpace <jobId>`, 46 chars, plus a pre-flight length guard in `generateWorld`), worker deployed, and the owner-approved manual re-queue (guarded single transaction on the direct host: world `failed_generating_draft` → `generating_draft` + one `generate_draft` job) reached `draft_ready`. The dead job's 150-credit reservation still counts against that UTC day's budget. There is still no in-app retry for `failed_generating_draft`.

## Open items

- **Device walkthrough of the redesign** (see Owner's next steps); several WP acceptance items were unit-tested only (simulator tap automation is broken under Xcode 27): haptics, VoiceOver order, camera priming + Open Settings, Reduce Motion, replay onboarding from Settings, explorer WebGL kill/reload, Library pagination on device.
- **R24 real auth** (deferred by the owner until the main features work). Until then every install shares one library and the Account section is hidden under dev auth.
- **Quality:** walking away from the capture spot blurs lettering and distorts unseen areas (single-pano limit). Levers: full-res splats (done, opt-in via Settings "Maximum detail" since full-res made movement choppy on iPhone 17 Pro), viewer walk-radius limit (pending decision), multi-station capture (research option A, experiment pending), splat reconstruction (option C, L effort).
- **Stitcher residuals:** faint doubling on objects within about 0.5 m without LiDAR; a hard seam where content changed between shots.
- **Backend follow-ups:** structured logging (pino) for the worker; `statement_timeout` on the DB role (not via the pooler); R27 leftovers (finalize ignores `deleted_at`, `locked_by` missing from completion WHERE); raw-frame retention decision; Postgres integration suites need `TEST_DATABASE_URL` on a Neon branch (never prod).
- **R35 modernisation:** Spark 2.4 / three r187, `worker.ts` size, `PanoPreviewView` on SceneKit; `viewer.html` still has its own hidden "Couldn't render" text.
- **Older carry-overs:** mirrored pre-2026-09-18 worlds (regenerate = owner's call); R1 `findWorldByDisplayName` API shape unverified; R5 sim guard never seen firing; pano preview heading believed correct (`initialYaw = 0`), confirm on device.
- The owner's uncommitted Xcode 27 project-setting changes (`project.pbxproj`, `VirtSpace.xcscheme`) are deliberately left uncommitted.

## Deploy (Railway) — how it actually works

- Not GitHub-linked; pushing does not deploy. The repo **is** `railway link`ed to production. From the repo root: `railway up -p 1690518b-f063-41df-8839-19c0b00a33a1 -e production -s api --ci`, then `-s worker`. `railway up` ships the working tree, so deploy from a clean `main`.
- **Config is IaC:** `.railway/railway.ts` declares both services; **a resource omitted there is deleted on apply**. Change with `railway config plan` then `railway config apply`; the SDK lives in `.railway/` (`cd .railway && npm ci`). Variables are unmanaged (secrets never in the file). api has healthcheck `/healthz`.
- **Migrations run on every api deploy** (`preDeploy: node dist/migrate.js`, applied 2026-11-05) using `MIGRATE_DATABASE_URL` (direct, non-`-pooler` Neon host) set on api. A failed migration fails the deploy and the old one keeps running. Manual fallback: `cd backend && MIGRATE_DATABASE_URL=… AUTH_MODE=dev DEV_AUTH_TOKEN=x npx tsx src/migrate.ts`.
- `ALLOW_DEV_AUTH=1` on api + worker (production still runs dev auth). Worker: `PROVIDER_MODE=live`, `DAILY_CREDIT_BUDGET=2000`. Base image must stay `node:24-trixie-slim` (numpy needs Python ≥3.12).
- Post-deploy checks: api log `[migrate] up to date`, `/healthz`; worker log shows `started; kinds=stitch,generate_draft,generate_hq,purge` and no `claim error`. The pg `sslmode` warning is gone (R33 deployed).
- Optional env vars (all defaulted) are listed in `backend/.env.example`.

## Standing rules learned the hard way

- **Pooler incident (2026-09-17):** `DATABASE_URL` is Neon's pgbouncer pooler, shared by local `.env` and production. A session `SET default_transaction_read_only = on` stuck to the pooled backend and broke production writes. Never issue session-level `SET` through the pooler; use `BEGIN READ ONLY … ROLLBACK` or the direct host. `migrate.ts`'s advisory lock is only reliable over the direct host.
- Production is the owner's data. Read-only DB/R2 inspection only at the owner's request; agents never touch it, never launch the sim against prod, never call `worlds:generate`.
- The 09-17 benchmark capture (frames in the session scratchpad, outputs in `/private/tmp/claude-501/stitch-bench/`) is personal: never commit it or send it anywhere. Export script pattern: direct host + `BEGIN READ ONLY`.

## Knowledge graph (graphify)

`graphify-out/` (gitignored) is the project map; query it first. The post-commit/post-checkout hook rebuilds the code graph (per clone: `graphify hook install`). The hook ignores docs: run `/graphify . --update` at the end of any session that changed spec/handoff/README/`CLAUDE.md`. `.graphifyignore` keeps vendored three.js/Spark bundles, `video-example.mp4` and `virtspace-logs.txt` out.

## Environment

- macOS/Xcode 27, iPhone 17 Pro (iPhone18,1) on iOS 27.0.1. iOS 27.0 simulator runtime installed; use "iPhone 18 Pro" (no "iPhone 17" device in Xcode 27). Dead simulators were deleted 2026-11-04; disk is tight (~13 GB free), and low disk has purged runtimes before.
- Node deps live in `backend/node_modules`. Stitcher tests need a venv (`python3 -m venv … && pip install -r backend/stitcher/requirements.txt`) passed as `STITCHER_TEST_PYTHON`; last one was `/private/tmp/claude-501/stitch-venv`.
- iOS worktrees compile only after copying the gitignored `Secrets.swift` in; keep worktree copies on localhost (`apiBaseURL = "http://localhost:3000"`).
- MCP servers that failed to connect: `magic`, `MCP_DOCKER`, `plugin:github` (use the `gh` CLI).

## Working agreements (from CLAUDE.md)

Fable orchestrates, reviews, QAs, commits and deploys; all implementation goes to Opus subagents. The orchestrator re-runs tests before every commit and push. Deploys and destructive actions need the owner's explicit go-ahead.
