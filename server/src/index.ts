import { serve } from '@hono/node-server';
import { createApp } from './app.js';
import { createPool, migrate } from './db.js';
import { apnsConfigFromEnv, createApnsPusher, noopPusher } from './apns.js';
import { runRetention } from './retention.js';

const port = Number(process.env.PORT ?? 8787);
const databaseUrl = process.env.DATABASE_URL;
if (!databaseUrl) {
  console.error('DATABASE_URL is required');
  process.exit(1);
}
const publicUrl = process.env.PUBLIC_URL ?? `http://localhost:${port}`;

const pool = createPool(databaseUrl);
pool.on('error', (e) => console.error(`[error] pool: ${e.message}`));

const applied = await migrate(pool);
if (applied.length) console.log(`migrations applied: ${applied.join(', ')}`);

const apns = apnsConfigFromEnv();
if (!apns) console.log('APNs not configured; cheers are stored without push');

const app = createApp({ pool, publicUrl, pusher: apns ? createApnsPusher(apns) : noopPusher });

const retention = () => runRetention(pool).catch((e: Error) => console.error(`[error] retention: ${e.message}`));
void retention();
const timer = setInterval(retention, 3_600_000);
timer.unref();

const server = serve({ fetch: app.fetch, port }, (info) => console.log(`loop server on :${info.port}`));

const shutdown = () => {
  server.close();
  void pool.end().finally(() => process.exit(0));
};
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
