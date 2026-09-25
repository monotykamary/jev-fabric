import { test, expect, beforeAll, afterAll } from 'bun:test';
import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { nativeBin, tempRoot } from './helpers.ts';

// Conformance tests for `serve`, the JSONL session protocol (docs/serve-protocol.md).
const root = tempRoot('native-serve-');
const home = join(root, 'jobs');
const bin = join(root, 'bin');
mkdirSync(bin);
afterAll(() => rmSync(root, { recursive: true, force: true }));

const secret = 'SYNTHETIC_KEY_FOR_SERVE_TESTS';
const noul = {
  state: 'synthetic',
  questions: { ok: { type: 'noul', instructions: 'Is two plus two four?' } },
};
const reply = {
  model: 'jev-test',
  answers: { ok: { type: 'noul', noul: 0.99 } },
  usage: { input_tokens: 4, output_tokens: 2 },
};

// Fake curl: stands in for the network and records one line per dispatch.
const fakeCurl = `
import { appendFileSync } from 'node:fs';
const config = await Bun.stdin.text();
if (!config.includes('Authorization: Bearer ${secret}')) process.exit(9);
appendFileSync(process.env.CURL_RECORD!, 'x');
process.stdout.write(process.env.FAKE_RESPONSE! + '\\n200');
`;

beforeAll(async () => {
  await Bun.write(join(root, 'curl.ts'), fakeCurl);
  const curl = join(bin, 'curl');
  await Bun.write(curl, `#!/bin/sh\nexec '${process.execPath}' '${join(root, 'curl.ts')}' "$@"\n`);
  chmodSync(curl, 0o700);
  const credential = join(root, 'credential.sh');
  await Bun.write(credential, `#!/bin/sh\nprintf x >> "$CREDENTIAL_RECORD"\nprintf '%s\\n' '${secret}'\n`);
  chmodSync(credential, 0o700);
});

type Env = Record<string, string>;

/** One serve child with a line reader over its stdout. */
class Session {
  readonly child;
  private buffered = '';
  private readonly reader;
  private readonly decoder = new TextDecoder();

  constructor(args: string[] = [], env: Env = {}) {
    this.child = Bun.spawn([nativeBin, '--', 'serve', ...args], {
      env: { PATH: process.env.PATH!, BEND_NO_TELEMETRY: '1', JEV_FABRIC_HOME: home, ...env },
      stdin: 'pipe',
      stdout: 'pipe',
      stderr: 'pipe',
    });
    this.reader = this.child.stdout.getReader();
  }

  send(line: string) {
    this.child.stdin.write(line);
    this.child.stdin.flush();
  }

  async line(): Promise<any> {
    for (;;) {
      const at = this.buffered.indexOf('\n');
      if (at >= 0) {
        const text = this.buffered.slice(0, at);
        this.buffered = this.buffered.slice(at + 1);
        return JSON.parse(text);
      }
      const { value, done } = await this.reader.read();
      if (done) return undefined;
      this.buffered += this.decoder.decode(value, { stream: true });
    }
  }

  async ask(request: unknown): Promise<any> {
    this.send(JSON.stringify(request) + '\n');
    return this.line();
  }

  async close() {
    this.child.stdin.end();
    const [code, err] = await Promise.all([this.child.exited, new Response(this.child.stderr).text()]);
    return { code, err };
  }
}

async function session(args: string[] = [], env: Env = {}) {
  const s = new Session(args, env);
  const banner = await s.line();
  return { s, banner };
}

test('serve announces its protocol, version, deadline and budgets', async () => {
  const { s, banner } = await session(['--timeout-ms', '60000', '3', '500']);
  expect(banner).toEqual({
    ready: { protocol: 1, version: '0.3.0-native', timeoutMs: 60000, maxEvaluations: 3, maxTokens: 500 },
  });
  expect(await s.close()).toEqual({ code: 0, err: '' });

  const defaults = await session();
  expect(defaults.banner.ready).toMatchObject({ timeoutMs: 3600000, maxEvaluations: 1, maxTokens: 100000 });
  await defaults.s.close();
});

test('invalid session options fail before the banner', async () => {
  for (const args of [['x'], ['1', '2', '3'], ['--timeout-ms', '0'], ['--stdin']]) {
    const s = new Session(args);
    expect(await s.line()).toBeUndefined();
    const { code } = await s.close();
    expect(code).toBe(2);
  }
});

