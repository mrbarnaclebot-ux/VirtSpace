import type { Config } from '../config.js';
import { createLocalStorage } from './local.js';
import { createS3Storage } from './s3.js';

export interface PresignedUpload {
  url: string;
  method: 'PUT';
  headers: Record<string, string>;
}

// Storage driver contract (task requirement 4). Keys are opaque paths like
// `captures/{captureId}/frame_0.heic`.
export interface StorageDriver {
  readonly kind: 'local' | 's3';
  presignUpload(
    key: string,
    contentType: string,
    maxBytes: number,
  ): Promise<PresignedUpload>;
  presignDownload(key: string, ttlSeconds: number): Promise<string>;
  putObject(key: string, bytes: Buffer): Promise<void>;
  getObject(key: string): Promise<Buffer>;
  deleteObject(key: string): Promise<void>;
}

export function createStorage(config: Config): StorageDriver {
  return config.STORAGE_DRIVER === 's3'
    ? createS3Storage(config)
    : createLocalStorage(config);
}

export { registerDevStorageRoutes } from './local.js';
