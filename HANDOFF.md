# VirtSpace — Session Handoff (2026-11-05)

Read this first next session, then `CLAUDE.md` and `spec-doc.md` §10 (ledger **R1–R41** is the authoritative status) and §5.2 (capture v2 contract). Repo: `~/Developer/VirtSpace` (not iCloud). `AGENTS.md` is a generic template; where it disagrees, `CLAUDE.md` and `spec-doc.md` win.

## State in one paragraph

Backend is on `main` and **deployed** (2026-11-04): the R20–R23 P1 fixes, the Railway IaC migration (R26 part) and **capture v2 backend** (stitcher v2 = R36 ghosting fix, 4096-wide stitch = R40, depth upload API = §5.2). iOS capture v2 (R34, R37, R38, R39, R31 relocalization, LiDAR depth) lives on branch **`feat/capture-v2`**, stacked on **`refactor/r19-r15-capture-split`** (R19 + R15). Both are unmerged: 80/80 unit tests pass on the iOS 27 simulator and a Debug device build exists, but **no device capture has been done with it yet**. That capture is the gate for merging.

## Owner's next steps (device)

1. Unlock + plug in the iPhone 17 Pro, then install the prebuilt capture-v2 Debug build (production backend):
   `xcrun devicectl device install app --device 00008150-00060CD23E21401C /private/tmp/claude-501/dd-capture-v2-device/Build/Products/Debug-iphoneos/VirtSpace.app`
   (`/private/tmp` may be wiped; if so, rebuild from the `capture-v2` worktree after copying the main checkout's `Secrets.swift` in, then restore the worktree's localhost copy.)
2. One full capture in a lit room (one 150-credit draft). Check: AE/AWB locked before shot 0 (no brightness jumps), low-light card in a dark room, pivot indicator nudges past ~15 cm drift, column order (12 around, 6 up, 8 down), relocalization / "Restart scan" after an interruption, no crash at the last shot (R16), un-mirrored text (R17), no doubled objects in the pano.
3. Optionally tap **Enhance to HQ** on a `draft_ready` world (1500 credits, budget 2000/UTC day) to verify R18 end to end.
4. Crash logs: `xcrun devicectl device info files --device <udid> --domain-type systemCrashLogs`, then `device copy from … --source <name>.ips`.

After a clean capture: rebase `refactor/r19-r15-capture-split` then `feat/capture-v2` onto `main`, re-run the sim tests, fast-forward `main`, push, and remove both worktrees (`.claude/worktrees/r19-qa`, `.claude/worktrees/capture-v2`).

## What landed 2026-11-04

| Item | What |
|---|---|
| Reviews | Three code reviews + two capture reviews → ledger rows **R20–R41** in `spec-doc.md` §10 |
| R15, R19 | `PendingSessionStore` actor (manifest I/O off the main actor); `CaptureView` 627 → 177 lines via `CaptureScreenModel`, `CaptureStartView`, DEBUG-only `CaptureDebugToolsView`. Branch only. |
| R20 | `frames:done` is a conditional flip in a transaction (only `uploading`/`failed_stitch` → `stitching`); replay returns the current world with `job_id: null`. Deployed. |
| R21 | Fastify `trustProxy` as a hop-count function (`TRUST_PROXY_HOPS`; **production api = 2**, measured — with 1 the logged client is a CDN77 edge IP). Spoofed `X-Forwarded-For` verified ignored. Deployed. |
| R22 | `failJob` returns the phase; a job going `dead` applies the failed world status. Deployed. |
| R23 | Root workspace + root lockfile deleted; `backend/package-lock.json` is the only app lockfile. Run commands inside `backend/`. |
| R26 (part) | `railway.json` (deprecated, cutoff 2026-12-01, never read) replaced by IaC `.railway/railway.ts`; see Deploy. |
| Capture v2 backend | Stitcher split into `geom/poses/warp/depth/fill/bench.py`; translation-aware reprojection about the camera centroid with a depth proxy (LiDAR when sent, else 2 m), gain compensation, GraphCut seams, banded multi-band blend, nadir body mask, width 4096. Depth API: `"depth": true` + `depth_frames` on create/`uploads:refresh`, response `depth_uploads`; worker stages `depth_<i>.png` best-effort. 09-17 benchmark: overlap error 11.43 → 9.06, edge-doubling 0.076 → 0.048, 4.8 s. Deployed. |
| Capture v2 iOS | AE/AWB lock before shot 0 (AF continuous), low-light card, centroid drift + `PivotIndicatorView` (15 cm soft gate after 3 s), column order 12/6/8, relocalization + restart after 10 s, iOS 26.0 shot-0 guard, per-frame LiDAR depth PNG uploaded best-effort. Branch only. |

