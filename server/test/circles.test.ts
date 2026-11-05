import { describe, expect, it } from 'vitest';
import { harness } from './helpers.js';

const h = await harness();

async function befriend(a: { token: string }, b: { token: string }) {
  const inv = await h.req('POST', '/v1/invites', { token: a.token });
  await h.req('POST', '/v1/invites/accept', { token: b.token, body: { code: inv.json.code } });
}
async function showup(u: { id: string }, day: string, kinds = 1) {
  await h.pool.query('INSERT INTO showups (user_id, day, kinds) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING', [u.id, day, kinds]);
}
const circles = async (u: { token: string }, date = '2026-11-06') => (await h.req('GET', `/v1/circles?date=${date}`, { token: u.token })).json;

describe('circles', () => {
  it('has no circles without friends or preferences', async () => {
    const a = await h.register();
    expect(await circles(a)).toEqual([]);
  });

  it('friends circle lists me and my friends with showedUpOnDate and week math', async () => {
    const a = await h.register();
    const b = await h.register();
    const c = await h.register();
    await befriend(a, b);
    await befriend(a, c);
    // ISO week of Fri 2026-11-06 is Mon 11-02 .. Sun 11-08.
    await showup(a, '2026-11-01'); // previous week (Sunday)
    await showup(a, '2026-11-02');
    await showup(a, '2026-11-06');
    await showup(b, '2026-11-08');
    await showup(c, '2026-11-09'); // next week (Monday)
    const list = await circles(a);
    expect(list).toHaveLength(1);
    const f = list[0];
    expect(f).toMatchObject({ id: 'friends', kind: 'friends', title: 'Friends', week: { done: 3, goal: 9 }, cheersForMeToday: 0 });
    expect(f.members[0]).toEqual({ id: a.id, handle: a.handle, me: true, showedUpOnDate: true });
    const byId = Object.fromEntries(f.members.map((m: any) => [m.id, m]));
    expect(byId[b.id]).toMatchObject({ me: false, showedUpOnDate: false });
    expect(byId[c.id]).toMatchObject({ me: false, showedUpOnDate: false });
    // A date in the next ISO week moves the window.
    const next = (await circles(a, '2026-11-09'))[0];
    expect(next.week).toEqual({ done: 1, goal: 9 });
    expect(next.members.find((m: any) => m.id === c.id).showedUpOnDate).toBe(true);
    // Sunday belongs to the week that started the Monday before.
    expect((await circles(a, '2026-11-01'))[0].week.done).toBe(1);
    // b sees their own friends circle: b and a only.
    expect((await circles(b))[0].members.map((m: any) => m.id).sort()).toEqual([a.id, b.id].sort());
  });

  it('assigns nearby and hour circles lazily and caps them at 12', async () => {
    const users = [];
    for (let i = 0; i < 13; i++) {
      const u = await h.register();
      await h.req('PUT', '/v1/me', { token: u.token, body: { area: 'tsq4', hour: 5 } });
      users.push(u);
    }
    expect((await h.pool.query("SELECT count(*)::int c FROM circles WHERE key = 'tsq4'")).rows[0].c).toBe(0);
    const ids = [];
    for (const u of users) {
      const list = await circles(u);
      expect(list.map((c: any) => c.title)).toEqual(['Nearby', 'Dawn']);
      ids.push(list[0].id);
    }
    expect(new Set(ids.slice(0, 12)).size).toBe(1);
    expect(ids[12]).not.toBe(ids[0]);
    const first = await circles(users[0]!);
    expect(first[0].members).toHaveLength(12);
    expect(first[0].week.goal).toBe(36);
    expect(first[1].members).toHaveLength(12);
    // Calling again does not duplicate membership.
    expect((await circles(users[0]!))[0].id).toBe(ids[0]);
    const m = await h.pool.query('SELECT count(*)::int c FROM circle_members WHERE user_id = $1', [users[0]!.id]);
    expect(m.rows[0].c).toBe(2);
  });

  it('maps hours to buckets', async () => {
    const expected: Record<number, string> = { 3: 'Night', 4: 'Dawn', 7: 'Dawn', 8: 'Morning', 12: 'Midday', 16: 'Evening', 19: 'Evening', 20: 'Night', 0: 'Night' };
    for (const [hour, title] of Object.entries(expected)) {
      const u = await h.register();
      await h.req('PUT', '/v1/me', { token: u.token, body: { hour: Number(hour), nearby: false } });
      expect((await circles(u)).map((c: any) => c.title)).toEqual([title]);
    }
  });

  it('respects preferences and leave', async () => {
    const a = await h.register();
    await h.req('PUT', '/v1/me', { token: a.token, body: { area: 'gcpv', hour: 18, sameHour: false } });
    let list = await circles(a);
    expect(list.map((c: any) => c.kind)).toEqual(['nearby']);
    const id = list[0].id;
    expect((await h.req('POST', `/v1/circles/${id}/leave`, { token: a.token })).status).toBe(200);
    expect((await h.req('GET', '/v1/me', { token: a.token })).json.nearby).toBe(false);
    expect(await circles(a)).toEqual([]);
    expect((await h.pool.query('SELECT count(*)::int c FROM circle_members WHERE user_id = $1', [a.id])).rows[0].c).toBe(0);
    expect((await h.req('POST', `/v1/circles/${id}/leave`, { token: a.token })).status).toBe(404);
    expect((await h.req('POST', '/v1/circles/friends/leave', { token: a.token })).status).toBe(404);
  });

  it('rejects bad dates', async () => {
    const a = await h.register();
    expect((await h.req('GET', '/v1/circles?date=2026-13-01', { token: a.token })).status).toBe(400);
  });
});

