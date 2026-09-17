import {
  creditsForModel,
  ProviderError,
  ProviderTimeoutError,
  type OperationStatus,
  type WorldAssets,
  type WorldGenProvider,
  type WorldMatch,
  type WorldModel,
} from './types.js';

// Live World Labs Marble provider. This is a faithful TypeScript port of
// tools/spike/spike.py (the LIVE-VERIFIED contract). Endpoint shapes, field
// names, and the tolerant fallbacks (media_asset.media_asset_id ?? .id, etc.)
// are copied deliberately — do not "clean up" without re-verifying live.
//
// Auth: header `WLT-Api-Key: <key>` (server-side only — never shipped in the
// app, spec §4/§14). Base URL https://api.worldlabs.ai.

const DEFAULT_BASE_URL = 'https://api.worldlabs.ai';
const DEFAULT_TIMEOUT_MS = 120_000; // matches spike.py urlopen timeout=120.

/** Injectable fetch (Node 24 global) so tests can assert request shaping. */
export type FetchLike = typeof fetch;

export interface WorldLabsOptions {
  apiKey: string;
  baseUrl?: string;
  fetchImpl?: FetchLike;
  timeoutMs?: number;
}

interface PrepareUploadResponse {
  media_asset?: { media_asset_id?: string; id?: string };
  upload_info?: {
    upload_url: string;
    upload_method?: string;
    required_headers?: Record<string, string> | null;
  };
}

