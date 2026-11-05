import { describe, expect, it } from 'vitest';
import { randomBytes } from 'node:crypto';
import { harness } from './helpers.js';

const h = await harness({ register: 2, mapNow: 1, authed: 3 });

describe('rate limits', () => {
  it('limits register per address without storing it', async () => {
    const t = () => ({ token: randomBytes(32).toString('base64url') });
    expect((await h.req('POST', '/v1/register', { body: t(), ip: '203.0.113.9' })).status).toBe(200);
    expect((await h.req('POST', '/v1/register', { body: t(), ip: '203.0.113.9' })).status).toBe(200);
    expect((await h.req('POST', '/v1/register', { body: t(), ip: '203.0.113.9' })).status).toBe(429);
    expect((await h.req('POST', '/v1/register', { body: t(), ip: '203.0.113.10' })).status).toBe(200);
  });
  it('limits authed routes per token', async () => {
    const token = randomBytes(32).toString('base64url');
    await h.req('POST', '/v1/register', { body: { token }, ip: '198.51.100.1' });
    for (let i = 0; i < 3; i++) expect((await h.req('GET', '/v1/me', { token })).status).toBe(200);
    expect((await h.req('GET', '/v1/me', { token })).status).toBe(429);
  });
});
