import { randomUUID } from 'node:crypto';
import { mkdirSync, readFileSync, renameSync, writeFileSync, watch, type FSWatcher } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import type { FabricEvent, RunPlan, RunRecord } from './types.js';
import { json } from './util.js';

/** Run IDs are lowercase version-4 UUIDs, so they can never traverse out of the state root. */
const RUN_ID_PATTERN = /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/;
const MAX_RECORD_BYTES = 1048576;
const PRIVATE_FILE_MODE = 0o600;
const PRIVATE_DIRECTORY_MODE = 0o700;

function defaultStateRoot(): string {
  const stateHome = process.env.XDG_STATE_HOME ?? join(homedir(), '.local', 'state');
  return join(stateHome, 'jev-fabric');
}
export function stateRoot(explicit?: string): string {
  return resolve(explicit ?? process.env.JEV_FABRIC_STATE_DIR ?? defaultStateRoot());
}
export function runDirectory(root: string, id: string): string {
  if (!RUN_ID_PATTERN.test(id)) throw new Error('Invalid run ID');
  return join(root, id);
}
export function atomic(directory: string, file: string, value: unknown): void {
  const temporary = join(directory, `.${file}.tmp`);
  writeFileSync(temporary, json(value, MAX_RECORD_BYTES) + '\n', { mode: PRIVATE_FILE_MODE });
  renameSync(temporary, join(directory, file));
}
export function createPlan(root: string, options: Omit<RunPlan, 'id' | 'directory'>): RunPlan {
  const id = randomUUID();
  const directory = runDirectory(root, id);
  mkdirSync(directory, { recursive: true, mode: PRIVATE_DIRECTORY_MODE });
  const plan = { ...options, id, directory };
  atomic(directory, 'plan.json', plan);
  return plan;
}
function readRecord<T>(directory: string, file: string): T {
  return JSON.parse(readFileSync(join(directory, file), 'utf8')) as T;
}
export function readPlan(directory: string): RunPlan {
  return readRecord<RunPlan>(directory, 'plan.json');
}
export function readRun(directory: string): RunRecord {
  return readRecord<RunRecord>(directory, 'state.json');
}
export interface EventSnapshot { firstSequence: number; nextSequence: number; events: FabricEvent[] }
export function readEvents(directory: string): EventSnapshot {
  return readRecord<EventSnapshot>(directory, 'events.json');
}

/** Subscribe before reading: an atomic rename between setup and inspection cannot be missed. */
export async function waitForRun(
  directory: string,
  signal?: AbortSignal,
  onChange?: () => void,
): Promise<RunRecord> {
  signal?.throwIfAborted();
  return new Promise((resolveResult, reject) => {
    let watcher: FSWatcher | undefined;
    let ended = false;
    const cleanup = () => {
      ended = true;
      watcher?.close();
      signal?.removeEventListener('abort', abort);
    };
    const fail = (error: unknown) => {
      cleanup();
      reject(error);
    };
    const abort = () => fail(signal?.reason ?? new Error('Wait cancelled'));
    const inspect = () => {
      if (ended) return;
      try {
        onChange?.();
        const run = readRun(directory);
        if (run.state !== 'running') {
          cleanup();
          resolveResult(run);
        }
      } catch (error) {
        fail(error);
      }
    };
    const isRunFile = (file: string | null) => !file || file === 'state.json' || file === 'events.json';
    try {
      watcher = watch(directory, (_event, file) => {
        if (isRunFile(file)) inspect();
      });
      watcher.on('error', fail);
      signal?.addEventListener('abort', abort, { once: true });
      inspect();
    } catch (error) {
      fail(error);
    }
  });
}
