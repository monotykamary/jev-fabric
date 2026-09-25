import { test, expect, afterAll } from 'bun:test';
import { mkdirSync, rmSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { Fabric, FabricError } from '../../clients/typescript/jev-fabric.ts';
import { capture, nativeBin, tempRoot } from './helpers.ts';

// Both clients against the real `serve` executable, offline.
const root = tempRoot('native-clients-');
afterAll(() => rmSync(root, { recursive: true, force: true }));
const env = { PATH: process.env.PATH!, BEND_NO_TELEMETRY: '1', JEV_FABRIC_HOME: join(root, 'jobs') };
const request = {
  state: 'synthetic',
  questions: { ok: { type: 'noul', instructions: 'Is two plus two four?' } },
};

function open(options: Parameters<typeof Fabric.open>[0] = {}) {
  return Fabric.open({ binary: nativeBin, env, ...options });
}

test('python client passes its offline suite', async () => {
  const tmp = join(root, 'python');
  mkdirSync(tmp);
  const r = await capture(['python3', resolve('clients/python/test_jev_fabric.py')], {
    env: { PATH: process.env.PATH!, JEV_FABRIC_BIN: nativeBin, JEV_FABRIC_TEST_TMP: tmp, PYTHONDONTWRITEBYTECODE: '1' },
  });
  expect(r.code, r.out + r.err).toBe(0);
  expect(r.err).toMatch(/Ran \d+ tests/);
}, 60000);

test('typescript client reports the session and returns receipts', async () => {
  const fabric = await open({ timeoutMs: 60000, maxEvaluations: 3, maxTokens: 500 });
  expect(fabric.ready).toEqual({ protocol: 1, version: '0.3.1-native', timeoutMs: 60000, maxEvaluations: 3, maxTokens: 500 });
  expect((await fabric.exec(['/bin/echo', 'hi'])).stdout).toBe('hi\n');
  expect((await fabric.exec(['/bin/cat'], { stdin: 'piped' })).stdout).toBe('piped');
  const failed = await fabric.exec(['/bin/sh', '-c', 'exit 3']);
  expect([failed.state, failed.exitCode]).toEqual(['failed', 3]);
  expect(await fabric.close()).toBe(0);
});

test('typescript client correlates pipelined requests and typed errors', async () => {
  const fabric = await open({ maxEvaluations: 0 });
  const outputs = await Promise.all([1, 2, 3, 4].map(n => fabric.exec(['/bin/echo', String(n)])));
  expect(outputs.map(r => r.stdout)).toEqual(['1\n', '2\n', '3\n', '4\n']);

  const rejected = await fabric.exec([]).catch(error => error);
  expect(rejected).toBeInstanceOf(FabricError);
  expect([rejected.code, rejected.op]).toEqual([2, 'exec']);

  expect(await fabric.validate(request)).toEqual(request);
  const invalid = await fabric.validate({ state: 'x', questions: {} }).catch(error => error);
  expect(invalid.code).toBe(22);
  const exhausted = await fabric.jev(request).catch(error => error);
  expect(exhausted.message).toBe('jev: Jev budget exhausted');
  await fabric.close();
});

test('typescript client drives jobs', async () => {
  const fabric = await open();
  const job = await fabric.start(['/bin/sh', '-c', 'sleep 0.2; echo ready; sleep 0.2']);
  const records = await fabric.watch(job, 'ready', { timeoutMs: 5000 });
  const lines = records.filter(r => r.type === 'monitor.batch').flatMap(r => r.lines as { text: string }[]);
  expect(lines.map(line => line.text)).toEqual(['ready']);
  expect((await fabric.wait(job, { timeoutMs: 5000 })).state).toBe('exited');
  expect((await fabric.status(job)).state).toBe('exited');
  expect((await fabric.events(job)).every(e => typeof e.sequence === 'number')).toBe(true);
  expect((await fabric.stop(job)).state).toBe('exited');
  await fabric.close();
});

test('typescript client surfaces startup failures and session end', async () => {
  const bad = await open({ timeoutMs: 0 }).catch(error => error);
  expect(bad).toBeInstanceOf(FabricError);
  expect(bad.code).toBe(2);
  const missing = await Fabric.open({ binary: join(root, 'missing'), env }).catch(error => error);
  expect(missing.message).toContain('could not start');

  // Less than the two-second receipt grace remains, so no request can run.
  const fabric = await open({ timeoutMs: 2100 });
  await Bun.sleep(200);
  const late = await fabric.exec(['/bin/echo', 'late']).catch(error => error);
  expect(late.code).toBe(124);
  const ended = await fabric.exec(['/bin/echo', 'ended']).catch(error => error);
  expect(ended.code).toBe(124);
  expect(ended.message).toContain('serve deadline expired');
  expect(await fabric.close()).toBe(124);
});
