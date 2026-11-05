# Loop server

Small API for Loop's circles, invites, showed-up days and world map. Built so the database holds no personal data.

Stack: TypeScript, Node 22+, Hono, Postgres (`pg`), zod, vitest.

## Run

```sh
npm ci
DATABASE_URL=postgres://localhost/loop PORT=8787 npm run dev   # tsx watch
npm run build && npm start                                     # production
```

Migrations in `migrations/NNN_name.sql` run at boot in one transaction (tracked in `schema_migrations`). A retention job runs at boot and then hourly.

## Test

```sh
npm test        # starts a throwaway Postgres (Homebrew initdb + pg_ctl), runs vitest, removes it
npm run typecheck
```

Set `TEST_DATABASE_URL` to an admin connection to use an existing Postgres instead; each test file creates its own database.

## Environment

| Var | |
| --- | --- |
| `DATABASE_URL` | required |
| `PORT` | default 8787 |
| `PUBLIC_URL` | base for invite links, e.g. `https://loop.example.com` |
| `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_KEY` (p8 PEM contents), `APNS_TOPIC` | optional; without all four, cheers are stored and push is skipped |

## API

Auth: `Authorization: Bearer <token>`, where the token is 32 random bytes (base64url) made on the phone. The server stores only its SHA-256.
Dates are `YYYY-MM-DD` (UTC).

| Route | |
| --- | --- |
| `POST /v1/register {token}` | `{id, handle}`, idempotent |
| `GET /v1/me`, `PUT /v1/me {area?, hour?, nearby?, sameHour?, pushToken?, pushEnv?}` | area = geohash p4, hour 0..23 |
| `DELETE /v1/me` | deletes the user and everything linked |
| `POST /v1/invites` | `{code, url}`, 7 days, single use |
| `POST /v1/invites/accept {code}` | `{friend}`; 404 unknown, 400 self, 410 used/expired, 409 friend_limit (50) |
| `GET /v1/friends`, `DELETE /v1/friends/:id` | |
| `POST /v1/showups {day, kinds}` | kinds bitmask run=1 walk=2 ride=4 swim=8 gym=16; day within today -2..+1 |
| `GET /v1/circles?date=` | friends, nearby and same-hour circles with members, showedUpOnDate, week `{done, goal}` |
| `POST /v1/circles/:id/leave` | nearby/hour only; turns that preference off |
| `POST /v1/circles/:id/cheer {to?}` | `:id` may be `friends`; 409 when already cheered today |
| `POST /v1/map/cells {day, cells: [{g, t}]}` | no auth; g = geohash p5..p7, t = 16-byte tag; up to 3000 |
| `POST /v1/map/now {g, t}` | no auth; g = p5; 5-minute buckets |
| `GET /v1/map?bbox=w,s,e,n&p=7` | `{p, cells, blur, live}`; squares need 5 people; `p` drops when over 5000 squares |
| `GET /i/:code`, `GET /privacy`, `GET /support`, `GET /health` | pages and health |

## Privacy rules

- No request logging. Errors log message and route only. Never IPs, tokens, bodies or headers.
- Rate limits live in memory only. Unauthenticated routes key on HMAC(daily in-memory salt, IP).
- Invite codes and tokens are stored only as SHA-256.
- No column holds a name, phone, email, contact, IP, route, distance, pace or duration. `users.area` is a p4 geohash (city scale), `users.hour` an hour. A test (`test/schema.test.ts`) audits every column.
- Map submissions carry no user ID and nothing that links entries together. A square is shown only after 5 different tags.
- Retention: showups 10 weeks, cheers 14 days, old invites 7 days, map 3 months, live 2 hours, circles 2 months.

## Deploy (Railway)

`railway.json` sets build, start, `/health` healthcheck, restart on failure and the Singapore region (`asia-southeast1-eqsg3a`). Add a Postgres service and set `DATABASE_URL` to its reference variable.

## Next

- App Attest on register and map routes to keep out scripted clients.
- Universal links (`apple-app-site-association`) for invite URLs.
