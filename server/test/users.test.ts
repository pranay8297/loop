import { describe, expect, it } from 'vitest';
import { harness, tag } from './helpers.js';

const h = await harness();

async function count(table: string, where = 'true', params: unknown[] = []) {
  return (await h.pool.query(`SELECT count(*)::int AS c FROM ${table} WHERE ${where}`, params)).rows[0].c as number;
}

describe('register and me', () => {
  it('is idempotent for the same token', async () => {
    const a = await h.register();
    const again = await h.req('POST', '/v1/register', { body: { token: a.token } });
    expect(again.json).toEqual({ id: a.id, handle: a.handle });
    expect(a.handle).toMatch(/^[A-Z][a-z]+ \d{2}$/);
  });
  it('rejects bad tokens and unknown fields', async () => {
    expect((await h.req('POST', '/v1/register', { body: { token: 'short' } })).status).toBe(400);
    expect((await h.req('POST', '/v1/register', { body: { token: 'a'.repeat(43), name: 'x' } })).status).toBe(400);
    expect((await h.req('POST', '/v1/register', { raw: '{bad' })).status).toBe(400);
  });
  it('requires auth', async () => {
    expect((await h.req('GET', '/v1/me')).status).toBe(401);
    expect((await h.req('GET', '/v1/me', { token: 'x'.repeat(43) })).status).toBe(401);
    expect((await h.req('GET', '/v1/friends')).status).toBe(401);
    expect((await h.req('GET', '/v1/circles')).status).toBe(401);
    expect((await h.req('POST', '/v1/showups', { body: { day: '2026-11-06', kinds: 1 } })).status).toBe(401);
  });
  it('updates preferences with validation', async () => {
    const a = await h.register();
    const r = await h.req('PUT', '/v1/me', { token: a.token, body: { area: 'w21z', hour: 6, sameHour: false, pushToken: '12'.repeat(32), pushEnv: 'sandbox' } });
    expect(r.json).toMatchObject({ area: 'w21z', hour: 6, nearby: true, sameHour: false });
    expect((await h.req('PUT', '/v1/me', { token: a.token, body: { area: 'w21z1' } })).status).toBe(400);
    expect((await h.req('PUT', '/v1/me', { token: a.token, body: { hour: 24 } })).status).toBe(400);
    expect((await h.req('PUT', '/v1/me', { token: a.token, body: { pushEnv: 'dev' } })).status).toBe(400);
    expect((await h.req('PUT', '/v1/me', { token: a.token, body: { email: 'a@b.c' } })).status).toBe(400);
    expect((await h.req('GET', '/v1/me', { token: a.token })).json).toMatchObject({ area: 'w21z', hour: 6 });
  });
});

describe('DELETE /v1/me', () => {
  it('removes every linked row and keeps anonymous map counts', async () => {
    const a = await h.register();
    const b = await h.register();
    const c = await h.register();
    await h.req('PUT', '/v1/me', { token: a.token, body: { area: 'w21z', hour: 6, pushToken: 'ab'.repeat(32) } });
    await h.req('PUT', '/v1/me', { token: c.token, body: { area: 'w21z', hour: 6 } });
    const inv = await h.req('POST', '/v1/invites', { token: a.token });
    await h.req('POST', '/v1/invites/accept', { token: b.token, body: { code: inv.json.code } });
    await h.req('POST', '/v1/invites', { token: a.token });
    await h.req('POST', '/v1/showups', { token: a.token, body: { day: '2026-11-06', kinds: 1 } });
    await h.req('GET', '/v1/circles', { token: a.token });
    const circles = (await h.req('GET', '/v1/circles', { token: c.token })).json;
    await h.req('POST', '/v1/circles/friends/cheer', { token: a.token, body: { to: b.id } });
    await h.req('POST', '/v1/circles/friends/cheer', { token: b.token, body: { to: a.id } });
    await h.req('POST', `/v1/circles/${circles[0].id}/cheer`, { token: c.token, body: {} });
    await h.req('POST', '/v1/map/cells', { body: { day: '2026-11-06', cells: [{ g: 'w21z7bb', t: tag() }] } });

    expect(await count('friendships', 'a = $1 OR b = $1', [a.id])).toBe(2);
    expect(await count('circle_members', 'user_id = $1', [a.id])).toBe(2);
    expect(await count('showups', 'user_id = $1', [a.id])).toBe(1);
    expect(await count('invites', 'inviter = $1', [a.id])).toBe(2);
    expect(await count('cheers', 'from_user = $1 OR to_user = $1 OR to_user IS NULL', [a.id])).toBe(3);

    const del = await h.req('DELETE', '/v1/me', { token: a.token });
    expect(del.status).toBe(200);

    expect(await count('users', 'id = $1', [a.id])).toBe(0);
    expect(await count('friendships', 'a = $1 OR b = $1', [a.id])).toBe(0);
    expect(await count('circle_members', 'user_id = $1', [a.id])).toBe(0);
    expect(await count('showups', 'user_id = $1', [a.id])).toBe(0);
    expect(await count('invites', 'inviter = $1', [a.id])).toBe(0);
    expect(await count('cheers', 'from_user = $1 OR to_user = $1', [a.id])).toBe(0);
    expect(await count('users', 'push_token = $1', ['ab'.repeat(32)])).toBe(0);
    // Other people's rows remain.
    expect(await count('users', 'id = ANY($1::uuid[])', [[b.id, c.id]])).toBe(2);
    expect(await count('cheers', 'from_user = $1', [c.id])).toBe(1);
    expect(await count('map_cells')).toBe(1);
    expect((await h.req('GET', '/v1/me', { token: a.token })).status).toBe(401);
  });
});

describe('showups', () => {
  it('upserts by OR-ing kinds and enforces the day window', async () => {
    const a = await h.register();
    const r1 = await h.req('POST', '/v1/showups', { token: a.token, body: { day: '2026-11-06', kinds: 1 } });
    expect(r1.json).toEqual({ day: '2026-11-06', kinds: 1 });
    const r2 = await h.req('POST', '/v1/showups', { token: a.token, body: { day: '2026-11-06', kinds: 6 } });
    expect(r2.json).toEqual({ day: '2026-11-06', kinds: 7 });
    expect(await count('showups', 'user_id = $1', [a.id])).toBe(1);
    expect((await h.req('POST', '/v1/showups', { token: a.token, body: { day: '2026-11-04', kinds: 1 } })).status).toBe(200);
    expect((await h.req('POST', '/v1/showups', { token: a.token, body: { day: '2026-11-07', kinds: 1 } })).status).toBe(200);
    expect((await h.req('POST', '/v1/showups', { token: a.token, body: { day: '2026-11-03', kinds: 1 } })).status).toBe(400);
    expect((await h.req('POST', '/v1/showups', { token: a.token, body: { day: '2026-11-08', kinds: 1 } })).status).toBe(400);
    expect((await h.req('POST', '/v1/showups', { token: a.token, body: { day: '2026-02-30', kinds: 1 } })).status).toBe(400);
    expect((await h.req('POST', '/v1/showups', { token: a.token, body: { day: '2026-11-06', kinds: 0 } })).status).toBe(400);
    expect((await h.req('POST', '/v1/showups', { token: a.token, body: { day: '2026-11-06', kinds: 32 } })).status).toBe(400);
  });
});
