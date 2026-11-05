import { describe, expect, it } from 'vitest';
import { harness, tag } from './helpers.js';
import { bbox, encode } from '../src/geohash.js';

const h = await harness();
const DAY = '2026-11-06';

// Singapore area.
const P7 = encode(1.3000, 103.8000, 7);
const box = (g: string, pad = 0.001) => { const b = bbox(g); return `${b.w - pad},${b.s - pad},${b.e + pad},${b.n + pad}`; };
const post = (cells: { g: string; t: string }[], day = DAY) => h.req('POST', '/v1/map/cells', { body: { day, cells } });
const get = async (bb: string, p = 7) => (await h.req('GET', `/v1/map?bbox=${bb}&p=${p}`)).json;

describe('map cells', () => {
  it('hides a square until 5 different people', async () => {
    const g = encode(1.3100, 103.8100, 7);
    for (let i = 0; i < 4; i++) expect((await post([{ g, t: tag() }])).status).toBe(200);
    expect((await get(box(g))).cells).toEqual([]);
    await post([{ g, t: tag() }]);
    expect((await get(box(g))).cells).toEqual([{ g, n: 5 }]);
  });

  it('counts the same tag once for people and every time for n', async () => {
    const g = encode(1.3200, 103.8200, 7);
    const t = tag();
    await post([{ g, t }, { g, t }]);
    await post([{ g, t }]);
    const row = (await h.pool.query('SELECT n, people, p, month FROM map_cells WHERE g = $1', [g])).rows[0];
    expect(row).toEqual({ n: 3, people: 1, p: 7, month: '2026-11-01' });
    expect((await h.pool.query('SELECT count(*)::int c FROM map_tags WHERE g = $1', [g])).rows[0].c).toBe(1);
  });

  it('stores nothing that links entries of one request', async () => {
    const cols = await h.pool.query(
      "SELECT table_name, column_name FROM information_schema.columns WHERE table_name IN ('map_cells','map_tags') ORDER BY 1, 2",
    );
    expect(cols.rows.map((r) => `${r.table_name}.${r.column_name}`)).toEqual([
      'map_cells.g', 'map_cells.lat', 'map_cells.lng', 'map_cells.month', 'map_cells.n', 'map_cells.p', 'map_cells.people',
      'map_tags.g', 'map_tags.month', 'map_tags.tag',
    ]);
  });

  it('sums n over the current and previous month and ignores older months', async () => {
    const g = encode(1.3300, 103.8300, 7);
    for (let i = 0; i < 5; i++) await post([{ g, t: tag() }], '2026-10-30');
    await post([{ g, t: tag() }]);
    expect((await get(box(g))).cells).toEqual([{ g, n: 6 }]);
    // A month later, October is "previous"; in January it is gone.
    h.clock.now = new Date('2027-01-10T00:00:00Z');
    expect((await get(box(g))).cells).toEqual([]);
    h.clock.now = new Date('2026-11-06T12:00:00Z');
  });

  it('falls back to coarser squares in quiet areas', async () => {
    // Five people, each in a different p7 square of the same p6 square: no p7 passes, the p6 does.
    const base = encode(1.4000, 103.9000, 6);
    const kids = '0123456789'.slice(0, 5).split('').map((c) => base + c);
    for (const k of kids) await post([{ g: k, t: tag() }, { g: base, t: tag() }]);
    const r = await get(box(base));
    expect(r.cells).toEqual([]);
    expect(r.blur).toEqual([{ g: base, n: 5 }]);

    // A p5-only area shows as p5.
    const p5 = encode(1.5000, 104.0000, 5);
    for (let i = 0; i < 5; i++) await post([{ g: p5, t: tag() }]);
    expect((await get(box(p5))).blur).toEqual([{ g: p5, n: 5 }]);

    // When a finer square passes, the coarse parent is not repeated.
    const fine = kids[0]!;
    for (let i = 0; i < 5; i++) await post([{ g: fine, t: tag() }]);
    const r2 = await get(box(base));
    expect(r2.cells).toEqual([{ g: fine, n: 6 }]);
    expect(r2.blur).toEqual([]);
  });

  it('filters by bbox', async () => {
    const r = await get('103.79,1.29,103.815,1.315');
    const gs = r.cells.map((c: any) => c.g);
    expect(gs).toContain(encode(1.3100, 103.8100, 7));
    expect(gs).not.toContain(encode(1.3300, 103.8300, 7));
    expect((await get('-10,-10,-9,-9')).cells).toEqual([]);
  });

  it('validates input', async () => {
    expect((await post([{ g: encode(1, 103, 4), t: tag() }])).status).toBe(400);
    expect((await post([{ g: encode(1, 103, 8), t: tag() }])).status).toBe(400);
    expect((await post([{ g: P7, t: 'short' }])).status).toBe(400);
    expect((await h.req('POST', '/v1/map/cells', { body: { day: DAY, cells: [{ g: P7, t: tag(), user: 'x' }] } })).status).toBe(400);
    expect((await h.req('POST', '/v1/map/cells', { body: { day: DAY, cells: [{ g: P7, t: tag() }], id: 1 } })).status).toBe(400);
    const many = Array.from({ length: 3001 }, () => ({ g: P7, t: tag() }));
    expect((await post(many)).status).toBe(400);
    const ok = Array.from({ length: 3000 }, () => ({ g: P7, t: tag() }));
    expect((await post(ok)).status).toBe(200);
    expect((await h.req('GET', '/v1/map?bbox=1,2,3')).status).toBe(400);
    expect((await h.req('GET', '/v1/map?bbox=0,10,1,5&p=7')).status).toBe(400);
    expect((await h.req('GET', '/v1/map?bbox=0,0,1,1&p=8')).status).toBe(400);
  });

  it('rejects bodies over 512 KB', async () => {
    const r = await h.req('POST', '/v1/map/cells', { raw: JSON.stringify({ day: DAY, cells: [], pad: 'x'.repeat(600 * 1024) }) });
    expect(r.status).toBe(413);
  });

  it('downgrades precision when a bbox holds too many squares', async () => {
    // 5001 qualifying p7 squares inserted directly (fast), all inside one p5 area.
    await h.pool.query(`
      INSERT INTO map_cells (g, p, month, n, people, lat, lng)
      SELECT 'zzz' || lpad(i::text, 4, '0'), 7, '2026-11-01', 5, 5, 10 + i * 0.00001, 10 FROM generate_series(0, 5000) i`);
    await h.pool.query(`INSERT INTO map_cells (g, p, month, n, people, lat, lng) VALUES ('zzzzz9', 6, '2026-11-01', 9, 9, 10.01, 10)`);
    const r = await get('9.9,9.9,10.2,10.2');
    expect(r.p).toBe(6);
    expect(r.cells).toEqual([{ g: 'zzzzz9', n: 9 }]);
  });
});

