import { setTimeout as delay } from 'node:timers/promises';
import type { Json } from './types.js';

const MAX_JSON_NODES = 100000;
const MAX_JSON_DEPTH = 32;
const MAX_MESSAGE_LENGTH = 2000;

export function record(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
export function integer(value: number, name: string, min = 1, max = 2_147_483_647): number {
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    throw new Error(`${name} must be an integer in ${min}..${max}`);
  }
  return value;
}
function isPlainObject(value: unknown): value is Record<string, unknown> {
  return record(value) && [Object.prototype, null].includes(Object.getPrototypeOf(value));
}
export function json(value: unknown, maxBytes = 131072): string {
  let count = 0;
  function visit(v: unknown, depth: number): void {
    if (++count > MAX_JSON_NODES || depth > MAX_JSON_DEPTH) throw new Error('JSON complexity limit exceeded');
    if (v === null || typeof v === 'string' || typeof v === 'boolean') return;
    if (typeof v === 'number' && Number.isFinite(v)) return;
    if (Array.isArray(v)) {
      for (const item of v) visit(item, depth + 1);
      return;
    }
    if (isPlainObject(v)) {
      for (const item of Object.values(v)) visit(item, depth + 1);
      return;
    }
    throw new Error('Expected finite JSON data (return null, not undefined)');
  }
  visit(value, 0);
  const text = JSON.stringify(value);
  if (Buffer.byteLength(text) > maxBytes) throw new Error(`JSON exceeds ${maxBytes} bytes`);
  return text;
}
export function asJson(value: unknown, maxBytes?: number): Json {
  return JSON.parse(json(value, maxBytes)) as Json;
}
export function message(error: unknown): string {
  const text = error instanceof Error ? error.message : String(error);
  return text.slice(0, MAX_MESSAGE_LENGTH);
}
export function killGroup(pid: number | undefined, signal: NodeJS.Signals = 'SIGTERM'): void {
  if (!pid) return;
  // A negative PID addresses the whole POSIX process group.
  const target = process.platform === 'win32' ? pid : -pid;
  try {
    process.kill(target, signal);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ESRCH') throw error;
  }
}
export async function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  integer(ms, 'sleep', 0);
  await delay(ms, undefined, { signal });
}
export async function abortable<T>(signal: AbortSignal, work: Promise<T>): Promise<T> {
  signal.throwIfAborted();
  let cancel: () => void = () => {};
  const aborted = new Promise<never>((_, reject) => {
    cancel = () => reject(signal.reason ?? new Error('Cancelled'));
    signal.addEventListener('abort', cancel, { once: true });
  });
  try {
    return await Promise.race([work, aborted]);
  } finally {
    signal.removeEventListener('abort', cancel);
  }
}
