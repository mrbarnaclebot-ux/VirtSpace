import { describe, it, expect } from 'vitest';
import { createSpaitialLiveClient, createSpaitialClient } from '../src/provider/spaitial.js';
import { ProviderError } from '../src/provider/types.js';
import type { FetchLike } from '../src/provider/worldlabs.js';
import { loadConfig } from '../src/config.js';

// Live SpAItial client request shaping (spec §5.3). Fake fetch only — no
// network, nothing billable.

const KEY = 'spt_live_secret';

interface Call {
  url: string;
  method: string;
  headers: Record<string, string>;
  body?: unknown;
  redirect?: string;
}

function fakeFetch(respond: (c: Call, i: number) => Response) {
  const calls: Call[] = [];
  const f = (async (url: string | URL | Request, init?: RequestInit) => {
    const c: Call = {
      url: String(url),
      method: init?.method ?? 'GET',
      headers: { ...((init?.headers as Record<string, string>) ?? {}) },
      redirect: init?.redirect,
    };
    if (typeof init?.body === 'string') c.body = JSON.parse(init.body);
    calls.push(c);
    return respond(c, calls.length - 1);
  }) as unknown as FetchLike;
  return { f, calls };
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

const live = (f: FetchLike, over = {}) => createSpaitialLiveClient({ apiKey: KEY, fetchImpl: f, ...over });

describe('SpAItial live client', () => {
  it('quote: GET process-quote?model=echo-3&frame_count=N with Bearer auth', async () => {
    const { f, calls } = fakeFetch(() =>
      json({ model: 'echo-3', required_credits: 1620, available_credits: 7500, has_enough: true, estimated_duration_seconds: 1860 }),
    );
    expect(await live(f).quote(720)).toEqual({ requiredCredits: 1620, hasEnough: true, estimatedDurationSeconds: 1860 });
    expect(calls[0]).toMatchObject({
      method: 'GET',
      url: 'https://api.spaitial.ai/v1/captures/process-quote?model=echo-3&frame_count=720',
      redirect: 'error',
    });
    expect(calls[0]!.headers['Authorization']).toBe(`Bearer ${KEY}`);
  });

  it('quote without required_credits/has_enough is an error, not a free pass', async () => {
    const { f } = fakeFetch(() => json({ model: 'echo-3' }));
    await expect(live(f).quote(10)).rejects.toBeInstanceOf(ProviderError);
  });

  it('createWorld: POST /v1/worlds, capture_bundle zip url body, Idempotency-Key header', async () => {
    const { f, calls } = fakeFetch(() => json({ request_id: 'req_abc', status_url: 'x' }, 202));
    const id = await live(f).createWorld({ zipUrl: 'https://r2.example/b.zip?sig', title: 'VirtSpace j1', idempotencyKey: 'j1' });
    expect(id).toBe('req_abc');
    expect(calls).toHaveLength(1);
    expect(calls[0]).toMatchObject({ method: 'POST', url: 'https://api.spaitial.ai/v1/worlds' });
    expect(calls[0]!.headers).toMatchObject({
      Authorization: `Bearer ${KEY}`,
      'Idempotency-Key': 'j1',
      'Content-Type': 'application/json',
    });
    expect(calls[0]!.body).toEqual({
      model: 'echo-3',
      title: 'VirtSpace j1',
      input: { type: 'capture_bundle', zip: { type: 'url', zip_url: 'https://r2.example/b.zip?sig' } },
    });
  });

  it('createWorld error surfaces as ProviderError with the HTTP status (and is sent once)', async () => {
    const { f, calls } = fakeFetch(() => json({ error: { code: 'INSUFFICIENT_CREDITS' } }, 402));
    const err = await live(f).createWorld({ zipUrl: 'https://x/y', title: 't', idempotencyKey: 'k' }).catch((e) => e);
    expect(err).toBeInstanceOf(ProviderError);
    expect(err.status).toBe(402);
    expect(err.message).toContain('INSUFFICIENT_CREDITS');
    expect(calls).toHaveLength(1);
  });

  it('findRequestByTitle pages the listing until a short page and matches the exact title', async () => {
    const page0 = Array.from({ length: 100 }, (_, i) => ({ request_id: `req_${i}`, title: `other ${i}` }));
    const { f, calls } = fakeFetch((_c, i) =>
      json({ requests: i === 0 ? page0 : [{ request_id: 'req_hit', world: { title: 'VirtSpace j1' } }] }),
    );
    expect(await live(f).findRequestByTitle('VirtSpace j1')).toBe('req_hit');
    expect(calls.map((c) => c.url)).toEqual([
      'https://api.spaitial.ai/v1/worlds/requests?limit=100&offset=0',
      'https://api.spaitial.ai/v1/worlds/requests?limit=100&offset=100',
    ]);
  });

  it('findRequestByTitle: no match on a short page → null; unknown envelope → throws (could not determine)', async () => {
    const { f } = fakeFetch(() => json({ items: [{ id: 'req_1', title: 'nope' }] }));
    expect(await live(f).findRequestByTitle('VirtSpace j1')).toBeNull();
    const { f: g } = fakeFetch(() => json({ something: 'else' }));
    await expect(live(g).findRequestByTitle('VirtSpace j1')).rejects.toBeInstanceOf(ProviderError);
  });

  it('getStatus / getResult / getExport parse the documented shapes', async () => {
    const { f, calls } = fakeFetch((c) => {
      if (c.url.endsWith('/status')) {
        return json({ request_id: 'req_1', status: 'FAILED', progress: null, estimated_duration_seconds: null, error: { code: 'IMAGES_MISSING', message: 'no images' } });
      }
      if (c.url.endsWith('/exports/floorplan')) {
        return json({ type: 'floorplan', status: 'READY', download_url: 'https://api.spaitial.ai/v1/worlds/requests/req_1/exports/floorplan?download=1' });
      }
      if (c.url.endsWith('/exports/mesh-simplified')) {
        return json({ type: 'mesh-simplified', status: 'PROCESSING' }, 202);
      }
      return json({
        request_id: 'req_1', status: 'COMPLETED', completed_at: '2026-11-23T12:00:00Z',
        world: { splat_url: 'https://api.spaitial.ai/v1/worlds/requests/req_1/splat', thumbnail_url: 'https://img.spaitial.ai/t.webp' },
      });
    });
    const c = live(f);
    expect(await c.getStatus('req_1')).toEqual({
      status: 'FAILED', progress: null, estimatedDurationSeconds: null, error: 'IMAGES_MISSING: no images',
    });
    expect(await c.getResult('req_1')).toEqual({
      splatUrl: 'https://api.spaitial.ai/v1/worlds/requests/req_1/splat',
      thumbnailUrl: 'https://img.spaitial.ai/t.webp',
      completedAt: '2026-11-23T12:00:00Z',
    });
    expect(await c.getExport('req_1', 'floorplan')).toEqual({
      status: 'READY',
      downloadUrl: 'https://api.spaitial.ai/v1/worlds/requests/req_1/exports/floorplan?download=1',
    });
    expect(await c.getExport('req_1', 'mesh-simplified')).toEqual({ status: 'PROCESSING' });
    expect(calls.map((x) => `${x.method} ${x.url}`)).toEqual([
      'GET https://api.spaitial.ai/v1/worlds/requests/req_1/status',
      'GET https://api.spaitial.ai/v1/worlds/requests/req_1',
      'POST https://api.spaitial.ai/v1/worlds/requests/req_1/exports/floorplan',
      'POST https://api.spaitial.ai/v1/worlds/requests/req_1/exports/mesh-simplified',
    ]);
  });

  it('download: Bearer on the API hop only; the 302 signed URL is fetched without it', async () => {
    const { f, calls } = fakeFetch((_c, i) =>
      i === 0
        ? new Response(null, { status: 302, headers: { location: 'https://storage.spaitial.ai/splat.spz?sig=1' } })
        : new Response(Buffer.from('SPZ')),
    );
    const bytes = await live(f).download('https://api.spaitial.ai/v1/worlds/requests/req_1/splat');
    expect(bytes.toString()).toBe('SPZ');
    expect(calls[0]!.headers['Authorization']).toBe(`Bearer ${KEY}`);
    expect(calls[1]!.url).toBe('https://storage.spaitial.ai/splat.spz?sig=1');
    expect(calls[1]!.headers['Authorization']).toBeUndefined();
  });

  it('download refuses a redirect to a host off the allowlist, and caps the body', async () => {
    const { f } = fakeFetch(() =>
      new Response(null, { status: 302, headers: { location: 'https://evil.example/x' } }),
    );
    await expect(live(f).download('https://api.spaitial.ai/v1/worlds/requests/r/splat')).rejects.toThrow(/allowlist/);

    const { f: g } = fakeFetch(() => new Response(Buffer.alloc(64)));
    await expect(live(g, { assetMaxBytes: 16 }).download('https://img.spaitial.ai/t.webp')).rejects.toThrow(/cap/);

    // SPAITIAL_ASSET_HOSTS widens it for the real signed-URL host.
    const { f: h } = fakeFetch((_c, i) =>
      i === 0 ? new Response(null, { status: 302, headers: { location: 'https://bucket.storage.example/x' } }) : new Response('ok'),
    );
    const ok = await live(h, { assetHosts: 'api.spaitial.ai,.storage.example' }).download('https://api.spaitial.ai/v1/worlds/requests/r/splat');
    expect(ok.toString()).toBe('ok');
  });

  it('SPAITIAL_MODE defaults to mock (independent of PROVIDER_MODE); live without a key refuses', () => {
    const base = { DATABASE_URL: 'x', DEV_AUTH_TOKEN: 't', PROVIDER_MODE: 'live' } as NodeJS.ProcessEnv;
    expect(createSpaitialClient(loadConfig(base)).mode).toBe('mock');
    expect(() => createSpaitialClient(loadConfig({ ...base, SPAITIAL_MODE: 'live' }))).toThrow(/SPAITIAL_API_KEY/);
  });
});