describe('live layer', () => {
  it('uses 5-minute buckets, shows only the current and previous bucket with 5+ people', async () => {
    const g = encode(1.2800, 103.8500, 5);
    h.clock.now = new Date('2026-11-06T12:03:00Z');
    for (let i = 0; i < 4; i++) expect((await h.req('POST', '/v1/map/now', { body: { g, t: tag() } })).status).toBe(200);
    const t = tag();
    await h.req('POST', '/v1/map/now', { body: { g, t } });
    await h.req('POST', '/v1/map/now', { body: { g, t } });
    const row = (await h.pool.query('SELECT bucket, people, n FROM live_cells WHERE g = $1', [g])).rows[0];
    expect(row.bucket.toISOString()).toBe('2026-11-06T12:00:00.000Z');
    expect(row).toMatchObject({ people: 5, n: 6 });
    expect((await get(box(g, 0.01))).live).toEqual([{ g, people: 5 }]);

    h.clock.now = new Date('2026-11-06T12:07:00Z'); // previous bucket still shown
    expect((await get(box(g, 0.01))).live).toEqual([{ g, people: 5 }]);
    h.clock.now = new Date('2026-11-06T12:10:00Z'); // two buckets later: gone
    expect((await get(box(g, 0.01))).live).toEqual([]);
    h.clock.now = new Date('2026-11-06T12:00:00Z');

    expect((await h.req('POST', '/v1/map/now', { body: { g: g + 'b', t: tag() } })).status).toBe(400);
  });
});
