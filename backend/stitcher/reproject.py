#!/usr/bin/env python3
"""VirtSpace production panorama stitcher (Phase 0.5 winning algorithm).

Ports the gate-winning rotation-only reprojection spike into a production CLI.
Given a directory of ARKit-native landscape frames (and, optionally, the
per-frame ARKit poses), it rotates each frame upright, reprojects it onto an
equirectangular sphere using the camera orientation, feather-blends the
overlaps, inpaints the residual holes and writes an 8192x4096 (2:1) pano.

Two orientation modes:

  * poses provided  -> derive each frame's orientation from its ARKit 4x4
                       camera-to-world transform and its intrinsics-derived FOV
                       (translation is ignored; this is a pure rotation pano).
  * poses absent    -> fall back to the nominal 16-target guided-capture angles
                       with the winning parameters (pitch_sign=-1, hfov=52),
                       exactly as the spike did.

Coordinate conventions (see derive_pose_rotation for the full derivation):
  Equirect world  : right-handed, +Y up (gravity), +Z at lon=0/lat=0.
  ARKit camera    : right-handed, +X image-right, +Y image-up, optical axis
                    -Z (camera looks down -Z) in the landscape sensor frame.
  Projection cam  : left-handed pinhole used by the reprojection equations,
                    +X right, +Y up, forward +Z, image +y downward.

Usage:
  reproject.py --frames-dir DIR --out pano.jpg [--poses poses.json]
               [--width 8192] [--preview-out pano_preview.jpg]

On success: prints progress lines to stdout and exits 0.
On failure: prints a message to stderr and exits non-zero.
"""

import argparse
import json
import math
import os
import re
import sys

import cv2
import numpy as np

# Constant mapping from ARKit camera axes to the projection-camera axes, applied
# AFTER the frame is rotated 90 deg clockwise into portrait-upright. Derivation:
#   The optical axis is ARKit -Z, which must become projection-forward +Z.
#   Rotating the landscape image 90 deg CW makes native "up" (+Y_ak) the new
#   image-right, and native "right" (+X_ak) the new image-down; hence:
#       X_proj (right) = +Y_ak
#       Y_proj (up)    = -X_ak
#       Z_proj (fwd)   = -Z_ak
#   Rows of M are those projection axes expressed in ARKit-camera coordinates.
#   det(M) = -1 is EXPECTED: it converts the right-handed ARKit camera into the
#   left-handed projection convention (forward = +Z), not a bug.
ARKIT_TO_PROJ = np.array(
    [[0.0, 1.0, 0.0], [-1.0, 0.0, 0.0], [0.0, 0.0, -1.0]], dtype=np.float64
)

# Winning fallback parameters (spike Phase 0.5 gate).
DEFAULT_HFOV = 52.0
DEFAULT_YAW_DIR = 1
DEFAULT_PITCH_SIGN = -1

REMAP_CHUNK = 8192  # cv2.remap 2D grid width cap (stay under SHRT_MAX).
POLE_LAT_DEG = 60.0  # frames looking steeper than this get the pole weight boost.
POLE_BOOST = 8.0


def log(msg):
    print(msg, flush=True)


def progress(pct):
    """Machine-readable progress line for the worker (stdout stream parsing).

    Format is exactly `PROGRESS <0-100>` on its own line; the Node worker
    (src/worker.ts) parses these incrementally and mirrors them into
    worlds.progress. Human log lines are unaffected.
    """
    print(f"PROGRESS {int(max(0, min(100, pct)))}", flush=True)


def die(msg, code=1):
    print(f"reproject: error: {msg}", file=sys.stderr, flush=True)
    sys.exit(code)


# --- nominal capture geometry (fallback, no poses) --------------------------
# yaw about world up(+Y), pitch about world +X, roll about +Z. degrees.
# horizon ring 0-7 at 45 deg apart, +45 pitch ring 8-11 at 90, -45 pitch 12-13
# at 0/180, 14 zenith (up), 15 nadir (down).
def nominal_pose(i, yaw_dir, pitch_sign):
    if i < 8:
        return (yaw_dir * i * 45.0, 0.0, 0.0)
    if 8 <= i <= 11:
        return (yaw_dir * (i - 8) * 90.0, pitch_sign * 45.0, 0.0)
    if i == 12:
        return (0.0, -pitch_sign * 45.0, 0.0)
    if i == 13:
        return (180.0, -pitch_sign * 45.0, 0.0)
    if i == 14:
        return (0.0, pitch_sign * 90.0, 0.0)  # zenith (up)
    if i == 15:
        return (0.0, -pitch_sign * 90.0, 0.0)  # nadir (down)
    # Beyond the nominal 16 targets we have no angle; treat as horizon spillover.
    return (yaw_dir * (i % 8) * 45.0, 0.0, 0.0)


