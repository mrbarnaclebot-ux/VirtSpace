# Reconstruction vs generation for broker tours (research, 2026-11-05)

Question from the owner: can PlayCanvas, Gaussian splat reconstruction or SpAItial Echo-3 make our scans much better? The product is for brokers to scan a whole house so buyers and renters can walk it in a browser on a listings page.

## Bottom line

- **Generation vs reconstruction is the decision that matters, not the renderer.** World Labs Marble (current) *generates* a world from one pano: invented outside the capture spot, one viewpoint, no whole house. Reconstruction trains splats from many views of the real place: faithful where seen, walkable through every room.
- **For listings, faithful wins.** A generated tour can show things that aren't there. Marble fits only clearly labelled staging or "what-if" scenes.
- **Every faithful option needs a walk-through capture** (frames plus ARKit poses plus LiDAR depth from many positions), not the current one-spot spin. See `live-mapping.md` options A and C.
- **The renderer (PlayCanvas or Spark) does not fix one-viewpoint blur.** Choose it for the web listings page later.

## PlayCanvas

- **What it is:** engine, SuperSplat editor, supersplat-viewer and splat-transform, all MIT.
- **Rendering and formats:** PLY, SOG and streamed SOG with LOD and a splat budget. SPZ loads via a parser script. Sorting runs on the GPU and is stochastic on WebGPU, and in a CPU worker on WebGL2.
- **Viewer features:** walk mode, hotspots, collision and embeds.
- **Publishing:** there is a REST publishing API to superspl.at, but its terms and pricing are unverified, so self-host.
- **No reconstruction.** PlayCanvas points to Polycam, Scaniverse, Postshot, Brush and nerfstudio.
- **No published iPhone fps** for it or for Spark.
- **Fit:** strong candidate for the **web listings viewer** (ready-made tour features). Not worth swapping into the app now. Trial Spark's own LoD/paging there first (about 1 day).

## Echo-3 (SpAItial, launched 2026-10-27)

- **What it does:** iPhone walking capture in SpAItial's app becomes a metric-scale splat that "preserves what you captured and completes what you missed". It is pitched at homes, multi-floor buildings and real estate.
- **Exports:** SPZ, SOG, mesh, normals and depth.
- **Price:** about 300 credits/scan-minute (900 minimum), 1 credit = $0.01, so roughly **$30-60 per house** (our estimate). Commercial rights need Pro (15k credits/month).
- **API:** Echo-3 is **Enterprise-only**. The public API has Echo-2 and HQ, which are generative.
- **Unverified:** whether the Enterprise API accepts our own frames and poses, the whole-house limits, quality benchmarks and data terms.

## Options

| Option | Faithful | Whole house | Cost/house | Our effort |
|---|---|---|---|---|
| Marble (current) | no | no | $1.20-2.48 | done |
| Echo-3 Enterprise | yes + gap fill | claimed | ~$30-60 | low if it takes our frames |
| Varjo Teleport API | yes | likely (3,000 images, 4M splats) | ~$16 + $30/mo | low |
| Self-host gsplat/Brush on GPU (Apache-2.0), ARKit poses | yes | yes, per-room chunks | ~$0.50-2 GPU | high |
| On-device msplat (Apache-2.0) | yes | one room | $0 | medium-high |

- **Teleport:** pricing and limits come from radiancefields, and its terms are unverified.
- **Avoid:** INRIA 3DGS (non-commercial license) and Luma (uploads disabled since 2024-11).
- **Competitor:** Splat Tour, a phone video per floor turned into a per-room 3DGS tour with a floor plan, €19-89/month. Zillow SkyTour splats are exterior drone shots only. Matterport is still pano-to-pano.

## Proposed experiment

1. Capture one real room as a walk-through: frames plus poses plus depth, using our existing capture data.
2. Reconstruct it with Teleport (about $1-5 for one room).
3. If SpAItial grants access, also run Echo-3 on the same room.
4. View both next to the Marble world of the same room, in Spark and in supersplat-viewer on the iPhone.
5. Decide the provider and the capture redesign from the result.

Sources are in the 2026-11-05 research agent reports. Key ones:

- PlayCanvas formats: https://developer.playcanvas.com/user-manual/gaussian-splatting/formats/
- PlayCanvas recommended reconstruction tools: https://developer.playcanvas.com/user-manual/gaussian-splatting/creating/recommended-tools/
- Echo-3 launch: https://radiancefields.com/spaitial-echo-3-turns-iphone-scans-into-3d-worlds
- SpAItial API: https://docs.spaitial.ai/api/getting-started
- Teleport developer plan: https://radiancefields.com/teleport-adds-developer-plan-with-api-access
- Splat Tour: https://radiancefields.com/splat-tour-turns-phone-video-into-3d-property-tours

## SpAItial API check (2026-11-05, owner's key, read-only calls only, 0 credits spent)

- `GET /v1/models` for our key: only `echo-2` (160 credits, 115 from a pano, ~9 min) and `echo-hq` (800, ~60 min). Both take a `single` image or pano, so they are **generative**, the same class as Marble.
- The capture API exists (`/v1/openapi.json`): `POST /v1/captures` (Idempotency-Key) → `upload-urls` (signed PUTs, at most 100 paths per call) → `complete` → `process` (Idempotency-Key, reserves credits); `GET /v1/captures/process-quote?duration_seconds=` quotes first.
  - Two input forms:
    - an **iOS frame bundle**: `images/Image_000001.jpg…`, plus `cameras/camera_trajectory.json`, `cameras/camera_intrinsics.json` and `cameras/orientation.json`; up to 5,000 frames;
    - an **unposed video** at `source/video.mp4|mov`: 5-600 s, up to 1 GB.
  - Price: 300 credits per minute, 900 minimum (scan of at least 180 s).
- `process-quote` on our key: "No models for this input are enabled for API access on this account. Contact support to enable it." So Echo-3 needs enablement (docs: Enterprise).
- The JSON schemas for the bundle files are not public, so ask support.
- Outputs:
  - formats: SPZ (RDF, y-down: same 180° X flip as Marble), SOG and PLY;
  - exports: `mesh` and `mesh-simplified` (collision), plus `floorplan` (a visual top-down render, automatic for capture worlds);
  - the result also includes a `viewer_url`.
- Webhooks are signed with HMAC-SHA256 (`whsec_` secret, in local `.env`).
