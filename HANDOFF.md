# VirtSpace — Session Handoff (2026-09-17)

Read this first next session, then `CLAUDE.md` and `spec-doc.md` §10 (hardening ledger R1–R15 is the authoritative status).

## What this session did

1. **Mapped the project with graphify** → `graphify-out/` (gitignored; regenerate with `/graphify`).
   - 1,384 nodes · 2,757 edges · 69 communities; vendored `three.js`/Spark bundles deliberately filtered out of the AST pass.
   - `faster-whisper` + `tree-sitter-sql` were injected into the pipx `graphifyy` venv. `video-example.mp4` has no narration (transcript is a Whisper hallucination) — left out of the graph.
   - Top god node: `CaptureEngine` (legit coordinator, was overloaded → split in R14).
2. **Full-project review** by two Opus reviewers (iOS, backend), orchestrator-verified. Findings recorded in `spec-doc.md` §10 as R1–R14; §14 credit-safety claim corrected.
3. **Fixed everything in the ledger** (~45 atomic commits, all on `origin/main`, tip at time of writing: see `git log`):

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
| R11 | jose 6, `node:24-slim`, fastify/drizzle-kit/pg/aws-sdk bumps, numpy 2.5.3 + opencv 4.14 (needed for cp313 wheels on the Node 24 image). `npm audit --omit=dev` = 0 |
| R12 | Ring haptics derived from `TargetLayout`; per-session upload claims + 10-min resource timeout; `URLSession` download tasks; SPZ mapped once; WKWebView navigation allowlist; resume errors no longer swallowed |
| R13 | `VirtSpaceTests` Swift Testing target + shared scheme |
| R14 | `CaptureEngine` split (`HUDPublishThrottle`, `ThermalGovernor`, `ShotPipeline`, `CaptureHUDState`; 704→479 lines); **Swift 6 language mode**, 0 warnings; deployment target unified at 26.0; fixed a racy `lazy var` background `URLSession` (real crash) |

**Last verified test state:** backend `tsc` clean, vitest **283 passed / 19 skipped** (+13 stitcher tests pass when `STITCHER_TEST_PYTHON` points at a venv with the pinned numpy/opencv); iOS **53/53**, 0 warnings (run before the simulator runtime vanished — see Environment).

## Addendum — 2026-09-17 late session (first iOS 27 / Xcode 27 device run)

