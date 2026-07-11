import { randomUUID } from 'node:crypto';
import {
  creditsForModel,
  ProviderError,
  type OperationStatus,
  type WorldAssets,
  type WorldGenProvider,
  type WorldModel,
} from './types.js';

// Offline provider for PROVIDER_MODE=mock. Burns ZERO credits and makes NO
// network calls, so the whole pipeline (stitch → generate → store) runs end to
// end locally. Operations complete instantly. Asset "downloads" are served from
// a tiny in-memory fixture map keyed by the fake URLs this provider hands out.

const FAKE_HOST = 'https://mock.worldlabs.local';

/** A byte fixture used for every mock asset (small, non-empty, deterministic). */
const FIXTURE_BYTES = Buffer.from('VIRTSPACE-MOCK-ASSET');

interface MockState {
  operations: Map<string, string>; // operationId -> worldId
}

export function createMockProvider(): WorldGenProvider {
  const state: MockState = { operations: new Map() };
  // Every URL we mint lives here so downloadAsset resolves offline.
  const assetBytes = new Map<string, Buffer>();

  const mintAssetUrl = (worldId: string, name: string): string => {
    const url = `${FAKE_HOST}/worlds/${worldId}/${name}`;
    assetBytes.set(url, FIXTURE_BYTES);
    return url;
  };

  return {
    mode: 'mock',

    // Mock generations are FREE. Cost is a property of the provider (not a
    // PROVIDER_MODE check in the worker): the worker derives BOTH the
    // reserveCredits amount and the world's credits_spent increment from
    // creditsForModel, so returning 0 here means dev runs never consume the
    // DAILY_CREDIT_BUDGET or inflate spend metrics — while reserveCredits(0)
    // still runs, keeping the budget/ledger money path exercised offline
    // (a 0-amount credit_events row is intentional).
    creditsForModel(model: WorldModel): number {
      creditsForModel(model); // validate the model id exactly like live.
      return 0;
    },

    async uploadPano(_bytes, _filename): Promise<string> {
      return `mock-media-${randomUUID()}`;
    },

    async generateWorld(_mediaAssetId, _model: WorldModel, _displayName): Promise<string> {
      const operationId = `mock-op-${randomUUID()}`;
      const worldId = `mock-world-${randomUUID()}`;
      state.operations.set(operationId, worldId);
      return operationId;
    },

    async getOperation(operationId): Promise<OperationStatus> {
      const worldId = state.operations.get(operationId);
      if (!worldId) {
        // Unknown op id (e.g. resumed from a persisted id in a fresh process):
        // synthesize a deterministic world id so resume still completes.
        const synthesized = `mock-world-${operationId}`;
        state.operations.set(operationId, synthesized);
        return { done: true, worldId: synthesized };
      }
      return { done: true, worldId };
    },

    async getWorld(worldId): Promise<WorldAssets> {
      return {
        spzUrls: {
          k100: mintAssetUrl(worldId, 'splat_100k.spz'),
          k500: mintAssetUrl(worldId, 'splat_500k.spz'),
          full: mintAssetUrl(worldId, 'splat_full.spz'),
        },
        colliderMeshUrl: mintAssetUrl(worldId, 'collider.glb'),
        thumbnailUrl: mintAssetUrl(worldId, 'thumbnail.jpg'),
        caption: 'A mock world generated offline (zero credits).',
      };
    },

    async downloadAsset(url): Promise<Buffer> {
      const bytes = assetBytes.get(url);
      if (!bytes) {
        // Tolerate resumed worlds whose URLs were minted in a prior process.
        if (url.startsWith(FAKE_HOST)) return FIXTURE_BYTES;
        throw new ProviderError(`mock asset not found: ${url}`);
      }
      return bytes;
    },
  };
}