test('exec returns receipts; a failing command never ends the session', async () => {
  const { s } = await session();
  const echo = await s.ask({ id: 1, op: 'exec', argv: ['/bin/echo', 'hi'] });
  expect(echo).toMatchObject({ id: 1, ok: true, result: { state: 'exited', exitCode: 0, stdout: 'hi\n' } });

  const piped = await s.ask({ id: 2, op: 'exec', argv: ['/bin/cat'], stdin: 'piped\n' });
  expect(piped.result.stdout).toBe('piped\n');

  const failed = await s.ask({ id: 3, op: 'exec', argv: ['/bin/sh', '-c', 'echo no >&2; exit 3'] });
  expect(failed).toMatchObject({ ok: true, result: { state: 'failed', exitCode: 3, stderr: 'no\n' } });

  const missing = await s.ask({ id: 4, op: 'exec', argv: [join(root, 'missing')] });
  expect(missing).toMatchObject({ id: 4, ok: false, error: { code: 2 } });

  const slow = await s.ask({ id: 5, op: 'exec', argv: ['/bin/sleep', '5'], timeoutMs: 200 });
  expect(slow).toMatchObject({ ok: true, result: { state: 'timed_out', exitCode: 124, timedOut: true } });

  // Literal argv: nothing is parsed as a jev-fabric option or a shell word.
  const literal = await s.ask({ id: 6, op: 'exec', argv: ['/bin/echo', '--timeout-ms', '$HOME', '--'] });
  expect(literal.result.stdout).toBe('--timeout-ms $HOME --\n');

  expect((await s.ask({ id: 7, op: 'exec', argv: ['/bin/echo', 'still here'] })).result.stdout).toBe('still here\n');
  expect((await s.close()).code).toBe(0);
});

test('requests are strict: bad lines get a correlated error and the session continues', async () => {
  const { s } = await session();
  s.send('not json\n');
  const bad = await s.line();
  expect(bad).toMatchObject({ id: null, ok: false, error: { code: 1 } });
  expect(bad.error.message).toContain('not strict JSON');

  const cases: [unknown, number, string][] = [
    [{ id: 'a', op: 'launch' }, 2, 'unknown op'],
    [{ id: 'b', op: 'exec', argv: ['/bin/echo'], timeout: 5 }, 2, 'unknown request field: timeout'],
    [{ id: 'c', op: 'exec' }, 2, 'missing field: argv'],
    [{ id: 'd', op: 'exec', argv: [] }, 2, 'argv must be an array of 1 to 57 strings'],
    [{ id: 'e', op: 'exec', argv: [''] }, 2, 'argv[0] must name a command'],
    [{ id: 'f', op: 'exec', argv: ['/bin/echo', 1] }, 2, 'argv entries must be a string'],
    [{ id: 'g', op: 'exec', argv: Array(58).fill('/bin/echo') }, 2, 'argv must be an array of 1 to 57 strings'],
    [{ id: 'h', op: 'exec', argv: ['/bin/echo'], timeoutMs: 0 }, 2, 'timeoutMs must be an integer from 1 to 3600000'],
    [{ id: 'i', op: 'watch', job: 'x', literal: 'y', timeoutMs: 300001 }, 2, 'from 1 to 300000'],
    [{ id: 'j', op: 'status', job: '--help' }, 2, 'job must be an id returned by start'],
    [{ id: 'k', op: 'events', job: 'x', after: -1 }, 2, 'after must be an event sequence number'],
    [{ id: { nested: true }, op: 'status', job: 'x' }, 2, 'id must be a string or number'],
    [[1, 2], 2, 'request must be a JSON object'],
  ];
  for (const [request, code, message] of cases) {
    const response = await s.ask(request);
    const id = (request as any)?.id;
    expect(response.id).toEqual(typeof id === 'string' ? id : null);
    expect(response.ok).toBe(false);
    expect(response.error.code).toBe(code);
    expect(response.error.message).toContain(message);
  }
  // Duplicate keys are rejected by the strict JSON boundary.
  s.send('{"id":1,"id":2,"op":"status","job":"x"}\n');
  expect((await s.line()).ok).toBe(false);
  expect((await s.ask({ id: 99, op: 'exec', argv: ['/bin/echo', 'ok'] })).ok).toBe(true);
  expect((await s.close()).code).toBe(0);
});

