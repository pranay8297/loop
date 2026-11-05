// All dates are plain 'YYYY-MM-DD' strings in UTC.
export const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;

export function isDay(s: string): boolean {
  if (!DAY_RE.test(s)) return false;
  const d = new Date(s + 'T00:00:00Z');
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === s;
}

export function utcDay(d: Date): string {
  return d.toISOString().slice(0, 10);
}

export function addDays(day: string, n: number): string {
  const d = new Date(day + 'T00:00:00Z');
  d.setUTCDate(d.getUTCDate() + n);
  return utcDay(d);
}

export function monthStart(day: string): string {
  return day.slice(0, 7) + '-01';
}

export function addMonths(month: string, n: number): string {
  const d = new Date(month.slice(0, 7) + '-01T00:00:00Z');
  d.setUTCMonth(d.getUTCMonth() + n);
  return utcDay(d);
}

/** Monday of the ISO week containing day. */
export function isoMonday(day: string): string {
  const d = new Date(day + 'T00:00:00Z');
  const dow = (d.getUTCDay() + 6) % 7; // Mon=0
  return addDays(day, -dow);
}

export const LIVE_BUCKET_MS = 5 * 60 * 1000;
export function liveBucket(now: Date, back = 0): Date {
  return new Date(Math.floor(now.getTime() / LIVE_BUCKET_MS) * LIVE_BUCKET_MS - back * LIVE_BUCKET_MS);
}
