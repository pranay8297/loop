import { describe, expect, it } from 'vitest';
import { harness } from './helpers.js';
import { runRetention } from '../src/retention.js';

const h = await harness();

describe('retention', () => {
  it('deletes only rows past their keep period', async () => {
    const a = await h.register();
    const b = await h.register();
    const q = (sql: string, p: unknown[] = []) => h.pool.query(sql, p);
    const now = new Date('2026-11-06T12:00:00Z');
    // showups: 10 weeks = 70 days -> keep 2026-08-28 and later
    await q("INSERT INTO showups VALUES ($1, '2026-08-27', 1), ($1, '2026-08-28', 1), ($1, '2026-11-06', 1)", [a.id]);
    // cheers: 14 days -> keep 2026-10-23 and later
    await q("INSERT INTO cheers VALUES ('friends:x', $1, $2, '2026-10-22'), ('friends:x', $1, $2, '2026-10-23')", [a.id, b.id]);
    // invites
    await q(`INSERT INTO invites (code_hash, inviter, expires_at, used) VALUES
      ('\\x01', $1, '2026-10-29T11:00:00Z', false),  -- expired more than 7 days ago: delete
      ('\\x02', $1, '2026-11-01T00:00:00Z', false),  -- expired recently: keep
      ('\\x03', $1, '2026-11-05T00:00:00Z', true),   -- used and older than 7 days: delete
      ('\\x04', $1, '2026-11-10T00:00:00Z', true)    -- used, created 3 days ago: keep
    `, [a.id]);
    // map: keep 2026-08-01 and later
    await q(`INSERT INTO map_cells VALUES ('w21z7bb', 7, '2026-07-01', 1, 1, 0, 0), ('w21z7bb', 7, '2026-08-01', 1, 1, 0, 0)`);
    await q(`INSERT INTO map_tags VALUES ('w21z7bb', '2026-07-01', '\\x01'), ('w21z7bb', '2026-08-01', '\\x01')`);
    // live: 2 hours
    await q(`INSERT INTO live_cells VALUES ('w21z7', '2026-11-06T09:55:00Z', 1, 1, 0, 0), ('w21z7', '2026-11-06T10:05:00Z', 1, 1, 0, 0)`);
    await q(`INSERT INTO live_tags VALUES ('w21z7', '2026-11-06T09:55:00Z', '\\x01'), ('w21z7', '2026-11-06T10:05:00Z', '\\x01')`);
    // circles: keep 2026-09-01 and later
    const old = await q(`INSERT INTO circles (kind, key, month) VALUES ('hour', 'dawn', '2026-08-01') RETURNING id`);
    const keep = await q(`INSERT INTO circles (kind, key, month) VALUES ('hour', 'dawn', '2026-09-01') RETURNING id`);
    await q('INSERT INTO circle_members VALUES ($1, $3), ($2, $3)', [old.rows[0].id, keep.rows[0].id, a.id]);

    const r = await runRetention(h.pool, now);
    expect(r).toEqual({ showups: 1, cheers: 1, invites: 2, map_tags: 1, map_cells: 1, live_tags: 1, live_cells: 1, circles: 1 });

    const days = (await q('SELECT day FROM showups ORDER BY day')).rows.map((x) => x.day);
    expect(days).toEqual(['2026-08-28', '2026-11-06']);
    expect((await q('SELECT day FROM cheers')).rows.map((x) => x.day)).toEqual(['2026-10-23']);
    expect((await q('SELECT code_hash FROM invites ORDER BY code_hash')).rows.map((x) => x.code_hash.toString('hex'))).toEqual(['02', '04']);
    expect((await q('SELECT month FROM map_cells')).rows).toEqual([{ month: '2026-08-01' }]);
    expect((await q('SELECT month FROM map_tags')).rows).toEqual([{ month: '2026-08-01' }]);
    expect((await q('SELECT count(*)::int c FROM live_cells')).rows[0].c).toBe(1);
    expect((await q('SELECT circle_id FROM circle_members')).rows).toEqual([{ circle_id: keep.rows[0].id }]);
    // Running again is a no-op.
    expect(Object.values(await runRetention(h.pool, now)).every((n) => n === 0)).toBe(true);
  });
});
