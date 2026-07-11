# VirtSpace Phase 0 Spike — World Labs Marble → Spark viewer

Phase 0 de-risking spike. Proves the full path from an equirectangular panorama
to an explorable Gaussian-splat world rendered in a WebView-class browser:

1. `spike.py` drives the **World Labs Marble API** to turn a pano into a
   downloadable SPZ splat world.
2. `viewer.html` loads that SPZ with **Spark + three.js** and lets you look
   around (drag) and move (on-screen joystick) — the Spark-in-WebView proof.

**Proven live 2026-07-12:** a `marble-1.0-draft` world generated in ~16 s; the
SPZ at the 500k tier was ~6.1 MB.

## Prerequisites

- Python 3 (standard library only — no pip installs needed).
- A World Labs API key, resolved in this order:
  1. `WORLDLABS_API_KEY` environment variable (takes precedence), or
  2. a `worldlabs_api` (also accepts `worldlabs_api_key` / `wlt_api_key`) entry
     in the repo-root `.env` (the directory containing `spec-doc.md`, found by
     walking up from the script).

## Stage-by-stage usage

Run from the repo root. State persists between stages in `state.json` (kept in
this directory), so each stage is a separate invocation.

```bash
# 1. upload the pano (FREE). Default pano is ./pano_test.jpg (cwd);
#    optionally pass a path as the 2nd arg.
python3 tools/spike/spike.py upload
python3 tools/spike/spike.py upload /path/to/my_pano.jpg

# 2. generate the world  ⚠️ SPENDS ~150 credits (~$0.12) with marble-1.0-draft
python3 tools/spike/spike.py generate

# 3. poll the operation until done (FREE)
python3 tools/spike/spike.py poll

# 4. fetch the world + download world.spz next to viewer.html (FREE)
python3 tools/spike/spike.py fetch
```

> **⚠️ Cost warning:** only the `generate` stage spends credits —
> `marble-1.0-draft` costs ~150 credits (≈ $0.12 per world). `upload`, `poll`,
> and `fetch` are free. Run `generate` only when you mean to spend.

### View the result

`viewer.html` fetches `world.spz`, and browsers block `fetch()` on `file://`
URLs, so it must be served over http:

```bash
cd tools/spike && python3 -m http.server
# then open http://localhost:8000/viewer.html
```

## Getting a test pano

You need a **2:1 equirectangular** panorama (roughly **8192 × 4096**) saved as a
JPG. [Poly Haven](https://polyhaven.com/hdris) is a good source — its HDRIs are
**CC0** (public domain, no attribution required). Download an equirectangular
image, resize/convert to ~8192 × 4096 JPG, and point the `upload` stage at it.

## What is / isn't committed

`world.spz` and the pano JPGs are **intentionally NOT committed** — they are
regenerable binaries, not source. `.gitignore` here excludes them (and
`state.json`). Regenerate them any time by re-running the stages above.
