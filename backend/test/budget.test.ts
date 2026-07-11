import { describe, it, expect } from 'vitest';
import { wouldExceedBudget, BudgetExceededError } from '../src/budget.js';

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
