import { randomUUID } from 'node:crypto';
import type { Config } from '../config.js';
import { fixtureFor } from './mock.js';
import { ProviderError, ProviderTimeoutError } from './types.js';
import { downloadAllowlisted, parseAssetHosts, type FetchLike } from './worldlabs.js';

// SpAItial Echo-3 client for room scans (spec §5.3). Only the operations the
// `reconstruct` worker job needs. Live: https://api.spaitial.ai, Bearer key,
// server-side only. Mock: zero credits, no network, completes at once.
//
// Shapes follow docs.spaitial.ai/api/{worlds,capture-worlds,exports}.md and
// the public OpenAPI (2026-11-23). The request LISTING envelope is not
// documented anywhere, so findRequestByTitle parses it tolerantly and throws
// (never returns "not found") when it cannot recognise the shape.

export const ECHO3_MODEL = 'echo-3';
const DEFAULT_BASE_URL = 'https://api.spaitial.ai';
const DEFAULT_TIMEOUT_MS = 60_000;
/** Splats run to hundreds of MB; one timeout covers the whole redirect chain. */
const DEFAULT_DOWNLOAD_TIMEOUT_MS = 5 * 60_000;
/**
 * `/splat` and `?download=1` answer 302 to a ~5 min signed storage URL. Its host
 * is NOT documented — set SPAITIAL_ASSET_HOSTS to the real one before the first
 * live run (a refused host fails the download retryably, it never re-bills).
 */
export const DEFAULT_SPAITIAL_ASSET_HOSTS = ['api.spaitial.ai', '.spaitial.ai'];
const LIST_PAGE_SIZE = 100;
const LIST_MAX_PAGES = 10;

export interface CaptureQuote {
  requiredCredits: number;
  hasEnough: boolean;
  estimatedDurationSeconds: number | null;
}

export interface RequestStatus {
  /** PENDING | PROCESSING | COMPLETED | FAILED | CANCELLED (open set). */
  status: string;
  /** 0..1, or null when the provider has no meaningful progress. */
  progress: number | null;
  estimatedDurationSeconds: number | null;
  error?: string;
}

export interface RequestResult {
  splatUrl?: string;
  thumbnailUrl?: string;
  completedAt?: string;
}

export interface FloorplanExport {
  /** READY | PROCESSING | FAILED | NOT_REQUESTED … (open set). */
  status: string;
  downloadUrl?: string;
}

export interface SpaitialClient {
  readonly mode: 'mock' | 'live';
  /** GET /v1/captures/process-quote (FREE). */
  quote(frameCount: number): Promise<CaptureQuote>;
  /**
   * POST /v1/worlds (SPENDS CREDITS). Returns the request id. Never retried
   * internally — the worker persists a pending marker first and reconciles by
   * title on resume (spec §14).
   */
  createWorld(input: { zipUrl: string; title: string; idempotencyKey: string }): Promise<string>;
  /** Reconciliation (FREE): the request id whose title matches exactly, or null. */
  findRequestByTitle(title: string): Promise<string | null>;
  getStatus(requestId: string): Promise<RequestStatus>;
  getResult(requestId: string): Promise<RequestResult>;
  /** POST …/exports/floorplan: start-or-retrieve, free, auto-started for Echo-3. */
  getFloorplan(requestId: string): Promise<FloorplanExport>;
  download(url: string): Promise<Buffer>;
}

export interface SpaitialOptions {
  apiKey: string;
  baseUrl?: string;
  fetchImpl?: FetchLike;
  timeoutMs?: number;
  downloadTimeoutMs?: number;
  assetHosts?: string;
  assetMaxBytes?: number;
}

const num = (v: unknown): number | null => (typeof v === 'number' && Number.isFinite(v) ? v : null);
const str = (v: unknown): string | undefined => (typeof v === 'string' && v ? v : undefined);

