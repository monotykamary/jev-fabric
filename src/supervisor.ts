import { fork, type ChildProcess } from 'node:child_process';
import { existsSync, watch, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { EventBus } from './events.js';
import type { ProgramOutcome } from './program.js';
import { atomic, readPlan } from './store.js';
import type { FabricEvent, RunPlan, RunRecord } from './types.js';
import { asJson, killGroup, message } from './util.js';

export async function supervise(plan: RunPlan, signal?: AbortSignal, ready?: () => void): Promise<RunRecord> {
  if (process.platform === 'win32') throw new Error('The initial supervisor supports macOS and Linux process groups');
  const run: RunRecord = { schemaVersion: 1, id: plan.id, program: plan.program, state: 'running', startedAt: new Date().toISOString(), evaluations: 0, usage: { input_tokens: 0, output_tokens: 0 } };
  const bus = new EventBus(128);
  let persistTimer: ReturnType<typeof setTimeout> | undefined;
  let deadline: ReturnType<typeof setTimeout> | undefined;
  let forceTimer: ReturnType<typeof setTimeout> | undefined;
  let desired: ProgramOutcome | undefined;
  let finished = false;
  const groups = new Set<number>();
  const persist = () => {
    if (persistTimer) clearTimeout(persistTimer);
    persistTimer = undefined;
    atomic(plan.directory, 'events.json', bus.snapshot());
    atomic(plan.directory, 'state.json', run);
  };
  const emit = (type: string, data: Parameters<EventBus['emit']>[1]) => {
    if (finished) return;
    bus.emit(type, data);
    if (!persistTimer) persistTimer = setTimeout(persist, 25);
  };
  emit('run.started', { id: run.id }); persist();
  const worker = fork(new URL('./worker.js', import.meta.url), [], {
    cwd: plan.cwd, detached: true, stdio: ['ignore', 'pipe', 'pipe', 'ipc'], execArgv: [],
  });
  const cleanupGroups = () => { for (const pid of groups) killGroup(pid, 'SIGKILL'); groups.clear(); };
  // Darwin can return EPERM for a zombie-only group before waitpid reaps its
  // leader. Stop the owned child handle first; finish() signals the group after
  // the exit event, when the leader is reaped, to remove surviving descendants.
  const force = () => { cleanupGroups(); worker.kill('SIGKILL'); };
  const cancel = (state: 'cancelled' | 'timed_out') => {
    if (finished || desired) return;
    desired = { state, evaluations: run.evaluations, usage: run.usage };
    emit('run.stopping', { state });
    if (worker.connected) worker.send({ kind: 'cancel' }, () => {});
    forceTimer = setTimeout(force, 500);
  };
  const abort = () => cancel('cancelled');
  const stopPath = join(plan.directory, 'stop-request');
  const watcher = watch(plan.directory, (_event, name) => { if ((!name || name === 'stop-request') && existsSync(stopPath)) cancel('cancelled'); });
  watcher.on('error', () => cancel('cancelled'));
  signal?.addEventListener('abort', abort, { once: true });
  deadline = setTimeout(() => cancel('timed_out'), plan.timeoutMs);
  const output = { stdout: { text: '', bytes: 0 }, stderr: { text: '', bytes: 0 } };
  const flushOutput = () => {
    for (const stream of ['stdout', 'stderr'] as const) {
      const batch = output[stream];
      if (batch.bytes) emit('program.output', { stream, text: batch.text, bytes: batch.bytes, truncated: batch.bytes > Buffer.byteLength(batch.text) });
      batch.text = ''; batch.bytes = 0;
    }
  };
  const outputTimer = setInterval(flushOutput, 100);
  for (const stream of ['stdout', 'stderr'] as const) worker[stream]!.on('data', (chunk: Buffer) => {
    const batch = output[stream]; batch.text = (batch.text + chunk.toString('utf8')).slice(-512); batch.bytes += chunk.length;
  });
  const completion = new Promise<RunRecord>(resolveResult => {
    worker.on('message', value => {
      try {
        const msg = value as { kind: string; event?: FabricEvent; action?: string; pid?: number; outcome?: ProgramOutcome };
        if (msg.kind === 'process' && Number.isSafeInteger(msg.pid) && msg.pid! > 0) {
          if (msg.action === 'started') groups.add(msg.pid!); else if (msg.action === 'closed') groups.delete(msg.pid!);
        } else if (msg.kind === 'event' && msg.event) {
          emit(msg.event.type, asJson(msg.event.data, 4096));
          if (msg.event.type === 'jev.usage') {
            const stats = msg.event.data as { evaluations: number; usage: RunRecord['usage'] };
            run.evaluations = stats.evaluations; run.usage = stats.usage;
          }
        } else if (msg.kind === 'result' && msg.outcome) {
          desired ??= msg.outcome;
          run.evaluations = msg.outcome.evaluations; run.usage = msg.outcome.usage;
          force();
        }
      } catch (error) {
        desired ??= { state: 'failed', error: message(error), evaluations: run.evaluations, usage: run.usage }; force();
      }
    });
    const finish = (code: number | null) => {
      if (finished) return;
      cleanupGroups(); killGroup(worker.pid, 'SIGKILL');
      flushOutput();
      const result = desired ?? { state: 'failed' as const, error: `Worker exited without a result (exit ${code})`, evaluations: run.evaluations, usage: run.usage };
      Object.assign(run, result, { evaluations: run.evaluations, usage: run.usage, endedAt: new Date().toISOString() });
      emit('run.finished', { state: run.state });
      finished = true;
      if (deadline) clearTimeout(deadline);
      if (forceTimer) clearTimeout(forceTimer);
      clearInterval(outputTimer); watcher.close(); signal?.removeEventListener('abort', abort);
      persist(); bus.close(); resolveResult(run);
    };
    worker.once('exit', finish);
    worker.once('error', error => { desired = { state: 'failed', error: message(error), evaluations: 0, usage: run.usage }; finish(null); });
  });
  // Start is sent first so a simultaneous cancellation cannot become the worker's initial message.
  worker.send({ kind: 'run', plan }, error => { if (error) cancel('cancelled'); });
  if (signal?.aborted || existsSync(stopPath)) cancel('cancelled');
  ready?.();
  return completion;
}

export async function startDetached(plan: RunPlan, signal?: AbortSignal): Promise<void> {
  signal?.throwIfAborted();
  await new Promise<void>((resolveReady, reject) => {
    const child: ChildProcess = fork(new URL('./supervisor.js', import.meta.url), [plan.directory], {
      cwd: plan.cwd, detached: true, stdio: ['ignore', 'ignore', 'ignore', 'ipc'], execArgv: [],
    });
    let settled = false;
    const finish = (error?: Error) => {
      if (settled) return; settled = true;
      clearTimeout(timer); signal?.removeEventListener('abort', abort);
      child.off('exit', exit); child.off('error', failed);
      if (error) {
        writeFileSync(join(plan.directory, 'stop-request'), '', { mode: 0o600 });
        killGroup(child.pid); reject(error);
      } else { child.disconnect(); child.unref(); resolveReady(); }
    };
    const abort = () => finish(new Error('Start cancelled'));
    const exit = () => finish(new Error('Background supervisor exited before readiness'));
    const failed = (error: Error) => finish(error);
    const timer = setTimeout(() => finish(new Error('Background supervisor did not become ready')), 10000);
    child.once('error', failed); child.once('exit', exit);
    child.once('message', value => (value as { ready?: boolean }).ready ? finish() : finish(new Error('Invalid supervisor handshake')));
    signal?.addEventListener('abort', abort, { once: true });
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const controller = new AbortController();
  process.on('SIGTERM', () => controller.abort()); process.on('SIGINT', () => controller.abort());
  try {
    const directory = process.argv[2];
    if (!directory) throw new Error('Missing run directory');
    await supervise(readPlan(directory), controller.signal, () => process.send?.({ ready: true }));
  } catch (error) { process.stderr.write(message(error) + '\n'); process.exitCode = 1; }
}
