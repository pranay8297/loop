import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import path from 'node:path';
import type { TestProject } from 'vitest/node';

declare module 'vitest' {
  export interface ProvidedContext { pgAdminUrl: string }
}

function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const s = createServer();
    s.listen(0, '127.0.0.1', () => {
      const port = (s.address() as { port: number }).port;
      s.close(() => resolve(port));
    });
    s.on('error', reject);
  });
}

/** Starts a throwaway Postgres for the test run (Homebrew initdb + pg_ctl), or uses TEST_DATABASE_URL. */
export default async function setup(project: TestProject) {
  if (process.env.TEST_DATABASE_URL) {
    project.provide('pgAdminUrl', process.env.TEST_DATABASE_URL);
    return;
  }
  const dir = mkdtempSync(path.join(tmpdir(), 'loop-pg-'));
  const data = path.join(dir, 'data');
  const port = await freePort();
  execFileSync('initdb', ['-D', data, '-U', 'postgres', '--auth=trust', '-E', 'UTF8', '--no-locale'], { stdio: 'ignore' });
  execFileSync('pg_ctl', ['-D', data, '-l', path.join(dir, 'log'), '-o', `-p ${port} -k ${dir} -c listen_addresses=127.0.0.1 -c fsync=off`, '-w', 'start'], { stdio: 'ignore' });
  project.provide('pgAdminUrl', `postgres://postgres@127.0.0.1:${port}/postgres`);
  return () => {
    try {
      execFileSync('pg_ctl', ['-D', data, '-m', 'immediate', '-w', 'stop'], { stdio: 'ignore' });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  };
}
