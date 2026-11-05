import { createHash, createHmac, randomBytes, randomInt } from 'node:crypto';

export function sha256(data: string | Buffer): Buffer {
  return createHash('sha256').update(data).digest();
}

export function fromB64url(s: string): Buffer | null {
  if (!/^[A-Za-z0-9_-]*$/.test(s)) return null;
  return Buffer.from(s, 'base64url');
}

const CROCKFORD = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
export const INVITE_RE = /^[0-9A-HJKMNP-TV-Z]{10}$/;

export function newInviteCode(): string {
  let s = '';
  for (let i = 0; i < 10; i++) s += CROCKFORD[randomInt(32)];
  return s;
}

/** Crockford decoding is forgiving: case, I/L -> 1, O -> 0, hyphens ignored. */
export function normalizeInviteCode(raw: string): string {
  return raw.toUpperCase().replace(/-/g, '').replace(/[IL]/g, '1').replace(/O/g, '0');
}

/** Keyed hash of a client address, with a salt that lives only in memory and rotates daily. */
let salt = randomBytes(32);
let saltDay = new Date().toISOString().slice(0, 10);
export function ipKey(ip: string): string {
  const today = new Date().toISOString().slice(0, 10);
  if (today !== saltDay) { salt = randomBytes(32); saltDay = today; }
  return createHmac('sha256', salt).update(ip).digest('base64url');
}
