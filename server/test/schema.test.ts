import { describe, expect, it } from 'vitest';
import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { harness } from './helpers.js';

const h = await harness();

const FORBIDDEN = /name|phone|email|contact|ip|lat|lng|route|distance|pace|duration/;
const ALLOWED = new Set(['map_cells.lat', 'map_cells.lng', 'live_cells.lat', 'live_cells.lng', 'users.handle']);

describe('privacy audit', () => {
  it('has no column that could hold personal data', async () => {
    const r = await h.pool.query(
      "SELECT table_name, column_name FROM information_schema.columns WHERE table_schema = 'public' ORDER BY 1, 2",
    );
    expect(r.rows.length).toBeGreaterThan(30);
    const bad = r.rows.map((x) => `${x.table_name}.${x.column_name}`).filter((c) => FORBIDDEN.test(c.split('.')[1]!) && !ALLOWED.has(c));
    expect(bad).toEqual([]);
  });

  it('has no logging middleware or request logging in the source', () => {
    const dir = path.resolve(import.meta.dirname, '..', 'src');
    for (const f of readdirSync(dir)) {
      const src = readFileSync(path.join(dir, f), 'utf8');
      expect(src, f).not.toMatch(/hono\/logger|morgan|pino|winston/);
      expect(src, f).not.toMatch(/console\.\w+\([^)]*(header|body|ip|token|remote)/i);
    }
  });

  it('privacy and support pages carry no em dashes and list the essentials', async () => {
    const p = await h.req('GET', '/privacy');
    expect(p.status).toBe(200);
    for (const s of ['random ID', 'made-up handle', 'Showed-up days', '14 days', 'notification token', 'Anonymous map counts', 'IP addresses are not logged', 'Delete my data', 'github.com/pranay8297/loop']) {
      expect(p.text).toContain(s);
    }
    expect(p.text).not.toContain('—');
    const s = await h.req('GET', '/support');
    expect(s.status).toBe(200);
    expect(s.text).not.toContain('—');
  });

  it('health pings the database', async () => {
    expect((await h.req('GET', '/health')).json).toEqual({ ok: true, db: true });
  });
});