export function createSpaitialLiveClient(opts: SpaitialOptions): SpaitialClient {
  const baseUrl = (opts.baseUrl ?? DEFAULT_BASE_URL).replace(/\/$/, '');
  const apiHost = new URL(baseUrl).hostname;
  const doFetch: FetchLike = opts.fetchImpl ?? fetch;
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const assetHosts = opts.assetHosts
    ? parseAssetHosts(opts.assetHosts)
    : DEFAULT_SPAITIAL_ASSET_HOSTS;
  const auth = { Authorization: `Bearer ${opts.apiKey}` };

  async function call<T>(
    method: string,
    path: string,
    init: { body?: unknown; headers?: Record<string, string> } = {},
  ): Promise<T> {
    const url = `${baseUrl}${path}`;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    let res: Response;
    try {
      res = await doFetch(url, {
        method,
        headers: {
          ...auth,
          ...(init.body !== undefined ? { 'Content-Type': 'application/json' } : {}),
          ...init.headers,
        },
        ...(init.body !== undefined ? { body: JSON.stringify(init.body) } : {}),
        signal: controller.signal,
        // The key must never follow a redirect (spec §10 R29); JSON routes
        // don't redirect, so one is an error.
        redirect: 'error',
      });
    } catch (err) {
      if (err instanceof Error && err.name === 'AbortError') {
        throw new ProviderTimeoutError(`request timed out after ${timeoutMs}ms`, url);
      }
      throw new ProviderError(`network error: ${String(err)}`, { endpoint: url, cause: err });
    } finally {
      clearTimeout(timer);
    }
    if (!res.ok) {
      const text = await res.text().catch(() => '');
      throw new ProviderError(`${method} ${path} failed: ${res.status} ${text}`.trim(), {
        status: res.status,
        endpoint: url,
      });
    }
    return (await res.json()) as T;
  }

  const req = (id: string) => `/v1/worlds/requests/${encodeURIComponent(id)}`;

  return {
    mode: 'live',

    async quote(frameCount) {
      const q = new URLSearchParams({ model: ECHO3_MODEL, frame_count: String(frameCount) });
      const body = await call<Record<string, unknown>>('GET', `/v1/captures/process-quote?${q}`);
      const requiredCredits = num(body['required_credits']);
      if (requiredCredits === null || typeof body['has_enough'] !== 'boolean') {
        throw new ProviderError('process-quote returned no required_credits/has_enough');
      }
      return {
        requiredCredits,
        hasEnough: body['has_enough'],
        estimatedDurationSeconds: num(body['estimated_duration_seconds']),
      };
    },

    async createWorld({ zipUrl, title, idempotencyKey }) {
      const body = await call<Record<string, unknown>>('POST', '/v1/worlds', {
        headers: { 'Idempotency-Key': idempotencyKey },
        body: {
          model: ECHO3_MODEL,
          title,
          input: { type: 'capture_bundle', zip: { type: 'url', zip_url: zipUrl } },
        },
      });
      const requestId = str(body['request_id']);
      if (!requestId) throw new ProviderError('POST /v1/worlds returned no request_id');
      return requestId;
    },

    async findRequestByTitle(title) {
      for (let page = 0; page < LIST_MAX_PAGES; page++) {
        const q = new URLSearchParams({
          limit: String(LIST_PAGE_SIZE),
          offset: String(page * LIST_PAGE_SIZE),
        });
        const body = await call<unknown>('GET', `/v1/worlds/requests?${q}`);
        const b = body as Record<string, unknown>;
        const list = Array.isArray(body)
          ? body
          : [b['requests'], b['items'], b['data'], b['jobs'], b['results']].find(Array.isArray);
        if (!Array.isArray(list)) {
          // "Could not determine" — must not read as "no such request".
          throw new ProviderError('GET /v1/worlds/requests: unrecognised list envelope');
        }
        for (const entry of list as Record<string, unknown>[]) {
          const world = entry['world'] as Record<string, unknown> | undefined;
          const name = str(entry['title']) ?? str(world?.['title']);
          const id = str(entry['request_id']) ?? str(entry['id']);
          if (name === title && id) return id;
        }
        if (list.length < LIST_PAGE_SIZE) return null;
      }
      return null;
    },

    async getStatus(requestId) {
      const body = await call<Record<string, unknown>>('GET', `${req(requestId)}/status`);
      const status = str(body['status']);
      if (!status) throw new ProviderError(`status for ${requestId} has no status`);
      const out: RequestStatus = {
        status,
        progress: num(body['progress']),
        estimatedDurationSeconds: num(body['estimated_duration_seconds']),
      };
      const err = body['error'] as Record<string, unknown> | null | undefined;
      if (err) out.error = [str(err['code']), str(err['message'])].filter(Boolean).join(': ');
      return out;
    },

    async getResult(requestId) {
      const body = await call<Record<string, unknown>>('GET', req(requestId));
      const world = (body['world'] as Record<string, unknown> | null) ?? {};
      const out: RequestResult = {};
      const splat = str(world['splat_url']);
      const thumb = str(world['thumbnail_url']);
      const done = str(body['completed_at']) ?? str(world['completed_at']);
      if (splat) out.splatUrl = splat;
      if (thumb) out.thumbnailUrl = thumb;
      if (done) out.completedAt = done;
      return out;
    },

    async getFloorplan(requestId) {
      const body = await call<Record<string, unknown>>(
        'POST',
        `${req(requestId)}/exports/floorplan`,
      );
      const out: FloorplanExport = { status: str(body['status']) ?? 'UNKNOWN' };
      const url = str(body['download_url']);
      if (url) out.downloadUrl = url;
      return out;
    },

    download(url) {
      // Bearer rides the first hop only, and only to the API host itself: the
      // 302 target is a signed storage URL that needs no credential.
      const host = (() => {
        try {
          return new URL(url).hostname;
        } catch {
          return '';
        }
      })();
      return downloadAllowlisted(doFetch, url, {
        allowlist: assetHosts,
        maxBytes: opts.assetMaxBytes ?? 1024 * 1024 * 1024,
        timeoutMs: opts.downloadTimeoutMs ?? DEFAULT_DOWNLOAD_TIMEOUT_MS,
        ...(host === apiHost ? { firstHopHeaders: auth } : {}),
      });
    },
  };
}

