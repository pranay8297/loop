import { Hono, type Context, type MiddlewareHandler } from 'hono';
import { bodyLimit } from 'hono/body-limit';
import { getConnInfo } from '@hono/node-server/conninfo';
import { z } from 'zod';
import type { Pool } from './db.js';
import { tx } from './db.js';
import { sha256, fromB64url, newInviteCode, normalizeInviteCode, INVITE_RE, ipKey } from './crypto.js';
import { newHandle } from './handles.js';
import { RateLimiter, DEFAULT_LIMITS, type Limits } from './ratelimit.js';
import { addDays, addMonths, isDay, isoMonday, liveBucket, monthStart, utcDay } from './dates.js';
import { decode, isGeohash } from './geohash.js';
import { noopPusher, type Pusher } from './apns.js';
import { invitePage, privacyPage, supportPage } from './pages.js';

/** A map square is shown only once this many different people passed through it. */
export const K_ANON = 5;
export const MAX_FRIENDS = 50;
export const CIRCLE_SIZE = 12;
export const WEEKLY_GOAL_PER_MEMBER = 3;
export const MAX_MAP_CELLS = 5000;
export const MAX_MAP_ENTRIES = 3000;
export const BODY_LIMIT = 512 * 1024;
export const INVITE_DAYS = 7;

export interface AppOptions {
  pool: Pool;
  publicUrl: string;
  now?: () => Date;
  pusher?: Pusher;
  limits?: Partial<Limits>;
}

interface User {
  id: string;
  handle: string;
  area: string | null;
  hour: number | null;
  nearby: boolean;
  same_hour: boolean;
}

type Env = { Variables: { user: User } };

class HttpError extends Error {
  constructor(public status: number, public code: string) { super(code); }
}

const TOKEN = z.string().regex(/^[A-Za-z0-9_-]{43}$/);
const TAG = z.string().regex(/^[A-Za-z0-9_-]{22}$/);
const DAY = z.string().refine(isDay, 'day');
const GH5_7 = z.string().refine((g) => isGeohash(g) && g.length >= 5 && g.length <= 7, 'geohash');

const schemas = {
  register: z.strictObject({ token: TOKEN }),
  me: z.strictObject({
    area: z.string().refine((g) => isGeohash(g, 4), 'area').nullable().optional(),
    hour: z.number().int().min(0).max(23).nullable().optional(),
    nearby: z.boolean().optional(),
    sameHour: z.boolean().optional(),
    pushToken: z.string().regex(/^[0-9a-fA-F]{32,200}$/).nullable().optional(),
    pushEnv: z.enum(['sandbox', 'production']).nullable().optional(),
  }),
  accept: z.strictObject({ code: z.string().min(1).max(20) }),
  showup: z.strictObject({ day: DAY, kinds: z.number().int().min(1).max(31) }),
  cheer: z.strictObject({ to: z.uuid().optional() }),
  mapCells: z.strictObject({
    day: DAY,
    cells: z.array(z.strictObject({ g: GH5_7, t: TAG })).min(1).max(MAX_MAP_ENTRIES),
  }),
  mapNow: z.strictObject({ g: z.string().refine((g) => isGeohash(g, 5), 'geohash'), t: TAG }),
};

async function body<T extends z.ZodType>(c: Context, schema: T): Promise<z.infer<T>> {
  let raw: unknown;
  try {
    const text = await c.req.text();
    raw = text ? JSON.parse(text) : {};
  } catch {
    throw new HttpError(400, 'invalid_json');
  }
  const r = schema.safeParse(raw);
  if (!r.success) throw new HttpError(400, 'invalid');
  return r.data;
}

function clientIp(c: Context): string {
  // Railway's edge sets X-Real-IP. Otherwise use the hop the nearest proxy appended:
  // the first X-Forwarded-For entry is whatever the client sent, so it can't key a limit.
  const real = c.req.header('x-real-ip');
  if (real) return real.trim();
  const fwd = c.req.header('x-forwarded-for');
  if (fwd) return fwd.split(',').at(-1)!.trim();
  try {
    return getConnInfo(c).remote.address ?? 'unknown';
  } catch {
    return 'unknown';
  }
}

