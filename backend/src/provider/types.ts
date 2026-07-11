// World-generation provider contract (spec §4 "World Labs job contract", §14).
// Two implementations: worldlabs.ts (live, money-path) and mock.ts (offline,
// zero-credit). The worker (src/worker.ts) only ever talks to this interface.

/** Supported Marble models and their credit cost (spec §2.1 / pricing). */
export type WorldModel = 'marble-1.0-draft' | 'marble-1.1';

export const MODEL_CREDITS: Record<WorldModel, number> = {
  'marble-1.0-draft': 150,
  'marble-1.1': 1500,
};

/** Pure credit lookup — exported for reuse + testing. */
export function creditsForModel(model: WorldModel): number {
  const credits = MODEL_CREDITS[model];
  if (credits === undefined) {
    throw new ProviderError(`unknown model: ${model}`);
  }
  return credits;
}

/** Result of GET /operations/{id} — normalized across provider quirks. */
export interface OperationStatus {
  done: boolean;
  worldId?: string;
  error?: string;
}

/**
 * Normalized world assets. All URLs point at the PROVIDER CDN; the worker
 * downloads them and re-hosts on our storage before exposing anything (spec
 * §14 "asset ownership"). spzUrls keys map to the provider's 100k/500k/full_res.
 */
export interface WorldAssets {
  spzUrls: { k100?: string; k500?: string; full?: string };
  colliderMeshUrl?: string;
  thumbnailUrl?: string;
  caption?: string;
}

export interface WorldGenProvider {
  readonly mode: 'mock' | 'live';
  /** prepare_upload + PUT the pano (FREE). Returns the media_asset_id. */
  uploadPano(bytes: Buffer, filename: string): Promise<string>;
  /**
   * worlds:generate (SPENDS CREDITS). Returns the operation_id. MUST NOT be
   * retried internally — a blind resubmit double-bills (spec §14).
   */
  generateWorld(
    mediaAssetId: string,
    model: WorldModel,
    displayName: string,
  ): Promise<string>;
  /** Poll an operation (FREE). */
  getOperation(operationId: string): Promise<OperationStatus>;
  /** Fetch a finished world's asset URLs (FREE). */
  getWorld(worldId: string): Promise<WorldAssets>;
  /**
   * Download an asset's bytes from a provider URL. Part of the interface (not
   * in the original 5-method sketch) so mock mode can serve fixture bytes for
   * an end-to-end offline run without a real HTTP fetch.
   */
  downloadAsset(url: string): Promise<Buffer>;
  creditsForModel(model: WorldModel): number;
}

/** Typed provider failure. `retryable` distinguishes transient vs terminal. */
export class ProviderError extends Error {
  readonly status?: number;
  readonly endpoint?: string;
  constructor(
    message: string,
    opts?: { status?: number; endpoint?: string; cause?: unknown },
  ) {
    super(message, opts?.cause !== undefined ? { cause: opts.cause } : undefined);
    this.name = 'ProviderError';
    this.status = opts?.status;
    this.endpoint = opts?.endpoint;
  }
}

/** A request exceeded its deadline. */
export class ProviderTimeoutError extends ProviderError {
  constructor(message: string, endpoint?: string) {
    super(message, endpoint !== undefined ? { endpoint } : undefined);
    this.name = 'ProviderTimeoutError';
  }
}
