import { describe, it, expect } from 'vitest';
import { loadConfig } from '../src/config.js';

const base = {
  DATABASE_URL: 'postgres://u:p@localhost:5432/db',
  DEV_AUTH_TOKEN: 'dev-token',
};

describe('loadConfig', () => {
  it('applies defaults', () => {
    const cfg = loadConfig(base as NodeJS.ProcessEnv);
    expect(cfg.PORT).toBe(8080);
    expect(cfg.AUTH_MODE).toBe('dev');
    expect(cfg.STORAGE_DRIVER).toBe('local');
    expect(cfg.PROVIDER_MODE).toBe('mock');
    expect(cfg.DAILY_CREDIT_BUDGET).toBe(500);
    expect(cfg.DAILY_SCAN_QUOTA).toBe(10);
    expect(cfg.LOCAL_STORAGE_DIR).toBe('./data');
    expect(cfg.PUBLIC_BASE_URL).toBe('http://localhost:8080');
  });

  it('coerces numeric env vars', () => {
    const cfg = loadConfig({ ...base, PORT: '9090', DAILY_SCAN_QUOTA: '3' } as NodeJS.ProcessEnv);
    expect(cfg.PORT).toBe(9090);
    expect(cfg.DAILY_SCAN_QUOTA).toBe(3);
  });

  it('requires DATABASE_URL', () => {
    expect(() => loadConfig({ DEV_AUTH_TOKEN: 'x' } as NodeJS.ProcessEnv)).toThrow(
      /DATABASE_URL/,
    );
  });

  it('requires DEV_AUTH_TOKEN in dev mode', () => {
    expect(() =>
      loadConfig({ DATABASE_URL: base.DATABASE_URL } as NodeJS.ProcessEnv),
    ).toThrow(/DEV_AUTH_TOKEN/);
  });

  it('requires APPLE_BUNDLE_ID in apple mode', () => {
    expect(() =>
      loadConfig({ ...base, AUTH_MODE: 'apple' } as NodeJS.ProcessEnv),
    ).toThrow(/APPLE_BUNDLE_ID/);
  });

  it('requires S3 vars when driver is s3', () => {
    expect(() =>
      loadConfig({ ...base, STORAGE_DRIVER: 's3' } as NodeJS.ProcessEnv),
    ).toThrow(/S3_/);
  });

  it('accepts a complete s3 config', () => {
    const cfg = loadConfig({
      ...base,
      STORAGE_DRIVER: 's3',
      S3_ENDPOINT: 'https://r2.example.com',
      S3_BUCKET: 'worlds',
      S3_ACCESS_KEY_ID: 'ak',
      S3_SECRET_ACCESS_KEY: 'sk',
    } as NodeJS.ProcessEnv);
    expect(cfg.STORAGE_DRIVER).toBe('s3');
    expect(cfg.S3_BUCKET).toBe('worlds');
  });
});
