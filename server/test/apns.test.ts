import { describe, expect, it } from 'vitest';
import { generateKeyPairSync, verify } from 'node:crypto';
import { apnsConfigFromEnv, makeJwt } from '../src/apns.js';

describe('apns', () => {
  it('builds a valid ES256 provider token', () => {
    const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
    const jwt = makeJwt({ keyId: 'ABC123DEFG', teamId: '538T684785' }, privateKey, 1_700_000_000);
    const [h, p, s] = jwt.split('.');
    expect(JSON.parse(Buffer.from(h!, 'base64url').toString())).toEqual({ alg: 'ES256', kid: 'ABC123DEFG' });
    expect(JSON.parse(Buffer.from(p!, 'base64url').toString())).toEqual({ iss: '538T684785', iat: 1_700_000_000 });
    const sig = Buffer.from(s!, 'base64url');
    expect(sig).toHaveLength(64);
    expect(verify('sha256', Buffer.from(`${h}.${p}`), { key: publicKey, dsaEncoding: 'ieee-p1363' }, sig)).toBe(true);
  });

  it('is off unless every variable is set', () => {
    expect(apnsConfigFromEnv({ APNS_KEY_ID: 'a', APNS_TEAM_ID: 'b', APNS_TOPIC: 'c' })).toBeNull();
    expect(apnsConfigFromEnv({ APNS_KEY_ID: 'a', APNS_TEAM_ID: 'b', APNS_TOPIC: 'c', APNS_KEY: 'k' })).not.toBeNull();
  });
});