**Verified test state (2026-11-04):** backend `tsc` clean, vitest **348 passed / 12 skipped** (skips = Postgres integration suites) with `STITCHER_TEST_PYTHON` set. iOS `feat/capture-v2`: **80/80** on a freshly erased iPhone 18 Pro simulator (iOS 27):
`xcodebuild test -project VirtSpace/VirtSpace.xcodeproj -scheme VirtSpace -destination 'platform=iOS Simulator,name=iPhone 18 Pro'`

## Open items

- **Device capture with `feat/capture-v2`** (above), then merge both iOS branches. R16/R17/R18 also still unseen on the phone.
- **Stitcher residuals:** faint doubling on objects ≲0.5 m without LiDAR (overlap-based depth estimate deferred); a hard seam where content changed between shots (e.g. a playing monitor).
- **Follow-ups:** split `CaptureEngine.swift` (620 lines: exposure/relocalization out); `MIGRATE_DATABASE_URL` on the direct Neon host, then `preDeploy: "node dist/migrate.js"` on api in `railway.ts`.
- **Backlog (not started):** R24 real auth before sharing the app (P1); R25 background uploads (P1); rest of R26 (CI, deploy from a clean commit); R27 status-flip + enqueue atomicity; R28 pg pool error/timeouts, structured logs; R29 redirect SSRF; R30 `npm audit` (zod high); rest of R31 (WebGL process termination, caches in Application Support); R32 terms + consent screen, `fixture.spz` in Release, privacy manifest; R33 `STORAGE_DRIVER` default, PID 1, image size, pg `sslmode` warning; R35 modernisation (Spark 2.4, three r187, `worker.ts` 1328 lines, …).
- **Older carry-overs:** R18 no retry after `failed_generating_hq` + raw status copy; mirrored pre-2026-09-18 worlds (regenerate = owner's call); R1 `findWorldByDisplayName` API shape unverified; Postgres integration suites need `TEST_DATABASE_URL` on a Neon branch; R5 sim guard never seen firing; `PanoPreviewView` opens facing lon ≈ 180°.
- The owner's uncommitted Xcode 27 project-setting changes (`project.pbxproj`, `VirtSpace.xcscheme`) are deliberately left uncommitted.

## Deploy (Railway) — how it actually works

- Not GitHub-linked; pushing does not deploy. The repo **is** `railway link`ed to production. From the repo root: `railway up -p 1690518b-f063-41df-8839-19c0b00a33a1 -e production -s api --ci`, then `-s worker`. `railway up` ships the working tree, so deploy from a clean `main`.
- **Config is IaC:** `.railway/railway.ts` declares both services; **a resource omitted there is deleted on apply**. Change with `railway config plan` then `railway config apply`; the SDK lives in `.railway/` (`cd .railway && npm ci`). Variables are unmanaged (secrets never in the file). api has healthcheck `/healthz`.
- **Migrations do not run on deploy.** Apply by hand *before* `railway up`, over the direct (non-`-pooler`) host: `cd backend && DATABASE_URL=… AUTH_MODE=dev DEV_AUTH_TOKEN=x npx tsx src/migrate.ts`.
- `ALLOW_DEV_AUTH=1` on api + worker (production still runs dev auth). Worker: `PROVIDER_MODE=live`, `DAILY_CREDIT_BUDGET=2000`. Base image must stay `node:24-trixie-slim` (numpy needs Python ≥3.12).
- Post-deploy checks: `/healthz`; worker log shows `started; kinds=stitch,generate_draft,generate_hq,purge` and no `claim error`. The pg `sslmode` security warning in worker logs is known (R33).
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
