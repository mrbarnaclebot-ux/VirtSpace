# VirtSpace — Session Handoff (2026-11-05)

Read this first next session, then `CLAUDE.md` and `spec-doc.md` §10 (ledger **R1–R41** is the authoritative status) and §5.2 (capture v2 contract). Repo: `~/Developer/VirtSpace` (not iCloud). `AGENTS.md` is a generic template; where it disagrees, `CLAUDE.md` and `spec-doc.md` win.

## State in one paragraph

Everything is on `main` (`e8ec6bd`+) and the backend is **deployed** (api + worker, 2026-11-05): R20–R23, Railway IaC, capture v2 (stitcher v2, depth API, 4096 stitch), the World Labs `display_name` 64-char fix and **full-resolution splats** (worker stores `splat_full.spz`; iOS loads it on 8 GB+ iPhones, else 500k). iOS capture v2 and the R19/R15 refactor are merged (83/83 sim tests) and a Debug build of `main` with production Secrets is on the owner's iPhone 17 Pro. The owner's first capture-v2 world (`b936c74a`) ran end to end incl. **Enhance to HQ (R18 verified: complete, asset_version 2)**; its HQ full_res splat was backfilled by hand. Owner verdict: ghosting reduced, HQ sharper, but walking away from the capture spot blurs lettering and distorts unseen areas (single-pano limit; see the live-mapping research below).

## Landed 2026-11-05 (all on `main`; see the spec §10 "Status 2026-11-05" row for detail)

| Item | Deployed? |
|---|---|
| Capture v2 iOS + R19/R15 merged; display_name 422 fix; full-res splats (worker + iOS) | worker yes; iOS = Debug build on the owner's phone |
| Backend hardening (R26 CI + migrate URL, R28, R29, R30 zod 4, R33 Dockerfile/guards) | **no** |
| Backend state + retry (R27, `:retry` R42, distinct 429 codes, budget default 2000) | **no** |
| iOS robustness (R25 background uploads, R31 WebGL reload + Caches, R32 privacy, CaptureEngine split) | no (needs a device build) |
| `docs/design/ui-spec.md` (UI/UX audit + redesign, WP1-WP5); `docs/research/live-mapping.md` | docs |

**Pending owner decisions:** (1) deploy the backend (api first, then worker; new multi-stage image never built locally, Railway keeps the old deploy if the build fails); (2) set `MIGRATE_DATABASE_URL` (direct Neon host) on api, then `railway config plan` and `apply` to enable the api preDeploy migrate; (3) whether a draft `:retry` should charge a scan (currently yes); (4) viewer walk-radius limit; (5) the ~550-credit multi-station experiment from the live-mapping research.

**In flight:** WP1 UI foundation (`feat/ui-wp1-foundation`, agent worktree). Then WP2-WP5 in parallel per the design spec. Orchestrator lesson: agents pick their own branch names; always read `git -C <worktree> branch --show-current` before merging (a wrong-branch merge + `branch -D` happened once and was recovered from the SHA).

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

- R16 (no crash at last shot) and R17 (un-mirrored) passed implicitly on the 11-05 capture; R18 verified. In-app retry for failed generation is being built (`:retry`).
- Viewer walk-radius limit (keep users near the capture spot) was proposed, not yet approved by the owner.
- **Stitcher residuals:** faint doubling on objects ≲0.5 m without LiDAR (overlap-based depth estimate deferred); a hard seam where content changed between shots (e.g. a playing monitor).
- **Follow-ups:** split `CaptureEngine.swift` (620 lines: exposure/relocalization out); `MIGRATE_DATABASE_URL` on the direct Neon host, then `preDeploy: "node dist/migrate.js"` on api in `railway.ts`.
- **Backlog (not started):** R24 real auth before sharing the app (P1); R25 background uploads (P1); rest of R26 (CI, deploy from a clean commit); R27 status-flip + enqueue atomicity; R28 pg pool error/timeouts, structured logs; R29 redirect SSRF; R30 `npm audit` (zod high); rest of R31 (WebGL process termination, caches in Application Support); R32 terms + consent screen, `fixture.spz` in Release, privacy manifest; R33 `STORAGE_DRIVER` default, PID 1, image size, pg `sslmode` warning; R35 modernisation (Spark 2.4, three r187, `worker.ts` 1328 lines, …).
- **Older carry-overs:** R18 no retry after `failed_generating_hq` + raw status copy; mirrored pre-2026-09-18 worlds (regenerate = owner's call); R1 `findWorldByDisplayName` API shape unverified; Postgres integration suites need `TEST_DATABASE_URL` on a Neon branch; R5 sim guard never seen firing; `PanoPreviewView` opens facing lon ≈ 180°.
- The owner's uncommitted Xcode 27 project-setting changes (`project.pbxproj`, `VirtSpace.xcscheme`) are deliberately left uncommitted.

## Deploy (Railway) — how it actually works

- Not GitHub-linked; pushing does not deploy. The repo **is** `railway link`ed to production. From the repo root: `railway up -p 1690518b-f063-41df-8839-19c0b00a33a1 -e production -s api --ci`, then `-s worker`. `railway up` ships the working tree, so deploy from a clean `main`.
- **Config is IaC:** `.railway/railway.ts` declares both services; **a resource omitted there is deleted on apply**. Change with `railway config plan` then `railway config apply`; the SDK lives in `.railway/` (`cd .railway && npm ci`). Variables are unmanaged (secrets never in the file). api has healthcheck `/healthz`.
- **Migrations do not run on deploy yet** (the api `preDeploy` is in `railway.ts` but not applied; needs `MIGRATE_DATABASE_URL` first). Apply by hand *before* `railway up`, over the direct (non-`-pooler`) host: `cd backend && DATABASE_URL=… AUTH_MODE=dev DEV_AUTH_TOKEN=x npx tsx src/migrate.ts`.
- `ALLOW_DEV_AUTH=1` on api + worker (production still runs dev auth). Worker: `PROVIDER_MODE=live`, `DAILY_CREDIT_BUDGET=2000`. Base image must stay `node:24-trixie-slim` (numpy needs Python ≥3.12).
- Post-deploy checks: `/healthz`; worker log shows `started; kinds=stitch,generate_draft,generate_hq,purge` and no `claim error`. The pg `sslmode` warning disappears once the R33 fix is deployed.
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
