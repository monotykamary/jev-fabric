import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import { existsSync, mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { resolve } from 'node:path';

// Dev-only harness. Fixtures are stock Bend:
//   bend native/tests/monitor.bend      -o build/test-monitor
//   bend native/tests/monitor-pure.bend -o build/test-monitor-pure
// Jobs fixture is produced by scripts/test-native.sh; build it if absent.
mkdirSync('.tmp', { recursive: true });
const root = mkdtempSync(resolve('.tmp/monitor-test-'));
const jobsBin = resolve(process.env.JEV_JOBS_BIN ?? 'build/test-jobs');
const monitorBin = resolve(process.env.JEV_MONITOR_BIN ?? 'build/test-monitor');
const pureBin = resolve(process.env.JEV_MONITOR_PURE_BIN ?? 'build/test-monitor-pure');
const jobEnv = { PATH: '/usr/bin:/bin', JEV_FABRIC_HOME: root };
const active = new Set<string>();

async function buildBend(src: string, out: string) {
  const p = Bun.spawn([resolve('build/jev-fabric'), '--', 'exec', '90000', 'bend', src, '-o', out], {
    env: { ...process.env, BEND_NO_TELEMETRY: '1' }, stdin: 'ignore', stdout: 'pipe', stderr: 'pipe',
  });
  const [stdout, stderr, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
  if (code !== 0) throw new Error('bend ' + src + ' failed (' + code + '): ' + stderr + stdout);
}

beforeAll(async () => {
  if (process.env.JEV_NATIVE_PREBUILT === '1') return;
  if (!process.env.JEV_MONITOR_BIN) await buildBend('native/tests/monitor.bend', monitorBin);
  if (!process.env.JEV_MONITOR_PURE_BIN) await buildBend('native/tests/monitor-pure.bend', pureBin);
  if (!existsSync(jobsBin)) await buildBend('native/tests/jobs.bend', jobsBin);
}, 300000);

async function run(bin: string, args: string[], env: Record<string, string> = jobEnv) {
  const p = Bun.spawn([bin, '--threads', '2', '--', ...args], {
    env, stdin: 'ignore', stdout: 'pipe', stderr: 'pipe',
  });
  const [stdout, stderr, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
  return { stdout, stderr, code };
}

async function start(argv: string[], ms = 5000) {
  const result = await run(jobsBin, ['start', String(ms), ...argv]);
  expect(result.code, result.stderr).toBe(0);
  const id = JSON.parse(result.stdout).id as string;
  active.add(id);
  return id;
}

async function watch(id: string, ms: number, literal: string) {
  const result = await run(monitorBin, ['watch', id, String(ms), literal]);
  expect(result.code, result.stderr).toBe(0);
  return result.stdout.trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
}

function batchLines(events: any[]): string[] {
  const out: string[] = [];
  for (const event of events) if (event.type === 'monitor.batch') for (const line of event.lines) out.push(line.text);
  return out;
}

afterAll(async () => {
  await Promise.all([...active].map(id => run(jobsBin, ['stop', id])));
  rmSync(root, { recursive: true, force: true });
});

describe('native bounded monitor watch', () => {
  test('pure framing/filter/dedup/batch policy assertions pass', async () => {
    const result = await run(pureBin, []);
    expect(result.code, result.stderr).toBe(0);
    expect(result.stdout).toContain('monitor pure assertions: 15');
  });

  test('reassembles a split line from live output, filters by literal, and dedups', async () => {
    const id = await start(['/bin/sh', '-c', 'printf "HEL"; /bin/sleep 0.15; printf "LO\\nHELLO\\n"; /bin/sleep 0.05; printf "HELLO\\n"']);
    const events = await watch(id, 4000, 'HEL');
    expect(batchLines(events)).toEqual(['HELLO']);
    expect(events.at(-1)).toMatchObject({ type: 'monitor.end', reason: 'finished', terminal: true, lines: 1 });
  });

  test('flushes a trailing partial line at stream EOF', async () => {
    const id = await start(['/bin/sh', '-c', 'printf "partial-no-newline"']);
    const events = await watch(id, 4000, 'part');
    expect(batchLines(events)).toEqual(['partial-no-newline']);
  });

  test('caps a partial line at 4096 chars and discloses clipping', async () => {
    const id = await start(['/bin/sh', '-c', 'i=0; while [ "$i" -lt 5 ]; do /usr/bin/head -c 1000 /dev/zero | /usr/bin/tr "\\0" a; /bin/sleep 0.08; i=$((i+1)); done; printf "\\n"']);
    const events = await watch(id, 5000, 'aaa');
    const batch = events.find(event => event.type === 'monitor.batch');
    expect(batch.lines.length).toBe(1);
    expect(batch.lines[0].text.length).toBe(4096);
    expect(batch.lines[0].clipped).toBe(true);
    expect(batch.clipped).toBe(1);
  });

  test('stops on terminal even when nothing matches', async () => {
    const id = await start(['/bin/sleep', '0.2']);
    const events = await watch(id, 4000, 'NEVER-MATCHES');
    expect(batchLines(events)).toEqual([]);
    expect(events.at(-1)).toMatchObject({ type: 'monitor.end', terminal: true, reason: 'finished', lines: 0 });
  });

  test('stops at its own deadline while the job keeps running', async () => {
    const id = await start(['/bin/sleep', '30'], 30000);
    const events = await watch(id, 300, 'ZZZ');
    expect(events.at(-1)).toMatchObject({ type: 'monitor.end', terminal: false, reason: 'deadline' });
  }, 10000);

  test('needs no node or bun on PATH', async () => {
    const id = await start(['/bin/sh', '-c', 'printf "native-live\\n"']);
    const events = await watch(id, 4000, 'native');
    expect(batchLines(events)).toContain('native-live');
    expect(jobEnv.PATH).not.toContain('node');
    expect(jobEnv.PATH).not.toContain('bun');
  });

  test('rejects bad ids and invalid numeric arguments before looping', async () => {
    expect((await run(monitorBin, ['watch', '../outside', '1000', 'x'])).code).not.toBe(0);
    expect((await run(monitorBin, ['watch', 'a'.repeat(32), '0', 'x'])).code).not.toBe(0);
    expect((await run(monitorBin, ['watch', 'a'.repeat(32), '300001', 'x'])).code).not.toBe(0);
    expect((await run(monitorBin, ['watch', 'a'.repeat(32), '1000', ''])).code).not.toBe(0);
    expect((await run(monitorBin, ['unknown'])).code).not.toBe(0);
  });
});
