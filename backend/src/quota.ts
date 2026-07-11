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
  if (resetAt === null || resetAt.getTime() <= now.getTime()) {
    // Window absent or expired → start a fresh 24h window at count 1.
    return { allowed: true, newCount: 1, newResetAt: new Date(now.getTime() + DAY_MS) };
  }

  if (state.dailyScanCount >= max) {
    return {
      allowed: false,
      newCount: state.dailyScanCount,
      newResetAt: resetAt,
      retryAt: resetAt,
    };
  }

  return { allowed: true, newCount: state.dailyScanCount + 1, newResetAt: resetAt };
}