def nominal_angles(frame_count, yaw_dir, pitch_sign):
    """Per-frame (yaw, pitch, roll) table for the pose-less fallback, selected
    by capture pattern:

      16 -> legacy layout (8 horizon @45 / 4 up @90 / 2 down / zenith / nadir)
      28 -> densified layout, same order as the iOS TargetLayout:
            12 horizon @30 / 8 up(+45) @45 / 6 down(-45) @60 / zenith / nadir
      other -> WARN and evenly distribute a horizon-only ring.

    pitch_sign follows the legacy convention (winning params use -1, i.e.
    "up" rings get pitch_sign * 45).
    """
    if frame_count == 16:
        return [nominal_pose(i, yaw_dir, pitch_sign) for i in range(16)]
    if frame_count == 28:
        angles = []
        for i in range(12):  # horizon ring, every 30 deg
            angles.append((yaw_dir * i * 30.0, 0.0, 0.0))
        for i in range(8):  # upper ring (+45), every 45 deg
            angles.append((yaw_dir * i * 45.0, pitch_sign * 45.0, 0.0))
        for i in range(6):  # lower ring (-45), every 60 deg
            angles.append((yaw_dir * i * 60.0, -pitch_sign * 45.0, 0.0))
        angles.append((0.0, pitch_sign * 90.0, 0.0))  # zenith
        angles.append((0.0, -pitch_sign * 90.0, 0.0))  # nadir
        return angles
    log(
        f"WARN unknown capture pattern ({frame_count} frames) — "
        "using an even horizon-only ring"
    )
    n = max(1, int(frame_count))
    return [(yaw_dir * i * (360.0 / n), 0.0, 0.0) for i in range(n)]


def rmat(yaw, pitch, roll):
    """Camera->world rotation for nominal yaw/pitch/roll (degrees)."""
    y, p, r = map(math.radians, (yaw, pitch, roll))
    cy, sy = math.cos(y), math.sin(y)
    cp, sp = math.cos(p), math.sin(p)
    cr, sr = math.cos(r), math.sin(r)
    ry = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
    rx = np.array([[1, 0, 0], [0, cp, -sp], [0, sp, cp]])
    rz = np.array([[cr, -sr, 0], [sr, cr, 0], [0, 0, 1]])
    return ry @ rx @ rz


def derive_pose_rotation(transform):
    """R_proj (world->projection-camera) from an ARKit 4x4 transform.

    `transform` is 16 numbers in COLUMN-MAJOR order (ARKit's simd_float4x4),
    camera-to-world. Its upper-left 3x3 R_ak maps ARKit-camera -> world.
    R_ak.T maps world -> ARKit-camera; ARKIT_TO_PROJ then rebases into the
    upright projection camera. Translation (column 3) is intentionally ignored.
    """
    t = [float(x) for x in transform]
    if len(t) != 16:
        raise ValueError(f"transform must have 16 elements, got {len(t)}")
    # column-major: element(row, col) = t[col * 4 + row]
    r_ak = np.array(
        [
            [t[0], t[4], t[8]],
            [t[1], t[5], t[9]],
            [t[2], t[6], t[10]],
        ],
        dtype=np.float64,
    )
    return ARKIT_TO_PROJ @ r_ak.T


def intrinsics_fx_fy_cx_cy(intrinsics):
    """Convention-tolerant (fx, fy, cx, cy) from 9 intrinsics floats.

    The iOS client flattens ARKit's simd_float3x3 COLUMN-major —
    [fx,0,0, 0,fy,0, cx,cy,1] (cx at [6], cy at [7]) — while this script
    historically read ROW-major [fx,0,cx, 0,fy,cy, 0,0,1] (cx at [2], cy at
    [5]); that mismatch made real captures look like "zeroed" centers. fx/fy
    sit on the diagonal ([0]/[4]) in BOTH conventions; for the principal point
    prefer the row-major slot and fall back to the column-major one when the
    row-major slot is non-positive. Raises ValueError on wrong length or
    non-numeric values; positivity is the CALLER's check (a non-positive
    result after both fallbacks means genuinely unusable intrinsics).
    """
    k = [float(x) for x in intrinsics]
    if len(k) != 9:
        raise ValueError(f"intrinsics must have 9 elements, got {len(k)}")
    fx, fy = k[0], k[4]
    cx = k[2] if k[2] > 0 else k[6]
    cy = k[5] if k[5] > 0 else k[7]
    return fx, fy, cx, cy


