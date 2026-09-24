import { randomUUID } from 'node:crypto';
import { mkdirSync, readFileSync, renameSync, writeFileSync, watch, type FSWatcher } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import type { FabricEvent, RunPlan, RunRecord } from './types.js';
import { json } from './util.js';

export function stateRoot(explicit?: string): string {
  return resolve(explicit ?? process.env.JEV_FABRIC_STATE_DIR ?? join(process.env.XDG_STATE_HOME ?? join(homedir(), '.local', 'state'), 'jev-fabric'));
}
export function runDirectory(root: string, id: string): string {
  if (!/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/.test(id)) throw new Error('Invalid run ID');
  return join(root, id);
}
export function atomic(directory: string, file: string, value: unknown): void {
  const temporary = join(directory, `.${file}.tmp`);
  writeFileSync(temporary, json(value, 1048576) + '\n', { mode: 0o600 });
  renameSync(temporary, join(directory, file));
}
export function createPlan(root: string, options: Omit<RunPlan, 'id' | 'directory'>): RunPlan {
  const id = randomUUID();
  const directory = runDirectory(root, id);
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const plan = { ...options, id, directory };
  atomic(directory, 'plan.json', plan);
  return plan;
}
export function readPlan(directory: string): RunPlan { return JSON.parse(readFileSync(join(directory, 'plan.json'), 'utf8')) as RunPlan; }
export function readRun(directory: string): RunRecord { return JSON.parse(readFileSync(join(directory, 'state.json'), 'utf8')) as RunRecord; }
export interface EventSnapshot { firstSequence: number; nextSequence: number; events: FabricEvent[] }
export function readEvents(directory: string): EventSnapshot { return JSON.parse(readFileSync(join(directory, 'events.json'), 'utf8')) as EventSnapshot; }

/** Subscribe before reading: an atomic rename between setup and inspection cannot be missed. */
export async function waitForRun(directory: string, signal?: AbortSignal, onChange?: () => void): Promise<RunRecord> {
  signal?.throwIfAborted();
  return new Promise((resolveResult, reject) => {
    let watcher: FSWatcher | undefined;
    let ended = false;
    const cleanup = () => { ended = true; watcher?.close(); signal?.removeEventListener('abort', abort); };
    const abort = () => { cleanup(); reject(signal?.reason ?? new Error('Wait cancelled')); };
    const inspect = () => {
      if (ended) return;
      try {
        onChange?.();
        const run = readRun(directory);
        if (run.state !== 'running') { cleanup(); resolveResult(run); }
      } catch (error) { cleanup(); reject(error); }
    };
    try {
      watcher = watch(directory, (_event, file) => { if (!file || file === 'state.json' || file === 'events.json') inspect(); });
      watcher.on('error', error => { cleanup(); reject(error); });
      signal?.addEventListener('abort', abort, { once: true });
      inspect();
    } catch (error) { cleanup(); reject(error); }
  });
}
