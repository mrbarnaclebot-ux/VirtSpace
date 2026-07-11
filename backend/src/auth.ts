import { createRemoteJWKSet, jwtVerify } from 'jose';
import type { FastifyReply, FastifyRequest, preHandlerHookHandler } from 'fastify';
import type { Config } from './config.js';
import { getDb } from './db/client.js';
import { upsertUserBySub } from './db/users.js';

declare module 'fastify' {
  interface FastifyRequest {
    userId?: string;
  }
}

// --- Dev-mode header parsing (pure, testable without a DB) -------------------

export type DevAuthResult =
  | { ok: true; subject: string; displayName?: string }
  | { ok: false; status: number; message: string };

/**
 * Validate dev-mode auth headers: `Authorization: Bearer <DEV_AUTH_TOKEN>` plus
 * an `x-dev-user` identity header. Returns the subject to upsert, or a rejection.
 */
export function parseDevAuth(
  headers: Record<string, string | string[] | undefined>,
  devToken: string | undefined,
): DevAuthResult {
  if (!devToken) {
    return { ok: false, status: 500, message: 'DEV_AUTH_TOKEN not configured' };
  }
  const authz = headers['authorization'];
  const authHeader = Array.isArray(authz) ? authz[0] : authz;
  const bearer = authHeader?.startsWith('Bearer ')
    ? authHeader.slice('Bearer '.length).trim()
    : undefined;
  if (!bearer || bearer !== devToken) {
    return { ok: false, status: 401, message: 'invalid or missing bearer token' };
  }
  const devUser = headers['x-dev-user'];
  const subject = (Array.isArray(devUser) ? devUser[0] : devUser)?.trim();
  if (!subject) {
    return { ok: false, status: 401, message: 'missing x-dev-user header' };
  }
  return { ok: true, subject, displayName: subject };
}

// --- Apple identity token verification --------------------------------------

const APPLE_JWKS_URL = 'https://appleid.apple.com/auth/keys';
const APPLE_ISSUER = 'https://appleid.apple.com';

// Cache the remote JWKS across requests (jose caches keys internally too).
let appleJwks: ReturnType<typeof createRemoteJWKSet> | undefined;
function getAppleJwks() {
  if (!appleJwks) appleJwks = createRemoteJWKSet(new URL(APPLE_JWKS_URL));
  return appleJwks;
}

export async function verifyAppleToken(
  token: string,
  audience: string,
): Promise<{ subject: string; email?: string }> {
  const { payload } = await jwtVerify(token, getAppleJwks(), {
    issuer: APPLE_ISSUER,
    audience,
  });
  if (!payload.sub) throw new Error('apple token missing sub');
  const email = typeof payload['email'] === 'string' ? payload['email'] : undefined;
  return { subject: payload.sub, email };
}

// --- Fastify preHandler ------------------------------------------------------

function bearerFrom(req: FastifyRequest): string | undefined {
  const authz = req.headers['authorization'];
  const header = Array.isArray(authz) ? authz[0] : authz;
  return header?.startsWith('Bearer ') ? header.slice(7).trim() : undefined;
}

/**
 * Build the auth preHandler for the configured mode. Attaches `request.userId`
 * (upserting the user) or replies 401/500.
 */
export function makeAuthPreHandler(config: Config): preHandlerHookHandler {
  return async (req: FastifyRequest, reply: FastifyReply) => {
    if (config.AUTH_MODE === 'dev') {
      const res = parseDevAuth(req.headers, config.DEV_AUTH_TOKEN);
      if (!res.ok) return reply.code(res.status).send({ error: res.message });
      const user = await upsertUserBySub(getDb(), res.subject, res.displayName);
      req.userId = user.id;
      return;
    }

    // apple mode
    const token = bearerFrom(req);
    if (!token) return reply.code(401).send({ error: 'missing bearer token' });
    try {
      const { subject, email } = await verifyAppleToken(
        token,
        config.APPLE_BUNDLE_ID as string,
      );
      const user = await upsertUserBySub(getDb(), subject, email ?? null);
      req.userId = user.id;
    } catch (err) {
      req.log.warn({ err }, 'apple token verification failed');
      return reply.code(401).send({ error: 'invalid apple identity token' });
    }
  };
}