- **R16 — crash at shot 28 on iOS 27, fixed** (`92fbdf4`, `7f9bb86`): `.finished` rebuilt the `ARSCNView` while the session was pausing; iOS 27 ARKit re-enters SwiftUI under `-[ARSession setViewLayer:]`'s unfair lock. Camera layer now has one identity across ready→finished and `CameraPreviewHost` attaches the session off the SwiftUI update pass. Device build clean (0 warnings). **Not yet re-run on device; unit tests not run (no simulator runtime installed after the Xcode 27 update).** Crash logs can be pulled with `xcrun devicectl device info files --domain-type systemCrashLogs` / `device copy from`.
- **The device capture itself worked end-to-end** (world `2e3d5479`, 28 frames, stitch + `generate_draft` first attempt, 150 credits): ring angles within ~2° of nominal, exposure locked on 27/28 (shot 0 unlocked — the flagged first-shot issue is real), up to 52 cm translation drift → parallax ghosting on near objects.
- **R17 — stitched panos were MIRRORED, fixed, not deployed** (`8ffa6b7`): ray-grid longitude sign. All previously generated worlds came from mirrored panos; regenerate any that matter after deploy (150 credits each — owner's call). Backend now: tsc clean, vitest **296 passed / 11 skipped** with `STITCHER_TEST_PYTHON` set (the 283/19 figure below was without the stitcher venv).
- Cosmetic, open: `PanoPreviewView` opens facing lon ≈ 180° (behind the capture's first shot).

## NOT deployed — deploy checklist (owner's go-ahead required)

Railway services are **not** GitHub-linked; pushing does not deploy. In order:
1. Set `ALLOW_DEV_AUTH=1` on **api and worker** (production still runs dev auth; without it both exit at boot).
2. **api service only:** Pre-deploy command = `node dist/migrate.js` (applies `0003` + `0004`). Leave the worker's empty.
3. Deploy (`railway up`); watch the image build — it has **never been built** (no Docker on the dev Mac).
4. Check `/healthz`, then `GET /v1/worlds` under the iOS 3 s poll (rate limit defaults: 300/min per user).

New optional env vars (all have defaults): `RATE_LIMIT_WINDOW_MS`, `RATE_LIMIT_MAX`, `RATE_LIMIT_IP_MAX`, `RATE_LIMIT_CREATE_MAX`, `AUTH_FAIL_MAX`, `SHUTDOWN_GRACE_MS`, `WORLDLABS_ASSET_MAX_BYTES`, `WORLDLABS_ASSET_HOSTS`. See `backend/.env.example`.

## Open items

- **Real-device 28-shot capture run** — the R14 refactor/Swift 6 migration cannot be exercised in the simulator. Watch first-shot exposure lock and ring-completion haptics (indices 11/19/25) — `ShotPipeline` is the least-certain spot.
- **R15 (new, unfixed):** upload flows inherit `@MainActor` from `UploadManager`, so `CaptureStore` manifest I/O during uploads is synchronous disk I/O on the main thread. Behaviour change → do with device testing.
- **R1 live verification:** `findWorldByDisplayName` (`GET /marble/v1/worlds?page_size=100`) is a best-guess API shape. Wrong guess ⇒ parked job, never a double bill. Verify once against the real API (costs nothing — it's a list call). Expect occasional parked jobs needing an operator look at the provider account.
- **Postgres integration suites are written but skipped** (need `TEST_DATABASE_URL`): 20-way concurrent quota race, `heartbeatJob` cases.
- **R5 simulator guard was never seen firing** (agents may not launch the app); proven only that the app launches under XCTest with it compiled in.
- opencv/numpy bump shifts stitched pixels slightly (max 6/255, 97.7 % within 1) — visually identical, unreviewed on a real pano.
- Deferred on purpose: vitest/zod/TypeScript majors (remaining audit findings are dev-only); `worlds.spz_full_url` dead column; root `package.json` engines `>=22` vs backend `>=24`; iOS frames are JPEG bytes under `.heic` keys (client contract — stitcher sniffs magic bytes).
- Still-open pre-existing spec §10 items (World Labs deletion API, training-data ToS, marble-1.1 latency, etc.) are unchanged.

## Environment problems found (important)

- **The repo lived in iCloud Drive** (`~/Documents` is a file-provider domain) on a ~90 %-full disk. Symptoms today: a source file read back as NUL bytes mid-build, flaky `git rebase`, git commands taking 30–670 s (GitHub Desktop "Command failed"), an agent's `node_modules` corrupted. **Fix (done 2026-09-17): the repo now lives at `~/Developer/VirtSpace`** — a fresh clone of `origin/main` (a plain `mv` was unsafe: 15,698 files in the old folder were evicted iCloud placeholders) plus the gitignored local files copied and byte-verified (`.env`, `Secrets.swift`, `.claude/settings.local.json`, Xcode `xcuserdata`, `tools/spike/state.json`, `tools/spike/world.spz`). Backend re-verified there (tsc clean, 283 passed). Not carried over: `node_modules`, `backend/dist`, `graphify-out/` (regenerate with `/graphify`). The old `~/Documents/Git Projects/VirtSpace` folder should be deleted once Xcode/VS Code/GitHub Desktop point at the new path; Claude Code memory was copied to the new project key.
- **The iOS simulator runtime disappeared** (0 disk images; "iOS 26.5 is not installed") — most likely macOS purging under disk pressure. Nothing builds or tests until it is reinstalled: Xcode → Settings → Components, or `xcodebuild -downloadPlatform iOS` (~8–10 GB). Then re-run:
  `xcodebuild test -project VirtSpace/VirtSpace.xcodeproj -scheme VirtSpace -destination 'platform=iOS Simulator,name=iPhone 17'`
- Free disk space before the next heavy session; low disk is the root of both problems.

## Working agreements (unchanged, from CLAUDE.md)

Fable orchestrates/reviews/QA/commits; all implementation goes to Opus subagents (worktree-isolated worked well — one stream per directory, atomic commits, orchestrator re-runs tests before fast-forwarding `main`). Agents never touch production, never launch the sim against prod, never call `worlds:generate`.
