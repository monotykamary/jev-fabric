import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const cli = fileURLToPath(new URL('../src/cli.js', import.meta.url));
function command(args: string[], input = ''): Promise<{ code: number | null; out: string; err: string }> {
  return new Promise((resolveResult, reject) => {
    const child = spawn(process.execPath, [cli, ...args], { stdio: ['pipe', 'pipe', 'pipe'], env: { ...process.env, JEV_PROVIDER: 'typesafe' } });
    let out = '', err = '';
    child.stdout.on('data', data => { out += data; }); child.stderr.on('data', data => { err += data; });
    child.once('error', reject); child.once('close', code => resolveResult({ code, out, err }));
    child.stdin.end(input);
  });
}
async function fixture(t: TestContext, source: string, extension = 'mjs') {
  const directory = await mkdtemp(join(tmpdir(), 'jvf-test-'));
  const program = join(directory, `program.${extension}`);
  await writeFile(program, source);
  t.after(() => rm(directory, { recursive: true, force: true }));
  const args = ['--state-dir', join(directory, 'runs')];
  return { directory, program, args };
}

test('CLI help/version and actual public compiled exports', async () => {
  assert.match((await command(['--help'])).out, /NOT a sandbox/);
  assert.equal((await command(['--version'])).out.trim(), '0.1.0');
  const api = await import('../src/index.js');
  for (const name of ['JevClient', 'Shell', 'ManagedProcess', 'EventBus', 'defineProgram', 'runProgram']) assert.equal(typeof api[name as keyof typeof api], 'function');
});

