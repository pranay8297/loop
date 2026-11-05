import type { Pool } from './db.js';
import { addDays, addMonths, monthStart, utcDay } from './dates.js';

export interface RetentionResult { [table: string]: number }

/** Deletes data past its keep period. Safe to run any time. */
export async function runRetention(pool: Pool, now = new Date()): Promise<RetentionResult> {
  const today = utcDay(now);
  const month = monthStart(today);
  const day = 86_400_000;
  const q = async (sql: string, params: unknown[]) => (await pool.query(sql, params)).rowCount ?? 0;
  return {
    showups: await q('DELETE FROM showups WHERE day < $1', [addDays(today, -70)]),
    cheers: await q('DELETE FROM cheers WHERE day < $1', [addDays(today, -14)]),
    // An invite is created 7 days before it expires, so a used invite is older than 7 days once expires_at has passed.
    invites: await q('DELETE FROM invites WHERE expires_at < $1 OR (used AND expires_at < $2)', [new Date(now.getTime() - 7 * day), now]),
    map_tags: await q('DELETE FROM map_tags WHERE month < $1', [addMonths(month, -3)]),
    map_cells: await q('DELETE FROM map_cells WHERE month < $1', [addMonths(month, -3)]),
    live_tags: await q('DELETE FROM live_tags WHERE bucket < $1', [new Date(now.getTime() - 2 * 3_600_000)]),
    live_cells: await q('DELETE FROM live_cells WHERE bucket < $1', [new Date(now.getTime() - 2 * 3_600_000)]),
    circles: await q('DELETE FROM circles WHERE month < $1', [addMonths(month, -2)]),
  };
}
