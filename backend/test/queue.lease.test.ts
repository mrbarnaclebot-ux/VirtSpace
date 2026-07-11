import { describe, it, expect } from 'vitest';
import { LEASE_SECONDS, isJobClaimable } from '../src/queue.js';

// Lease-expiry claim logic (QA defect fix). isJobClaimable is the pure mirror
// of the claimNextJob WHERE clause; the SQL must stay in sync with it.

const now = new Date('2026-07-12T12:00:00Z');

function job(overrides: {
  phase: string;
  lockedAt: Date | null;
  runAfter?: Date;
}) {
  return {
    phase: overrides.phase,
    lockedAt: overrides.lockedAt,
    runAfter: overrides.runAfter ?? new Date(now.getTime() - 1000),
  };
}

describe('LEASE_SECONDS', () => {
  it('is 600 (10 minutes)', () => {
    expect(LEASE_SECONDS).toBe(600);
  });
});

describe('isJobClaimable', () => {
  it('claims an unlocked queued job whose backoff has passed', () => {
    expect(isJobClaimable(job({ phase: 'queued', lockedAt: null }), now)).toBe(true);
  });

  it('does not claim a job still inside its backoff window', () => {
    const runAfter = new Date(now.getTime() + 60_000);
    expect(isJobClaimable(job({ phase: 'queued', lockedAt: null, runAfter }), now)).toBe(false);
  });

  it('does not claim a freshly-leased (running) job', () => {
    const lockedAt = new Date(now.getTime() - 60_000); // 1 min ago, lease valid.
    expect(isJobClaimable(job({ phase: 'running', lockedAt }), now)).toBe(false);
  });

  it('RE-claims a running job whose lease has expired (crashed worker)', () => {
    const lockedAt = new Date(now.getTime() - (LEASE_SECONDS + 1) * 1000);
    expect(isJobClaimable(job({ phase: 'running', lockedAt }), now)).toBe(true);
  });

  it('treats the lease boundary as not-yet-expired (must be strictly older)', () => {
    const lockedAt = new Date(now.getTime() - LEASE_SECONDS * 1000);
    expect(isJobClaimable(job({ phase: 'running', lockedAt }), now)).toBe(false);
  });

  it('never claims done or dead jobs', () => {
    expect(isJobClaimable(job({ phase: 'done', lockedAt: null }), now)).toBe(false);
    expect(isJobClaimable(job({ phase: 'dead', lockedAt: null }), now)).toBe(false);
  });
});