test('SIGINT interrupts an unfinished stdin program before launch', { timeout: 12000 }, async t => {
  const f = await fixture(t, 'export default () => null');
  const readiness = join(f.directory, 'readiness.mjs');
  await writeFile(readiness, `
    const original = process.stdin[Symbol.asyncIterator];
    process.stdin[Symbol.asyncIterator] = function () {
      process.send?.({ ready: true });
      return original.call(this);
    };
  `);
  const child = spawn(process.execPath, ['--import', readiness, cli, 'run', '-', ...f.args], { stdio: ['pipe', 'pipe', 'pipe', 'ipc'] });
  let error = '';
  child.stdout!.resume(); child.stderr!.on('data', chunk => { error += chunk; });
  child.once('message', () => child.kill('SIGINT'));
  const watchdog = setTimeout(() => child.kill('SIGKILL'), 8000);
  t.after(() => { clearTimeout(watchdog); if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL'); });
  const outcome = await new Promise<{ code: number | null; signal: string | null }>((resolveResult, reject) => {
    child.once('error', reject); child.once('close', (code, signal) => resolveResult({ code, signal }));
  });
  assert.equal(outcome.code, 2, error); assert.notEqual(outcome.signal, 'SIGKILL');
  assert.match(error, /Interrupted/);
});

test('native TypeScript file returns one JSON envelope; console logs are events', async t => {
  const f = await fixture(t, "export default async ({ input }: { input: unknown }) => { console.log('diagnostic'); return { input }; }", 'ts');
  const input = join(f.directory, 'input.json'); await writeFile(input, '{"n":42}');
  const result = await command(['run', f.program, '--input', input, ...f.args]);
  assert.equal(result.code, 0, result.err);
  const run = JSON.parse(result.out); assert.equal(run.result.input.n, 42); assert.equal(run.evaluations, 0);
  const events = JSON.parse((await command(['events', run.id, ...f.args])).out);
  assert.ok(events.events.some((event: { type: string }) => event.type === 'program.output'));
  const permissions = await stat(join(f.directory, 'runs', run.id, 'state.json'));
  assert.equal(permissions.mode & 0o077, 0);
});

test('stdin program, argv errors and explicit handoff exit status', async t => {
  const f = await fixture(t, 'export default () => null');
  const inline = await command(['run', '-', ...f.args], 'export default async ({shell}) => { const r = await shell.script("printf hello"); return {out:r.stdout}; }');
  assert.equal(inline.code, 0, inline.err); assert.equal(JSON.parse(inline.out).result.out, 'hello');
  const handoff = await command(['run', '-', ...f.args], "export default ({handoff}) => handoff('Need review', {reason:'ambiguous'});");
  assert.equal(handoff.code, 3, handoff.err + handoff.out); assert.equal(JSON.parse(handoff.out).state, 'needs_attention');
  assert.equal((await command(['status', '../../not-a-run', ...f.args])).code, 2);
  assert.equal((await command(['run', f.program, '--timeout-ms', '0', ...f.args])).code, 2);
});

test('detached start/status/events/wait/stop work across independent CLI processes', async t => {
  const f = await fixture(t, "export default async ({emit,sleep}) => { emit('watch.ready',{ok:true}); await sleep(10000); return null; }");
  const started = await command(['start', f.program, '--timeout-ms', '15000', ...f.args]);
  assert.equal(started.code, 0, started.err);
  const id = JSON.parse(started.out).id;
  t.after(async () => { await command(['stop', id, '--timeout-ms', '3000', ...f.args]); });
  assert.equal(JSON.parse((await command(['status', id, ...f.args])).out).state, 'running');
  const waiting = command(['wait', id, '--timeout-ms', '5000', ...f.args]);
  const following = command(['events', id, '--follow', '--timeout-ms', '5000', ...f.args]);
  const stopped = await command(['stop', id, '--timeout-ms', '5000', ...f.args]);
  assert.equal(stopped.code, 0, stopped.err); assert.equal(JSON.parse(stopped.out).state, 'cancelled');
  assert.equal((await waiting).code, 130);
  const streamed = await following; assert.equal(streamed.code, 0, streamed.err);
  const events = streamed.out.trim().split('\n').map(line => JSON.parse(line));
  assert.ok(events.some(event => event.type === 'run.finished'));
});

test('cancelling a wait does not cancel a detached run', async t => {
  const f = await fixture(t, 'export default async ({sleep}) => { await sleep(1000); return 7; }');
  const started = await command(['start', f.program, '--timeout-ms', '5000', ...f.args]);
  assert.equal(started.code, 0, started.err); const id = JSON.parse(started.out).id;
  assert.equal((await command(['wait', id, '--timeout-ms', '20', ...f.args])).code, 2);
  const terminal = await command(['wait', id, '--timeout-ms', '5000', ...f.args]);
  assert.equal(terminal.code, 0, terminal.err); assert.equal(JSON.parse(terminal.out).result, 7);
});

test('external deadline terminates an infinite synchronous worker and its managed process', async t => {
  const f = await fixture(t, '');
  const marker = join(f.directory, 'child.pid');
  await writeFile(f.program, `import {writeFileSync} from 'node:fs';
export default async ({shell}) => {
  const job = shell.spawn({command:process.execPath,args:['-e','console.log(process.pid);setInterval(()=>{},1000)']});
  const line = await job.lines().next(); writeFileSync(${JSON.stringify(marker)}, line.value);
  while(true) {}
}`);
  const result = await command(['run', f.program, '--timeout-ms', '800', ...f.args]);
  assert.equal(result.code, 124, result.err); assert.equal(JSON.parse(result.out).state, 'timed_out');
  const pid = Number((await readFile(marker, 'utf8')).trim());
  // Give init a brief opportunity to reap a terminated orphan.
  let alive = true;
  for (let i = 0; i < 100; i++) {
    try { process.kill(pid, 0); } catch { alive = false; break; }
    await new Promise(resolveDelay => setTimeout(resolveDelay, 20));
  }
  assert.equal(alive, false, `managed child ${pid} survived the deadline`);
});

test('bounded retained events disclose cursor gaps', async t => {
  const f = await fixture(t, "export default async ({emit,sleep}) => { for(let i=0;i<200;i++){ emit('tick',{i}); if(i%20===0) await sleep(5); } return null; }");
  const run = await command(['run', f.program, ...f.args]); assert.equal(run.code, 0, run.err);
  const events = JSON.parse((await command(['events', JSON.parse(run.out).id, ...f.args])).out);
  assert.equal(events.events.length, 128); assert.ok(events.gap > 0);
});
