// Minimal geohash helpers (no external dependency).
const BASE32 = '0123456789bcdefghjkmnpqrstuvwxyz';
const VALID = /^[0123456789bcdefghjkmnpqrstuvwxyz]+$/;

export function isGeohash(g: string, precision?: number): boolean {
  if (!VALID.test(g)) return false;
  return precision === undefined || g.length === precision;
}

export function encode(lat: number, lng: number, precision: number): string {
  let latMin = -90, latMax = 90, lngMin = -180, lngMax = 180;
  let out = '';
  let bit = 0, ch = 0, even = true;
  while (out.length < precision) {
    if (even) {
      const mid = (lngMin + lngMax) / 2;
      if (lng >= mid) { ch = (ch << 1) | 1; lngMin = mid; } else { ch <<= 1; lngMax = mid; }
    } else {
      const mid = (latMin + latMax) / 2;
      if (lat >= mid) { ch = (ch << 1) | 1; latMin = mid; } else { ch <<= 1; latMax = mid; }
    }
    even = !even;
    if (++bit === 5) { out += BASE32[ch]; bit = 0; ch = 0; }
  }
  return out;
}

export interface Box { s: number; w: number; n: number; e: number }

export function bbox(g: string): Box {
  if (!isGeohash(g)) throw new Error('invalid geohash');
  let latMin = -90, latMax = 90, lngMin = -180, lngMax = 180;
  let even = true;
  for (const c of g) {
    const v = BASE32.indexOf(c);
    for (let i = 4; i >= 0; i--) {
      const b = (v >> i) & 1;
      if (even) {
        const mid = (lngMin + lngMax) / 2;
        if (b) lngMin = mid; else lngMax = mid;
      } else {
        const mid = (latMin + latMax) / 2;
        if (b) latMin = mid; else latMax = mid;
      }
      even = !even;
    }
  }
  return { s: latMin, w: lngMin, n: latMax, e: lngMax };
}

export function decode(g: string): { lat: number; lng: number } {
  const b = bbox(g);
  return { lat: (b.s + b.n) / 2, lng: (b.w + b.e) / 2 };
}