describe('cheers', () => {
  it('limits to one per person per day and one circle-wide per circle per day, and pushes anonymously', async () => {
    const a = await h.register();
    const b = await h.register();
    const c = await h.register();
    await befriend(a, b);
    await befriend(a, c);
    await h.req('PUT', '/v1/me', { token: b.token, body: { pushToken: 'cd'.repeat(32) } });
    h.pushes.length = 0;

    const r1 = await h.req('POST', '/v1/circles/friends/cheer', { token: a.token, body: { to: b.id } });
    expect(r1.status).toBe(200);
    expect(h.pushes).toEqual([{ tokens: ['cd'.repeat(32)], body: 'Someone in your Friends circle cheered you on.' }]);
    expect((await h.req('POST', '/v1/circles/friends/cheer', { token: a.token, body: { to: b.id } })).status).toBe(409);
    expect((await h.req('POST', '/v1/circles/friends/cheer', { token: a.token, body: { to: c.id } })).status).toBe(200);
    expect((await h.req('POST', '/v1/circles/friends/cheer', { token: a.token, body: {} })).status).toBe(200);
    expect((await h.req('POST', '/v1/circles/friends/cheer', { token: a.token, body: {} })).status).toBe(409);
    // Cannot cheer yourself or a non-member. b and c are not friends.
    expect((await h.req('POST', '/v1/circles/friends/cheer', { token: a.token, body: { to: a.id } })).status).toBe(400);
    expect((await h.req('POST', '/v1/circles/friends/cheer', { token: b.token, body: { to: c.id } })).status).toBe(400);

    // b got one direct and one circle-wide cheer today.
    expect((await circles(b))[0].cheersForMeToday).toBe(2);
    expect((await circles(a))[0].cheersForMeToday).toBe(0);

    // Next day the limit resets.
    h.clock.now = new Date('2026-11-07T08:00:00Z');
    expect((await h.req('POST', '/v1/circles/friends/cheer', { token: a.token, body: { to: b.id } })).status).toBe(200);
    h.clock.now = new Date('2026-11-06T12:00:00Z');
  });

  it('names no one in hour circle pushes and requires membership', async () => {
    const a = await h.register();
    const b = await h.register();
    const outsider = await h.register();
    for (const u of [a, b]) await h.req('PUT', '/v1/me', { token: u.token, body: { hour: 5, nearby: false, pushToken: 'ef'.repeat(32) } });
    await circles(a);
    const id = (await circles(b))[0].id;
    h.pushes.length = 0;
    expect((await h.req('POST', `/v1/circles/${id}/cheer`, { token: b.token, body: {} })).status).toBe(200);
    expect(h.pushes[0]!.body).toBe('Someone in your Dawn circle cheered you on.');
    expect(h.pushes[0]!.body).not.toContain(b.handle);
    expect((await circles(a))[0].cheersForMeToday).toBe(1);
    expect((await h.req('POST', `/v1/circles/${id}/cheer`, { token: outsider.token, body: {} })).status).toBe(404);
  });
});