def focals_from_intrinsics(intrinsics, wf, hf):
    """Per-axis focal lengths (pixels) for the UPRIGHT wf x hf image.

    `intrinsics` is 9 numbers (row- OR column-major — see
    intrinsics_fx_fy_cx_cy), expressed in the ARKit-native landscape sensor
    frame. We recover the native FOVs (resolution-independent) and re-derive
    focals for the actual upright image so a resolution mismatch between
    intrinsics and frame does not matter. After the 90 deg CW rotation the
    upright WIDTH spans the native VERTICAL FOV and the upright HEIGHT spans
    the native HORIZONTAL FOV.
    """
    fx, fy, cx, cy = intrinsics_fx_fy_cx_cy(intrinsics)
    if fx <= 0 or fy <= 0 or cx <= 0 or cy <= 0:
        raise ValueError("intrinsics fx/fy/cx/cy must be positive")
    ref_w, ref_h = 2.0 * cx, 2.0 * cy  # native landscape sensor extent
    hfov_native = 2.0 * math.atan(ref_w / (2.0 * fx))
    vfov_native = 2.0 * math.atan(ref_h / (2.0 * fy))
    focal_x = (wf / 2.0) / math.tan(vfov_native / 2.0)  # upright width  <- native vertical
    focal_y = (hf / 2.0) / math.tan(hfov_native / 2.0)  # upright height <- native horizontal
    return focal_x, focal_y


def load_frame(frames_dir, i):
    """Read frame i, tolerating zero-padded / alternate extensions. Returns the
    ARKit-native (landscape) BGR image, or None if the frame does not exist."""
    candidates = (
        f"frame_{i}.jpg",
        f"frame_{i:02d}.jpg",
        f"frame_{i}.jpeg",
        f"frame_{i}.png",
        f"frame_{i:02d}.png",
    )
    for name in candidates:
        path = os.path.join(frames_dir, name)
        if os.path.exists(path):
            img = cv2.imread(path)
            if img is None:
                die(f"failed to decode frame: {path}")
            return img
    return None


def upright(img):
    """Rotate an ARKit-native landscape frame 90 deg clockwise to portrait."""
    return cv2.rotate(img, cv2.ROTATE_90_CLOCKWISE)


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


FRAME_NAME_RE = re.compile(r"^frame_\d+\.(jpg|jpeg|png)$", re.IGNORECASE)


def count_frames(frames_dir):
    """Number of frame_<i>.jpg/png files present, or None if unreadable."""
    try:
        return sum(1 for name in os.listdir(frames_dir) if FRAME_NAME_RE.match(name))
    except OSError:
        return None


def load_poses(path):
    """Load poses.json (the captures.poses_json array).

    Returns (poses, None) on success or (None, reason) when the file is
    missing/unreadable/malformed. Pose problems are NEVER fatal — the caller
    WARNs and falls back to the nominal-angle path (a legacy client once
    shipped zeroed intrinsics and hard-failing here burned every retry)."""
    if not path:
        return None, None
    if not os.path.exists(path):
        return None, f"poses file not found: {path}"
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        return None, f"failed to read poses: {exc}"
    if not isinstance(data, list) or len(data) == 0:
        return None, "poses.json must be a non-empty array"
    return data, None


