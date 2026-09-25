import { afterAll, beforeAll, expect, test } from 'bun:test';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { join, resolve } from 'node:path';

mkdirSync('.tmp', { recursive: true });
const root = mkdtempSync(resolve('.tmp/timers-'));
const bin = resolve('build/jev-fabric');
const fakeBin = join(root, 'bin');
const request = JSON.stringify({ state: 'synthetic', questions: { ok: { type: 'noul', instructions: 'Is two plus two four?' } } });
const requestFile = join(root, 'request.json');
const credential = join(root, 'credential.sh');
let serial = 0;

beforeAll(async () => {
  if (process.env.JEV_NATIVE_PREBUILT !== '1') {
    for (const name of ['time-core', 'timers']) {
      const p = Bun.spawnSync([bin, '--', 'exec', '300000', 'bend', `native/tests/${name}.bend`, '-o', `build/test-${name}`], { stdout: 'pipe', stderr: 'pipe' });
      expect(p.exitCode, p.stdout.toString() + p.stderr.toString()).toBe(0);
    }
  }
  mkdirSync(fakeBin);
  await Bun.write(requestFile, request);
  await Bun.write(join(fakeBin, 'curl'), '#!/bin/sh\n/usr/bin/sed -n \'s/^max-time = //p\' >> "$CURL_RECORD"\n/bin/sleep "${CURL_DELAY:-0}"\nprintf \'%s\\n200\' \'{"model":"test","answers":{"ok":{"type":"noul","noul":0.99}},"usage":{"input_tokens":4,"output_tokens":2}}\'\n');
  await Bun.write(credential, '#!/bin/sh\nprintf x >> "$CREDENTIAL_RECORD"\nprintf "SYNTHETIC_TIMER_KEY\\n"\n');
  await Bun.write(join(fakeBin, '123'), '#!/bin/sh\nprintf "%s\\n" "$@"\n');
  await Bun.write(join(fakeBin, '--stdin'), '#!/bin/sh\nprintf "literal-command:%s\\n" "$1"\n');
  for (const name of ['curl', '123', '--stdin']) chmodSync(join(fakeBin, name), 0o700);
  chmodSync(credential, 0o700);
}, 610000);
afterAll(() => rmSync(root, { recursive: true, force: true }));

