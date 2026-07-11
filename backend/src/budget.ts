import { sql } from 'drizzle-orm';
import type { Db } from './db/client.js';
import { creditEvents } from './db/schema.js';

// Daily credit budget guard (spec §14). A world:generate call spends real money;
// we cap total credits spent per calendar day (DAILY_CREDIT_BUDGET). A single
// `credits_spent` column can't do this atomically under concurrency, so we use
// an append-only `credit_events` ledger and reserve inside a transaction.

/** Thrown when a reservation would exceed the daily budget. NOT retryable. */
export class BudgetExceededError extends Error {
  readonly requested: number;
  readonly spentToday: number;
  readonly budget: number;
  constructor(requested: number, spentToday: number, budget: number) {
    super(
      `daily credit budget exceeded: requested ${requested}, ` +
        `already spent ${spentToday} of ${budget} today`,
    );
    this.name = 'BudgetExceededError';
    this.requested = requested;
    this.spentToday = spentToday;
    this.budget = budget;
  }
}

/**
 * Pure boundary check — reserving `amount` on top of `spentToday` is allowed
 * only while the running total stays at or under `budget`. Exported for tests.
 */
export function wouldExceedBudget(
  spentToday: number,
  amount: number,
  budget: number,
): boolean {
  return spentToday + amount > budget;
}

// Stable advisory-lock key so concurrent reservations serialize (the sum +
// insert must be atomic; an aggregate can't be row-locked). Arbitrary constant.
const BUDGET_LOCK_KEY = 0x7645_7370; // "VtSp"

/**
 * Atomically reserve `amount` credits against today's budget. Inserts a
 * credit_events row iff today's sum + amount <= budget, else throws
 * BudgetExceededError. Runs in a transaction with a transaction-scoped advisory
 * lock so parallel workers can't both slip past the cap.
 */
export async function reserveCredits(
  db: Db,
  amount: number,
  budget: number,
  worldId?: string,
): Promise<void> {
  await db.transaction(async (tx) => {
    // Serialize budget checks across workers for the duration of this txn.
    await tx.execute(sql`SELECT pg_advisory_xact_lock(${BUDGET_LOCK_KEY})`);

    const res = await tx.execute<{ total: string | number | null }>(sql`
      SELECT COALESCE(SUM(amount), 0) AS total
      FROM credit_events
      WHERE created_at >= date_trunc('day', now())
    `);
    const rows = (res as unknown as { rows: { total: string | number | null }[] }).rows;
    const spentToday = Number(rows[0]?.total ?? 0);

    if (wouldExceedBudget(spentToday, amount, budget)) {
      throw new BudgetExceededError(amount, spentToday, budget);
    }

    await tx.insert(creditEvents).values({
      amount,
      worldId: worldId ?? null,
    });
  });
}