test('framing: blank lines are skipped, CRLF is accepted, a final unterminated line is answered', async () => {
  const { s } = await session();
  s.send('\n\r\n{"id":1,"op":"exec","argv":["/bin/echo","crlf"]}\r\n');
  expect((await s.line()).result.stdout).toBe('crlf\n');
  // Two requests in one write are answered in order.
  s.send('{"id":2,"op":"exec","argv":["/bin/echo","a"]}\n{"id":3,"op":"exec","argv":["/bin/echo","b"]}\n');
  expect((await s.line()).id).toBe(2);
  expect((await s.line()).id).toBe(3);
  s.send('{"id":4,"op":"exec","argv":["/bin/echo","last"]}');
  s.child.stdin.end();
  expect(await s.line()).toMatchObject({ id: 4, ok: true, result: { stdout: 'last\n' } });
  expect(await s.child.exited).toBe(0);
});

test('an oversized partial line ends the session instead of desynchronizing', async () => {
  const { s } = await session();
  s.send('{"id":1,"op":"exec","argv":["' + 'x'.repeat(1048600));
  expect(await s.line()).toMatchObject({ id: null, ok: false, error: { code: 2, message: 'request line exceeds 1 MiB' } });
  const { code, err } = await s.close();
  expect(code).toBe(2);
  expect(err).toContain('request line exceeds 1 MiB');
});

test('validate runs in process with the strict Jev request contract', async () => {
  const { s } = await session();
  const ok = await s.ask({ id: 1, op: 'validate', request: noul });
  expect(ok).toEqual({ id: 1, ok: true, result: noul });
  const bad = await s.ask({ id: 2, op: 'validate', request: { state: 'x', questions: {} } });
  expect(bad).toMatchObject({ id: 2, ok: false, error: { code: 22, message: 'invalid question count' } });
  const extra = await s.ask({ id: 3, op: 'validate', request: { ...noul, extra: 1 } });
  expect(extra.error.message).toBe('unknown request field');
  await s.close();
});

test('jobs: start, watch, wait, status, events and stop, with jobs outliving the session', async () => {
  const { s } = await session();
  const started = await s.ask({
    id: 1,
    op: 'start',
    argv: ['/bin/sh', '-c', 'echo booting; sleep 0.3; echo ready; sleep 0.3; echo done'],
  });
  expect(started.ok).toBe(true);
  const job = started.result.id;
  expect(job).toMatch(/^[0-9a-f]{32}$/);

  const watched = await s.ask({ id: 2, op: 'watch', job, literal: 'ready', timeoutMs: 5000 });
  expect(watched.ok).toBe(true);
  const lines = watched.result.filter((r: any) => r.type === 'monitor.batch').flatMap((r: any) => r.lines);
  expect(lines).toEqual([{ text: 'ready', clipped: false }]);
  expect(watched.result.at(-1).type).toBe('monitor.end');

  const waited = await s.ask({ id: 3, op: 'wait', job, timeoutMs: 5000 });
  expect(waited.result).toMatchObject({ id: job, state: 'exited', stdout: 'booting\nready\ndone\n' });
  expect((await s.ask({ id: 4, op: 'status', job })).result.state).toBe('exited');

  const events = await s.ask({ id: 5, op: 'events', job });
  expect(Array.isArray(events.result)).toBe(true);
  const sequences = events.result.map((e: any) => e.sequence);
  const after = await s.ask({ id: 6, op: 'events', job, after: sequences[1] });
  expect(after.result.map((e: any) => e.sequence)).toEqual(sequences.slice(2));

  expect((await s.ask({ id: 7, op: 'stop', job })).result.state).toBe('exited');
  const unknown = await s.ask({ id: 8, op: 'status', job: 'deadbeef' });
  expect(unknown).toMatchObject({ ok: false, error: { code: 22 } });

  // A job started in a session keeps running after that session ends.
  const long = (await s.ask({ id: 9, op: 'start', argv: ['/bin/sleep', '30'] })).result.id;
  await s.close();
  const next = await session();
  expect((await next.s.ask({ id: 1, op: 'status', job: long })).result.state).toBe('running');
  expect((await next.s.ask({ id: 2, op: 'stop', job: long })).ok).toBe(true);
  const stopped = await next.s.ask({ id: 3, op: 'wait', job: long, timeoutMs: 5000 });
  expect(stopped.result.state).toBe('cancelled');
  await next.s.close();
});