export function createWorldLabsProvider(opts: WorldLabsOptions): WorldGenProvider {
  const baseUrl = (opts.baseUrl ?? DEFAULT_BASE_URL).replace(/\/$/, '');
  const doFetch: FetchLike = opts.fetchImpl ?? fetch;
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;

  const jsonHeaders = (): Record<string, string> => ({
    'WLT-Api-Key': opts.apiKey,
    'Content-Type': 'application/json',
  });

  // Core request helper with an AbortController timeout + typed errors.
  async function request(
    method: string,
    url: string,
    init?: { headers?: Record<string, string>; body?: string | Uint8Array },
  ): Promise<Response> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      return await doFetch(url, {
        method,
        headers: init?.headers ?? jsonHeaders(),
        body: init?.body,
        signal: controller.signal,
      });
    } catch (err) {
      if (err instanceof Error && err.name === 'AbortError') {
        throw new ProviderTimeoutError(`request timed out after ${timeoutMs}ms`, url);
      }
      throw new ProviderError(`network error: ${String(err)}`, { endpoint: url, cause: err });
    } finally {
      clearTimeout(timer);
    }
  }

  async function requestJson<T>(
    method: string,
    path: string,
    body?: unknown,
  ): Promise<T> {
    const url = `${baseUrl}${path}`;
    const res = await request(method, url, {
      headers: jsonHeaders(),
      ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
    });
    if (!res.ok) {
      const text = await res.text().catch(() => '');
      throw new ProviderError(`${method} ${path} failed: ${res.status} ${text}`.trim(), {
        status: res.status,
        endpoint: url,
      });
    }
    return (await res.json()) as T;
  }

  return {
    mode: 'live',
    creditsForModel,

    async uploadPano(bytes, filename): Promise<string> {
      // 1. prepare_upload (FREE) — mirrors spike.stage_upload.
      const prep = await requestJson<PrepareUploadResponse>(
        'POST',
        '/marble/v1/media-assets:prepare_upload',
        { file_name: filename, kind: 'image', extension: 'jpg' },
      );
      const mediaAssetId =
        prep.media_asset?.media_asset_id ?? prep.media_asset?.id;
      const upload = prep.upload_info;
      if (!mediaAssetId || !upload?.upload_url) {
        throw new ProviderError('prepare_upload returned no media_asset_id/upload_url', {
          endpoint: '/marble/v1/media-assets:prepare_upload',
        });
      }
      // 2. PUT the bytes to the signed URL with the provider's required headers
      //    plus a default Content-Type (spike: put_hdrs.setdefault image/jpeg).
      const method = upload.upload_method ?? 'PUT';
      const putHeaders: Record<string, string> = { ...(upload.required_headers ?? {}) };
      if (!('Content-Type' in putHeaders) && !('content-type' in putHeaders)) {
        putHeaders['Content-Type'] = 'image/jpeg';
      }
      const putRes = await request(method, upload.upload_url, {
        headers: putHeaders,
        // Node fetch accepts a Uint8Array/Buffer body.
        body: new Uint8Array(bytes),
      });
      if (putRes.status !== 200 && putRes.status !== 201) {
        const text = await putRes.text().catch(() => '');
        throw new ProviderError(`pano PUT failed: ${putRes.status} ${text}`.trim(), {
          status: putRes.status,
          endpoint: upload.upload_url,
        });
      }
      return mediaAssetId;
    },

    async generateWorld(mediaAssetId, model: WorldModel, displayName): Promise<string> {
      // worlds:generate (SPENDS CREDITS). NEVER retried internally — a resumed
      // worker resumes via the persisted operation_id instead (spec §14).
      const body = await requestJson<Record<string, unknown>>(
        'POST',
        '/marble/v1/worlds:generate',
        {
          display_name: displayName,
          model,
          world_prompt: {
            type: 'image',
            image_prompt: { source: 'media_asset', media_asset_id: mediaAssetId },
            is_pano: true,
          },
        },
      );
      const operationId =
        (body['operation_id'] as string | undefined) ??
        (body['id'] as string | undefined) ??
        (body['name'] as string | undefined);
      if (!operationId) {
        throw new ProviderError('worlds:generate returned no operation_id', {
          endpoint: '/marble/v1/worlds:generate',
        });
      }
      return operationId;
    },

    async getOperation(operationId): Promise<OperationStatus> {
      const body = await requestJson<Record<string, unknown>>(
        'GET',
        `/marble/v1/operations/${operationId}`,
      );
      const done = Boolean(body['done']);
      const error = body['error'];
      const response = (body['response'] as Record<string, unknown> | undefined) ?? {};
      const world = response['world'] as Record<string, unknown> | undefined;
      const worldId =
        (response['world_id'] as string | undefined) ??
        (response['id'] as string | undefined) ??
        (world?.['id'] as string | undefined);
      const result: OperationStatus = { done };
      if (worldId) result.worldId = worldId;
      if (error) {
        result.error =
          typeof error === 'string' ? error : JSON.stringify(error);
      }
      return result;
    },

    async findWorldByDisplayName(displayName): Promise<WorldMatch | null> {
      // Reconciliation lookup for a `pending:<jobId>` marker (spec §10 R1). FREE
      // — it lists worlds this key already owns; it never generates.
      //
      // ⚠️ UNVERIFIED SHAPE. Unlike every other call in this file, the list
      // endpoint was NOT exercised by tools/spike/spike.py against the live API,
      // so both the path and the response envelope are best-effort guesses at
      // the documented `GET /marble/v1/worlds` listing, parsed tolerantly (any
      // of `worlds` / `items` / `results`, and id/display-name aliases). If the
      // endpoint 404s or the shape differs, requestJson throws a ProviderError,
      // which the worker treats as RETRYABLE reconciliation failure — the job
      // retries the lookup and is eventually parked; it NEVER re-generates. So
      // a wrong guess costs a stalled job, never a double bill. Verify against
      // the live API before relying on automatic recovery.
      const body = await requestJson<Record<string, unknown>>(
        'GET',
        '/marble/v1/worlds?page_size=100',
      );
      const list =
        (body['worlds'] as unknown[] | undefined) ??
        (body['items'] as unknown[] | undefined) ??
        (body['results'] as unknown[] | undefined) ??
        [];
      for (const entry of list) {
        const w = entry as Record<string, unknown>;
        const name =
          (w['display_name'] as string | undefined) ?? (w['name'] as string | undefined);
        if (name !== displayName) continue;
        const worldId =
          (w['world_id'] as string | undefined) ?? (w['id'] as string | undefined);
        if (!worldId) continue;
        const match: WorldMatch = { worldId };
        const operationId = w['operation_id'] as string | undefined;
        if (operationId) match.operationId = operationId;
        const status = (w['status'] as string | undefined) ?? (w['state'] as string | undefined);
        if (status) {
          // Anything that isn't an explicit terminal-success state is treated as
          // "still running" → reconcile again later rather than adopt an
          // unfinished world.
          match.done = /^(done|complete|completed|succeeded|ready)$/i.test(status);
        }
        return match;
      }
      return null;
    },

    async getWorld(worldId): Promise<WorldAssets> {
      const body = await requestJson<Record<string, unknown>>(
        'GET',
        `/marble/v1/worlds/${worldId}`,
      );
      const assets = (body['assets'] as Record<string, unknown> | undefined) ?? {};
      const splats = (assets['splats'] as Record<string, unknown> | undefined) ?? {};
      const spz = (splats['spz_urls'] as Record<string, string> | undefined) ?? {};
      const mesh = (assets['mesh'] as Record<string, unknown> | undefined) ?? {};

      const out: WorldAssets = { spzUrls: {} };
      if (spz['100k']) out.spzUrls.k100 = spz['100k'];
      if (spz['500k']) out.spzUrls.k500 = spz['500k'];
      if (spz['full_res']) out.spzUrls.full = spz['full_res'];
      const collider = mesh['collider_mesh_url'] as string | undefined;
      if (collider) out.colliderMeshUrl = collider;
      const thumb = assets['thumbnail_url'] as string | undefined;
      if (thumb) out.thumbnailUrl = thumb;
      const caption = assets['caption'] as string | undefined;
      if (caption) out.caption = caption;
      return out;
    },

    async downloadAsset(url): Promise<Buffer> {
      const res = await request('GET', url, { headers: { 'WLT-Api-Key': opts.apiKey } });
      if (!res.ok) {
        throw new ProviderError(`asset download failed: ${res.status}`, {
          status: res.status,
          endpoint: url,
        });
      }
      return Buffer.from(await res.arrayBuffer());
    },
  };
}
