import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { EventBus, Queue } from './events.js';
import { LineFramer, Monitor, type MonitorOptions } from './monitor.js';
import { integer, killGroup, message } from './util.js';
import type { FabricEvent } from './types.js';

export interface ProcessOptions {
  command: string;
  args?: string[];
  cwd?: string;
  env?: NodeJS.ProcessEnv;
  input?: string;
  timeoutMs?: number;
  monitor?: MonitorOptions;
}
export interface ProcessResult {
  id: string;
  state: 'exited' | 'failed' | 'cancelled' | 'timed_out';
  exitCode: number | null;
  signal: string | null;
  error?: string;
  stdout: string;
  stderr: string;
  truncated: { stdout: boolean; stderr: boolean };
}
export interface ShellOptions {
  signal?: AbortSignal;
  cwd?: string;
  maxConcurrent?: number;
  maxStarts?: number;
  events?: EventBus;
  onProcess?: (kind: 'started' | 'closed', pid: number) => void;
}
class Tail {
  private buffer = Buffer.alloc(0);
  truncated = false;
  append(chunk: Buffer): void {
    const next = Buffer.concat([this.buffer, chunk]);
    this.truncated ||= next.length > 32768;
    this.buffer = next.subarray(Math.max(0, next.length - 32768));
  }
  text(): string { return this.buffer.toString('utf8'); }
}

export class ManagedProcess {
  readonly id = randomUUID();
  private readonly child: ChildProcessWithoutNullStreams;
  private readonly bus = new EventBus(64);
  private readonly out = new Tail();
  private readonly err = new Tail();
  private readonly monitor: Monitor | undefined;
  private readonly timers = new Set<ReturnType<typeof setTimeout>>();
  private readonly done: Promise<ProcessResult>;
  private finished = false;
  private stopping: 'cancelled' | 'timed_out' | undefined;
  private readonly pending = { stdout: { text: '', bytes: 0 }, stderr: { text: '', bytes: 0 } };
  private outputTimer: ReturnType<typeof setTimeout> | undefined;
  private readers = 0;
  private failure: string | undefined;