const MOCK_HOST = 'https://mock.spaitial.local';

/**
 * SPAITIAL_MODE=mock: accepts any bundle, quotes 0 credits (the ledger still
 * runs), "completes" on the first poll and serves the World Labs mock's fixture
 * bytes. Like the World Labs mock, the title index is in-process only, so a
 * cross-restart reconcile finds nothing and parks — the conservative outcome.
 */
export function createSpaitialMockClient(): SpaitialClient {
  const byTitle = new Map<string, string>();
  const asset = (id: string, name: string) => `${MOCK_HOST}/${id}/${name}`;
  return {
    mode: 'mock',
    async quote() {
      return { requiredCredits: 0, hasEnough: true, estimatedDurationSeconds: 60 };
    },
    async createWorld({ title }) {
      const id = `mock-req-${randomUUID()}`;
      byTitle.set(title, id);
      return id;
    },
    async findRequestByTitle(title) {
      return byTitle.get(title) ?? null;
    },
    async getStatus() {
      return { status: 'COMPLETED', progress: 1, estimatedDurationSeconds: null };
    },
    async getResult(id) {
      return {
        splatUrl: asset(id, 'splat.spz'),
        thumbnailUrl: asset(id, 'thumbnail.jpg'),
        completedAt: new Date().toISOString(),
      };
    },
    async getFloorplan(id) {
      return { status: 'READY', downloadUrl: asset(id, 'floorplan.png') };
    },
    async download(url) {
      if (!url.startsWith(MOCK_HOST)) throw new ProviderError(`mock asset not found: ${url}`);
      return fixtureFor(url);
    },
  };
}

export function createSpaitialClient(config: Config): SpaitialClient {
  if (config.SPAITIAL_MODE === 'mock') return createSpaitialMockClient();
  if (!config.SPAITIAL_API_KEY) throw new Error('SPAITIAL_MODE=live requires SPAITIAL_API_KEY');
  return createSpaitialLiveClient({
    apiKey: config.SPAITIAL_API_KEY,
    ...(config.SPAITIAL_ASSET_HOSTS ? { assetHosts: config.SPAITIAL_ASSET_HOSTS } : {}),
    assetMaxBytes: config.SPAITIAL_ASSET_MAX_BYTES,
  });
}
