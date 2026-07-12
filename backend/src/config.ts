import { z } from 'zod';

// Zod-validated environment loader. Validation runs on demand (loadConfig /
// getConfig) rather than at import time so tests can inject their own env and
// so importing a module never throws for a missing var.

const numberFromEnv = (def: number) =>
  z
    .string()
    .optional()
    .transform((v) => (v === undefined || v === '' ? def : Number(v)))
    .pipe(z.number().int().nonnegative());

const baseSchema = z.object({
  DATABASE_URL: z.string().min(1, 'DATABASE_URL is required'),
  PORT: numberFromEnv(8080),

  AUTH_MODE: z.enum(['dev', 'apple']).default('dev'),
  DEV_AUTH_TOKEN: z.string().optional(),
  APPLE_BUNDLE_ID: z.string().optional(),

  STORAGE_DRIVER: z.enum(['local', 's3']).default('local'),
  LOCAL_STORAGE_DIR: z.string().default('./data'),
  // Base URL used to build dev-storage "presigned" links for the local driver.
  PUBLIC_BASE_URL: z.string().optional(),

  S3_ENDPOINT: z.string().optional(),
  S3_REGION: z.string().default('auto'),
  S3_BUCKET: z.string().optional(),
  S3_ACCESS_KEY_ID: z.string().optional(),
  S3_SECRET_ACCESS_KEY: z.string().optional(),

  WORLDLABS_API_KEY: z.string().optional(),
  PROVIDER_MODE: z.enum(['mock', 'live']).default('mock'),

  DAILY_CREDIT_BUDGET: numberFromEnv(500),
  DAILY_SCAN_QUOTA: numberFromEnv(10),

  // Worker loop poll interval (ms) between empty claim attempts (Stage 2).
  WORKER_POLL_MS: numberFromEnv(2000),

  // --- Stitcher (Phase 0.5) -------------------------------------------------
  // Wall-clock ceiling for a single reproject.py run before it's killed and the
  // stitch job fails (retryable). Default 5 minutes.
  STITCHER_TIMEOUT_MS: numberFromEnv(300000),
  // Equirect pano width (height = width/2). Default 8192 → 8192x4096.
  STITCHER_WIDTH: numberFromEnv(8192),
  // Python interpreter used to run stitcher/reproject.py.
  PYTHON_BIN: z.string().default('python3'),
});

export type Config = z.infer<typeof baseSchema> & { PUBLIC_BASE_URL: string };

function refine(cfg: z.infer<typeof baseSchema>): Config {
  // S3 driver requires its credentials; local driver does not.
  if (cfg.STORAGE_DRIVER === 's3') {
    const missing = (
      ['S3_ENDPOINT', 'S3_BUCKET', 'S3_ACCESS_KEY_ID', 'S3_SECRET_ACCESS_KEY'] as const
    ).filter((k) => !cfg[k]);
    if (missing.length > 0) {
      throw new Error(
        `STORAGE_DRIVER=s3 requires: ${missing.join(', ')}`,
      );
    }
  }
  // Apple auth needs an audience; dev auth needs a shared token.
  if (cfg.AUTH_MODE === 'apple' && !cfg.APPLE_BUNDLE_ID) {
    throw new Error('AUTH_MODE=apple requires APPLE_BUNDLE_ID');
  }
  if (cfg.AUTH_MODE === 'dev' && !cfg.DEV_AUTH_TOKEN) {
    throw new Error('AUTH_MODE=dev requires DEV_AUTH_TOKEN');
  }
  return {
    ...cfg,
    PUBLIC_BASE_URL: cfg.PUBLIC_BASE_URL ?? `http://localhost:${cfg.PORT}`,
  };
}

/** Validate an env object into a typed Config. Throws on invalid input. */
export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const parsed = baseSchema.safeParse(env);
  if (!parsed.success) {
    const issues = parsed.error.issues
      .map((i) => `${i.path.join('.')}: ${i.message}`)
      .join('; ');
    throw new Error(`Invalid environment: ${issues}`);
  }
  return refine(parsed.data);
}

let cached: Config | undefined;

/** Memoized config for the running process. */
export function getConfig(): Config {
  if (!cached) cached = loadConfig();
  return cached;
}

/** Test hook — clears the memoized config. */
export function resetConfigCache(): void {
  cached = undefined;
}
