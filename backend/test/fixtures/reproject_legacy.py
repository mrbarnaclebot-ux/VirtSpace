"""TEST-ONLY reference copy of reproject.py's pre-banding `build()`/`fill_holes()`.

Vendored VERBATIM from commit 274d6d9 — the last revision before the spec §10 R8
row-band rewrite — so `stitcher.banding.test.ts` can prove the banded
implementation is numerically identical to the full-frame one it replaced.

Do NOT "fix", optimise or re-sync this file with production: its whole value is
being the OLD code. Everything it needs (load_frame, upright, rmat,
derive_pose_rotation, focals_from_intrinsics, nominal_angles, count_frames, die,
progress, log and the tuning constants) is imported from the live module, so the
comparison isolates the one thing that changed: how the equirect is traversed.
"""

import math
import sys
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "stitcher"))

from reproject import (  # noqa: E402
    POLE_BOOST,
    POLE_LAT_DEG,
    REMAP_CHUNK,
    count_frames,
    derive_pose_rotation,
    die,
    focals_from_intrinsics,
    load_frame,
    log,
    nominal_angles,
    progress,
    rmat,
    upright,
)


def build(width, frames_dir, poses, yaw_dir, pitch_sign, hfov_deg, power=2.0):
    """Reproject all frames into an equirect pano. Returns (pano, coverage%, mask)."""
    w = width
    h = width // 2

    # equirect ray grid (world directions), +Y up, +Z at lon=lat=0.
    u = (np.arange(w) + 0.5) / w
    v = (np.arange(h) + 0.5) / h
    lon = (u * 2 - 1) * math.pi  # -pi..pi
    lat = (0.5 - v) * math.pi  # +pi/2..-pi/2
    lon2, lat2 = np.meshgrid(lon, lat)
    clat = np.cos(lat2)
    dx = (clat * np.sin(lon2)).astype(np.float32)
    dy = (np.sin(lat2)).astype(np.float32)
    dz = (clat * np.cos(lon2)).astype(np.float32)
    d = np.stack([dx.ravel(), dy.ravel(), dz.ravel()], 0)  # 3 x N

    n = h * w
    accum = np.zeros((n, 3), np.float32)
    wsum = np.zeros((n,), np.float32)
    cover = np.zeros((n,), np.uint8)

    # Determine which frame indices to process.
    if poses is not None:
        indices = [int(p["index"]) for p in poses]
        pose_by_index = {int(p["index"]): p for p in poses}
        angles = None
    else:
        # Pattern-aware fallback: pick the angle table from the number of
        # frames actually present (16 legacy / 28 densified / other WARN+ring).
        n_frames = count_frames(frames_dir) or 16
        angles = nominal_angles(n_frames, yaw_dir, pitch_sign)
        indices = list(range(len(angles)))
        pose_by_index = None

    processed = 0
    total = len(indices)
    for k, i in enumerate(indices):
        # Per-frame reprojection spans PROGRESS 5..70 (blend/inpaint/write take
        # the rest — see main()).
        progress(5 + 65 * k / total)
        img = load_frame(frames_dir, i)
        if img is None:
            log(f"frame {i}: missing, skipped")
            continue
        img = upright(img)
        hf, wf = img.shape[:2]

        if pose_by_index is not None:
            p = pose_by_index[i]
            try:
                r_proj = derive_pose_rotation(p["transform"])
                intr = p.get("intrinsics")
                if intr is not None:
                    focal_x, focal_y = focals_from_intrinsics(intr, wf, hf)
                else:
                    focal_x = focal_y = (wf / 2.0) / math.tan(math.radians(hfov_deg) / 2.0)
            except (KeyError, ValueError, TypeError) as exc:
                die(f"frame {i}: invalid pose ({exc})")
            # forward direction in world = row 2 of R_proj; its latitude tells
            # us whether this is a pole (zenith/nadir) frame.
            fwd_lat = math.degrees(math.asin(max(-1.0, min(1.0, float(r_proj[2, 1])))))
            is_pole = abs(fwd_lat) > POLE_LAT_DEG
            label = f"pose(lat={fwd_lat:.0f})"
        else:
            yaw, pitch, roll = angles[i]
            r_proj = rmat(yaw, pitch, roll).T  # world -> camera
            focal_x = focal_y = (wf / 2.0) / math.tan(math.radians(hfov_deg) / 2.0)
            # Pattern-independent pole detection (zenith/nadir at +/-90).
            is_pole = abs(pitch) > POLE_LAT_DEG
            label = f"pose(y={yaw:.0f},p={pitch:.0f})"

        dc = r_proj @ d  # projection-camera-frame rays, 3xN
        zc = dc[2]
        valid = zc > 1e-6
        px = np.full(d.shape[1], -1.0, np.float32)
        py = np.full(d.shape[1], -1.0, np.float32)
        px[valid] = focal_x * dc[0, valid] / zc[valid] + wf / 2.0
        py[valid] = hf / 2.0 - focal_y * dc[1, valid] / zc[valid]
        inb = valid & (px >= 0) & (px < wf - 1) & (py >= 0) & (py < hf - 1)
        if inb.sum() == 0:
            log(f"frame {i}: 0 px")
            continue

        # bilinear sample via remap on the in-bounds subset (reshaped to 2D).
        mx = px[inb].astype(np.float32)
        my = py[inb].astype(np.float32)
        m = mx.shape[0]
        pad = (-m) % REMAP_CHUNK
        mxp = np.concatenate([mx, np.zeros(pad, np.float32)]).reshape(-1, REMAP_CHUNK)
        myp = np.concatenate([my, np.zeros(pad, np.float32)]).reshape(-1, REMAP_CHUNK)
        sampg = cv2.remap(img, mxp, myp, cv2.INTER_LINEAR)
        samp = sampg.reshape(-1, 3)[:m]

        # feather weight: center falloff in normalized image coords.
        nx = (px[inb] - wf / 2.0) / (wf / 2.0)
        ny = (py[inb] - hf / 2.0) / (hf / 2.0)
        wc = np.clip(1 - np.abs(nx), 0, 1) * np.clip(1 - np.abs(ny), 0, 1)
        weight = (wc ** power).astype(np.float32)
        if is_pole:  # pole frames dominate their caps to avoid smeared bleed.
            weight *= POLE_BOOST

        idx = np.nonzero(inb)[0]
        accum[idx] += samp.astype(np.float32) * weight[:, None]
        wsum[idx] += weight
        cover[idx] = 1
        processed += 1
        log(f"frame {i}: {label} covered {int(inb.sum())} px")

    if processed == 0:
        die(f"no usable frames found in {frames_dir}")

    progress(70)  # reprojection done; feather-blend normalization next.
    out = np.zeros((n, 3), np.float32)
    nz = wsum > 0
    out[nz] = accum[nz] / wsum[nz, None]
    pano = out.reshape(h, w, 3).astype(np.uint8)
    covpct = 100.0 * cover.mean()
    mask = (cover.reshape(h, w) == 0).astype(np.uint8) * 255
    return pano, covpct, mask


def fill_holes(pano, mask):
    """Inpaint residual holes at reduced res (holes are large plain surfaces),
    then composite the filled pixels back into the full-res pano."""
    h, w = pano.shape[:2]
    sw = 2048
    sh = sw * h // w
    ps = cv2.resize(pano, (sw, sh))
    ms = cv2.resize(mask, (sw, sh), interpolation=cv2.INTER_NEAREST)
    ms = cv2.dilate(ms, np.ones((5, 5), np.uint8), iterations=1)
    filled = cv2.inpaint(ps, ms, 7, cv2.INPAINT_TELEA)
    fu = cv2.resize(filled, (w, h))
    m3 = (mask > 0)[:, :, None]
    return np.where(m3, fu, pano)
