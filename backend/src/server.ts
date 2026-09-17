import { pathToFileURL } from 'node:url';
import Fastify, { type FastifyInstance } from 'fastify';
import { getConfig } from './config.js';
import { closeDb } from './db/client.js';
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

/**
 * Install SIGTERM/SIGINT handling: stop accepting connections, let in-flight
 * requests finish, then close the DB pool (spec §10 R10).
 *
 * Order matters — `app.close()` first, `closeDb()` second. Closing the pool
 * while a handler is still mid-query turns a request that was about to succeed
 * into a 500. The hard timer is the backstop for a wedged connection: a deploy
 * that hangs forever is worse than one that drops a straggler, and the platform
 * will SIGKILL us shortly after regardless.
 *
 * Exported for tests.
 */
export function installShutdownHandlers(
  app: FastifyInstance,
  graceMs: number,
  exit: (code: number) => void = process.exit,
): (signal: string) => void {
  let shuttingDown = false;

  const shutdown = (signal: string): void => {
    // A second SIGTERM (impatient orchestrator) must not start a second drain.
    if (shuttingDown) return;
    shuttingDown = true;
    app.log.info(`received ${signal}, draining in-flight requests`);

    const hard = setTimeout(() => {
      app.log.error(`shutdown exceeded ${graceMs}ms, exiting with work in flight`);
      exit(1);
    }, graceMs);
    // Don't let the backstop itself hold the process open once we're done.
    hard.unref();

    void (async () => {
      try {
        await app.close();
        await closeDb();
        clearTimeout(hard);
        app.log.info('shutdown complete');
        exit(0);
      } catch (err) {
        app.log.error({ err }, 'shutdown failed');
        clearTimeout(hard);
        exit(1);
      }
    })();
  };

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
  return shutdown;
}

async function main(): Promise<void> {
  const config = getConfig();
  const app = await buildServer();
  await app.listen({ port: config.PORT, host: '0.0.0.0' });
  installShutdownHandlers(app, config.SHUTDOWN_GRACE_MS);
}

// Run when executed directly (node/tsx src/server.ts), not when imported.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((err) => {
    // eslint-disable-next-line no-console
    console.error(err);
    process.exit(1);
  });
}
