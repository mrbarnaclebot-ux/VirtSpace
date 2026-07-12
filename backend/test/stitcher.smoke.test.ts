import { describe, it, expect } from 'vitest';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// End-to-end smoke for stitcher/reproject.py. Runs ONLY when a Python with cv2
// + numpy is available (skipIf otherwise) — no network, no DB. Point it at a
// specific interpreter with STITCHER_TEST_PYTHON (e.g. a venv) if the default
// `python3` lacks the deps.
const PY = process.env.STITCHER_TEST_PYTHON ?? 'python3';

function pyHasDeps(): boolean {
  try {
    execFileSync(PY, ['-c', 'import cv2, numpy'], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

const available = pyHasDeps();
const script = fileURLToPath(new URL('../stitcher/reproject.py', import.meta.url));

describe.skipIf(!available)('reproject.py smoke', () => {
  it('produces a 2:1 pano from tiny synthetic frames + poses (width 512)', () => {
    const dir = mkdtempSync(path.join(tmpdir(), 'stitch-smoke-'));
    try {
      const framesDir = path.join(dir, 'frames');
      const posesPath = path.join(dir, 'poses.json');
      // Generate 3 solid-color landscape frames + synthetic ARKit poses via cv2.
      // Transforms are built as R_ak = R_nominal @ ARKIT_TO_PROJ so the stitcher's
      // pose math places them at yaw 0/120/240 around the horizon.
      const gen = `
import cv2, numpy as np, json, os, math
fd = ${JSON.stringify(framesDir)}
os.makedirs(fd, exist_ok=True)
colors = [(60,60,200),(60,200,60),(200,60,60)]
W, H = 640, 480
for i, c in enumerate(colors):
    img = np.zeros((H, W, 3), np.uint8); img[:] = c
    cv2.imwrite(os.path.join(fd, f'frame_{i}.jpg'), img)
def rot_y(a):
    ca, sa = math.cos(a), math.sin(a)
    return np.array([[ca,0,sa],[0,1,0],[-sa,0,ca]])
ARK = np.array([[0,1,0],[-1,0,0],[0,0,-1]], float)
poses = []
for i in range(3):
    R_ak = rot_y(math.radians(i*120)) @ ARK
    T = np.eye(4); T[:3,:3] = R_ak
    cm = [float(T[r,c]) for c in range(4) for r in range(4)]
    poses.append({'index': i, 'timestamp': i*0.1, 'transform': cm,
                  'intrinsics': [500,0,320,0,500,240,0,0,1], 'exposureLocked': True})
json.dump(poses, open(${JSON.stringify(posesPath)}, 'w'))
`;
      execFileSync(PY, ['-c', gen], { stdio: 'inherit' });

      const out = path.join(dir, 'pano.jpg');
      execFileSync(
        PY,
        [script, '--frames-dir', framesDir, '--poses', posesPath, '--out', out, '--width', '512'],
        { stdio: 'inherit' },
      );

      expect(existsSync(out)).toBe(true);
      const shape = execFileSync(
        PY,
        ['-c', `import cv2;im=cv2.imread(${JSON.stringify(out)});print(im.shape[1], im.shape[0])`],
        { encoding: 'utf8' },
      ).trim();
      expect(shape).toBe('512 256'); // 2:1 equirect
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
