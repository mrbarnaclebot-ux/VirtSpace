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


def focals_from_intrinsics(intrinsics, wf, hf):
    """Per-axis focal lengths (pixels) for the UPRIGHT wf x hf image.

    `intrinsics` is 9 numbers ROW-MAJOR: [fx,0,cx, 0,fy,cy, 0,0,1], expressed in
    the ARKit-native landscape sensor frame. We recover the native FOVs
    (resolution-independent) and re-derive focals for the actual upright image
    so a resolution mismatch between intrinsics and frame does not matter.
    After the 90 deg CW rotation the upright WIDTH spans the native VERTICAL FOV
    and the upright HEIGHT spans the native HORIZONTAL FOV.
    """
    k = [float(x) for x in intrinsics]
    if len(k) != 9:
        raise ValueError(f"intrinsics must have 9 elements, got {len(k)}")
    fx, fy, cx, cy = k[0], k[4], k[2], k[5]
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
    else:
        indices = list(range(16))
        pose_by_index = None

    processed = 0
    for i in indices:
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
            yaw, pitch, roll = nominal_pose(i, yaw_dir, pitch_sign)
            r_proj = rmat(yaw, pitch, roll).T  # world -> camera
            focal_x = focal_y = (wf / 2.0) / math.tan(math.radians(hfov_deg) / 2.0)
            is_pole = i in (14, 15)
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


def load_poses(path):
    """Load poses.json (the captures.poses_json array) and normalize it to a
    list of pose dicts with integer indices and a transform. Returns None if the
    file is absent; dies on malformed content."""
    if not path:
        return None
    if not os.path.exists(path):
        die(f"poses file not found: {path}")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        die(f"failed to read poses: {exc}")
    if not isinstance(data, list) or len(data) == 0:
        die("poses.json must be a non-empty array")
    for p in data:
        if not isinstance(p, dict) or "transform" not in p or "index" not in p:
            die("each pose needs at least 'index' and 'transform'")
    return sorted(data, key=lambda p: int(p["index"]))


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

    poses = load_poses(args.poses)
    mode = "poses" if poses is not None else "nominal-fallback"
    log(f"reproject: mode={mode} width={args.width} frames_dir={args.frames_dir}")

    pano, cov, mask = build(
        args.width, args.frames_dir, poses,
        args.yaw_dir, args.pitch_sign, args.hfov,
    )
    log(f"coverage {cov:.1f}% before inpaint")
    pano = fill_holes(pano, mask)

    out_dir = os.path.dirname(os.path.abspath(args.out))
    os.makedirs(out_dir, exist_ok=True)
    if not cv2.imwrite(args.out, pano, [cv2.IMWRITE_JPEG_QUALITY, 92]):
        die(f"failed to write pano: {args.out}")
    log(f"wrote pano {pano.shape[1]}x{pano.shape[0]} -> {args.out}")

    if args.preview_out:
        preview = cv2.resize(pano, (2000, 1000), interpolation=cv2.INTER_AREA)
        pv_dir = os.path.dirname(os.path.abspath(args.preview_out))
        os.makedirs(pv_dir, exist_ok=True)
        if not cv2.imwrite(args.preview_out, preview, [cv2.IMWRITE_JPEG_QUALITY, 90]):
            die(f"failed to write preview: {args.preview_out}")
        log(f"wrote preview 2000x1000 -> {args.preview_out}")

    log("reproject: done")


if __name__ == "__main__":
    main()
