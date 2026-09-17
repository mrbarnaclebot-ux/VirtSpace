# VirtSpace backend — single image for BOTH services (API + worker).
# Lives at repo root because Railway builds with the upload root as context.
# `npm start` dispatches on SERVICE_ENTRY:  node dist/${SERVICE_ENTRY:-server}.js
#   SERVICE_ENTRY=server  → Fastify API      (default)
#   SERVICE_ENTRY=worker  → job queue worker (runs the Python stitcher)
#
# The worker shells out to stitcher/reproject.py, so this image ships Python 3 +
# numpy + opencv-python-headless alongside Node. The API service never invokes
# Python but shares the same image for operational simplicity.

FROM node:22-slim

# --- OS deps: Python + pip (opencv-headless needs libGL/libglib at runtime) ---
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 \
      python3-pip \
      python3-venv \
      libgl1 \
      libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# --- Python deps into an isolated venv on PATH (avoids PEP 668 conflicts) -----
ENV VIRTUAL_ENV=/opt/venv
RUN python3 -m venv "$VIRTUAL_ENV"
ENV PATH="$VIRTUAL_ENV/bin:$PATH"
# PYTHON_BIN defaults to python3, which now resolves to the venv interpreter.
COPY backend/stitcher/requirements.txt ./stitcher/requirements.txt
RUN pip install --no-cache-dir -r stitcher/requirements.txt

# --- Node build ---------------------------------------------------------------
# Install ALL deps (incl. dev) to compile TypeScript, then prune to prod-only so
# the final image doesn't carry the toolchain.
COPY backend/package.json backend/package-lock.json* ./
RUN npm ci
COPY backend/tsconfig.json ./
COPY backend/src ./src
COPY backend/stitcher ./stitcher
# Committed migration SQL + snapshots. drizzle-kit is a devDependency and is
# pruned below, so the release step runs dist/migrate.js (drizzle-orm's own
# migrator) against THIS folder — without it, code ships ahead of schema.
COPY backend/drizzle ./drizzle
RUN npm run build && npm prune --omit=dev

ENV NODE_ENV=production
# SERVICE_ENTRY selects the entrypoint at runtime (server | worker).
CMD ["npm", "start"]
