# VirtSpace — Product & Technical Spec

> Turn any space into a navigable digital clone in minutes. Capture a guided 360° panorama on iPhone → stitch to equirectangular → World Labs *Marble* reconstructs a walkable 3D world → explore, save, and share.

**Status:** v1.1 — reviewed & hardened (2026-07-12). Phase 0 spike **complete** (§2.1). Pre-implementation.
**Date:** 2026-07-12
**Owner:** Uzman Fassy
**Target:** Real product on TestFlight (multi-user, cloud gallery, sharing, push) — built to scale later.

### Locked decisions (from review)
1. **World Labs API key** — provided in `.env` as `worldlabs_api` (server-side only; `.env` is now gitignored — never commit it). In production the key lives in Railway env vars; local `.env` is dev-scripts only.
2. **v1 scope** — prove the core tech end-to-end + a **private per-user gallery of your scans** (tabs: **Capture · Library/Profile**). No public/social Explore feed in v1.
3. **Monetization** — none for now (no PRO+/paywall/credits). Data model leaves room to add it later. A basic **per-user daily scan quota exists from day one anyway** — every scan spends real credits, so cost control is not a monetization feature.
4. **Backend host** — **Railway** (API service + always-on polling worker).
5. **3D renderer** — **Spark in WKWebView** for MVP (native MetalSplatter deferred to a later phase). Spark + three.js are **bundled in the app** (pinned versions, no runtime CDN dependency); nav controls live *inside* the web page.
6. **Generation flow** — **draft-first**: every scan generates `marble-1.0-draft` (~16 s, ~$0.12) automatically; the user can then tap **Enhance** to run `marble-1.1` (~$1.20) on the same pano. One VirtSpace world can therefore reference **two provider worlds** (draft + HQ) — the data model reflects this.

---

## 1. What we're building (from the reference walkthrough)

