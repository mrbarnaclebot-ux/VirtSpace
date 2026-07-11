#!/usr/bin/env python3
"""
World Labs Marble API spike.

WHAT IT DOES
  Drives the World Labs Marble API end to end to turn an equirectangular
  panorama into a downloadable Gaussian-splat world (SPZ). Each pipeline
  stage is run explicitly so credits are only spent when you mean to.

  Stages:
    upload   : prepare_upload + PUT the pano (FREE) -> writes media_asset_id
    generate : worlds:generate with marble-1.0-draft -> writes operation_id
    poll     : poll operation until done (FREE) -> writes world_id
    fetch    : get world + download SPZ 500k (FREE) -> writes world.spz

  State is persisted to state.json (in this script's directory) between
  stages, so you can run each stage in a separate invocation.

COST WARNING
  The 'generate' stage SPENDS credits: marble-1.0-draft costs ~150 credits
  (approximately $0.12 per world). upload / poll / fetch are all free.
  Run 'generate' only when you intend to spend.

AUTH
  The API key is resolved in this order:
    1. WORLDLABS_API_KEY environment variable (takes precedence)
    2. A .env file at the repo root (the directory containing spec-doc.md),
       found by walking up from this script's location. Accepted keys in
       .env: worldlabs_api, worldlabs_api_key, wlt_api_key.

USAGE EXAMPLES
    # 1. Upload the default pano (./pano_test.jpg) -- free
    python3 tools/spike/spike.py upload

    # ...or upload a specific pano file (optional 2nd arg)
    python3 tools/spike/spike.py upload /path/to/my_pano.jpg

    # 2. Generate the world -- SPENDS ~150 credits (~$0.12)
    python3 tools/spike/spike.py generate

    # 3. Poll until the operation is done -- free
    python3 tools/spike/spike.py poll

    # 4. Fetch the world + download world.spz -- free
    python3 tools/spike/spike.py fetch

    # Provide the key inline instead of using .env:
    WORLDLABS_API_KEY=wlt_... python3 tools/spike/spike.py upload
"""
import sys, os, json, time, urllib.request, urllib.error, pathlib

HERE = pathlib.Path(__file__).resolve().parent
STATE = HERE / "state.json"
BASE = "https://api.worldlabs.ai"
MODEL = "marble-1.0-draft"  # cheapest: 150 credits


def find_repo_root(start):
    """Walk up from `start` looking for the directory containing spec-doc.md."""
    for d in [start, *start.parents]:
        if (d / "spec-doc.md").exists():
            return d
    return None


def load_key():
    # 1. Environment variable takes precedence over .env
    env_key = os.environ.get("WORLDLABS_API_KEY")
    if env_key and env_key.strip():
        return env_key.strip()
    # 2. Fall back to .env at the repo root (dir containing spec-doc.md)
    root = find_repo_root(HERE)
    if root is None:
        raise SystemExit(
            "Could not locate repo root (no spec-doc.md found walking up from "
            f"{HERE}); set WORLDLABS_API_KEY instead."
        )
    env = root / ".env"
    if not env.exists():
        raise SystemExit(
            f"No .env found at repo root {root}; set WORLDLABS_API_KEY instead."
        )
    for line in env.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        if k.strip().lower() in ("worldlabs_api", "worldlabs_api_key", "wlt_api_key"):
            return v.strip().strip('"').strip("'")
    raise SystemExit(f"No worldlabs_api key found in {env}")


KEY = load_key()
HDRS = {"WLT-Api-Key": KEY, "Content-Type": "application/json"}


def pano_path():
    """Pano path for the upload stage: optional 2nd CLI arg, else ./pano_test.jpg (cwd)."""
    if len(sys.argv) > 2:
        return pathlib.Path(sys.argv[2])
    return pathlib.Path("pano_test.jpg")


def state():
    return json.loads(STATE.read_text()) if STATE.exists() else {}
def save(d):
    s = state(); s.update(d); STATE.write_text(json.dumps(s, indent=2)); return s

def req(method, url, data=None, headers=None, raw=None):
    body = raw if raw is not None else (json.dumps(data).encode() if data is not None else None)
    r = urllib.request.Request(url, data=body, method=method, headers=headers or HDRS)
    try:
        with urllib.request.urlopen(r, timeout=120) as resp:
            b = resp.read()
            return resp.status, (json.loads(b) if b and resp.headers.get("content-type","").startswith("application/json") else b)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")