  constructor(readonly options: ProcessOptions, private readonly host: ShellOptions, onDone: () => void) {
    if (!options.command || options.command.includes('\0') || options.args?.some(x => typeof x !== 'string' || x.includes('\0'))) throw new Error('Invalid command/argv');
    if (options.timeoutMs !== undefined) integer(options.timeoutMs, 'process timeout');
    if (options.input !== undefined && Buffer.byteLength(options.input) > 1048576) throw new Error('Process input exceeds 1 MiB');
    this.monitor = options.monitor ? new Monitor(options.monitor, batch => this.emit('process.monitor', { ...batch })) : undefined;
    this.child = spawn(options.command, options.args ?? [], {
      cwd: options.cwd ?? host.cwd, env: options.env ? { ...process.env, ...options.env } : process.env,
      detached: process.platform !== 'win32', stdio: ['pipe', 'pipe', 'pipe'],
    });
    if (this.child.pid) {
      try { host.onProcess?.('started', this.child.pid); }
      catch (error) { this.failure = message(error); killGroup(this.child.pid, 'SIGKILL'); }
    }
    // EPIPE is reflected by write() / process completion, never an unhandled stream error.
    this.child.stdin.on('error', () => {});
    this.child.stdout.on('data', (chunk: Buffer) => this.capture('stdout', chunk));
    this.child.stderr.on('data', (chunk: Buffer) => this.capture('stderr', chunk));
    let spawnError = false;
    this.child.on('error', () => { spawnError = true; });
    // Descendants must not outlive the command, even if they inherited its output pipes.
    this.child.once('exit', () => killGroup(this.child.pid, 'SIGKILL'));
    const abort = () => this.stop();
    host.signal?.addEventListener('abort', abort, { once: true });
    this.done = new Promise(resolve => {
      this.child.once('close', (code, signal) => {
        killGroup(this.child.pid, 'SIGKILL');
        this.finished = true;
        for (const timer of this.timers) clearTimeout(timer);
        if (this.outputTimer) clearTimeout(this.outputTimer);
        this.flushOutput();
        this.monitor?.close();
        host.signal?.removeEventListener('abort', abort);
        const result: ProcessResult = {
          id: this.id, state: this.failure ? 'failed' : this.stopping ?? (code === 0 && !spawnError ? 'exited' : 'failed'), exitCode: code, signal,
          ...(this.failure ? { error: this.failure } : {}),
          stdout: this.out.text(), stderr: this.err.text(), truncated: { stdout: this.out.truncated, stderr: this.err.truncated },
        };
        this.emit('process.exit', { state: result.state, exitCode: code, signal });
        this.bus.close();
        if (this.child.pid) {
          try { host.onProcess?.('closed', this.child.pid); }
          catch (error) { result.state = 'failed'; result.error = message(error); }
        }
        onDone(); resolve(result);
      });
    });
    this.emit('process.started', { command: options.command.slice(0, 256) });
    const lifetime = Math.min(options.timeoutMs ?? Infinity, options.monitor ? options.monitor.lifetimeMs ?? 300000 : Infinity);
    if (Number.isFinite(lifetime)) this.timers.add(setTimeout(() => this.stop('timed_out'), lifetime));
    if (options.input !== undefined) this.child.stdin.end(options.input);
    if (host.signal?.aborted) this.stop();
  }
  private emit(type: string, data: Record<string, string | number | boolean | null | string[]>): void {
    const payload = { processId: this.id, ...data };
    try { this.bus.emit(type, payload); this.host.events?.emit(type, payload); }
    catch (error) { this.failure = message(error); this.stop(); }
  }
  private capture(stream: 'stdout' | 'stderr', chunk: Buffer): void {
    (stream === 'stdout' ? this.out : this.err).append(chunk);
    // Monitor stdout only, so stderr chunks cannot splice into a protocol line.
    if (stream === 'stdout') this.monitor?.framer.append(chunk);
    const pending = this.pending[stream];
    pending.bytes += chunk.length;
    pending.text = (pending.text + chunk.toString('utf8')).slice(-512);
    if (!this.outputTimer) this.outputTimer = setTimeout(() => { this.outputTimer = undefined; this.flushOutput(); }, 100);
  }
  private flushOutput(): void {
    for (const stream of ['stdout', 'stderr'] as const) {
      const pending = this.pending[stream];
      if (pending.bytes) this.emit('process.output', { stream, text: pending.text, bytes: pending.bytes, truncated: pending.bytes > Buffer.byteLength(pending.text) });
      pending.text = ''; pending.bytes = 0;
    }
  }
  events(after = 0): Queue<FabricEvent> { return this.bus.subscribe(after); }
  wait(): Promise<ProcessResult> { return this.done; }
  async write(text: string): Promise<void> {
    if (this.finished || this.stopping) throw new Error('Process is not writable');
    if (Buffer.byteLength(text) > 1048576) throw new Error('Write exceeds 1 MiB');
    await new Promise<void>((resolve, reject) => this.child.stdin.write(text, error => error ? reject(error) : resolve()));
  }
  end(): void { this.child.stdin.end(); }
  pipeTo(target: ManagedProcess): void {
    if (this.finished || target.finished) throw new Error('Cannot pipe a completed process');
    this.child.stdout.pipe(target.child.stdin);
  }
  /** Subscribe before writing a request. Overflow or an oversized line fails explicitly. */
  lines(stream: 'stdout' | 'stderr' = 'stdout', capacity = 16): Queue<string> {
    integer(capacity, 'line queue capacity', 1, 128);
    if (stream !== 'stdout' && stream !== 'stderr') throw new Error('Unknown process stream');
    if (this.readers >= 8) throw new Error('Line subscriber limit reached');
    this.readers++;
    const source = this.child[stream];
    const onData = (chunk: Buffer) => framer.append(chunk);
    const onEnd = () => { framer.close(); queue.close(); };
    const queue = new Queue<string>(capacity, () => { this.readers--; source.off('data', onData); source.off('end', onEnd); });
    const framer = new LineFramer((line, truncated) => truncated ? queue.fail(new Error('Protocol line exceeds 128 KiB')) : queue.push(line), 131072);
    source.on('data', onData); source.once('end', onEnd);
    if (source.readableEnded || this.finished) queue.close();
    return queue;
  }
  stop(state: 'cancelled' | 'timed_out' = 'cancelled'): void {
    if (this.finished || this.stopping) return;
    this.stopping = state;
    killGroup(this.child.pid);
    this.timers.add(setTimeout(() => killGroup(this.child.pid, 'SIGKILL'), 250));
  }
}

export class Shell {
  private readonly active = new Set<ManagedProcess>();
  private starts = 0;
  private closed = false;
  constructor(private readonly options: ShellOptions = {}) {
    integer(options.maxConcurrent ?? 8, 'process concurrency', 1, 64);
    integer(options.maxStarts ?? 1000, 'process start budget');
  }
  spawn(options: ProcessOptions): ManagedProcess {
    if (this.closed) throw new Error('Shell is closed');
    this.options.signal?.throwIfAborted();
    if (this.active.size >= (this.options.maxConcurrent ?? 8)) throw new Error('Process concurrency limit reached');
    if (this.starts >= (this.options.maxStarts ?? 1000)) throw new Error('Process start budget exhausted');
    const handle = new ManagedProcess(options, this.options, () => this.active.delete(handle));
    this.active.add(handle); this.starts++;
    return handle;
  }
  async exec(options: ProcessOptions): Promise<ProcessResult> {
    const handle = this.spawn(options);
    if (options.input === undefined) handle.end();
    return handle.wait();
  }
  script(source: string, options: Omit<ProcessOptions, 'command' | 'args'> = {}): Promise<ProcessResult> {
    return this.exec({ ...options, command: 'bash', args: ['-euo', 'pipefail', '-c', source] });
  }
  async close(): Promise<void> {
    this.closed = true;
    const active = [...this.active];
    for (const handle of active) handle.stop();
    await Promise.all(active.map(handle => handle.wait()));
  }
}
