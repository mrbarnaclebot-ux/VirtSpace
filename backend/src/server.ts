import { pathToFileURL } from 'node:url';
import Fastify, { type FastifyInstance } from 'fastify';
import { getConfig } from './config.js';
import { createStorage } from './storage/index.js';
import { registerRoutes } from './routes/index.js';

// Build a fully-wired Fastify instance. Does NOT connect to Postgres — the DB
// pool is created lazily on first query (see db/client.ts), so boot and
// /healthz work without a live database (task requirement 10).
export async function buildServer(): Promise<FastifyInstance> {
  const config = getConfig();
  const app = Fastify({ logger: true });
  const storage = createStorage(config);
  await registerRoutes(app, { config, storage });
  return app;
}

async function main(): Promise<void> {
  const config = getConfig();
  const app = await buildServer();
  await app.listen({ port: config.PORT, host: '0.0.0.0' });
}

// Run when executed directly (node/tsx src/server.ts), not when imported.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((err) => {
    // eslint-disable-next-line no-console
    console.error(err);
    process.exit(1);
  });
}
