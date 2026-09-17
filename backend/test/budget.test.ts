import { describe, it, expect, vi } from 'vitest';
import { wouldExceedBudget, releaseCredits, BudgetExceededError } from '../src/budget.js';
import { creditEvents } from '../src/db/schema.js';
import type { Db } from '../src/db/client.js';

// Budget boundary math (spec §14). Reserving is allowed only while the running
// total stays AT OR UNDER the cap.
describe('wouldExceedBudget', () => {
  it('allows a reservation that lands exactly on the budget', () => {
    // 350 already spent + 150 draft = 500 == budget → allowed.
    expect(wouldExceedBudget(350, 150, 500)).toBe(false);
  });

  it('rejects a reservation that overshoots by one', () => {
    expect(wouldExceedBudget(351, 150, 500)).toBe(true);
  });

  it('rejects when already at the cap and any amount is requested', () => {
    expect(wouldExceedBudget(500, 1, 500)).toBe(true);
  });

  it('allows the first spend of the day', () => {
    expect(wouldExceedBudget(0, 1500, 1500)).toBe(false);
    expect(wouldExceedBudget(0, 1501, 1500)).toBe(true);
  });
});

// Releasing a reservation that provably bought nothing (spec §10 R1). The ledger
// is append-only and the daily guard is a SUM, so a release is a COMPENSATING
// negative entry — never a delete or an update.
describe('releaseCredits', () => {
  function fakeDb() {
    const inserts: { table: unknown; values: Record<string, unknown> }[] = [];
    const db = {
      insert: (table: unknown) => ({
        values: vi.fn(async (values: Record<string, unknown>) => {
          inserts.push({ table, values });
        }),
      }),
    } as unknown as Db;
    return { db, inserts };
  }

  it('appends a negative event for the same world', async () => {
    const { db, inserts } = fakeDb();
    await releaseCredits(db, 150, 'w-1');

    expect(inserts).toHaveLength(1);
    expect(inserts[0]!.table).toBe(creditEvents);
    expect(inserts[0]!.values).toEqual({ amount: -150, worldId: 'w-1' });
  });

  it('nets the day back to zero against its reservation', async () => {
    const { db, inserts } = fakeDb();
    await releaseCredits(db, 1500);
    expect(1500 + (inserts[0]!.values['amount'] as number)).toBe(0);
    expect(inserts[0]!.values['worldId']).toBeNull();
  });

  it('is a no-op for a zero-cost (mock mode) reservation', async () => {
    const { db, inserts } = fakeDb();
    await releaseCredits(db, 0, 'w-1');
    expect(inserts).toHaveLength(0);
  });
});

describe('BudgetExceededError', () => {
  it('carries the requested / spent / budget context', () => {
    const err = new BudgetExceededError(150, 400, 500);
    expect(err).toBeInstanceOf(Error);
    expect(err.name).toBe('BudgetExceededError');
    expect(err.requested).toBe(150);
    expect(err.spentToday).toBe(400);
    expect(err.budget).toBe(500);
  });
});