The reference app (30s walkthrough, shot in Tokyo's Golden Gai) demonstrates this flow:

1. **Guided 360° capture** — Camera viewfinder with target dots arranged on a virtual sphere. Prompt: *"Point your device at the blue target."* User stands on one spot and rotates the phone to hit each dot; each hit turns a dot green. Counter runs **1 of 16 → 16 of 16** with a bottom progress bar. Guidance: *"Shoot all photos from the same spot as your initial photo to ensure an optimal result."*
2. **"Generating 3D World"** — Full-screen dark state, animated sphere, copy: *"This will take about 2 minutes — feel free to leave the app and come back."* Progress bar. (Async cloud job.)
3. **Result detail ("Golden Gai")** — Named space card: stitched 360° equirectangular thumbnail + mini-map pinned to Tokyo, status *"Complete · Two minutes ago."* Actions: a **3D World [PRO+]** card, **Preview** (view 360 pano), **Share** (create a link), **Advanced → Download** (save 360 to Photos).
4. **3D World viewer** — Fully navigable reconstruction: look up at the sky, pan, and move down the alley via a **joystick** (bottom-center); back button (top-left).
5. **Tab bar** — **Explore · Capture · Profile** (a full app with a gallery/feed, not a single demo screen).

**Our mandate:** replicate this end-to-end with materially better UI/UX.
**v1 scoping note:** the reference's **Explore** tab (public feed) is post-v1; v1 ships **Capture · Library/Profile** only (locked decision #2).

---

## 2. Feasibility verdict (research-backed)

| Question | Answer | Confidence |
|---|---|---|
| Is the World Labs 3D-gen API real & usable today? | **Yes — public GA "World API" (Marble), launched Jan 21 2026. Self-serve key, no waitlist.** | High — [docs](https://docs.worldlabs.ai/api), [announcement](https://www.worldlabs.ai/blog/announcing-the-world-api) |
| Does it accept a 360° equirectangular pano? | **Yes — native first-class input (`is_pano` param), and feeding an existing pano incurs no extra pano-gen charge.** | High |
| What does it return? | **Downloadable SPZ Gaussian splats (100k/500k/full), PLY & GLB via export, hosted viewer URL, pano/thumbnail/caption.** | High |
| Cost per world? | **~$1.20 (`marble-1.1`), ~$0.12 draft (`marble-1.0-draft`), up to ~$2.48 (`plus`). $1 = 1,250 credits, $5 min.** | High |
| Latency? | **Measured live: draft ~16 s (§2.1). Docs say ~5 min for full models — `marble-1.1` unmeasured; design UI for a variable async wait, never a hard-coded timer.** | High (draft measured) |
| Commercial rights? | **Paid/API accounts own outputs & may use commercially; free tier is personal-only. Attribution ("Generated using World Labs") on request.** | High — [ToS](https://www.worldlabs.ai/terms-of-service) |
| Can we render it natively/in-app? | **Yes. Two paths: WKWebView + Spark (World Labs' own MIT Three.js splat renderer, streams huge worlds) or native MetalSplatter (MIT).** | High |

**Bottom line: the whole pipeline is buildable today against real, documented, commercially-licensed APIs.** With the World Labs link now proven live (§2.1), **the top remaining technical risk has moved to our own stitching**: the spike used a tripod-perfect professional pano — nobody has yet shown that a handheld 16-shot stitch from our capture flow produces a pano Marble reconstructs well. That is the Phase 0.5 gate (§11).

### 2.1 Phase 0 spike — LIVE verification (2026-07-12) ✅

Ran the full World Labs pipeline against the real API with the provided key, using a CC0 8192×4096 equirectangular test pano (Kloofendal, Poly Haven). **The pipeline works end-to-end.**

| Step | Result |
|---|---|
| Auth (`WLT-Api-Key`) | ✅ Valid, paid account (world generated & billed) |
| `prepare_upload` → `PUT` 10 MB pano | ✅ 200; GCS signed URL, required header `x-goog-content-length-range` |
| `worlds:generate` (`marble-1.0-draft`, `is_pano:true`) | ✅ 200; 150 credits spent |
| Generation latency | ⚡ **~16 seconds for draft** (docs say ~5 min — draft is dramatically faster; `marble-1.1` full expected slower — measure before hard-coding UI) |
| Poll `operations/{id}` | ✅ `done:true` at 16s |
| Output assets | ✅ SPZ (100k/500k/full_res), GLB collider mesh, WebP thumbnail, rich AI `caption` |
| SPZ size (500k tier) | ✅ **6.1 MB** — very mobile-friendly |
| Reconstructed world quality | ✅ Thumbnail shows correct, navigable 3D geometry (true parallax from a single pano) |
| Spark WebView render | ⏳ Deferred — the automation browser is network-isolated from the local test server; will verify in the on-device iOS WKWebView (no sandbox there). Low risk (Spark is World Labs' own SPZ renderer). |

**Corrections/facts folded back into the contract:**
- Upload id field is `media_asset.media_asset_id` (not `.id`).
- Worlds are **private by default** (`permission.public:false`) — matches our v1 private-gallery model; sharing = explicit permission change later.
- When you supply your own pano, `assets.imagery.pano_url` is `null` (they don't re-store your input) — **we keep our own pano in R2** for the 2D Preview screen.
- `semantics_metadata` (metric scale / ground plane) was `null` on draft — check whether `marble-1.1` populates it (useful for grounding the walk camera).

**Implication:** offering a fast **draft preview** (~16s, $0.12) then an optional **HQ upgrade** (`marble-1.1`, ~$1.20) is not just a cost lever — it's a genuinely better UX (near-instant first result). Strongly recommend building the draft-first flow into v1's pipeline even though monetization is deferred.

---

## 3. Recommended tech stack

### 3.1 iOS client
| Concern | Choice | Why |
|---|---|---|
| UI | **SwiftUI** (iOS 17+), MVVM, `@Observable` | Modern, fast to build the redesigned UX; matches a greenfield project. |
| Guided capture attitude | **ARKit `ARWorldTrackingConfiguration`** (camera transform / VIO) primary; **CoreMotion** (`CMMotionManager`, magnetometer-corrected reference frame) fallback | ARKit's visual-inertial tracking keeps world-anchored dots stable across a full rotation; raw gyro drifts in yaw. Fallback for low-light/low-texture. |
| Photo capture | **ARKit-native stills**: `ARSession.captureHighResolutionFrame()` for 12 MP+ captures mid-session, `configurableCaptureDeviceForPrimaryCamera` to **lock AE/AF/AWB** on ARKit's own capture device after the first shot | Locking exposure/focus/white-balance is the single biggest lever against stitch seams. *(Corrected 2026-07-12: a parallel `AVCaptureSession` cannot run — ARKit owns the camera exclusively; these iOS 16+ APIs exist precisely for this.)* |
| 360 pano viewer (2D preview) | **CTPanoramaView** (MIT) or SceneKit inverted-normal sphere | Turnkey gyro + touch look-around for the "Preview" screen. |
| 3D world renderer | **WKWebView + Spark 2.0** (World Labs' MIT renderer) for MVP; **MetalSplatter** (MIT) native path later | Spark streams 100M+ splat worlds with LoD/virtual-memory — MetalSplatter has no streaming and OOMs on large worlds. **Implementation notes:** bundle pinned Spark+three.js in the app (no runtime CDN dependency); serve the page + cached `.spz` via **`WKURLSchemeHandler`** (`fetch()` on `file://` is blocked); joystick/look controls live **inside the web page** (a native→JS bridge at 60 fps is too laggy); default to the **500k SPZ tier** on phones (WKWebView has a hard memory ceiling — full_res is for export/desktop share pages). |
| Networking | `URLSession` + `Codable`; background download tasks for splats | No official Swift SDK; REST is simple. Resumable background downloads for 50–500 MB assets. |
| Auth | **Sign in with Apple** | App Store expectation; low friction. |

### 3.2 Backend

> **Locked at Phase 1 kickoff (2026-07-12):** TypeScript (Node 24) for both API and worker — one ecosystem shared with the future web share-viewer (Spark is JS). **Fastify + zod** (API), **Drizzle ORM** (Neon Postgres, migrations via drizzle-kit). Storage behind an **S3-compatible driver**: Cloudflare R2 in production, local-disk driver for dev.

| Concern | Choice | Why |
|---|---|---|
| API + workers | **Railway** — API service + always-on worker service in one project | First-class long-running background workers (no request timeout on the multi-minute poll loop), simple secret management, great DX. |
| Database | **Neon Postgres** (already provisioned) | Users, worlds, job state, gallery/social graph. Scale-to-zero. |
| Job queue / orchestration | **Postgres-backed queue** in Neon (`FOR UPDATE SKIP LOCKED` on the `jobs` table) for v1; SQS/Trigger.dev is the documented swap point at scale | Jobs are low-volume and the table already exists — one less external service. Retries via `attempts` + backoff columns; permanent failures — non-retryable or retries exhausted — park the job `dead` and the world `failed_*` (DLQ-equivalent). *(Locked 2026-07-12 at Phase 1 kickoff.)* |
| Object storage + CDN | **Cloudflare R2 (zero egress)** for splats/panos; signed URLs | Egress is the silent cost killer — a viral 300 MB world downloaded repeatedly is real money on S3/CloudFront. R2 has no egress fees. |
| Push | **APNs** (optionally via SNS) | "Your world is ready" when the async job completes. |
| Panorama stitching | **Server-side worker** (OpenCV/Hugin `nona`+`enblend`), with an optional on-device low-res preview | See §5. Server-side = best quality, iterate without app updates, no phone heat/battery. |
| 3D-gen provider | **World Labs World API — draft-first** (`marble-1.0-draft` auto, `marble-1.1` on Enhance), behind a **swappable provider interface** | Draft = ~16 s/$0.12 (proven live) → near-instant first result; HQ on demand. Provider interface keeps Blockade Labs / Luma swappable without touching the app. |

---

## 4. System architecture

```
┌─────────────── iOS app (SwiftUI) ───────────────┐
│  Capture | Library/Profile   (Explore: post-v1)  │
│  ARKit + AVFoundation guided capture (16 shots)  │
│  Spark-in-WKWebView 3D explorer + joystick       │
│  CTPanoramaView 2D pano preview                   │
└───────┬───────────────────────────────▲──────────┘
        │ upload 16 frames + poses       │ APNs "world ready"
        ▼ (signed R2 URL)                │ + signed asset URLs
┌─────────────── Backend API (stateless) ──────────┐
│  Sign in with Apple · REST · gallery queries      │
│      │                    ▲                        │
│      ▼ enqueue            │ update status          │
│  ┌── Durable job queue (retries + DLQ) ──┐         │
│  │  Worker (each step persisted to jobs   │         │
│  │  row → idempotent resume, no re-bill): │         │
│  │   1. stitch 16 frames → equirect pano  │         │
│  │   2. World Labs: prepare_upload → PUT  │         │
│  │   3. worlds:generate (is_pano:true)    │         │
│  │      — operation_id saved atomically   │         │
│  │   4. poll operation until done         │         │
│  │   5. copy SPZ/GLB/thumb → R2 at once   │         │
│  │      (provider CDN longevity unknown)  │         │
│  │   6. write world row, fire APNs        │         │
│  └────────────────────────────────────────┘        │
│  Neon Postgres (users, worlds, jobs, social)       │
│  Cloudflare R2 + CDN (panos, splats, thumbnails)   │
└────────────────────────────────────────────────────┘
                    │ REST (WLT-Api-Key)
                    ▼
         World Labs World API (Marble)
```

### World Labs job contract (confirmed from docs)
- Auth header: `WLT-Api-Key: <key>` (server-side only — **never ship the key in the app**).
- `POST /marble/v1/media-assets:prepare_upload` → `PUT` pano JPEG to signed URL.
- `POST /marble/v1/worlds:generate` with `is_pano: true`, model `marble-1.1` → returns `operation_id`.
- `GET /marble/v1/operations/{id}` → poll until `done: true`.
- `GET /marble/v1/worlds/{world_id}` → `assets.splats.spz_urls` (100k/500k/full), `assets.imagery.pano_url`, `assets.thumbnail_url`, `assets.caption`, `world_marble_url`.
- Optional `POST .../worlds/{id}:export` for PLY/GLB.

---

## 5. The stitching decision (compute placement)

You asked me to recommend. **Recommendation: capture on-device, stitch on the backend.**

- **Capture on-device** (ARKit guidance + AVFoundation stills, AE/AF/AWB locked). Non-negotiable — it's where the camera and motion sensors are.
- **Stitch on the backend.** Reasoning for a *real product*:
  - **Quality & control** — a server toolchain (Hugin `nona` + `enblend` multiband blend, or OpenCV with explicit bundle adjustment) beats one-call on-device `cv::Stitcher`, which OOMs and is unstable on full-sphere inputs on iOS.
  - **Iterate without shipping app updates** — tune stitching/pole-handling server-side.
  - **Battery/thermal** — no heavy CV on the phone.
  - **We already know per-shot pose** (from ARKit) → the worker can do *pose-assisted* reprojection, skipping fragile feature-matching.
- **Trade-off:** uploading ~16 frames instead of one image. Acceptable on Wi-Fi/LTE; mitigate with a **fast on-device low-res preview stitch** shown immediately so the user sees their pano while the HQ job runs.
- **Alternative considered:** stitch fully on-device and upload one pano (saves bandwidth, works offline). Rejected as the *default* for a product because quality/consistency and iterability matter more here — but keep the on-device path as a future offline mode.

> Note: World Labs can *auto-generate* panos from multi-image/video too, but that path costs extra credits and gives us less control over quality. We stitch ourselves and send a finished pano (`is_pano: true`, no surcharge).

### 5.1 De-risk fallback: skip stitching entirely (multi-image input)

Marble also accepts **`multi-image` prompts** (e.g. 4 views at azimuth 0°/90°/180°/270°) and generates the panorama itself for **+100 credits (~$0.08)**. The iPhone ultra-wide (~106° HFOV) covers 360° in 4 shots with overlap — meaning **v1 could ship with zero stitching infrastructure**: capture 4 guided ultra-wide shots, upload 4 images, done.

- **Why it's not the default:** their pano step is *generative* — it can invent detail between views, which cuts against "faithful digital clone of *your* space." We also lose the user-facing 360° pano (Preview screen / save-to-Photos) unless we display their generated one.
- **When to take it:** if the Phase 0.5 stitch spike shows our handheld stitch quality is poor or the stitch worker drags the schedule, ship v1 on multi-image and move our own stitcher to v1.5.
- **Target pano spec (own-stitch path):** ~8192×4096 equirect JPEG (proven Marble input size from the spike), stitched server-side from 16 pose-tagged frames.

---

### 5.2 Capture v2 contract (2026-11-04, ledger R36–R41)

Target devices are **Pro iPhones** (LiDAR). Depth is optional on the wire so non-LiDAR devices and older clients keep working, but the quality bar is set with depth. Baseline evidence: the 2026-09-17 capture (28 frames) drifted 52 cm from shot 0 but only 21 cm median / 37 cm max from the centroid of shot positions, over a 43 cm height range, with cameras biased outward-facing (orbit signature): most "drift" is the phone swinging on the arm, not walking. 97 s capture.

1. **`FramePose` (frames:done `poses[]`, stored verbatim in `captures.poses_json`)** — existing fields unchanged (`index`, `timestamp`, `transform` column-major camera-to-world, `intrinsics` column-major for the uploaded JPEG pixels, `exposureLocked`). New optional camelCase fields: `iso` (Float), `exposureDuration` (Double, seconds), `featureDepthMedian` (Float, metres, median depth of ARKit `rawFeaturePoints` in view — non-LiDAR fallback), `depth` (`{ "width": Int, "height": Int }`, present iff a depth file was uploaded for this frame). The backend keeps `.passthrough()` for unknown fields but validates these (`iso` 0–100000, `exposureDuration` 0–60 s, `featureDepthMedian` 0–1000 m, `depth` Ints 1–4096): a wrong type or JSON `null` 400s the whole frames:done, so clients omit absent fields.
2. **Depth file per frame:** R2 key `<capture prefix>/depth_<i>.png`, `image/png`, **16-bit grayscale PNG, millimetres, 0 = invalid** (the device zeroes `ARConfidenceLevel.low`). Same orientation and field of view as that frame's uploaded JPEG; its intrinsics are the frame intrinsics scaled by `depth.width / jpegWidth` (x) and `depth.height / jpegHeight` (y). Hard cap 1 MB.
3. **API:** `POST /v1/worlds` and `POST /v1/worlds/{id}/uploads:refresh` accept optional `"depth": true`; plus optional `"depth_frames": [{index, bytes}]` (signed content-length, ≤ 1 MiB); the response then adds `depth_uploads` with exactly the shape of `uploads` (keys `depth_<i>.png`). Absent → byte-identical response to today. An idempotent replay returns `depth_uploads` only if the retried request also sends `depth: true` (the opt-in is not persisted), so clients resend the identical body.
4. **Worker:** for each pose with `depth`, read `depth_<i>.png` (≤ 1 MB; missing or invalid → stitch that frame without depth and log, never fail the job), stage it beside the frames, pass `--depth-dir` to the stitcher. Purge removes depth keys with the frames. Stitch width default **4096** (R40).
5. **Stitcher (`reproject.py`):** optional `--depth-dir`; reads the new pose fields. Pipeline: per-frame `INTER_AREA` prefilter → translation-aware reprojection about the centroid camera position (per-pixel depth from the depth map when present; else `featureDepthMedian`; else a fixed proxy distance) → exposure/gain compensation (from `iso`·`exposureDuration` when present, refined over overlaps) → graph-cut seam selection → multi-band blend → nadir mask (user's body) and inpaint. R17 orientation tests must keep passing.

## 6. UI/UX redesign — where we beat the reference

The reference UX is functional but generic. Our differentiation:

### 6.1 Capture (the make-or-break screen)
- **Spatial, world-locked targets** rendered in a true 3D sphere (ARKit-anchored), not flat dots — dots sit in space and stay put as you turn, with a subtle horizon ring and depth cues.
- **Live "steadiness + alignment" feedback** — a reticle that snaps and a soft haptic + sound on each successful capture; auto-fire only when aligned *and* still (uses `rotationRate`), so shots are sharp.
- **Parallax coaching** — use ARKit's *translation* estimate to gently warn when the user is walking/orbiting instead of pivoting ("Stay on your spot"). This directly attacks the #1 stitching failure.
- **Progress as an filling sphere**, not just "1 of 16" — the sphere visibly completes, giving a sense of "capturing the space."
- **Smart dot layout from measured camera FOV** with ≥30% overlap, plus explicit **zenith/nadir** prompts for true full-sphere coverage (16 is marginal for a full sphere — we design the pattern deliberately).
- Graceful **low-light handling** — longer locked exposure + steadiness gate, fallback to CoreMotion attitude when ARKit confidence drops.
- **Preflight checks** before the first shot — warn on low light and low disk space; capture never starts in a state that will fail 16 shots later.
- **Crash-proof capture** — every frame + pose is written to disk the moment it's taken; a killed app resumes the upload on next launch (nobody loses a 16-shot walk-around).

### 6.2 Generating state
- **Honest, calm waiting UX** — real progress tied to job phases (Uploading → Stitching → Reconstructing → Finalizing), not a fake 2-min timer. "Leave and we'll notify you" with a real APNs push.
- Delightful ambient animation (the space "materializing") instead of a static grey sphere.

### 6.3 Library (v1) / Explore (post-v1)
- **v1 Library** — the user's own scans: thumbnail cards with status (draft ready / enhancing / complete / failed-with-retry), place name, time; pull-to-refresh + poll while a job is live.
- **Named, geolocated spaces** with auto-captions (World Labs returns a `caption`) + reverse-geocoded place names (location optional — scans work without it).
- **Post-v1 Explore** — public feed: living splat thumbnails / short auto-orbits, map-clustered, searchable.

### 6.4 3D explorer
- **Best-in-class navigation** — dual controls: left thumbstick to move, drag to look; momentum + gentle collision so you can't fly through walls (SuperSplat-style walk controls or a custom Spark cam). Optional gyro "magic window" mode.
- **Onboarding coach marks** the first time.
- Photo-mode / share-a-viewpoint.

### 6.5 Design system
- One cohesive visual language (typography, color, motion) — dark, immersive, content-forward. Apply the design skills (`impeccable`, `polish`, `animate`) during implementation.

---

## 7. Data model (Neon Postgres)

- `users` — id, apple_sub, display_name, created_at; **quota fields** (daily_scan_count, quota_reset_at) — cost control from day one, independent of monetization.
- `worlds` — id, owner_id, title, caption, lat/lng (nullable — location is optional), place_name, is_public (default false), created_at, deleted_at (soft delete → async purge).
  - **Status state machine:** `capturing → uploading → stitching → generating_draft → draft_ready → (enhance) generating_hq → complete`, with `failed_<phase>` variants that are retryable.
  - **Asset columns** (all pointing at **our R2**, never provider CDN): pano_url, thumbnail_url, spz_100k_url, spz_500k_url, spz_full_url, collider_glb_url, asset_version.
  - **Provider columns** (draft-first means *two* provider worlds per VirtSpace world): provider, draft_world_id, hq_world_id, draft_model, hq_model, credits_spent.
- `captures` — id, world_id, frame_count, poses_json (per-frame ARKit attitude), r2_frames_prefix; **purgeable after successful stitch** (frames are the biggest at-rest cost).
- `jobs` — id, world_id, kind (`stitch|generate_draft|generate_hq|purge`), phase, attempts, last_error, **provider_operation_id (persisted atomically around `worlds:generate` — a worker retry must never blind-resubmit a credit-spending call)**, timestamps.
- `devices` — user_id, apns_token, updated_at (push targets).
- `share_slugs` (Phase 3) — world_id, slug (cryptographically unguessable), created_at, revoked_at.
- `social` (post-v1) — likes, follows.

### 7.1 Client ↔ backend API surface (v1)

```
POST   /v1/auth/apple              SIWA identity token → session JWT
POST   /v1/worlds                  create world shell → presigned R2 URLs for N frames
POST   /v1/worlds/{id}/frames:done all frames uploaded → enqueue stitch + draft-gen job (idempotent: only flips from uploading/failed_stitch; a replay returns 200, job_id null)
GET    /v1/worlds/{id}             status/phase + signed asset URLs (client polls ~3s while foregrounded; APNs covers background)
GET    /v1/worlds                  my library (paginated)
POST   /v1/worlds/{id}:enhance     trigger marble-1.1 HQ generation
POST   /v1/worlds/{id}:retry       re-run a failed phase (see below)
DELETE /v1/worlds/{id}             delete world → cascade R2 assets (+ provider-side deletion, see §13)
POST   /v1/devices                 register APNs token
DELETE /v1/account                 full account deletion (App Store requirement — see §13)
```
**`:retry`** (owner-only, not deleted; own rate-limit key, create-sized bucket). One conditional transaction flips and enqueues:
`failed_stitch → stitching` + `stitch`; `failed_generating_draft → generating_draft` + `generate_draft` (needs a pano; charges one scan against `DAILY_SCAN_QUOTA`, like the create that paid for the first draft); `failed_generating_hq → generating_hq` + `generate_hq` (needs a finished draft, as enhance needs `draft_ready`). Responses: `200 {world, job_id}`; `200 {world, job_id: null}` when the world is already in a status a retry produces (double tap / lost-response replay) or a concurrent retry won the flip; `409 {error:"not_retryable", status}` for any other status or a missing precondition; `404 world_not_found`; `429` on the scan quota (draft only). **Credit safety:** a generation retry is a new job, hence a new `display_name`, and never reconciles against the failed job's operation. The failed job may or may not have been billed (a generate call that failed after submission is non-retryable, §10 R1), so a retry can pay for the phase twice; it is an explicit user action bounded by the scan quota (draft), the rate limit, and the worker's `DAILY_CREDIT_BUDGET` reservation, which applies exactly as for the original job.

**Error codes** (JSON body `{error, ...}`; clients branch on `error`, never on the status alone):

| Status | `error` | When | Extra fields |
|---|---|---|---|
| 429 | `scan_quota_exceeded` | per-user `DAILY_SCAN_QUOTA` refused (`POST /v1/worlds`, draft `:retry`) | `message`, `retry_at` (the user's rolling window reset) |
| 429 | `credit_budget_exceeded` | one more generation would not fit the deployment-wide `DAILY_CREDIT_BUDGET` (`:enhance`, generation `:retry`; advisory up-front check, the worker reservation stays authoritative) | `message`, `retry_at` (next UTC midnight) |
| 429 | `rate_limited` | per-route / per-user rate limit | `retry_after` |
| 409 | `not_enhanceable` / `not_retryable` | wrong status for `:enhance` / `:retry` | `status` |
| 404 | `world_not_found` | missing, someone else's, or deleted world | |

`scan_quota_exceeded` was `daily_scan_quota_exceeded` before 2026-11-05 (the shipped iOS app maps every 429 to one generic message and reads no code, so the rename breaks nothing).

Uploads go **directly to R2 via presigned URLs** (frames never proxy through the API); per-frame retry; background `URLSession` so an app suspension doesn't kill the batch.

---

## 8. Scalability & cost

**Two cost levers dominate:**
1. **World-gen credits (~$1.20/world)** — offer a cheap **draft mode** (`marble-1.0-draft`, ~$0.12) for previews; per-user quotas; monetize the **PRO+** tier (seen in the reference) so each paid generation covers its API cost.
2. **Asset egress** — 50–500 MB splats re-downloaded. Solve with **R2 zero-egress + aggressive on-device caching (keyed by world-id+version) + compressed SPZ + LoD tiers** so less data ships.

Everything else scales cheaply: Neon scale-to-zero, serverless workers (jobs are I/O-bound polling), CDN with signed URLs.

> ⚠️ **Current credit balance: ~7,000 credits ≈ $5.60 — that's only ~4 HQ worlds (or ~46 drafts).** Development and internal testing must default to draft mode; **top up before TestFlight** with real users. The worker enforces a **daily credit budget cap** (env var) and alerts as balance runs low, so a bug can never silently drain the account (see §14).

**Upload size reality check:** 16 frames × ~3–5 MB HEIC ≈ 50–80 MB per scan. Mitigations: capture at the resolution the stitcher actually needs (final pano is ~8K — per-frame 12 MP is plenty, no 48 MP), HEIC not JPEG on the wire, presigned direct-to-R2 uploads with per-frame retry, and warn (don't block) on cellular.

---

## 9. Pitfalls & mitigations

| Pitfall | Mitigation |
|---|---|
| **Parallax** (rotating off the lens's no-parallax point) — #1 stitch killer | Instruct pivot-in-place; ARKit translation warning; discrete fast auto-shots; prefer scenes without very close foreground. |
| **Exposure/WB seams** | Lock AE/AF/AWB across all 16 shots. |
| **Yaw drift** over a full rotation | ARKit VIO (primary) / magnetometer-corrected CoreMotion (fallback). |
| **Moving subjects → ghosts** | Fast discrete captures; multiband/seam blending; shoot when static. |
| **16 shots marginal for full sphere** | FOV-driven dot pattern with ≥30% overlap + explicit zenith/nadir shots. |
| **Latency ≠ "2 minutes"** (docs say ~5) | Phase-based progress + APNs; never hard-code a timer. |
| **Large splats OOM/thermal on iPhone** | Spark streaming/LoD; serve compressed SPZ; cap resident splats; native MetalSplatter only on pre-optimized scenes. |
| **API key exposure** | World Labs key lives server-side only; app never sees it. |
| **World Labs rate limits unknown** | Queue + backoff + DLQ; measure during Phase 1 load testing. |
| **Commercial licensing** | Use a **paid API account** (personal free tier is non-commercial); bake in attribution string. |
| **Double-billing on worker retry** — crash between `worlds:generate` and DB write → retry re-spends credits | Persist job state + `provider_operation_id` atomically around the call; a resumed worker checks for an in-flight operation before ever re-submitting. |
| **Runaway credit drain** (bug in a loop = drained account) | Daily credit budget cap enforced in the worker + low-balance alert. Balance today is only ~$5.60 (§8). |
| **Our handheld stitch ≠ Poly Haven quality** — spike used a tripod-perfect pro pano | Phase 0.5 stitch spike with *real handheld frames* is a hard gate before building the full capture UX (§11); multi-image fallback ready (§5.1). |
| **Spark/three.js CDN dependency** — app breaks if their release URL changes | Bundle pinned Spark + three.js in the app; serve via `WKURLSchemeHandler`. |
| **WKWebView local-asset gotcha** — `fetch()` on `file://` is blocked | Custom `WKURLSchemeHandler` serves the viewer page + cached `.spz`. |
| **WKWebView memory ceiling** kills the tab on huge splats | Default 500k SPZ tier on phones; full_res only for export/desktop share page. |
| **Provider CDN URL expiry unverified** (`cdn.marble.worldlabs.ai`) | Worker copies SPZ/GLB/thumbnail into R2 immediately on job completion; app only ever sees our URLs. |
| **Joystick latency through native→JS bridge** | Controls (joystick + look) implemented inside the web page; native SwiftUI provides only the chrome around the WebView. |
| **Lost scans** — app killed mid-capture/upload | Frames + poses persisted to disk at capture time; resumable background `URLSession` uploads; upload queue survives relaunch. |

---

## 10. Open items ledger

**Answered by the live Phase 0 spike (2026-07-12):**
- ✅ Key is a **paid, working account** — world generated & billed.
- ✅ Draft latency ~16 s; SPZ 500k tier = 6.1 MB; worlds private by default; assets include GLB collider + thumbnail + caption.

**Still open — each is assigned to a phase:**
| Item | Where it gets answered |
|---|---|
| **Handheld stitch quality → Marble output quality** (top remaining risk) | **Phase 0.5 gate** — decides own-stitch vs multi-image fallback (§5.1) |
| `marble-1.1` real latency & output sizes on our panos | Phase 0.5 (one HQ run on the winning pano) |
| Spark render verified on a real device (incl. splat orientation/axis convention) | Phase 0.5 — the on-device WKWebView check the sandbox blocked |
| Rate limits / concurrency (unpublished) | Phase 1 — worker backoff tuning |
| Does `marble-1.1` populate `semantics_metadata` (metric scale, ground plane)? Useful for grounding the walk camera | Phase 0.5 HQ run |
| Does World Labs expose **world deletion**? (needed for account-deletion cascade, §13) | Phase 1 — check docs/support; if not, document retention honestly |
| Marble CDN URL longevity | Mitigated by design (copy to R2 immediately); no longer blocking |
| Does World Labs use API inputs for training? (privacy disclosure wording) | Phase 1 — ToS/DPA read before TestFlight |

**Hardening ledger — full-project review 2026-09-17** (graphify map + iOS/backend audits; tick when the fix lands on `main`):

| # | Finding | Fix |
|---|---|---|
| R1 | `worlds:generate` can bill twice: provider timeout is retryable, and a kill between the generate call and persisting `provider_operation_id` re-generates (§14 claim was false) | Persist a `pending:<jobId>` intent marker *before* the call; on resume reconcile against the provider by a unique `display_name` embedding the job id; a failed generate call is non-retryable |
| R2 | `AUTH_MODE` defaults to `dev`; a dropped env var silently serves dev auth in production | Refuse to boot with `AUTH_MODE=dev` under `NODE_ENV=production` unless `ALLOW_DEV_AUTH=1`; constant-time token compare |
| R3 | `users.deleted_at` is written but never read — deleted accounts keep working; `captures.poses_json` never purged (§13) | Reject/ignore deleted users at auth; null `poses_json` in purge |
| R4 | iOS retries a complete-but-failing session forever, minting a fresh billable world per attempt; `POST /v1/worlds` has no idempotency key | Attempt counter + backoff + park after 5 with a user prompt; `Idempotency-Key: <session UUID>` header honoured by the backend (same world returned, quota charged once) |
| R5 | Debug/sim builds default to the production backend (`Secrets.swift.example` ships the prod URL) | Example defaults to localhost; DEBUG builds hard-fail on a production base URL unless `VIRTSPACE_ALLOW_PROD=1` |
| R6 | Job lease (600 s) < generate timeout (900 s) and no job heartbeat — a second worker can re-claim a live job | `heartbeatJob` refreshing `locked_at` from the poll tick + stitch progress; idempotent finalize |
| R7 | Presigned frame uploads have no enforced size cap on R2 | Sign `ContentLength` (or presigned POST policy) |
| R8 | 8192-wide stitch peaks >1.5 GB RSS; OOM/undecodable-frame exits retried 5× | Band-chunk the reprojection; cap width; classify exit 137 / decode failure as non-retryable |
| R9 | Quota check is read-then-write (race at the limit) | Single conditional `UPDATE … RETURNING` |
| R10 | Migrations manual and not in the image; no graceful shutdown, error handler, or rate limit; asset download sends the API key to any provider-returned host, unbounded | Release-phase migrate; SIGTERM → `app.close()`; `setErrorHandler`; `@fastify/rate-limit`; host allowlist + byte cap |
| R11 | Stale pins: `jose` 5 (EOL), Docker `node:22` vs engines `>=24`, opencv/numpy, fastify/drizzle-kit patches | Upgrade |
| R12 | iOS: ring haptics use the dead 16-target indices; one stuck background upload wedges all flows; byte-at-a-time asset downloads; SPZ re-read per range request; no WKWebView navigation policy; swallowed resume errors | Fix each (derive ring boundaries from `TargetLayout`; resource timeout + per-session chain; download tasks; cached mapped data; scheme allowlist) |
| R13 | No iOS test target | Swift Testing target; move `CaptureEngine.debugValidation` into it; cover the uploader resume state machine, `APIError.isWorldGone`, manifest round-trip, range parsing |
| R15 | Found during R14: upload flows inherit `@MainActor` from `UploadManager`, so every `CaptureStore` manifest read/write during an upload is synchronous disk I/O on the main thread (the old doc comment claimed otherwise) | Done 2026-11-04 on branch `refactor/r19-r15-capture-split` (`91c51af`), **unmerged**: `actor PendingSessionStore` serializes all upload-path manifest I/O off-main; manifest writes now throw (was `try?`), and `createWorld` refuses to mint if the idempotency key cannot be persisted. Generic-sim test build + Release build clean, 0 warnings. **Unit tests not run** (no simulator runtime installed) and needs a device upload run before merge |
| R16 | ✅ fixed 2026-09-17 (`92fbdf4`, `7f9bb86`) — iOS 27 crash at shot 28: `.finished` re-made the `ARSCNView` while the engine paused the `ARSession`; iOS 27 ARKit delivers the preview rotation angle synchronously under the session's unfair lock → layout → SwiftUI re-entry → second `makeUIView` → recursive-lock abort. Frames were already on disk; launch-time resume uploaded them | One camera-layer identity across ready→finished; `CameraPreviewHost` attaches the session on a guarded main-actor hop. **Needs a real-device re-run to confirm** |
| R17 | ✅ fixed 2026-09-17 (`8ffa6b7`), deployed 2026-09-18 — stitcher produced a horizontally MIRRORED pano on the pose path (ray-grid longitude ran toward +X; inside-view needs −X). Every world generated before this fix came from a mirrored pano. Pose-less fallback was accidentally correct and stays bit-identical | Grid sign + `FLIP_RIGHT` fallback basis; `stitcher.orientation.test.ts` (chirality, yaw-right→larger x, poles) fails on the old code. Verified on the 2026-09-17 device capture (text reads correctly; output == fliplr(old), seams unchanged). `PanoPreviewView`'s `scale(-1,1,1)` is the inside-sphere UV correction — leave it |
| R18 | ✅ fixed + deployed 2026-09-18 — "Enhance to HQ" never worked: backend served `/v1/worlds/:id/enhance`, spec + iOS use `{id}:enhance` → 404. Also: enhance flip was check-then-update (double tap = two 1500-credit jobs); `asset_version` was never bumped so a finished HQ would keep showing the cached draft splat | Colon route (regex-terminated param) + slash alias; atomic conditional flip; own rate-limit key; HQ finalize bumps `asset_version`. **Follow-ups done on branch `feat/backend-state-retry` (unmerged):** retry path = `:retry` (R42); default `DAILY_CREDIT_BUDGET` 500 -> 2000 (fits one HQ, matches prod); 429s now carry distinct `scan_quota_exceeded` / `credit_budget_exceeded` codes (§7.1 error codes), with an advisory budget check on `:enhance`/`:retry`. **Still open:** iOS maps every 429 to one "scan quota or credit budget" string and shows the raw status string for `failed_*`; first real HQ run is unverified end-to-end |
| R19 | `CaptureView` (627 lines) is a second god object: screen state machine + upload orchestration + quota policy + thermal/idle-timer + DEBUG test-scan tooling that calls the API from the view | Done 2026-11-04 on branch `refactor/r19-r15-capture-split` (`e075c52`), **unmerged**: `CaptureScreenModel` (239), `CaptureStartView` (135), DEBUG-only `CaptureDebugToolsView` (135, absent from the Release binary), `CaptureView` 627→177. R16 `content`/`cameraLayer` blocks verified unchanged. Also: `onSessionDiscarded` is now an immutable init param (was a MainActor-write/engine-queue-read race); `switch await` removed (it broke the graphify Swift parse); debug test scan sends an Idempotency-Key. Merge after tests run + the R16 device re-run |
| — | **Full-project review 2026-11-04** (graphify map + iOS / backend / infra Opus reviews; P1 findings orchestrator-verified in source). R20–R23 fixed on `main` 2026-11-04 (`05a75b8`, `77fef5f`, `c3ab577`, `6957484`) and **deployed** 2026-11-04 (api then worker; `/healthz` 200, authed `GET /v1/worlds` 200, worker started with no claim errors); 311 tests pass on the image lockfile (find-my-way 9.6.0); new SQL not yet run against real Postgres. | |
| R20 | P1 money: `frames:done` (`routes/worlds.ts` ~364) flips ANY world to `stitching` and enqueues a stitch. iOS stranded-session recovery replays it on a lost response, so a replay after `draft_ready`/`complete` re-stitches → `finalizeStitch` enqueues a second `generate_draft` (150 credits), knocks HQ back to draft, bypasses scan quota | Conditional flip from `uploading`/`failed_stitch` only, `deleted_at IS NULL`, flip + enqueue in one transaction; refused replay returns 200 with the current world and no job. Partial unique index on active `jobs(world_id, kind)` deferred to the next migration-bearing deploy |
| R21 | P1: Fastify has no `trustProxy`, so behind Railway every client shares the edge proxy's IP: 20 unauthenticated hits lock all devices out for a minute, and each successful auth resets the shared fail counter | `trustProxy` = `TRUST_PROXY_HOPS` (default 1, never `true`; Fastify >= 5.12 fails closed on a numeric value, so it is a function). Production measured at **2 hops** (CDN77 edge + Railway proxy): api env set to 2, real client IP logged, spoofed leftmost `X-Forwarded-For` ignored |
| R22 | P1: after `MAX_ATTEMPTS` retryable failures `failJob` parks the job `dead` but the world keeps its in-progress status forever (app polls every 3 s) | `failJob` returns the phase; `dead` applies the same failed-status path as non-retryable errors |
| R23 | P1: two lockfiles. Image `npm ci`s `backend/package-lock.json`, local tests use the root workspace lock; 11 packages differ (find-my-way 9.6.0 in prod vs 9.9.0 tested — the R18 colon route was only tested on 9.9.0) | Drop the root workspace; single `backend/` lockfile; rerun the suite on it |
| R24 | P1 before sharing the app: production dev auth = one bearer token compiled into every build + client-chosen `x-dev-user`. Anyone with the binary is anyone; all installs share one library; one "Delete account" tap 403s every install. Spend is capped by `DAILY_CREDIT_BUDGET`. Sign in with Apple needs the paid developer account | `user_tokens(token_hash pk, user_id, revoked_at)` + `mint-token` script + token paste field (Keychain) in Settings; hide Delete account under dev auth; later exchange a verified Apple token for the same table |
| R25 | P1 iOS: frames upload serially (next task created only on the previous completion), so nothing new is enqueued while suspended; relaunch only reconnects the session; 900 s presigns expire on slow runs and the 403s count toward parking | Enqueue all remaining frames at once (task description `<session>/<index>`), mark uploaded from the session delegate, `frames:done` on last completion; expired-presign 403 refreshes instead of counting; consider `BGContinuedProcessingTask` |
| R26 | P1 ops: no CI; `railway up` ships the laptop working tree (uncommitted files can deploy, no record of the live commit); the shared `railway.json` pre-deploy migrate never runs; `migrate.ts` uses the pooler URL | GitHub Actions: typecheck + vitest + stitcher (fail if stitcher suites skip) + Postgres service container for the integration suites + `docker build`. Per-service Railway configs (api: `preDeployCommand`, `healthcheckPath: /healthz`), `MIGRATE_DATABASE_URL` on the direct Neon host, GitHub-linked deploys with "wait for CI". iOS CI on demand only (macOS minutes bill 10x). **Railway config migrated 2026-11-04:** `railway.json` was never read by either service (that is why the pre-deploy migrate never ran) and is deleted; `.railway/railway.ts` (IaC, applied with `railway config plan/apply`, not read at deploy time) now owns both services: explicit Dockerfile builder, api health check `/healthz`, variables unmanaged. Pre-deploy migrate still off until `migrate.ts` reads a direct-host `MIGRATE_DATABASE_URL` |
| R27 | P2 backend state machine: status flip + enqueue are separate statements in finalize-stitch, enhance, delete-world, delete-account (crash between = world with no job; permanent for stitch); claim has no attempts cap (a process-killing job is re-claimed forever); finalize ignores `deleted_at` (assets re-written to R2 after purge, breaks §13); `completeJob`/`failJob`/`parkJobDead` don't check `locked_by` | One transaction per flip + enqueue; `AND attempts < MAX` on claim + reaper parks over-cap expired jobs; guard finalize on `deleted_at IS NULL`; `locked_by` in the job-completion WHERE clauses. **First two done** on branch `feat/backend-state-retry` (unmerged): finalize-stitch, enhance, delete-world, delete-account and the stale-upload reaper each flip + enqueue in one transaction; claim skips `attempts >= MAX_ATTEMPTS` and the reaper tick (`parkExhaustedJobs`) parks those jobs dead and applies the `failed_<phase>` world status (R22 path). **Still open:** finalize `deleted_at` guard, `locked_by` in completion WHERE clauses |
| R42 | R18 follow-up: no way out of a `failed_*` status (`failed_generating_hq` in particular: `canEnhance` needs `draft_ready`) | Done on branch `feat/backend-state-retry` (unmerged): `POST /v1/worlds/{id}:retry` (§7.1). A generation retry is a new job / new `display_name` and may re-bill a phase the failed job was already charged for (R1); bounded by scan quota (draft), rate limit and the daily credit budget. **iOS still needs** a Retry button on `failed_*` worlds calling it |
| R28 | P2: `pg` pool has no `error` listener (an idle-client drop crashes the process) and no connection/query timeouts (a half-open socket silently hangs the worker); no `unhandledRejection` handling; worker logs are unstructured `console.*`; no alerting | Pool `on('error')`, `connectionTimeoutMillis`, `query_timeout`, `keepAlive`; process-level handlers; pino child logger with job/world ids; reaper-tick webhook alert on dead jobs, budget > 80%, worlds stale > 30 min |
| R29 | P2 SSRF: World Labs `fetch` follows redirects, and the host allowlist only checks the first URL; `WLT-Api-Key` survives a cross-origin redirect | `redirect: 'manual'` + re-check every hop (or `'error'` for API calls); narrow the allowlist to the observed CDN host |
| R30 | P2 deps: `npm audit --omit=dev` is no longer 0 — zod < 4.6.6 (high), fast-uri (moderate), fastify < 5.12.6 (low) | Patch bumps + `npm audit fix`, then zod 4 (`.passthrough()`, stricter `.uuid()`, 400 issue text). Then vitest 5, TypeScript 6/7, `node --env-file-if-exists` in place of dotenv. Keep the hand-rolled queue (graphile-worker LISTEN/NOTIFY does not work through the transaction pooler) |
| R31 | P2 iOS robustness: no `webViewWebContentProcessDidTerminate` (killed WebGL process = permanent black viewer); ARKit `sessionShouldAttemptRelocalization` / interruption-ended unhandled; splat/pano caches in Application Support (backed up to iCloud), `.partial` files never swept, `captures/` not excluded from backup; `CaptureEngine.fail()` leaves partial sessions on disk 24 h; per-view poll tasks keep polling in background; `parseRange` mishandles suffix ranges | Route termination to `onError` (existing Retry); relocalize + handle interruption end; move caches to Caches, `isExcludedFromBackup`, launch sweep; purge on fail; `.task(id:)` gated on scenePhase; fix + test suffix ranges |
| R32 | P2 product/privacy: no terms page or consent prompt before photos leave the device (AGENTS.md §2); `fixture.spz` (6 MB owner capture) ships in Release; location usage string + privacy manifest declare collection that nothing performs | One-screen terms sheet with a versioned "I agree" before first capture, linked from Settings; exclude the fixture from Release; drop the location declarations |
| R33 | P3 backend: `STORAGE_DRIVER` defaults to `local` (a dropped env var serves unauthenticated `/dev-storage` in prod); Dockerfile `CMD npm start` puts npm/sh as PID 1 between SIGTERM and node, single-stage image keeps build layers; 2 s idle poll keeps the Neon compute awake; no CHECK constraints on `status`/`kind`/`phase`; `pg` warns that `sslmode=require` semantics change in the next major (set `sslmode=verify-full` explicitly in `DATABASE_URL`); `queue.pg.test.ts` uses session-level `SET search_path` (pooler pattern from the 09-17 incident) | Refuse `local` under `NODE_ENV=production`; `exec node`, multi-stage, `COPY --chown`; idle backoff to ~30 s; CHECKs in the next migration; integration suites only against a direct-host Neon branch or CI Postgres |
| R34 | Revised diagnosis of the shot-0 exposure "unlock": the pose is stamped before `lockCameraSettings()` runs (`ShotPipeline` ~123 vs ~144), so shot 0 is always labelled unlocked; real drift risk is only within one capture/encode | Lock when target 0 becomes ready, before the dwell fires |
| R35 | Modernisation backlog: vendored Spark 2.1.0 (current 2.4.0, still `three >=0.180`) and three r180 (current r187); `CaptureEngine` + helpers confined by comments behind `@unchecked Sendable`; `PanoPreviewView` on SceneKit; `worker.ts` 1328 lines, `routes/worlds.ts` 678, `WorldDetailView` 501 (next god object) | Spark 2.4.0 on three r180 (device check with `fixture.spz`), record sha256 in `VERSIONS.txt`, keep vendoring; `CaptureEngine` as an actor on the ARSession delegate queue; RealityKit `RealityView` pano; split `worker.ts` (stitch/generate/purge/reaper/loop) and `worlds.ts` by route group. Keep: JSON manifests (not SwiftData), Spark (MetalSplatter only if device profiling demands it) |
| — | **Capture v2 status 2026-11-04:** backend (R36 stitcher, R40, §5.2 items 3–5) on `main` and **deployed** 2026-11-04 (api + worker, healthz ok, worker `started`, no claim errors): 348 tests incl. stitcher suites; 09-17 benchmark at 4096 overlap error 11.43 → 9.06, edge-doubling 0.076 → 0.048, 4.8 s. iOS (R34, R37, R38, R39, R31 relocalization, §5.2 items 1–2) on branch `feat/capture-v2` (on top of R19/R15), builds clean, unit tests **80/80 pass** on the iOS 27 simulator (iPhone 18 Pro), Debug device build ready; needs a Pro-iPhone capture before merge. Follow-ups: `CaptureEngine.swift` 620 lines (split exposure/relocalization out); residual parallax on objects ≲0.5 m without LiDAR (overlap-based depth estimate deferred). | |
| — | **Status 2026-11-05 (on `main`):** iOS capture v2 + R19/R15 merged (owner's first device capture `b936c74a` ran end to end; R16, R17 and R18 verified on device). World Labs `display_name` 64-char 422 fixed + deployed. Full-resolution splats: worker stores `splat_full.spz`, iOS loads it only when the user turns on Settings "Maximum detail" on >= 7 GiB devices (default 500k: full-res made movement choppy on iPhone 17 Pro). **Merged, NOT deployed:** R27 atomic flip+enqueue, claim attempts cap, `:retry` (R42), distinct 429 codes, `DAILY_CREDIT_BUDGET` default 2000; R28 pool error listener + 10 s connect / 30 s query timeouts + crash handlers (no `statement_timeout` via pooler; set it on the DB role if wanted); R29 redirects re-checked per hop, API key never sent on asset downloads; R30 audit 0 (zod 4, fastify 5.12.8); R33 STORAGE_DRIVER=local refused in production, multi-stage Dockerfile with node as PID 1, sslmode normalised to verify-full; R26 `MIGRATE_DATABASE_URL` + api `preDeploy` in `.railway/railway.ts` (not applied) and GitHub Actions backend CI (green); R25 all uploads enqueued at once on the background session, expired presigns refreshed instead of counted; R31 WebGL process-death reload, caches moved to Caches/; R32 fixture.spz excluded from Release, location string removed, privacy manifest corrected (consent screen = UI WP3); CaptureEngine split to 299 lines. Pano preview heading: analysis says it already faces shot 0 (`initialYaw = 0`), needs a device check. UI redesign spec: `docs/design/ui-spec.md` (WP1-WP5). Live-mapping research: `docs/research/live-mapping.md`. | |
| — | **Status 2026-11-05, later (on `main` `1bb34ff`):** backend hardening + state/retry **deployed** (api, then worker; new multi-stage image, node is PID 1, sslmode warning gone, authed GET 200, worker started, no claim errors). **Migrations run on deploy:** `MIGRATE_DATABASE_URL` (direct Neon host) set on api, `railway config apply` added api `preDeploy: node dist/migrate.js` (plan: 1 change, 0 add/destroy); verified by an api redeploy (`[migrate] up to date`). UI redesign WP1-WP5 merged (172 iOS tests): tokens, one toast system, typed errors, WorldStore, Library/Detail with retry + pagination + offline banner, onboarding + versioned terms consent (uploads gated), scan flow coaching + camera priming, one-screen explorer loading, Settings restructure (account rows hidden under dev auth). Debug build of `main` installed on the owner's iPhone; needs a device walkthrough. Known flaky test: `CaptureUploaderDepthTests.depthUploadsAlongsideFrames` (1 failure in ~8 full runs, missing `depth_0.png`). | |
| — | **Capture design review 2026-11-04** (external research + end-to-end audit, key claims verified in source). Verdict: keep guided ARKit capture → own pano → Marble (`is_pano`, cheapest input, World Labs' own guidance says a pano gives the most accurate layout; Teleport ships the same shape at 16 shots). Quality is limited by drift + averaging blend, not by the architecture. | |
| R36 | Ghosting: `reproject.py` ignores translation by design (~264) and averages every overlapping frame with a power-2 centre weight (~552-563); 52 cm drift at a 2.5 m wall is ~12° misregistration, which Marble rebuilds as doubled geometry | S: `INTER_AREA` prefilter before remap (source ~57 px/deg vs pano ~23), steeper blend weight. M: `cv.detail` graph-cut seams + block-gain compensation + multi-band blend; translation-aware proxy-sphere reprojection (centre on mean camera position, depth from a fixed ~2.5 m or ARKit `rawFeaturePoints`). L (only if ghosting survives): LiDAR `sceneDepth` forward-splat |
| R37 | Drift is measured from shot 0's position (`CaptureEngine` ~315), never gates a shot, and the "step back to where you started" copy is likely wrong: turning the body with the phone held out orbits the camera ~50 cm without a step | Measure from the running centroid of shot positions; coach "phone at chest, shuffle around the phone" with a pivot indicator; soft-gate dwell beyond ~15-20 cm (threshold from a drift experiment) |
| R38 | Focus, exposure, light: focus and AE/WB are locked at whatever target 0 sees (`ARKitCaptureSource` ~160-178): near focus blurs far walls, a window in shot 0 underexposes the room; ISO/duration not persisted so the stitcher cannot compensate; no low-light preflight (promised §6.1, light estimation off); steadiness threshold ignores exposure time | Leave AF on (per-frame `fx` already handles breathing) or lock far; meter during ARKit preroll and lock before target 0's dwell (also fixes R34); persist ISO + duration per `FramePose`; ISO-near-max preflight; scale the steady threshold by 1/exposure |
| R39 | Capture flow: strict sequential rings = three body rotations (three chances to drift); down ring only ~20% overlap (6 @ 60°) while the floor matters most for a walkable world; nadir frames include the user, unmasked; ARKit interruptions don't relocalize (R31); on iOS 26.0 the first `captureHighResolutionFrame` can return a wrong transform (Apple forum 801508, fixed 26.1) and the deployment target is 26.0 | Column or any-order capture; rebalance to 6 up / 8 down; nadir mask; relocalization + restart prompt; ignore/replace shot 0's transform on 26.0 (or raise the target to 26.1) |
| R40 | We stitch and send 8192×4096; Marble's recommended pano width is 2560 and it returns 2560×1280 | Stitch at 4096 (halves stitch time/memory, keeps a decent user-facing Preview/Save) unless the 8192 download matters to the owner |
| R41 | Ultra-wide is not selectable in ARKit world tracking (Apple, 2026-06); an ultra-wide path means AVCapture + CoreMotion (no translation, no ARKit poses). Platform risk: AMD announced it will acquire World Labs (2026-09-28, pending) | Stay on the wide lens. Keep the provider interface swappable; no long-term credit pre-buys until the API's future is clear. Open empirical question: pano vs `video` vs `multi-image` (`reconstruct_images`, ≤8) on the same room — settle with a draft-model A/B, not a rebuild |
| — | **Status 2026-09-18:** R1–R17 **deployed** (api + worker, `node:24-trixie-slim` image, migrations 0003/0004 applied by hand — the Railway pre-deploy step did not run; see HANDOFF). `DATABASE_URL` is a pgbouncer pooler: no session-level `SET`/advisory-lock assumptions through it. | |
| — | **Status 2026-09-17:** ✅ landed on `main` with tests: R1, R2, R3, R4, R5, R6, R7, R9, R12, R13, R14 (Swift 6 mode, 0 warnings, 53 tests; `CaptureEngine` 704→479 lines — **needs one real-device 28-shot run**: the capture path cannot be exercised in the simulator). R8 (stitch peak RSS 4.5 GB → ~400 MB at 8192 wide, byte-identical output), R10, R11 also landed (`npm audit --omit=dev`: 0). Image build unverified locally (no Docker on the dev machine) — run `docker build` or watch the first Railway build. Deploy order: set `ALLOW_DEV_AUTH=1` on api + worker → set the **api** service pre-deploy command to `node dist/migrate.js` (applies 0003 + 0004; leave the worker's empty) → deploy → check `/healthz` and `GET /v1/worlds`. **Not yet deployed** — deploy prerequisites: set `ALLOW_DEV_AUTH=1` on Railway (api + worker) while production still runs dev auth, and migrations `0003`/`0004` must apply before the new API serves traffic (handled by the pre-deploy step below). R1 caveat: the live `findWorldByDisplayName` listing endpoint shape is unverified against World Labs — a wrong guess degrades to a parked job, never a double bill. | |
| R14 | Swift 5 language mode + default `MainActor` isolation while capture code runs on private queues — isolation is unchecked | Migrate to Swift 6 language mode; split `CaptureEngine` (HUD state, publish throttle, thermal governor, shot pipeline) |

---

## 11. Build phases (v1 = Phases 0–4)

**Phase 0 — World Labs spike** ✅ **DONE 2026-07-12** (§2.1)
- Full API pipeline proven live: upload → generate (draft, `is_pano:true`) → poll → SPZ download. ~16 s, 150 credits.
- Leftover (rolled into 0.5): Spark render check on a real device.

**Phase 0.5 — Stitch spike** ✅ **GATE DECIDED 2026-07-12** (input: a real 16-frame on-device capture from the Stage B app)
- **Feature-based stitching is DEAD for this product**: OpenCV `Stitcher` produced a warped 270° strip (no closed sphere); Hugin `cpfind` collapsed entirely (5 disconnected groups, 321 px CP error) — guided-capture geometry (~5° overlap at 45° yaw, blank walls, moving subjects) starves feature matchers. Not a tuning problem.
- **Winner: pose-assisted equirectangular reprojection** (custom ray-trace + feather blend + inpaint, ~30 s in NumPy). Even with *nominal* target angles it produced a coherent 8192×4096 full sphere (6.5/10: strong horizon band + zenith; weak nadir/mid-latitude inpaint). Real ARKit poses — now flowing client→backend (`captures.poses_json`, verified 16/16 in prod) — remove the nominal-pose seams.
- **Marble validated the pano**: `marble-1.0-draft` reconstructed the bedroom into a correct, navigable 3D world with an accurate scene caption. End-to-end own-capture → own-stitch → Marble is PROVEN.
- **v1 decisions:** ship the pose-assisted reprojection as the stitch worker (port `reproject.py` to the backend); densify the capture pattern (yaw step ≤30°, more pitch-ring frames — or evaluate ultra-wide lens for rings); multi-image fallback (§5.1) stays documented but is NOT needed.
- Deferred leftovers: one `marble-1.1` HQ run + `semantics_metadata` check; on-device Spark render check (moves to Stage C).

**Phase 1 — Backend skeleton** ✅ **DONE 2026-07-12**
- Deployed & E2E-verified on production infra: Railway api+worker, Neon schema (8 tables incl. credit_events), R2 (`virtspace-assets`) presigned uploads, credit-safe SKIP LOCKED queue (idempotent resume via persisted operation_id), daily budget guard, mock-provider mode, SIWA verification implemented (dev-auth mode active until the iOS app lands). Live smoke: world reached `draft_ready` in ~12 s with all assets re-hosted on R2.
- QA cycles caught & fixed: Drizzle array-tuple claim SQL, snake_case row mapping silently defeating the §14 resume check, stuck-job lease expiry, Neon pooler quirks. Real-Postgres integration suite added (opt-in via TEST_DATABASE_URL).
- ~~Known follow-ups~~ **both closed same day:** (1) mock generations now cost 0 (ledger path still exercised); (2) **live-provider validation ✅** — a real pano went through the deployed pipeline with `PROVIDER_MODE=live`: Marble draft world in ~40 s end-to-end, real caption, SPZ re-hosted to R2 and byte-validated (gzip+NGSP magic, 6.1 MB). Worker returned to mock mode for dev. Total live spend to date: 300 credits (2 draft worlds).
- **API contract note for clients:** `GET /v1/worlds/:id` returns `{ world, assets }` — presigned URLs live in the top-level `assets` object, not on `world`.

**Phase 2/3 head-start — iOS Stage A foundation** ✅ **DONE 2026-07-12**
- SwiftUI app shell (Capture · Library, dark-first), API client on the real `{world, assets}` contract, Library cards w/ presigned thumbnails + 3 s active polling, WorldDetail with honest §6.2 status timeline + Enhance/Delete, DEBUG test-scan harness.
- **Simulator E2E PASS against production**: app-driven scan → `draft_ready` in ~9 s, timeline/caption verified on-screen and via API. Follow-ups: mock provider serves text stubs (thumbnails show placeholder in dev — swap to real fixture bytes), relative timestamps don't live-tick (design pass item).

**Phase 2 — Capture pipeline (iOS)** 🟡 **engine + HUD done 2026-07-12; device validation pending**
- ✅ Stage B1 engine: 16-target sphere layout, alignment/dwell auto-fire, ARKit-native high-res stills with AE/AWB/AF lock, crash-proof per-shot persistence, resumable presigned uploads, simulator capture source.
- ✅ Stage B2 HUD: world-locked dots + edge chevrons, reticle snap + dwell ring, filling-sphere progress, priority coaching banners, viewfinder chrome, upload overlay. Sim-verified end-to-end (screenshots archived).
- ⏳ Pending: **real-device run** (ARKit transforms/projection sanity, real photos), preflight checks (low light/disk), on-device low-res preview stitch, and — critically — the **server stitcher is still v0 single-frame passthrough**: 16-frame scans fail at stitch until the Phase 0.5 gate decides own-stitch vs multi-image.

**Phase 3 — Full loop + Library (v1 core)** ✅ **DONE 2026-07-12**
- Draft-first generation + Enhance flow; honest phase-based status timeline; Result detail; private Library w/ thumbnails + polling; **Spark explorer** (bundled Spark 2.1 + three 0.180, WKURLSchemeHandler, splat cache, in-page joystick — verified rendering the owner's real bedroom splat); **360° pano preview** (SceneKit inverted sphere + Save to Photos). APNs dropped from v1 (no paid Apple Developer account — foreground polling covers it; revisit with a paid account).

**Phase 4 — v1 ship (self-testing scope)** ✅ **DONE 2026-07-12** (adjusted: no TestFlight — free provisioning to the owner's device)
- 28-target densified capture (Phase 0.5 remediation); Settings (cache mgmt, World Labs attribution, double-confirmed account deletion); PrivacyInfo.xcprivacy; splat/pano caching; error/failed-retry states; production live-provider mode with DAILY_CREDIT_BUDGET=2000 (fits one HQ enhance/day). **Deferred deliberately:** public share links + web viewer, deep design-system pass (pending real-device feedback), APNs, on-device orientation sanity check (owner's next run).

**Phase 5+ — Post-v1 (deferred)**
- Public **Explore** social gallery (brings App Store UGC moderation duties), map clustering, search; **PRO+** monetization; **native MetalSplatter** explorer + LoD tiers; cost dashboards, autoscaling, egress tuning.

---

## 12. Testing strategy

- **Capture needs hardware** — Simulator has no camera/ARKit. Keep two physical test devices (oldest supported + current). Capture flow gets a debug "replay mode" that feeds recorded frames+poses through the pipeline off-device.
- **Stitch worker** — golden fixtures: recorded 16-frame sets with poses → expected pano; assert similarity threshold in CI. Runs entirely server-side, no device needed.
- **Provider integration** — mock-provider mode (env flag) returns the spike's canned `world.spz`/thumbnail instantly: app and backend development spend zero credits. A tiny nightly live check (1 draft/week max) guards against API drift.
- **Viewer** — the spike's `viewer.html` + `world.spz` are the standing fixture for WebView work.
- **E2E** — one scripted happy path against staging (real draft gen) before each TestFlight build.

---

## 13. Privacy & App Store compliance (required for TestFlight/App Store)

- **Purpose strings:** `NSCameraUsageDescription` (capture), `NSLocationWhenInUseUsageDescription` (optional geotagging — scans work without it), `NSPhotoLibraryAddUsageDescription` (save 360 to Photos). Plus a **privacy manifest** (`PrivacyInfo.xcprivacy`).
- **Notification permission timing:** ask at the *first generation* ("we'll tell you when your world is ready"), never at first launch.
- **Account deletion (Apple requirement):** in-app `DELETE /v1/account` → cascade Neon rows, R2 assets, APNs tokens, and provider-side worlds (pending §10 check on World Labs deletion support; if unsupported, the privacy policy must say so honestly).
- **Third-party disclosure:** user photos leave the device to our backend **and to World Labs**. Privacy policy + App Store privacy labels must disclose this; confirm from the ToS/DPA whether API inputs are used for model training (§10).
- **Data minimization:** raw frames purged from R2 after successful stitch (§7) — **NOT IMPLEMENTED as of 2026-11-05**: frames are purged only on world delete or stale upload (`purge` job, `framesOnly` reaper); after a stitch they are kept (useful for re-stitching with an improved stitcher). Owner decision pending: purge after N days vs keep until delete; the in-app terms state the current behaviour; location optional; worlds private by default (matches provider default).
- **Attribution:** "Generated using World Labs" string in world detail/share pages (ToS requires on request — cheap to do proactively).
- **Share links (Phase 4):** unguessable slugs, revocable; full UGC moderation (report/block) only becomes an App Store duty when public Explore ships (Phase 5).

---

## 14. Reliability & operations

- **Credit safety (the money-touching path):** jobs row transitions persisted around every `worlds:generate`; a `pending:<jobId>` intent marker is persisted **before** the call and replaced by the real `provider_operation_id` immediately after; a worker resuming from a pending marker reconciles against the provider (unique `display_name` embedding the job id) and never blind-resubmits; a failed/timed-out generate call is non-retryable (§10 R1 — the 2026-09-17 review found the earlier "saved atomically" claim had a crash/timeout window). Daily credit budget cap (env var) + low-balance alerts.
- **Durability:** queue with retries + DLQ; every job phase idempotent; client uploads resumable; app relaunch resumes pending uploads and re-polls pending worlds.
- **Observability:** Sentry (app + backend); structured job logs; metrics: generations/day, credit spend/day, failure rate by phase, job latency p50/p95; alerts on DLQ depth and credit balance.
- **Asset ownership:** provider outputs copied to R2 the moment a job completes; the app and share pages only ever reference our signed URLs.
- **Secrets:** World Labs key + R2 keys live in Railway env vars; nothing secret ships in the app bundle.

---

## Appendix — Key sources
- World Labs World API: [docs](https://docs.worldlabs.ai/api) · [pricing](https://docs.worldlabs.ai/api/pricing) · [announcement](https://www.worldlabs.ai/blog/announcing-the-world-api) · [ToS](https://www.worldlabs.ai/terms-of-service)
- Spark renderer (MIT): [sparkjs.dev](https://sparkjs.dev/) · [Spark 2.0](https://www.worldlabs.ai/blog/spark-2.0) · [github](https://github.com/sparkjsdev/spark)
- MetalSplatter (MIT): [github](https://github.com/scier/MetalSplatter)
- SuperSplat viewer (walk controls, MIT): [github](https://github.com/playcanvas/supersplat-viewer)
- CTPanoramaView (MIT): [github](https://github.com/scihant/CTPanoramaView)
- ARKit world tracking: [Apple docs](https://developer.apple.com/documentation/arkit/understanding-world-tracking)
- AVFoundation manual controls: [WWDC 2014 S508](https://asciiwwdc.com/2014/sessions/508)
- OpenCV iOS stitching reference: [OpenCVSwiftStitch](https://github.com/foundry/OpenCVSwiftStitch)
- Neon pricing / object storage: [neon.com/pricing](https://neon.com/pricing)
- No-parallax point (stitching): [PanoTools](https://wiki.panotools.org/No-parallax_point)
