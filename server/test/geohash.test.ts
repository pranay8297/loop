import { describe, expect, it } from 'vitest';
import { bbox, decode, encode, isGeohash } from '../src/geohash.js';

describe('geohash', () => {
  it('matches known vectors', () => {
    expect(encode(42.6, -5.6, 5)).toBe('ezs42');
    expect(encode(57.64911, 10.40744, 11)).toBe('u4pruydqqvj');
    expect(encode(1.3521, 103.8198, 4)).toBe('w21z');
  });
  it('decodes to the cell centre', () => {
    const c = decode('ezs42');
    expect(c.lat).toBeCloseTo(42.605, 2);
    expect(c.lng).toBeCloseTo(-5.603, 2);
    const b = bbox('ezs42');
    expect(b.s).toBeLessThan(42.6);
    expect(b.n).toBeGreaterThan(42.6);
  });
  it('round trips', () => {
    for (let i = 0; i < 500; i++) {
      const lat = Math.random() * 170 - 85;
      const lng = Math.random() * 358 - 179;
      for (const p of [4, 5, 6, 7]) {
        const g = encode(lat, lng, p);
        expect(g).toHaveLength(p);
        const b = bbox(g);
        expect(lat).toBeGreaterThanOrEqual(b.s);
        expect(lat).toBeLessThanOrEqual(b.n);
        expect(lng).toBeGreaterThanOrEqual(b.w);
        expect(lng).toBeLessThanOrEqual(b.e);
        const c = decode(g);
        expect(encode(c.lat, c.lng, p)).toBe(g);
      }
    }
  });
  it('validates', () => {
    expect(isGeohash('w21z', 4)).toBe(true);
    expect(isGeohash('w21z', 5)).toBe(false);
    expect(isGeohash('w21a')).toBe(false); // 'a' is not in the alphabet
    expect(isGeohash('')).toBe(false);
  });
});
