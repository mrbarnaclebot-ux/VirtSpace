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
| Photo capture | **AVFoundation** `AVCaptureSession` + `AVCapturePhotoOutput`, **AE/AF/AWB locked** for the whole 16-shot set | Locking exposure/focus/white-balance is the single biggest lever against stitch seams. Grab full-res stills from a parallel AVCapture output; correlate to ARKit pose by timestamp. |
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
| Job queue / orchestration | **Postgres-backed queue** in Neon (`FOR UPDATE SKIP LOCKED` on the `jobs` table) for v1; SQS/Trigger.dev is the documented swap point at scale | Jobs are low-volume and the table already exists — one less external service. Retries via `attempts` + backoff columns; permanent failures parked as `failed_*` (DLQ-equivalent). *(Locked 2026-07-12 at Phase 1 kickoff.)* |
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
POST   /v1/worlds/{id}/frames:done all frames uploaded → enqueue stitch + draft-gen job
GET    /v1/worlds/{id}             status/phase + signed asset URLs (client polls ~3s while foregrounded; APNs covers background)
GET    /v1/worlds                  my library (paginated)
POST   /v1/worlds/{id}:enhance     trigger marble-1.1 HQ generation
DELETE /v1/worlds/{id}             delete world → cascade R2 assets (+ provider-side deletion, see §13)
POST   /v1/devices                 register APNs token
DELETE /v1/account                 full account deletion (App Store requirement — see §13)
```
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

---

## 11. Build phases (v1 = Phases 0–4)

**Phase 0 — World Labs spike** ✅ **DONE 2026-07-12** (§2.1)
- Full API pipeline proven live: upload → generate (draft, `is_pano:true`) → poll → SPZ download. ~16 s, 150 credits.
- Leftover (rolled into 0.5): Spark render check on a real device.

**Phase 0.5 — Stitch spike (NEXT — hard gate before any capture UI)**
- Hand-capture ~16 photos with an iPhone (manual, no app yet — locked exposure via a camera app, rotate in place), plus pose estimates.
- Stitch server-side two ways (Hugin `nona`+`enblend` pose-seeded vs OpenCV) → feed the best pano to `marble-1.0-draft` → judge world quality. Also run **one `marble-1.1`** on the winner (latency, sizes, `semantics_metadata`).
- In parallel: same scene via the **multi-image fallback** (§5.1) for an apples-to-apples fidelity comparison.
- Load `world.spz` in a WKWebView Spark page **on-device** (verify render, axis orientation, memory, fps).
- **Gate decision:** own-stitch (which toolchain) vs multi-image for v1.

**Phase 1 — Backend skeleton** ✅ **DONE 2026-07-12**
- Deployed & E2E-verified on production infra: Railway api+worker, Neon schema (8 tables incl. credit_events), R2 (`virtspace-assets`) presigned uploads, credit-safe SKIP LOCKED queue (idempotent resume via persisted operation_id), daily budget guard, mock-provider mode, SIWA verification implemented (dev-auth mode active until the iOS app lands). Live smoke: world reached `draft_ready` in ~12 s with all assets re-hosted on R2.
- QA cycles caught & fixed: Drizzle array-tuple claim SQL, snake_case row mapping silently defeating the §14 resume check, stuck-job lease expiry, Neon pooler quirks. Real-Postgres integration suite added (opt-in via TEST_DATABASE_URL).
- ~~Known follow-ups~~ **both closed same day:** (1) mock generations now cost 0 (ledger path still exercised); (2) **live-provider validation ✅** — a real pano went through the deployed pipeline with `PROVIDER_MODE=live`: Marble draft world in ~40 s end-to-end, real caption, SPZ re-hosted to R2 and byte-validated (gzip+NGSP magic, 6.1 MB). Worker returned to mock mode for dev. Total live spend to date: 300 credits (2 draft worlds).
- **API contract note for clients:** `GET /v1/worlds/:id` returns `{ world, assets }` — presigned URLs live in the top-level `assets` object, not on `world`.

**Phase 2/3 head-start — iOS Stage A foundation** ✅ **DONE 2026-07-12**
- SwiftUI app shell (Capture · Library, dark-first), API client on the real `{world, assets}` contract, Library cards w/ presigned thumbnails + 3 s active polling, WorldDetail with honest §6.2 status timeline + Enhance/Delete, DEBUG test-scan harness.
- **Simulator E2E PASS against production**: app-driven scan → `draft_ready` in ~9 s, timeline/caption verified on-screen and via API. Follow-ups: mock provider serves text stubs (thumbnails show placeholder in dev — swap to real fixture bytes), relative timestamps don't live-tick (design pass item).

**Phase 2 — Capture pipeline (iOS)**
- ARKit + AVFoundation guided 16-shot capture (locked AE/AF/AWB, world-locked dots, steadiness auto-fire, parallax coaching, preflight checks, crash-proof local persistence). Direct-to-R2 uploads. Server stitch integration. Fast on-device low-res preview.

**Phase 3 — Full loop + Library (v1 core)**
- Draft-first generation + Enhance flow; APNs "world ready"; honest phase-based Generating state; Result detail screen; **private Library**; Spark explorer (bundled assets, in-page joystick); CTPanoramaView 2D pano preview.

**Phase 4 — v1 polish & ship**
- Share links (public web viewer page + unguessable slugs); on-device caching + resumable downloads; empty/error/failed-retry states; account deletion + privacy compliance (§13); design-system pass (`impeccable`/`polish`/`animate`). **← v1 TestFlight ships here.**

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
- **Data minimization:** raw frames purged from R2 after successful stitch (§7); location optional; worlds private by default (matches provider default).
- **Attribution:** "Generated using World Labs" string in world detail/share pages (ToS requires on request — cheap to do proactively).
- **Share links (Phase 4):** unguessable slugs, revocable; full UGC moderation (report/block) only becomes an App Store duty when public Explore ships (Phase 5).

---

## 14. Reliability & operations

- **Credit safety (the money-touching path):** jobs row transitions persisted around every `worlds:generate`; `provider_operation_id` saved atomically; resumed workers never blind-resubmit. Daily credit budget cap (env var) + low-balance alerts.
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
