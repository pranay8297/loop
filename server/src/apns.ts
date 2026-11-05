import { connect, type ClientHttp2Session } from 'node:http2';
import { createPrivateKey, sign, type KeyObject } from 'node:crypto';

export interface ApnsConfig { keyId: string; teamId: string; key: string; topic: string }

export function apnsConfigFromEnv(env = process.env): ApnsConfig | null {
  const { APNS_KEY_ID, APNS_TEAM_ID, APNS_KEY, APNS_TOPIC } = env;
  if (!APNS_KEY_ID || !APNS_TEAM_ID || !APNS_KEY || !APNS_TOPIC) return null;
  return { keyId: APNS_KEY_ID, teamId: APNS_TEAM_ID, key: APNS_KEY.replace(/\\n/g, '\n'), topic: APNS_TOPIC };
}

/** ES256 provider token for APNs. */
export function makeJwt(cfg: { keyId: string; teamId: string }, key: KeyObject, nowSec = Math.floor(Date.now() / 1000)): string {
  const enc = (o: object) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const input = `${enc({ alg: 'ES256', kid: cfg.keyId })}.${enc({ iss: cfg.teamId, iat: nowSec })}`;
  const sig = sign('sha256', Buffer.from(input), { key, dsaEncoding: 'ieee-p1363' });
  return `${input}.${sig.toString('base64url')}`;
}

export interface Pusher { send(tokens: { token: string; env: string }[], body: string): Promise<void> }

export const noopPusher: Pusher = { async send() {} };

export function createApnsPusher(cfg: ApnsConfig): Pusher {
  const key = createPrivateKey(cfg.key);
  let jwt = '';
  let jwtAt = 0;
  const sessions = new Map<string, ClientHttp2Session>();
  const token = () => {
    const now = Math.floor(Date.now() / 1000);
    if (!jwt || now - jwtAt > 50 * 60) { jwt = makeJwt(cfg, key, now); jwtAt = now; }
    return jwt;
  };
  const session = (env: string) => {
    const host = env === 'sandbox' ? 'https://api.sandbox.push.apple.com' : 'https://api.push.apple.com';
    let s = sessions.get(host);
    if (!s || s.closed || s.destroyed) {
      s = connect(host);
      s.on('error', () => sessions.delete(host));
      s.on('close', () => sessions.delete(host));
      s.unref();
      sessions.set(host, s);
    }
    return s;
  };
  const one = (t: { token: string; env: string }, body: string) =>
    new Promise<void>((resolve) => {
      try {
        const req = session(t.env).request({
          ':method': 'POST',
          ':path': `/3/device/${t.token}`,
          authorization: `bearer ${token()}`,
          'apns-topic': cfg.topic,
          'apns-push-type': 'alert',
          'apns-priority': '10',
        });
        req.setEncoding('utf8');
        req.on('response', () => {});
        req.on('data', () => {});
        req.on('end', () => resolve());
        req.on('error', () => resolve());
        req.end(JSON.stringify({ aps: { alert: { body }, sound: 'default' } }));
      } catch {
        resolve();
      }
    });
  return {
    async send(tokens, body) {
      await Promise.all(tokens.map((t) => one(t, body)));
    },
  };
}
