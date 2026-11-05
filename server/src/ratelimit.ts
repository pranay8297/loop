// In-memory fixed-window rate limiter. Keys are hashes; nothing is persisted or logged.
export class RateLimiter {
  private hits = new Map<string, { count: number; reset: number }>();
  private lastSweep = Date.now();

  hit(key: string, limit: number, windowMs: number): boolean {
    const now = Date.now();
    if (now - this.lastSweep > 60_000) this.sweep(now);
    const e = this.hits.get(key);
    if (!e || e.reset <= now) {
      this.hits.set(key, { count: 1, reset: now + windowMs });
      return true;
    }
    e.count++;
    return e.count <= limit;
  }

  private sweep(now: number) {
    this.lastSweep = now;
    for (const [k, v] of this.hits) if (v.reset <= now) this.hits.delete(k);
  }
}

export interface Limits {
  register: number;   // per hour per IP key
  mapCells: number;   // per hour per IP key
  mapNow: number;     // per hour per IP key
  mapRead: number;    // per minute per IP key
  authed: number;     // per minute per token
}

export const DEFAULT_LIMITS: Limits = {
  register: 10,
  mapCells: 20,
  mapNow: 30,
  mapRead: 120,
  authed: 120,
};
