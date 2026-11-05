import { describe, expect, it } from 'vitest';
import { harness } from './helpers.js';
import { sha256 } from '../src/crypto.js';

const h = await harness();

describe('invites', () => {
  it('creates and accepts a single-use invite, storing only the hash', async () => {
    const a = await h.register();
    const b = await h.register();
    const inv = await h.req('POST', '/v1/invites', { token: a.token });
    expect(inv.json.code).toMatch(/^[0-9A-HJKMNP-TV-Z]{10}$/);
    expect(inv.json.url).toBe(`https://loop.test/i/${inv.json.code}`);
    const stored = await h.pool.query('SELECT code_hash, expires_at FROM invites WHERE inviter = $1', [a.id]);
    expect(stored.rows[0].code_hash.equals(sha256(inv.json.code))).toBe(true);
    expect(stored.rows[0].expires_at.toISOString()).toBe('2026-11-13T12:00:00.000Z');

    const acc = await h.req('POST', '/v1/invites/accept', { token: b.token, body: { code: inv.json.code.toLowerCase() } });
    expect(acc.status).toBe(200);
    expect(acc.json).toEqual({ friend: { id: a.id, handle: a.handle } });
    expect((await h.req('GET', '/v1/friends', { token: a.token })).json).toEqual([{ id: b.id, handle: b.handle }]);
    expect((await h.req('GET', '/v1/friends', { token: b.token })).json).toEqual([{ id: a.id, handle: a.handle }]);

    const c = await h.register();
    const again = await h.req('POST', '/v1/invites/accept', { token: c.token, body: { code: inv.json.code } });
    expect(again.status).toBe(410);
    expect(again.json.error).toBe('used');
  });

  it('rejects unknown, self and expired codes', async () => {
    const a = await h.register();
    const b = await h.register();
    expect((await h.req('POST', '/v1/invites/accept', { token: b.token, body: { code: '0000000000' } })).json.error).toBe('unknown');
    expect((await h.req('POST', '/v1/invites/accept', { token: b.token, body: { code: 'bad!' } })).status).toBe(404);
    const inv = await h.req('POST', '/v1/invites', { token: a.token });
    const self = await h.req('POST', '/v1/invites/accept', { token: a.token, body: { code: inv.json.code } });
    expect(self.status).toBe(400);
    expect(self.json.error).toBe('self');
    const saved = h.clock.now;
    h.clock.now = new Date(saved.getTime() + 7 * 86_400_000 + 1000);
    const exp = await h.req('POST', '/v1/invites/accept', { token: b.token, body: { code: inv.json.code } });
    h.clock.now = saved;
    expect(exp.status).toBe(410);
    expect(exp.json.error).toBe('expired');
  });

  it('caps friends at 50', async () => {
    const hub = await h.register();
    const day = '2026-11-06';
    const others = [];
    for (let i = 0; i < 50; i++) others.push(await h.register());
    await h.pool.query(
      `INSERT INTO friendships (a, b, created_on) SELECT $1, x, $3::date FROM unnest($2::uuid[]) x
       UNION ALL SELECT x, $1, $3::date FROM unnest($2::uuid[]) x`,
      [hub.id, others.map((o) => o.id), day],
    );
    const newcomer = await h.register();
    const inv = await h.req('POST', '/v1/invites', { token: hub.token });
    const r = await h.req('POST', '/v1/invites/accept', { token: newcomer.token, body: { code: inv.json.code } });
    expect(r.status).toBe(409);
    expect(r.json.error).toBe('friend_limit');
    // The invite was not consumed.
    const used = await h.pool.query('SELECT used FROM invites WHERE code_hash = $1', [sha256(inv.json.code)]);
    expect(used.rows[0].used).toBe(false);
    // After removing one friend there is room again.
    expect((await h.req('DELETE', `/v1/friends/${others[0]!.id}`, { token: hub.token })).status).toBe(200);
    expect((await h.req('POST', '/v1/invites/accept', { token: newcomer.token, body: { code: inv.json.code } })).status).toBe(200);
  });

  it('removes friends both ways', async () => {
    const a = await h.register();
    const b = await h.register();
    const inv = await h.req('POST', '/v1/invites', { token: a.token });
    await h.req('POST', '/v1/invites/accept', { token: b.token, body: { code: inv.json.code } });
    expect((await h.req('DELETE', `/v1/friends/${a.id}`, { token: b.token })).status).toBe(200);
    expect((await h.req('GET', '/v1/friends', { token: a.token })).json).toEqual([]);
    expect((await h.req('DELETE', `/v1/friends/${a.id}`, { token: b.token })).status).toBe(404);
    expect((await h.req('DELETE', '/v1/friends/not-a-uuid', { token: b.token })).status).toBe(404);
  });

  it('landing page does not reveal the inviter', async () => {
    const a = await h.register();
    const inv = await h.req('POST', '/v1/invites', { token: a.token });
    const page = await h.req('GET', `/i/${inv.json.code}`);
    expect(page.status).toBe(200);
    expect(page.text).toContain(`loop://invite/${inv.json.code}`);
    expect(page.text).toContain('Open in Loop');
    expect(page.text).toContain('Ask the friend who invited you for a TestFlight invite.');
    expect(page.text).not.toContain(a.handle);
    expect(page.text).not.toContain(a.id);
    expect(page.text).not.toContain('—');
    const junk = await h.req('GET', '/i/%3Cscript%3E');
    expect(junk.text).not.toContain('<script>');
    expect(junk.text).not.toContain('loop://invite/');
  });
});