def pose_validation_error(poses, frame_count=None):
    """Return a human-readable reason when the pose array is unusable, else
    None. Checks entry shape, transform (16 numbers), intrinsics (9 numbers
    with positive fx/fy/cx/cy) and — when known — pose count vs frame count.
    Mirrors everything build() would otherwise die on mid-run."""
    if frame_count is not None and frame_count > 0 and len(poses) != frame_count:
        return f"pose count {len(poses)} != frame count {frame_count}"
    for p in poses:
        if not isinstance(p, dict) or "transform" not in p or "index" not in p:
            return "each pose needs at least 'index' and 'transform'"
        try:
            i = int(p["index"])
        except (TypeError, ValueError):
            return f"non-integer pose index {p.get('index')!r}"
        t = p["transform"]
        if not isinstance(t, (list, tuple)) or len(t) != 16:
            return f"frame {i}: transform must have 16 elements"
        try:
            [float(x) for x in t]
        except (TypeError, ValueError):
            return f"frame {i}: non-numeric transform"
        k = p.get("intrinsics")
        if k is not None:
            if not isinstance(k, (list, tuple)) or len(k) != 9:
                return f"frame {i}: intrinsics must have 9 elements"
            try:
                # Convention-tolerant (row- or column-major) extraction; only
                # when BOTH principal-point candidates are non-positive is the
                # pose genuinely invalid.
                fx, fy, cx, cy = intrinsics_fx_fy_cx_cy(k)
            except (TypeError, ValueError):
                return f"frame {i}: non-numeric intrinsics"
            if fx <= 0 or fy <= 0 or cx <= 0 or cy <= 0:
                return f"frame {i}: non-positive intrinsics"
    return None


def main(argv=None):
    ap = argparse.ArgumentParser(description="VirtSpace equirect pano stitcher")
    ap.add_argument("--frames-dir", required=True, help="dir of ARKit-native landscape frame_N.jpg")
    ap.add_argument("--out", required=True, help="output pano.jpg path")
    ap.add_argument("--poses", default=None, help="optional poses.json (captures.poses_json array)")
    ap.add_argument("--width", type=int, default=8192, help="pano width (height = width/2)")
    ap.add_argument("--preview-out", default=None, help="optional 2000x1000 preview jpg path")
    # Nominal-fallback tuning (defaults are the Phase 0.5 winning parameters).
    ap.add_argument("--hfov", type=float, default=DEFAULT_HFOV)
    ap.add_argument("--yaw-dir", type=int, default=DEFAULT_YAW_DIR)
    ap.add_argument("--pitch-sign", type=int, default=DEFAULT_PITCH_SIGN)
    args = ap.parse_args(argv)

    if args.width < 2 or args.width % 2 != 0:
        die("--width must be a positive even integer")
    if not os.path.isdir(args.frames_dir):
        die(f"frames dir not found: {args.frames_dir}")

    # Pose problems are never fatal: WARN and fall back to the nominal-angle
    # path rather than exit non-zero (a hard fail here burns every job retry
    # on a permanently-bad payload, e.g. a legacy client's zeroed intrinsics).
    poses, reason = load_poses(args.poses)
    if poses is not None and reason is None:
        reason = pose_validation_error(poses, count_frames(args.frames_dir))
        if reason is None:
            poses = sorted(poses, key=lambda p: int(p["index"]))
    if reason is not None:
        log(f"WARN poses invalid ({reason}) — falling back to nominal angles")
        poses = None

    mode = "poses" if poses is not None else "nominal-fallback"
    log(f"reproject: mode={mode} width={args.width} frames_dir={args.frames_dir}")
    progress(0)

    pano, cov, mask = build(
        args.width, args.frames_dir, poses,
        args.yaw_dir, args.pitch_sign, args.hfov,
    )
    log(f"coverage {cov:.1f}% before inpaint")
    progress(75)  # blend done; inpainting residual holes next.
    pano = fill_holes(pano, mask)
    progress(85)  # inpaint done; encoding + writing outputs next.

    out_dir = os.path.dirname(os.path.abspath(args.out))
    os.makedirs(out_dir, exist_ok=True)
    if not cv2.imwrite(args.out, pano, [cv2.IMWRITE_JPEG_QUALITY, 92]):
        die(f"failed to write pano: {args.out}")
    log(f"wrote pano {pano.shape[1]}x{pano.shape[0]} -> {args.out}")
    progress(95)

    if args.preview_out:
        preview = cv2.resize(pano, (2000, 1000), interpolation=cv2.INTER_AREA)
        pv_dir = os.path.dirname(os.path.abspath(args.preview_out))
        os.makedirs(pv_dir, exist_ok=True)
        if not cv2.imwrite(args.preview_out, preview, [cv2.IMWRITE_JPEG_QUALITY, 90]):
            die(f"failed to write preview: {args.preview_out}")
        log(f"wrote preview 2000x1000 -> {args.preview_out}")

    progress(100)
    log("reproject: done")


if __name__ == "__main__":
    main()