type Options = { env?: Record<string, string>; input?: string; program?: string };
async function run(args: string[], options: Options = {}) {
  const id = serial++;
  const curl = join(root, `curl-${id}`), cred = join(root, `cred-${id}`);
  const p = Bun.spawn([options.program ?? bin, '--', ...args], {
    env: { PATH: `${fakeBin}:${process.env.PATH}`, BEND_NO_TELEMETRY: '1', JEV_FABRIC_HOME: join(root, 'jobs'), TYPESAFE_API_KEY: 'SYNTHETIC_TIMER_KEY', CURL_RECORD: curl, CREDENTIAL_RECORD: cred, ...options.env },
    stdin: 'pipe', stdout: 'pipe', stderr: 'pipe',
  });
  p.stdin.write(options.input ?? '');
  await p.stdin.end();
  const [out, err, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
  expect(out + err).not.toContain('SYNTHETIC_TIMER_KEY');
  return { out, err, code, curls: existsSync(curl) ? readFileSync(curl, 'utf8').trim().split('\n').map(x => x.split(' ')) : [], credentials: existsSync(cred) ? readFileSync(cred, 'utf8') : '' };
}
// curl's private stdin config rounds up; the native supervisor enforces exact ms.
function seconds(args: string[]) { return Number(args[0]); }
function gone(pid: number) {
  try { process.kill(pid, 0); return false; } catch (e: any) { return e.code === 'ESRCH'; }
}

test('public defaults and checked pure deadline/CLI policy are registered', async () => {
  const help = await run(['--help']);
  for (const text of ['--timeout-ms', 'work 1h', 'Jev 30s', 'wait 30s', 'watch 5s', 'JEV_FABRIC_TIMEOUT_MS', 'JEV_FABRIC_JEV_TIMEOUT_MS', 'JEV_FABRIC_WAIT_MS', 'JEV_FABRIC_WATCH_MS']) expect(help.out).toContain(text);
  const p = await run([], { program: resolve('build/test-time-core') });
  expect(p.code, p.err).toBe(0);
  expect(p.out).toContain('native timer policy assertions: 24');
});

test('timer-free literal exec, inherited stdin and legacy syntax return immediately', async () => {
  const text = 'literal ; $(not-a-command) --timeout-ms 1';
  for (const prefix of [[], ['2000'], ['--timeout-ms', '2000']]) {
    const r = await run(['exec', ...prefix, '/bin/echo', text]);
    expect(r.code, r.err).toBe(0);
    expect(JSON.parse(r.out).stdout).toBe(text + '\n');
  }
  for (const prefix of [['--stdin'], ['2000', '--stdin'], ['--stdin', '--timeout-ms', '2000']]) {
    const r = await run(['exec', ...prefix, '/bin/cat'], { input: 'streamed\n' });
    expect(r.code, r.err).toBe(0);
    expect(JSON.parse(r.out).stdout).toBe('streamed\n');
  }
  const literal = await run(['exec', '--', '123', '--timeout-ms', 'not-a-number']);
  expect(JSON.parse(literal.out).stdout).toBe('--timeout-ms\nnot-a-number\n');
  const dashed = await run(['exec', '--', '--stdin', 'argument']);
  expect(JSON.parse(dashed.out).stdout).toBe('literal-command:argument\n');
});

test('configured work limits and explicit overrides remain effective; malformed limits cannot launch', async () => {
  const timed = await run(['exec', '/bin/sleep', '1'], { env: { JEV_FABRIC_TIMEOUT_MS: '40' } });
  expect(timed.code).toBe(124);
  expect(JSON.parse(timed.out).timedOut).toBe(true);
  for (const prefix of [['300'], ['--timeout-ms', '300']]) {
    const override = await run(['exec', ...prefix, '/bin/sleep', '0.08'], { env: { JEV_FABRIC_TIMEOUT_MS: 'invalid' } });
    expect(override.code, override.err).toBe(0);
  }
  const marker = join(root, 'must-not-run');
  for (const raw of ['0', '-1', '1.5', '3600001', '4294967297', 'words']) {
    for (const [args, env] of [
      [['exec', '--timeout-ms', raw, '/usr/bin/touch', marker], {}],
      [['exec', '/usr/bin/touch', marker], { JEV_FABRIC_TIMEOUT_MS: raw }],
    ] as [string[], Record<string, string>][]) {
      expect((await run(args, { env })).code).not.toBe(0);
      expect(existsSync(marker)).toBe(false);
    }
  }
  for (const args of [['exec', '--timeout-ms'], ['exec', '--stdin', '--stdin', '/bin/echo'], ['exec', '--timeout-ms', '3', '4', '/bin/echo'], ['start', '--stdin', '/bin/echo']]) expect((await run(args)).code).not.toBe(0);
  expect((await run(['--help'], { env: { JEV_FABRIC_TIMEOUT_MS: 'invalid' } })).code).toBe(0);
});

test('timer-free run compiles and preserves source arguments', async () => {
  const file = join(root, 'source.bend');
  await Bun.write(file, 'import Base\ndef main() -> IO(Unit):\n  do IO<Unit>:\n    args : List<String> <- IO.args()\n    IO.print(List.show(&1, String, text => text, args))\n');
  const r = await run(['run', file, '--timeout-ms', 'child-argument']);
  expect(r.code, r.err).toBe(0);
  expect(JSON.parse(r.out).stdout).toContain('child-argument');
});

test('timer-free detached lifecycle; wait/watch limits do not stop or renew the job', async () => {
  const started = await run(['start', '/bin/sh', '-c', 'printf "ready\\n"; exec sleep 60'], { env: { JEV_FABRIC_TIMEOUT_MS: '3000' } });
  expect(started.code, started.err).toBe(0);
  const { id } = JSON.parse(started.out);
  try {
    const waited = await run(['wait', id], { env: { JEV_FABRIC_WAIT_MS: '30' } });
    expect(JSON.parse(waited.out).state).toBe('running');
    const watched = await run(['watch', id, 'ready'], { env: { JEV_FABRIC_WATCH_MS: '50' } });
    expect(watched.code, watched.err).toBe(0);
    expect(JSON.parse(watched.out.trim().split('\n').at(-1)!)).toMatchObject({ type: 'monitor.end', reason: 'deadline', terminal: false });
    expect(JSON.parse((await run(['status', id])).out).state).toBe('running');
    expect((await run(['watch', '--timeout-ms', '300001', id, 'ready'])).code).toBe(2);
    expect((await run(['wait', id], { env: { JEV_FABRIC_WAIT_MS: 'invalid' } })).code).toBe(2);
  } finally { await run(['stop', id]); }
  const done = await run(['start', '/bin/echo', 'ready']);
  const quick = JSON.parse(done.out).id;
  expect(JSON.parse((await run(['wait', quick])).out).state).toBe('exited');
  const watched = await run(['watch', quick, 'ready']);
  expect(JSON.parse(watched.out.trim().split('\n').at(-1)!)).toMatchObject({ terminal: true });
});

test('timer-free Jev and its override reach only the fake transport with bounded deadlines', async () => {
  for (const [prefix, env, max] of [[[], {}, 30], [[], { JEV_FABRIC_JEV_TIMEOUT_MS: '2000' }, 2], [['--timeout-ms', '300'], { JEV_FABRIC_JEV_TIMEOUT_MS: 'invalid' }, 0.3]] as [string[], Record<string, string>, number][]) {
    const r = await run(['jev', ...prefix, requestFile, '100'], { env });
    expect(r.code, r.err).toBe(0);
    expect(r.curls.length).toBe(1);
    expect(seconds(r.curls[0]!)).toBeGreaterThan(0);
    expect(seconds(r.curls[0]!)).toBeLessThanOrEqual(Math.ceil(max));
    expect(JSON.parse(r.out).answers.ok.noul).toBe(0.99);
  }
  const began = Date.now();
  const slow = await run(['jev', requestFile], { env: { JEV_FABRIC_JEV_TIMEOUT_MS: '50', CURL_DELAY: '1' } });
  expect(slow.code).not.toBe(0);
  expect(Date.now() - began).toBeLessThan(1000);
  const bad = await run(['jev', requestFile], { env: { JEV_FABRIC_JEV_TIMEOUT_MS: 'invalid' } });
  expect(bad.code).toBe(2);
  expect(bad.curls).toEqual([]);
});

test('public timer-free Process, Session, Jev and Scope APIs execute with configured defaults', async () => {
  const r = await run(['defaults'], { program: resolve('build/test-timers'), env: { JEV_FABRIC_TIMEOUT_MS: '1000', JEV_FABRIC_JEV_TIMEOUT_MS: '700' } });
  expect(r.code, r.err).toBe(0);
  const rows = r.out.trim().split('\n');
  expect(JSON.parse(rows[0]!).stdout).toBe('buffered\n');
  expect(JSON.parse(rows[1]!).stdout).toBe('session\n');
  expect(rows[2]).toBe('700');
  expect(JSON.parse(rows[3]!).stdout).toBe('scoped-default\n');
  expect(r.curls).toEqual([]);
});

test('shared budgets expire, reap processes/sessions and block new effects without charging Jev', async () => {
  const marker = join(root, 'expired-launch');
  const began = Date.now();
  const r = await run(['scope', marker], { program: resolve('build/test-timers'), env: { TYPESAFE_API_KEY: '', JEV_CREDENTIAL_COMMAND: JSON.stringify(['/bin/sh', credential]) } });
  expect(r.code, r.err).toBe(0);
  expect(Date.now() - began).toBeLessThan(2000);
  const reports = r.out.trim().split('\n').filter(x => x.startsWith('{')).map(x => JSON.parse(x));
  expect(reports.length).toBe(4);
  for (const row of reports) expect(row).toMatchObject({ exitCode: 124, timedOut: true });
  for (const row of [reports[0], reports[1], reports[3]]) { const pid = Number(row.stdout.trim()); expect(pid).toBeGreaterThan(1); expect(gone(pid)).toBe(true); }
  expect(reports[2].stdout).toBe('');
  expect(existsSync(marker)).toBe(false);
  expect(r.credentials).toBe('');
  expect(r.curls).toEqual([]);
  expect(r.out).toContain('expired session: no launch');
  expect(r.out).toContain('expired Jev: no reservation');
});

test('scoped Jev deadlines share remaining time, preserve credential cache and restore local caps', async () => {
  const r = await run(['jev', request], { program: resolve('build/test-timers'), env: { TYPESAFE_API_KEY: '', JEV_CREDENTIAL_COMMAND: JSON.stringify(['/bin/sh', credential]), JEV_FABRIC_JEV_TIMEOUT_MS: '10000' } });
  expect(r.code, r.err).toBe(0);
  expect(r.credentials).toBe('x');
  expect(r.curls.length).toBe(2);
  expect(seconds(r.curls[0]!)).toBe(1);
  expect(seconds(r.curls[1]!)).toBe(2);
  expect(r.out.trim().split('\n').at(-1)).toBe('10000');
});