test('wait returns the running state when its own timeout passes', async () => {
  const { s } = await session();
  const job = (await s.ask({ id: 1, op: 'start', argv: ['/bin/sleep', '30'] })).result.id;
  const started = Date.now();
  const waited = await s.ask({ id: 2, op: 'wait', job, timeoutMs: 300 });
  expect(waited.result).toMatchObject({ id: job, state: 'running' });
  expect(Date.now() - started).toBeLessThan(3000);
  await s.ask({ id: 3, op: 'stop', job });
  await s.close();
});

test('the session deadline bounds requests, then ends the session with 124', async () => {
  const { s } = await session(['--timeout-ms', '2600']);
  // 600 ms of the session remain after the two-second receipt grace: a longer
  // exec is cut to fit and reports its own timeout.
  const cut = await s.ask({ id: 1, op: 'exec', argv: ['/bin/sleep', '5'], timeoutMs: 60000 });
  expect(cut).toMatchObject({ ok: true, result: { state: 'timed_out' } });
  const late = await s.ask({ id: 2, op: 'validate', request: noul });
  expect(late).toEqual({ id: 2, ok: false, error: { code: 124, message: 'serve deadline expired' } });
  const { code, err } = await s.close();
  expect(code).toBe(124);
  expect(err).toContain('serve deadline expired');
});

function jevEnv(extra: Env = {}): Env & { CURL_RECORD: string; CREDENTIAL_RECORD: string } {
  const n = Math.random().toString(16).slice(2);
  return {
    PATH: `${bin}:/usr/bin:/bin`,
    JEV_FABRIC_HTTP: 'exec',
    JEV_PROVIDER: 'typesafe',
    TYPESAFE_API_KEY: '',
    JEV_CREDENTIAL_COMMAND: JSON.stringify(['/bin/sh', join(root, 'credential.sh')]),
    CURL_RECORD: join(root, `curl-${n}`),
    CREDENTIAL_RECORD: join(root, `cred-${n}`),
    FAKE_RESPONSE: JSON.stringify(reply),
    ...extra,
  };
}
const record = (path: string) => (existsSync(path) ? readFileSync(path, 'utf8') : '');

test('jev threads one client: one credential lookup, a session-wide call budget', async () => {
  const env = jevEnv();
  const { s } = await session(['2', '1000'], env);
  const first = await s.ask({ id: 1, op: 'jev', request: noul });
  expect(first).toEqual({ id: 1, ok: true, result: reply });
  const second = await s.ask({ id: 2, op: 'jev', request: noul, timeoutMs: 5000 });
  expect(second.ok).toBe(true);
  const third = await s.ask({ id: 3, op: 'jev', request: noul });
  expect(third).toEqual({ id: 3, ok: false, error: { code: 1, message: 'Jev budget exhausted' } });
  const { code, err } = await s.close();
  expect(code).toBe(0);
  expect(err).not.toContain(secret);
  expect(record(env.CURL_RECORD)).toBe('xx');
  // The credential resolved once and stayed cached in the threaded client.
  expect(record(env.CREDENTIAL_RECORD)).toBe('x');
});

test('jev never dispatches invalid requests, and defaults to one evaluation', async () => {
  const env = jevEnv();
  const { s } = await session([], env);
  const invalid = await s.ask({ id: 1, op: 'jev', request: { state: 'x', questions: {} } });
  expect(invalid).toMatchObject({ ok: false, error: { code: 22, message: 'invalid question count' } });
  expect((await s.ask({ id: 2, op: 'jev', request: noul })).ok).toBe(true);
  expect((await s.ask({ id: 3, op: 'jev', request: noul })).error.message).toBe('Jev budget exhausted');
  await s.close();
  expect(record(env.CURL_RECORD)).toBe('x');

  const none = jevEnv({ JEV_CREDENTIAL_COMMAND: '' });
  const bare = await session(['0'], none);
  expect((await bare.s.ask({ id: 1, op: 'jev', request: noul })).error.message).toBe('Jev budget exhausted');
  await bare.s.close();
  expect(record(none.CURL_RECORD)).toBe('');
  expect(record(none.CREDENTIAL_RECORD)).toBe('');
});
