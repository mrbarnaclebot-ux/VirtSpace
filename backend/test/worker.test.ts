import { describe, it, expect, vi } from 'vitest';
import {
  stitchPlan,
  runGeneration,
  type GenerationIO,
  type GenerationClock,
} from '../src/worker.js';
import { MODEL_CREDITS, type WorldGenProvider } from '../src/provider/index.js';
import { createMockProvider } from '../src/provider/mock.js';

// --- stitch passthrough decision (pure) -------------------------------------
describe('stitchPlan', () => {
  it('single frame → passthrough (the frame IS the pano)', () => {
    expect(stitchPlan(1)).toEqual({ type: 'passthrough' });
  });

  it('multi-frame → unsupported (Phase 0.5 gate pending)', () => {
    expect(stitchPlan(16)).toEqual({
      type: 'unsupported',
      reason: 'stitching not yet implemented (Phase 0.5 gate pending)',
    });
    expect(stitchPlan(2).type).toBe('unsupported');
  });

  it('zero frames is also unsupported', () => {
    expect(stitchPlan(0).type).toBe('unsupported');
  });
});

// --- credit-safe generation (spec §14) --------------------------------------
const instantClock: GenerationClock = { now: () => 0, sleep: async () => undefined };

function fakeProvider(overrides: Partial<WorldGenProvider> = {}): WorldGenProvider {
  return {
    mode: 'mock',
    creditsForModel: () => 150,
    uploadPano: vi.fn(async () => 'media-1'),
    generateWorld: vi.fn(async () => 'op-1'),
    getOperation: vi.fn(async () => ({ done: true, worldId: 'world-1' })),
    getWorld: vi.fn(async () => ({ spzUrls: { k500: 'u500' }, caption: 'cap' })),
    downloadAsset: vi.fn(async () => Buffer.from('bytes')),
    ...overrides,
  } as WorldGenProvider;
}

function fakeIO(): GenerationIO & { saved: string[]; reserved: number[] } {
  const saved: string[] = [];
  const reserved: number[] = [];
  return {
    saved,
    reserved,
    reserveCredits: vi.fn(async (amount: number) => {
      reserved.push(amount);
    }),
    getPanoBytes: vi.fn(async () => Buffer.from('pano')),
    saveOperationId: vi.fn(async (opId: string) => {
      saved.push(opId);
    }),
    storeAsset: vi.fn(async (name: string) => `worlds/world-1/${name}`),
  };
}

describe('runGeneration credit safety', () => {
  it('fresh job: reserves credits, uploads, generates once, persists op id', async () => {
    const provider = fakeProvider();
    const io = fakeIO();

    const result = await runGeneration(
      provider,
      io,
      { model: 'marble-1.0-draft', displayName: 'W', cost: 150, existingOperationId: null },
      instantClock,
    );

    expect(io.reserveCredits).toHaveBeenCalledWith(150);
    expect(provider.uploadPano).toHaveBeenCalledOnce();
    expect(provider.generateWorld).toHaveBeenCalledOnce();
    expect(io.saveOperationId).toHaveBeenCalledWith('op-1');
    expect(result.worldId).toBe('world-1');
    expect(result.assetKeys.spz500kUrl).toBe('worlds/world-1/splat_500k.spz');
    expect(result.caption).toBe('cap');
  });

  it('RESUME (op id already set): NEVER re-bills — no reserve, no generate', async () => {
    const provider = fakeProvider();
    const io = fakeIO();

    await runGeneration(
      provider,
      io,
      { model: 'marble-1.0-draft', displayName: 'W', cost: 150, existingOperationId: 'op-existing' },
      instantClock,
    );

    // The money path is entirely skipped on resume.
    expect(io.reserveCredits).not.toHaveBeenCalled();
    expect(provider.uploadPano).not.toHaveBeenCalled();
    expect(provider.generateWorld).not.toHaveBeenCalled();
    expect(io.saveOperationId).not.toHaveBeenCalled();
    // But it still polls the existing operation and fetches the world.
    expect(provider.getOperation).toHaveBeenCalledWith('op-existing');
    expect(provider.getWorld).toHaveBeenCalledWith('world-1');
  });

  it('polls until done, then fetches the world', async () => {
    const getOperation = vi
      .fn()
      .mockResolvedValueOnce({ done: false })
      .mockResolvedValueOnce({ done: true, worldId: 'world-1' });
    const provider = fakeProvider({ getOperation });
    const io = fakeIO();

    await runGeneration(
      provider,
      io,
      { model: 'marble-1.1', displayName: 'W', cost: 1500, existingOperationId: null },
      instantClock,
    );
    expect(getOperation).toHaveBeenCalledTimes(2);
  });

  it('throws ProviderTimeoutError if the operation never completes', async () => {
    const provider = fakeProvider({ getOperation: vi.fn(async () => ({ done: false })) });
    const io = fakeIO();
    // Clock advances past the deadline on the first check.
    let t = 0;
    const clock: GenerationClock = {
      now: () => (t += 1_000_000),
      sleep: async () => undefined,
    };

    await expect(
      runGeneration(
        provider,
        io,
        { model: 'marble-1.0-draft', displayName: 'W', cost: 150, existingOperationId: null },
        clock,
        { timeoutMs: 1 },
      ),
    ).rejects.toMatchObject({ name: 'ProviderTimeoutError' });
  });
});

// --- mock generations are FREE ------------------------------------------------
// PROVIDER_MODE=mock must not eat the daily budget or inflate spend metrics.
// The worker derives BOTH the reserveCredits amount and the world's
// credits_spent increment from provider.creditsForModel(model), so asserting
// the mock reports 0 (and that reserve is still called, with 0) covers both.
describe('mock provider billing', () => {
  it('creditsForModel returns 0 for every model (draft and hq)', () => {
    const provider = createMockProvider();
    expect(provider.creditsForModel('marble-1.0-draft')).toBe(0);
    expect(provider.creditsForModel('marble-1.1')).toBe(0);
  });

  it('mock generation still exercises the budget path: reserveCredits(0)', async () => {
    const provider = createMockProvider();
    const io = fakeIO();
    // Exactly how handleGenerate derives the cost it reserves AND increments
    // credits_spent by — 0 on the mock, so the world's spend stays 0.
    const cost = provider.creditsForModel('marble-1.0-draft');

    const result = await runGeneration(
      provider,
      io,
      { model: 'marble-1.0-draft', displayName: 'W', cost, existingOperationId: null },
      instantClock,
    );

    expect(io.reserveCredits).toHaveBeenCalledTimes(1);
    expect(io.reserveCredits).toHaveBeenCalledWith(0); // ledger row of amount 0.
    expect(cost).toBe(0); // → worlds.credits_spent += 0.
    // The pipeline itself still completes end to end offline.
    expect(result.worldId).toMatch(/^mock-world-/);
    expect(result.assetKeys.spz500kUrl).toBe('worlds/world-1/splat_500k.spz');
  });

  it('real provider costs are unchanged (draft 150 / hq 1500)', () => {
    // MODEL_CREDITS is what the live provider returns verbatim.
    expect(MODEL_CREDITS['marble-1.0-draft']).toBe(150);
    expect(MODEL_CREDITS['marble-1.1']).toBe(1500);
  });
});
