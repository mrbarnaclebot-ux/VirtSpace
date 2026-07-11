import { describe, it, expect } from 'vitest';
import { parseDevAuth } from '../src/auth.js';

const TOKEN = 'secret-dev-token';

describe('parseDevAuth', () => {
  it('accepts a valid bearer token + x-dev-user', () => {
    const res = parseDevAuth(
      { authorization: `Bearer ${TOKEN}`, 'x-dev-user': 'alice@example.com' },
      TOKEN,
    );
    expect(res).toEqual({
      ok: true,
      subject: 'alice@example.com',
      displayName: 'alice@example.com',
    });
  });

  it('rejects a missing Authorization header', () => {
    const res = parseDevAuth({ 'x-dev-user': 'alice' }, TOKEN);
    expect(res.ok).toBe(false);
    if (!res.ok) expect(res.status).toBe(401);
  });

  it('rejects a wrong bearer token', () => {
    const res = parseDevAuth(
      { authorization: 'Bearer nope', 'x-dev-user': 'alice' },
      TOKEN,
    );
    expect(res.ok).toBe(false);
    if (!res.ok) expect(res.status).toBe(401);
  });

  it('rejects a missing x-dev-user header', () => {
    const res = parseDevAuth({ authorization: `Bearer ${TOKEN}` }, TOKEN);
    expect(res.ok).toBe(false);
    if (!res.ok) expect(res.status).toBe(401);
  });

  it('errors 500 when no dev token is configured', () => {
    const res = parseDevAuth({ authorization: 'Bearer x' }, undefined);
    expect(res.ok).toBe(false);
    if (!res.ok) expect(res.status).toBe(500);
  });
});
