import { randomBytes } from 'node:crypto';
import pg from 'pg';
import { afterAll, inject } from 'vitest';
import { createApp } from '../src/app.js';
import { createPool, migrate, type Pool } from '../src/db.js';
import type { Pusher } from '../src/apns.js';

export interface Harness {
  pool: Pool;
  app: ReturnType<typeof createApp>;
  clock: { now: Date };
  pushes: { tokens: string[]; body: string }[];
  req: (method: string, path: string, opts?: { token?: string; body?: unknown; raw?: string; ip?: string }) => Promise<{ status: number; json: any; text: string }>;
  register: () => Promise<{ id: string; handle: string; token: string }>;
}

/** Fresh database per test file, migrated, with an app bound to a controllable clock. */
export async function harness(limits?: Parameters<typeof createApp>[0]['limits']): Promise<Harness> {
  const admin = new pg.Client({ connectionString: inject('pgAdminUrl') });
  await admin.connect();
  const name = `t_${randomBytes(6).toString('hex')}`;
  await admin.query(`CREATE DATABASE ${name}`);
  await admin.end();
  const url = new URL(inject('pgAdminUrl'));
  url.pathname = `/${name}`;
  const pool = createPool(url.toString());
  await migrate(pool);
  const clock = { now: new Date('2026-11-06T12:00:00Z') };
  const pushes: Harness['pushes'] = [];
  const pusher: Pusher = { async send(tokens, body) { pushes.push({ tokens: tokens.map((t) => t.token), body }); } };
  const app = createApp({
    pool,
    publicUrl: 'https://loop.test',
    now: () => clock.now,
    pusher,
    limits: limits ?? { register: 1e6, mapCells: 1e6, mapNow: 1e6, mapRead: 1e6, authed: 1e6 },
  });
  afterAll(async () => { await pool.end(); });

  const req: Harness['req'] = async (method, path, o = {}) => {
    const headers: Record<string, string> = {};
    if (o.token) headers.authorization = `Bearer ${o.token}`;
    if (o.ip) headers['x-forwarded-for'] = o.ip;
    let body: string | undefined = o.raw;
    if (o.body !== undefined) { body = JSON.stringify(o.body); }
    if (body !== undefined) headers['content-type'] = 'application/json';
    const res = await app.request(path, { method, headers, body });
    const text = await res.text();
    let json: any = null;
    try { json = JSON.parse(text); } catch { /* html */ }
    return { status: res.status, json, text };
  };
  const register = async () => {
    const token = randomBytes(32).toString('base64url');
    const r = await req('POST', '/v1/register', { body: { token } });
    if (r.status !== 200) throw new Error(`register ${r.status}`);
    return { ...r.json, token };
  };
  return { pool, app, clock, pushes, req, register };
}

export const tag = () => randomBytes(16).toString('base64url');
