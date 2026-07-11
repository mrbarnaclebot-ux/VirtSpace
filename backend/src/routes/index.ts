import type { FastifyInstance } from 'fastify';
import { makeAuthPreHandler } from '../auth.js';
import { registerDevStorageRoutes } from '../storage/index.js';
import { healthRoutes } from './health.js';
import { worldsRoutes } from './worlds.js';
import { devicesRoutes } from './devices.js';
import { accountRoutes } from './account.js';
import type { RouteDeps } from './deps.js';

export async function registerRoutes(
  app: FastifyInstance,
  deps: RouteDeps,
): Promise<void> {
  // Unauthenticated: liveness + (dev-only) local storage.
  healthRoutes(app);
  registerDevStorageRoutes(app, deps.storage);

  // Authenticated scope — auth preHandler applies to everything registered here.
  await app.register(async (authed) => {
    authed.addHook('preHandler', makeAuthPreHandler(deps.config));
    worldsRoutes(authed, deps);
    devicesRoutes(authed);
    accountRoutes(authed);
  });
}
