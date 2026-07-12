// Daily scan quota (spec §7 / task requirement 6). Pure logic so it can be unit
// tested without a DB; the route applies the returned counter to the user row.

const DAY_MS = 24 * 60 * 60 * 1000;

export interface QuotaState {
  dailyScanCount: number;
  quotaResetAt: Date | null;
}

export interface QuotaDecision {
  allowed: boolean;
  /** New counter value to persist (only meaningful when allowed). */
  newCount: number;
  /** New reset timestamp to persist. */
  newResetAt: Date;
  /** When denied, when the window frees up. */
  retryAt?: Date;
}

/** Read-only view of a user's remaining quota (GET /v1/me/quota contract). */
export interface QuotaStatus {
  scansRemaining: number;
  /** When the current window frees up; null when no window is active. */
  quotaResetsAt: Date | null;
  dailyQuota: number;
}

/**
 * True when the reset window is absent or has already elapsed — i.e. the next
 * scan starts a fresh 24h window. Shared by evaluateQuota and quotaStatus so
 * both agree on exactly when a window is "spent".
 */
function windowExpired(resetAt: Date | null, now: Date): boolean {
  return resetAt === null || resetAt.getTime() <= now.getTime();
}

/**
 * Decide whether a scan is allowed and compute the counter to persist.
 * The window resets 24h after it first opened; a passed/absent reset time
 * starts a fresh window at count 1.
 */
export function evaluateQuota(
  state: QuotaState,
  max: number,
  now: Date = new Date(),
): QuotaDecision {
  const resetAt = state.quotaResetAt;
  if (windowExpired(resetAt, now)) {
    // Window absent or expired → start a fresh 24h window at count 1.
    return { allowed: true, newCount: 1, newResetAt: new Date(now.getTime() + DAY_MS) };
  }
  // windowExpired === false guarantees a live window (resetAt is non-null).
  const activeResetAt = resetAt as Date;

  if (state.dailyScanCount >= max) {
    return {
      allowed: false,
      newCount: state.dailyScanCount,
      newResetAt: activeResetAt,
      retryAt: activeResetAt,
    };
  }

  return { allowed: true, newCount: state.dailyScanCount + 1, newResetAt: activeResetAt };
}

/**
 * Read-only quota snapshot for GET /v1/me/quota — the same window logic as
 * evaluateQuota, without persisting anything. If the reset window has passed (or
 * never opened) the user is back to a full allowance and there is no active
 * reset time; otherwise remaining = max − count and the window's reset stands.
 */
export function quotaStatus(
  state: QuotaState,
  max: number,
  now: Date = new Date(),
): QuotaStatus {
  const resetAt = state.quotaResetAt;
  if (windowExpired(resetAt, now)) {
    return { scansRemaining: max, quotaResetsAt: null, dailyQuota: max };
  }
  return {
    scansRemaining: Math.max(0, max - state.dailyScanCount),
    quotaResetsAt: resetAt as Date,
    dailyQuota: max,
  };
}
