import test from 'node:test';
import assert from 'node:assert/strict';
import { killGroup } from '../src/util.js';

test('killGroup ignores ESRCH but does not hide actual permission errors', t => {
  const absent = Object.assign(new Error('missing group'), {code: 'ESRCH'});
  const denied = Object.assign(new Error('permission denied'), {code: 'EPERM'});
  let failure = absent;
  const calls: Array<[number, unknown]> = [];
  t.mock.method(process, 'kill', (pid: number, signal: unknown) => { calls.push([pid, signal]); throw failure; });
  assert.doesNotThrow(() => killGroup(12345, 'SIGKILL'));
  failure = denied;
  assert.throws(() => killGroup(12345, 'SIGKILL'), error => error === denied);
  assert.deepEqual(calls, [[process.platform === 'win32' ? 12345 : -12345, 'SIGKILL'], [process.platform === 'win32' ? 12345 : -12345, 'SIGKILL']]);
});
