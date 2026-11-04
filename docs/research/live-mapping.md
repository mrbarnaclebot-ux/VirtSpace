# Live room / house mapping with iPhone Pro (research, 2026-11-05)

Question from the owner: can we map a whole room or house by recording it live with an iPhone Pro, then use World Labs, instead of taking photos from one spot?

## Bottom line

Marble turns **every** input (pano, multi-image, video) into one 2560x1280 panorama before generating, so a recorded walk-through still yields a single-viewpoint world. Whole-house coverage therefore means **several worlds placed by us**, or **real reconstruction** (Gaussian splat training) instead of generation.

## What the iPhone can capture

| API | Output | Whole house? | Feeds World Labs? |
|---|---|---|---|
| ARKit `sceneReconstruction` | LiDAR mesh anchors with classes | one session, drifts | no (Marble takes no mesh); alignment only |
| `sceneDepth` + frame poses | 256x192 depth per frame (already captured), LiDAR ~5 m | yes if tracking holds | poses/depth for splat training or world placement |
| RoomPlan + StructureBuilder | parametric rooms, multi-room merge, USDZ | single floor, ~1-4 bedrooms / ~2,000 sq ft, needs >= 50 lux; can share our ARSession ([WWDC23 10192](https://developer.apple.com/videos/play/wwdc2023/10192/)) | floor plan / placement only |
| ARWorldMap | relocalizable feature map | resume across sessions | indirect |
| iOS 27 | RealityKit can render Gaussian splats ([WWDC26 279](https://developer.apple.com/videos/play/wwdc2026/279/)); no new capture API found | n/a | viewer only |

Risks: an iOS 26.4 LiDAR walking-drift regression reportedly fixed in 26.6.1 ([forum](https://developer.apple.com/forums/thread/827240)); no published thermal limits (Scaniverse warns scans over 180 s may fail).

## World Labs facts (docs.worldlabs.ai)

- Video: <= 30 s, <= 100 MB, guidance is a 180-360 degree in-place rotation; costs pano generation 100 + world 150/1500, i.e. 100 more than sending our own pano.
- Multi-image (reconstruct): <= 8 images, azimuth only; one space per world; their advice for homes is one world per room, assembled in Compose.
- Expand, Compose and Chisel are **web-app only**; the API has generate/get/list/export/delete and `pano:depth_to_rgb` (textures come from the prompt, not the real room). No mesh or layout conditioning via API.
- Marble 1.1 Plus (2026-04) makes larger worlds in one pass, 1500-3000 credits. Credits: $1 per 1,250.

## Reconstruction instead of generation

Scaniverse trains splats on-device (~1 min); Polycam in the cloud (~10-20 min/room); nerfstudio splatfacto trains from iPhone LiDAR captures with poses (`ns-process-data record3d`), ~15 min and ~12 GB VRAM per room on an RTX 3090. Photoreal where seen, holes where not. A hybrid (reconstruct the seen, fill gaps with World Labs or a diffusion fixer such as Difix3D+) is feasible but research-grade.

## Product options

| | Flow | Build | Cost per 6-room house | Quality | Effort |
|---|---|---|---|---|---|
| **A. Multi-station house** (prototype first) | one continuous ARKit session; user does the current spin at 1-3 stations per room | store station poses + ARWorldMap (optional RoomPlan plan); one pano world per station; viewer places each world at its pose and metric scale (`metric_scale_factor` / `ground_plane_offset`, or fit LiDAR depth) and cross-fades between stations | ~12 stations: ~1,800 draft ($1.44) / ~18,000 HQ ($14.40) | good near each station; seams are the risk | M |
| B. Video spin per room | 30 s locked-exposure video per room | AVAssetWriter path | 250 draft / 1600 HQ per room | likely <= our stitched pano | S (A/B only, R41) |
| C. Splat reconstruction | chunked walk-through (<= 3 min each) of frames + poses + depth | GPU worker (gsplat/nerfstudio), ~15-30 GPU-min per room; optional World Labs gap fill | no credits; GPU time (host TBD) | closest to the real house | L |

## Smallest experiment for A (~550 credits, ~$0.44)

Two stations ~3 m apart in one session (log both poses), two draft worlds (300), place both in Spark by pose + scale, measure seam error in cm; plus one 30 s video-spin draft at station 1 (250) to settle B vs our pano. Run via a mock/test path, never blind retries; persist `provider_operation_id` before polling.

## Open questions

1. Does draft or 1.1 return `semantics_metadata` (metric scale), or must we fit scale from LiDAR?
2. How badly do neighbouring worlds disagree at doorways?
3. Thermal behaviour of a 10+ minute LiDAR session on iPhone 17 Pro / iOS 27.
4. Does tracking hold across a whole house on iOS 27, or is per-room ARWorldMap resume needed?
5. Where would C's GPU worker run, and at what cost vs credits?
6. Does the pending AMD acquisition of World Labs (R41) argue for building C sooner to reduce provider lock-in?