const HOUR_BUCKETS: { key: string; title: string; hours: number[] }[] = [
  { key: 'dawn', title: 'Dawn', hours: [4, 5, 6, 7] },
  { key: 'morning', title: 'Morning', hours: [8, 9, 10, 11] },
  { key: 'midday', title: 'Midday', hours: [12, 13, 14, 15] },
  { key: 'evening', title: 'Evening', hours: [16, 17, 18, 19] },
  { key: 'night', title: 'Night', hours: [20, 21, 22, 23, 0, 1, 2, 3] },
];
export function hourBucket(hour: number): { key: string; title: string } {
  return HOUR_BUCKETS.find((b) => b.hours.includes(hour))!;
}
function circleTitle(kind: string, key: string): string {
  if (kind === 'friends') return 'Friends';
  if (kind === 'nearby') return 'Nearby';
  return HOUR_BUCKETS.find((b) => b.key === key)?.title ?? 'Circle';
}

export function createApp(opts: AppOptions) {
  const { pool } = opts;
  const now = opts.now ?? (() => new Date());
  const pusher = opts.pusher ?? noopPusher;
  const limits: Limits = { ...DEFAULT_LIMITS, ...opts.limits };
  const limiter = new RateLimiter();
  const publicUrl = opts.publicUrl.replace(/\/$/, '');

  const app = new Hono<Env>();

  app.onError((err, c) => {
    if (err instanceof HttpError) return c.json({ error: err.code }, err.status as 400);
    // Message and route only. Never bodies, headers, tokens or addresses.
    console.error(`[error] ${c.req.method} ${c.req.routePath}: ${err.message}`);
    return c.json({ error: 'server_error' }, 500);
  });
  app.notFound((c) => c.json({ error: 'not_found' }, 404));

  app.use('*', bodyLimit({ maxSize: BODY_LIMIT, onError: (c) => c.json({ error: 'too_large' }, 413) }));

  const ipLimit = (name: string, limit: () => number, windowMs: number): MiddlewareHandler => async (c, next) => {
    if (!limiter.hit(`${name}:${ipKey(clientIp(c))}`, limit(), windowMs)) throw new HttpError(429, 'rate_limited');
    await next();
  };

  const auth: MiddlewareHandler<Env> = async (c, next) => {
    const m = /^Bearer ([A-Za-z0-9_-]{43})$/.exec(c.req.header('authorization') ?? '');
    if (!m) throw new HttpError(401, 'unauthorized');
    const hash = sha256(m[1]!);
    if (!limiter.hit(`t:${hash.toString('base64url')}`, limits.authed, 60_000)) throw new HttpError(429, 'rate_limited');
    const r = await pool.query<User>('SELECT id, handle, area, hour, nearby, same_hour FROM users WHERE token_hash = $1', [hash]);
    if (!r.rows[0]) throw new HttpError(401, 'unauthorized');
    c.set('user', r.rows[0]);
    await next();
  };

  // ---------- public ----------

  app.get('/health', async (c) => {
    try {
      await pool.query('SELECT 1');
      return c.json({ ok: true, db: true });
    } catch {
      return c.json({ ok: false, db: false }, 503);
    }
  });

  app.get('/privacy', (c) => c.html(privacyPage()));
  app.get('/support', (c) => c.html(supportPage()));
  app.get('/i/:code', (c) => {
    const code = normalizeInviteCode(c.req.param('code'));
    return c.html(invitePage(INVITE_RE.test(code) ? code : null));
  });

  app.post('/v1/register', ipLimit('register', () => limits.register, 3_600_000), async (c) => {
    const { token } = await body(c, schemas.register);
    const raw = fromB64url(token);
    if (!raw || raw.length !== 32) throw new HttpError(400, 'invalid');
    const hash = sha256(token);
    await pool.query(
      'INSERT INTO users (token_hash, handle, created_on) VALUES ($1, $2, $3) ON CONFLICT (token_hash) DO NOTHING',
      [hash, newHandle(), utcDay(now())],
    );
    const r = await pool.query<{ id: string; handle: string }>('SELECT id, handle FROM users WHERE token_hash = $1', [hash]);
    return c.json(r.rows[0]);
  });

  // ---------- me ----------

  app.use('/v1/me', auth);
  app.get('/v1/me', (c) => {
    const u = c.get('user');
    return c.json({ id: u.id, handle: u.handle, area: u.area, hour: u.hour, nearby: u.nearby, sameHour: u.same_hour });
  });
  app.put('/v1/me', async (c) => {
    const u = c.get('user');
    const b = await body(c, schemas.me);
    const sets: string[] = [];
    const vals: unknown[] = [u.id];
    const set = (col: string, v: unknown) => { vals.push(v); sets.push(`${col} = $${vals.length}`); };
    if (b.area !== undefined) set('area', b.area);
    if (b.hour !== undefined) set('hour', b.hour);
    if (b.nearby !== undefined) set('nearby', b.nearby);
    if (b.sameHour !== undefined) set('same_hour', b.sameHour);
    if (b.pushToken !== undefined) set('push_token', b.pushToken);
    if (b.pushEnv !== undefined) set('push_env', b.pushEnv);
    const r = sets.length
      ? await pool.query<User>(`UPDATE users SET ${sets.join(', ')} WHERE id = $1 RETURNING id, handle, area, hour, nearby, same_hour`, vals)
      : { rows: [u] };
    const n = r.rows[0]!;
    return c.json({ id: n.id, handle: n.handle, area: n.area, hour: n.hour, nearby: n.nearby, sameHour: n.same_hour });
  });
  app.delete('/v1/me', async (c) => {
    // Every linked row cascades from users. Anonymous map counts are not linked and stay.
    await pool.query('DELETE FROM users WHERE id = $1', [c.get('user').id]);
    return c.json({ ok: true });
  });

  // ---------- invites and friends ----------

  app.use('/v1/invites', auth);
  app.use('/v1/invites/*', auth);
  app.use('/v1/friends', auth);
  app.use('/v1/friends/*', auth);

  app.post('/v1/invites', async (c) => {
    const code = newInviteCode();
    const expires = new Date(now().getTime() + INVITE_DAYS * 86_400_000);
    await pool.query('INSERT INTO invites (code_hash, inviter, expires_at) VALUES ($1, $2, $3)', [sha256(code), c.get('user').id, expires]);
    return c.json({ code, url: `${publicUrl}/i/${code}` });
  });

  app.post('/v1/invites/accept', async (c) => {
    const me = c.get('user');
    const code = normalizeInviteCode((await body(c, schemas.accept)).code);
    if (!INVITE_RE.test(code)) throw new HttpError(404, 'unknown');
    const friend = await tx(pool, async (db) => {
      const r = await db.query<{ inviter: string; expires_at: Date; used: boolean }>(
        'SELECT inviter, expires_at, used FROM invites WHERE code_hash = $1 FOR UPDATE',
        [sha256(code)],
      );
      const inv = r.rows[0];
      if (!inv) throw new HttpError(404, 'unknown');
      if (inv.inviter === me.id) throw new HttpError(400, 'self');
      if (inv.used) throw new HttpError(410, 'used');
      if (inv.expires_at.getTime() <= now().getTime()) throw new HttpError(410, 'expired');
      // Lock both users in a stable order so the friend cap holds under concurrency.
      const ids = [me.id, inv.inviter].sort();
      await db.query('SELECT id FROM users WHERE id = ANY($1::uuid[]) ORDER BY id FOR UPDATE', [ids]);
      const already = await db.query('SELECT 1 FROM friendships WHERE a = $1 AND b = $2', [me.id, inv.inviter]);
      if (!already.rowCount) {
        const counts = await db.query<{ a: string; c: number }>(
          'SELECT a, count(*)::int AS c FROM friendships WHERE a = ANY($1::uuid[]) GROUP BY a',
          [ids],
        );
        if (counts.rows.some((x) => x.c >= MAX_FRIENDS)) throw new HttpError(409, 'friend_limit');
        const day = utcDay(now());
        await db.query('INSERT INTO friendships (a, b, created_on) VALUES ($1, $2, $3), ($2, $1, $3)', [me.id, inv.inviter, day]);
      }
      await db.query('UPDATE invites SET used = true WHERE code_hash = $1', [sha256(code)]);
      const f = await db.query<{ id: string; handle: string }>('SELECT id, handle FROM users WHERE id = $1', [inv.inviter]);
      return f.rows[0]!;
    });
    return c.json({ friend });
  });

  app.get('/v1/friends', async (c) => {
    const r = await pool.query<{ id: string; handle: string }>(
      'SELECT u.id, u.handle FROM friendships f JOIN users u ON u.id = f.b WHERE f.a = $1 ORDER BY u.handle',
      [c.get('user').id],
    );
    return c.json(r.rows);
  });

  app.delete('/v1/friends/:id', async (c) => {
    const id = c.req.param('id');
    if (!z.uuid().safeParse(id).success) throw new HttpError(404, 'not_found');
    const me = c.get('user').id;
    const r = await pool.query('DELETE FROM friendships WHERE (a = $1 AND b = $2) OR (a = $2 AND b = $1)', [me, id]);
    if (!r.rowCount) throw new HttpError(404, 'not_found');
    return c.json({ ok: true });
  });

  // ---------- showups ----------

  app.use('/v1/showups', auth);
  app.post('/v1/showups', async (c) => {
    const { day, kinds } = await body(c, schemas.showup);
    const today = utcDay(now());
    if (day < addDays(today, -2) || day > addDays(today, 1)) throw new HttpError(400, 'day_out_of_range');
    const r = await pool.query<{ day: string; kinds: number }>(
      `INSERT INTO showups (user_id, day, kinds) VALUES ($1, $2, $3)
       ON CONFLICT (user_id, day) DO UPDATE SET kinds = showups.kinds | EXCLUDED.kinds
       RETURNING day, kinds`,
      [c.get('user').id, day, kinds],
    );
    return c.json(r.rows[0]);
  });

  // ---------- circles ----------

  app.use('/v1/circles', auth);
  app.use('/v1/circles/*', auth);

  /** Lazily places the user in this month's circle for kind/key, creating one when all are full. */
  async function ensureCircle(userId: string, kind: 'nearby' | 'hour', key: string, month: string): Promise<string> {
    return tx(pool, async (db) => {
      await db.query('SELECT pg_advisory_xact_lock(hashtext($1))', [`circle:${kind}:${key}:${month}`]);
      const mine = await db.query<{ id: string; key: string }>(
        `SELECT c.id, c.key FROM circle_members m JOIN circles c ON c.id = m.circle_id
         WHERE m.user_id = $1 AND c.kind = $2 AND c.month = $3`,
        [userId, kind, month],
      );
      const same = mine.rows.find((r) => r.key === key);
      if (same) return same.id;
      if (mine.rows.length) {
        // Area or hour changed this month: move to a circle for the new key.
        await db.query('DELETE FROM circle_members WHERE user_id = $1 AND circle_id = ANY($2::uuid[])', [userId, mine.rows.map((r) => r.id)]);
      }
      const open = await db.query<{ id: string }>(
        `SELECT c.id FROM circles c LEFT JOIN circle_members m ON m.circle_id = c.id
         WHERE c.kind = $1 AND c.key = $2 AND c.month = $3
         GROUP BY c.id, c.created_at HAVING count(m.user_id) < $4
         ORDER BY c.created_at, c.id LIMIT 1`,
        [kind, key, month, CIRCLE_SIZE],
      );
      let id = open.rows[0]?.id;
      if (!id) {
        const created = await db.query<{ id: string }>(
          'INSERT INTO circles (kind, key, month, created_at) VALUES ($1, $2, $3, $4) RETURNING id',
          [kind, key, month, now()],
        );
        id = created.rows[0]!.id;
      }
      await db.query('INSERT INTO circle_members (circle_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING', [id, userId]);
      return id;
    });
  }

  async function friendIds(userId: string): Promise<string[]> {
    const r = await pool.query<{ b: string }>('SELECT b FROM friendships WHERE a = $1', [userId]);
    return r.rows.map((x) => x.b);
  }

  async function circleMemberIds(circleId: string): Promise<string[]> {
    const r = await pool.query<{ user_id: string }>('SELECT user_id FROM circle_members WHERE circle_id = $1', [circleId]);
    return r.rows.map((x) => x.user_id);
  }

  async function describe(me: string, id: string, kind: string, key: string, memberIds: string[], date: string) {
    const monday = isoMonday(date);
    const sunday = addDays(monday, 6);
    const members = await pool.query<{ id: string; handle: string; showed: boolean }>(
      `SELECT u.id, u.handle, EXISTS (SELECT 1 FROM showups s WHERE s.user_id = u.id AND s.day = $2) AS showed
       FROM users u WHERE u.id = ANY($1::uuid[]) ORDER BY (u.id = $3) DESC, u.handle`,
      [memberIds, date, me],
    );
    const week = await pool.query<{ done: number }>(
      'SELECT count(*)::int AS done FROM showups WHERE user_id = ANY($1::uuid[]) AND day BETWEEN $2 AND $3',
      [memberIds, monday, sunday],
    );
    const cheers = kind === 'friends'
      ? await pool.query<{ n: number }>(
          `SELECT count(*)::int AS n FROM cheers
           WHERE circle_key LIKE 'friends:%' AND day = $1 AND from_user = ANY($2::uuid[]) AND from_user <> $3
             AND (to_user = $3 OR to_user IS NULL)`,
          [date, memberIds, me],
        )
      : await pool.query<{ n: number }>(
          `SELECT count(*)::int AS n FROM cheers
           WHERE circle_key = $1 AND day = $2 AND from_user <> $3 AND (to_user = $3 OR to_user IS NULL)`,
          [id, date, me],
        );
    return {
      id,
      kind,
      title: circleTitle(kind, key),
      members: members.rows.map((m) => ({ id: m.id, handle: m.handle, me: m.id === me, showedUpOnDate: m.showed })),
      week: { done: week.rows[0]!.done, goal: WEEKLY_GOAL_PER_MEMBER * members.rows.length },
      cheersForMeToday: cheers.rows[0]!.n,
    };
  }

  app.get('/v1/circles', async (c) => {
    const me = c.get('user');
    const date = c.req.query('date') ?? utcDay(now());
    if (!isDay(date)) throw new HttpError(400, 'invalid');
    const month = monthStart(utcDay(now()));
    const out = [];
    const friends = await friendIds(me.id);
    if (friends.length) out.push(await describe(me.id, 'friends', 'friends', 'friends', [me.id, ...friends], date));
    if (me.nearby && me.area) {
      const id = await ensureCircle(me.id, 'nearby', me.area, month);
      out.push(await describe(me.id, id, 'nearby', me.area, await circleMemberIds(id), date));
    }
    if (me.same_hour && me.hour !== null) {
      const key = hourBucket(me.hour).key;
      const id = await ensureCircle(me.id, 'hour', key, month);
      out.push(await describe(me.id, id, 'hour', key, await circleMemberIds(id), date));
    }
    return c.json(out);
  });

  async function myCircle(userId: string, id: string): Promise<{ kind: string; key: string }> {
    if (!z.uuid().safeParse(id).success) throw new HttpError(404, 'not_found');
    const r = await pool.query<{ kind: string; key: string }>(
      'SELECT c.kind, c.key FROM circles c JOIN circle_members m ON m.circle_id = c.id WHERE c.id = $1 AND m.user_id = $2',
      [id, userId],
    );
    if (!r.rows[0]) throw new HttpError(404, 'not_found');
    return r.rows[0];
  }

  app.post('/v1/circles/:id/leave', async (c) => {
    const me = c.get('user');
    const id = c.req.param('id');
    const circle = await myCircle(me.id, id);
    await tx(pool, async (db) => {
      await db.query(`UPDATE users SET ${circle.kind === 'nearby' ? 'nearby' : 'same_hour'} = false WHERE id = $1`, [me.id]);
      await db.query('DELETE FROM circle_members WHERE circle_id = $1 AND user_id = $2', [id, me.id]);
    });
    return c.json({ ok: true });
  });

  app.post('/v1/circles/:id/cheer', async (c) => {
    const me = c.get('user');
    const id = c.req.param('id');
    const { to } = await body(c, schemas.cheer);
    let members: string[];
    let circleKey: string;
    let title: string;
    if (id === 'friends') {
      members = [me.id, ...(await friendIds(me.id))];
      circleKey = `friends:${me.id}`;
      title = 'Friends';
    } else {
      const circle = await myCircle(me.id, id);
      members = await circleMemberIds(id);
      circleKey = id;
      title = circleTitle(circle.kind, circle.key);
    }
    if (to !== undefined && (to === me.id || !members.includes(to))) throw new HttpError(400, 'not_in_circle');
    const recipients = to ? [to] : members.filter((m) => m !== me.id);
    if (!recipients.length) throw new HttpError(400, 'not_in_circle');
    const r = await pool.query(
      `INSERT INTO cheers (circle_key, from_user, to_user, day) VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING`,
      [circleKey, me.id, to ?? null, utcDay(now())],
    );
    if (!r.rowCount) throw new HttpError(409, 'already_cheered');
    const tokens = await pool.query<{ push_token: string; push_env: string | null }>(
      'SELECT push_token, push_env FROM users WHERE id = ANY($1::uuid[]) AND push_token IS NOT NULL',
      [recipients],
    );
    const text = title === 'Friends' ? 'Someone in your Friends circle cheered you on.' : `Someone in your ${title} circle cheered you on.`;
    pusher
      .send(tokens.rows.map((t) => ({ token: t.push_token, env: t.push_env ?? 'production' })), text)
      .catch((e: Error) => console.error(`[error] push: ${e.message}`));
    return c.json({ ok: true });
  });

  // ---------- world map (no auth on purpose: submissions carry no user ID) ----------

  app.post('/v1/map/cells', ipLimit('mapcells', () => limits.mapCells, 3_600_000), async (c) => {
    const { day, cells } = await body(c, schemas.mapCells);
    const today = utcDay(now());
    if (day < addDays(today, -40) || day > addDays(today, 1)) throw new HttpError(400, 'day_out_of_range');
    const month = monthStart(day);
    const gs: string[] = [], tags: Buffer[] = [], lats: number[] = [], lngs: number[] = [];
    for (const e of cells) {
      const centre = decode(e.g);
      gs.push(e.g); tags.push(fromB64url(e.t)!); lats.push(centre.lat); lngs.push(centre.lng);
    }
    // One statement: each entry adds a visit (n) and, if its tag is new for that square and month, a person.
    // Nothing that groups entries together is stored.
    await pool.query(
      `WITH e AS (SELECT * FROM unnest($1::text[], $2::bytea[], $3::float8[], $4::float8[]) AS e(g, tag, lat, lng)),
       fresh AS (INSERT INTO map_tags (g, month, tag) SELECT g, $5, tag FROM e ON CONFLICT DO NOTHING RETURNING g),
       visits AS (SELECT g, count(*)::int AS n, min(lat) AS lat, min(lng) AS lng FROM e GROUP BY g),
       people AS (SELECT g, count(*)::int AS people FROM fresh GROUP BY g)
       INSERT INTO map_cells (g, p, month, n, people, lat, lng)
       SELECT v.g, length(v.g), $5, v.n, coalesce(p.people, 0), v.lat, v.lng
       FROM visits v LEFT JOIN people p ON p.g = v.g
       ON CONFLICT (g, month) DO UPDATE SET n = map_cells.n + EXCLUDED.n, people = map_cells.people + EXCLUDED.people`,
      [gs, tags, lats, lngs, month],
    );
    return c.json({ ok: true, accepted: cells.length });
  });

  app.post('/v1/map/now', ipLimit('mapnow', () => limits.mapNow, 3_600_000), async (c) => {
    const { g, t } = await body(c, schemas.mapNow);
    const bucket = liveBucket(now());
    const centre = decode(g);
    await pool.query(
      `WITH fresh AS (INSERT INTO live_tags (g, bucket, tag) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING RETURNING 1)
       INSERT INTO live_cells (g, bucket, people, n, lat, lng)
       VALUES ($1, $2, (SELECT count(*)::int FROM fresh), 1, $4, $5)
       ON CONFLICT (g, bucket) DO UPDATE SET n = live_cells.n + 1, people = live_cells.people + EXCLUDED.people`,
      [g, bucket, fromB64url(t)!, centre.lat, centre.lng],
    );
    return c.json({ ok: true });
  });

  app.get('/v1/map', ipLimit('mapread', () => limits.mapRead, 60_000), async (c) => {
    const parts = (c.req.query('bbox') ?? '').split(',').map(Number);
    const [w, s, e, n] = parts as [number, number, number, number];
    if (parts.length !== 4 || parts.some((x) => !Number.isFinite(x)) || s > n || s < -90 || n > 90 || w < -180 || w > 180 || e < -180 || e > 180) {
      throw new HttpError(400, 'invalid_bbox');
    }
    const pq = c.req.query('p') ?? '7';
    if (!/^[567]$/.test(pq)) throw new HttpError(400, 'invalid_precision');
    let p = Number(pq);

    const thisMonth = monthStart(utcDay(now()));
    const months = [thisMonth, addMonths(thisMonth, -1)];
    const lngCond = w <= e ? 'lng BETWEEN $4 AND $5' : '(lng >= $4 OR lng <= $5)';
    const base = `FROM map_cells WHERE p = $1 AND month = ANY($2::date[]) AND lat BETWEEN $3 AND $6 AND ${lngCond}
                  GROUP BY g HAVING max(people) >= ${K_ANON}`;
    const args = (prec: number) => [prec, months, s, w, e, n];
    const count = async (prec: number) =>
      (await pool.query<{ c: number }>(`SELECT count(*)::int AS c FROM (SELECT g ${base}) x`, args(prec))).rows[0]!.c;
    const fetch = async (prec: number) =>
      (await pool.query<{ g: string; n: number }>(`SELECT g, sum(n)::int AS n ${base} ORDER BY sum(n) DESC LIMIT ${MAX_MAP_CELLS}`, args(prec))).rows;

    while (p > 5 && (await count(p)) > MAX_MAP_CELLS) p--;
    const cells = await fetch(p);

    // Quiet areas: coarser squares that pass the threshold but have no shown finer square inside.
    const blur: { g: string; n: number }[] = [];
    const shown = cells.map((x) => x.g);
    for (let q = p - 1; q >= 5; q--) {
      for (const coarse of await fetch(q)) {
        if (!shown.some((g) => g.startsWith(coarse.g))) blur.push(coarse);
      }
      shown.push(...blur.filter((b) => b.g.length === q).map((b) => b.g));
    }

    const buckets = [liveBucket(now()), liveBucket(now(), 1)];
    const liveLng = w <= e ? 'lng BETWEEN $3 AND $4' : '(lng >= $3 OR lng <= $4)';
    const live = await pool.query<{ g: string; people: number }>(
      `SELECT g, max(people)::int AS people FROM live_cells
       WHERE bucket = ANY($1::timestamptz[]) AND people >= ${K_ANON} AND lat BETWEEN $2 AND $5 AND ${liveLng}
       GROUP BY g LIMIT ${MAX_MAP_CELLS}`,
      [buckets, s, w, e, n],
    );

    return c.json({ p, cells, blur, live: live.rows });
  });

  return app;
}
