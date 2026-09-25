import { expect } from 'bun:test';
import { mkdirSync, mkdtempSync } from 'node:fs';
import { resolve } from 'node:path';

// Shared harness for the native suite. scripts/test-native.sh prebuilds every
// fixture and sets JEV_NATIVE_PREBUILT=1; standalone runs compile on demand.
export const nativeBin = resolve('build/jev-fabric');
export const prebuilt = process.env.JEV_NATIVE_PREBUILT === '1';

/** A fresh private directory under the repository's ignored `.tmp/`. */
export function tempRoot(prefix: string): string {
  mkdirSync('.tmp', { recursive: true });
  return mkdtempSync(resolve('.tmp', prefix));
}

/** Compiles `native/tests/<name>.bend` through the shipped executable's deadline. */
export function buildFixture(name: string, deadlineMs = 90000, output = `build/test-${name}`) {
  const source = `native/tests/${name}.bend`;
  const child = Bun.spawnSync(
    [nativeBin, '--', 'exec', String(deadlineMs), 'bend', source, '-o', output],
    { env: { ...process.env, BEND_NO_TELEMETRY: '1' }, stdout: 'pipe', stderr: 'pipe' },
  );
  return { code: child.exitCode, log: child.stdout.toString() + child.stderr.toString() };
}

/** Builds a fixture unless prebuilt, asserting that the compiler succeeded. */
export function expectFixture(name: string, deadlineMs?: number) {
  if (prebuilt) return;
  const build = buildFixture(name, deadlineMs);
  expect(build.code, build.log).toBe(0);
}

export interface Captured { out: string; err: string; code: number }
export interface CaptureOptions {
  env?: Record<string, string | undefined>;
  /** Written to a piped stdin, which is then closed. */
  input?: string;
  stdin?: 'ignore';
}

/** Runs argv to completion and collects its text output and exit code. */
export async function capture(argv: string[], options: CaptureOptions = {}): Promise<Captured> {
  const piped = options.input !== undefined;
  const child = Bun.spawn(argv, {
    env: options.env,
    stdin: piped ? 'pipe' : options.stdin,
    stdout: 'pipe',
    stderr: 'pipe',
  });
  let flushed: unknown;
  if (piped) {
    child.stdin.write(options.input);
    flushed = child.stdin.end();
  }
  const [out, err, code] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
    flushed,
  ]);
  return { out, err, code };
}

/** Parses newline-delimited JSON, ignoring blank lines. */
export function jsonLines(text: string): any[] {
  return text.trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
}

/** True once no process with this PID exists (it has been reaped). */
export function processGone(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return false;
  } catch (error: any) {
    return error.code === 'ESRCH';
  }
}