def stage_upload():
    pano = pano_path()
    if not pano.exists():
        raise SystemExit(f"pano not found: {pano} (pass a path as the 2nd arg or place pano_test.jpg in cwd)")
    print("[upload] prepare_upload...")
    st, body = req("POST", f"{BASE}/marble/v1/media-assets:prepare_upload",
                   {"file_name": "pano_test.jpg", "kind": "image", "extension": "jpg"})
    print("  status", st); print(json.dumps(body, indent=2)[:1200] if isinstance(body, dict) else body)
    if st != 200 or not isinstance(body, dict):
        raise SystemExit("prepare_upload failed")
    ma = body["media_asset"].get("media_asset_id") or body["media_asset"]["id"]
    up = body["upload_info"]
    url = up["upload_url"]; method = up.get("upload_method", "PUT")
    req_hdrs = up.get("required_headers", {}) or {}
    print(f"[upload] {method} {len(pano.read_bytes())} bytes with headers {list(req_hdrs.keys())}")
    put_hdrs = dict(req_hdrs); put_hdrs.setdefault("Content-Type", "image/jpeg")
    st2, body2 = req(method, url, raw=pano.read_bytes(), headers=put_hdrs)
    print("  upload status", st2, str(body2)[:300])
    if st2 not in (200, 201):
        raise SystemExit("PUT upload failed")
    save({"media_asset_id": ma})
    print("[upload] OK media_asset_id =", ma)

def stage_generate():
    ma = state().get("media_asset_id")
    if not ma: raise SystemExit("run upload first")
    print(f"[generate] worlds:generate model={MODEL} is_pano=true (SPENDS 150 credits)")
    st, body = req("POST", f"{BASE}/marble/v1/worlds:generate", {
        "display_name": "VirtSpace Spike - Kloofendal",
        "model": MODEL,
        "world_prompt": {
            "type": "image",
            "image_prompt": {"source": "media_asset", "media_asset_id": ma},
            "is_pano": True,
        },
    })
    print("  status", st); print(json.dumps(body, indent=2)[:1500] if isinstance(body, dict) else body)
    if st != 200 or not isinstance(body, dict):
        raise SystemExit("generate failed")
    op = body.get("operation_id") or body.get("id") or body.get("name")
    save({"operation_id": op, "generate_response": body})
    print("[generate] OK operation_id =", op)

def stage_poll():
    op = state().get("operation_id")
    if not op: raise SystemExit("run generate first")
    t0 = time.time()
    while True:
        st, body = req("GET", f"{BASE}/marble/v1/operations/{op}")
        if not isinstance(body, dict):
            print("  poll status", st, str(body)[:300]); time.sleep(15); continue
        done = body.get("done")
        el = int(time.time()-t0)
        print(f"  [{el}s] status={st} done={done} {json.dumps({k:v for k,v in body.items() if k!='response'})[:200]}")
        if done:
            save({"operation_done": body})
            resp = body.get("response", {})
            wid = resp.get("world_id") or resp.get("id") or (resp.get("world") or {}).get("id")
            save({"world_id": wid})
            print("[poll] DONE world_id =", wid)
            print(json.dumps(resp, indent=2)[:2000])
            return
        time.sleep(15)

def stage_fetch():
    wid = state().get("world_id")
    if not wid: raise SystemExit("no world_id")
    st, body = req("GET", f"{BASE}/marble/v1/worlds/{wid}")
    print("[fetch] status", st)
    print(json.dumps(body, indent=2)[:3000] if isinstance(body, dict) else body)
    if not isinstance(body, dict): return
    save({"world": body})
    assets = body.get("assets", {})
    spz = (assets.get("splats", {}) or {}).get("spz_urls", {}) or {}
    url = spz.get("500k") or spz.get("100k") or spz.get("full_res")
    if url:
        out = HERE / "world.spz"
        print("[fetch] downloading SPZ ->", url[:80])
        urllib.request.urlretrieve(url, out)
        print("[fetch] saved", out, out.stat().st_size, "bytes")
    else:
        print("[fetch] no spz url found; keys:", list(assets.keys()))

if __name__ == "__main__":
    stage = sys.argv[1] if len(sys.argv) > 1 else ""
    {"upload": stage_upload, "generate": stage_generate,
     "poll": stage_poll, "fetch": stage_fetch}.get(stage, lambda: print("usage: spike.py upload|generate|poll|fetch"))()
