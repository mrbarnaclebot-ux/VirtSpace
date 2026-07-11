import {
  S3Client,
  PutObjectCommand,
  GetObjectCommand,
  DeleteObjectCommand,
} from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import type { Config } from '../config.js';
import type { PresignedUpload, StorageDriver } from './index.js';

// S3-compatible driver. Endpoint-configurable so it works against Cloudflare R2
// (production) as well as AWS S3 / MinIO. forcePathStyle keeps R2 happy.

export function createS3Storage(config: Config): StorageDriver {
  const bucket = config.S3_BUCKET as string;
  const client = new S3Client({
    region: config.S3_REGION,
    endpoint: config.S3_ENDPOINT,
    forcePathStyle: true,
    credentials: {
      accessKeyId: config.S3_ACCESS_KEY_ID as string,
      secretAccessKey: config.S3_SECRET_ACCESS_KEY as string,
    },
  });

  return {
    kind: 's3',

    async presignUpload(key, contentType, _maxBytes): Promise<PresignedUpload> {
      // Note: byte-size ceilings are enforced with a bucket policy in prod;
      // the presigner does not bind Content-Length here.
      const cmd = new PutObjectCommand({
        Bucket: bucket,
        Key: key,
        ContentType: contentType,
      });
      const url = await getSignedUrl(client, cmd, { expiresIn: 900 });
      return { url, method: 'PUT', headers: { 'content-type': contentType } };
    },

    async presignDownload(key, ttlSeconds): Promise<string> {
      const cmd = new GetObjectCommand({ Bucket: bucket, Key: key });
      return getSignedUrl(client, cmd, { expiresIn: ttlSeconds });
    },

    async putObject(key, bytes): Promise<void> {
      await client.send(
        new PutObjectCommand({ Bucket: bucket, Key: key, Body: bytes }),
      );
    },

    async getObject(key): Promise<Buffer> {
      const res = await client.send(
        new GetObjectCommand({ Bucket: bucket, Key: key }),
      );
      const bytes = await res.Body?.transformToByteArray();
      if (!bytes) throw new Error(`Empty object: ${key}`);
      return Buffer.from(bytes);
    },

    async deleteObject(key): Promise<void> {
      await client.send(
        new DeleteObjectCommand({ Bucket: bucket, Key: key }),
      );
    },
  };
}
