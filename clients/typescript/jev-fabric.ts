/**
 * A thin client for `jev-fabric -- serve`, the JSONL session protocol.
 *
 * One file, Node built-ins only, erasable TypeScript: Bun, Deno, Node 22.6+
 * (type stripping) or any bundler.
 * Copy it next to your code, or import it from
 * `~/.local/share/jev-fabric/current/clients/typescript`.
 *
 * The client starts one `serve` child, writes one request line per call and
 * resolves each promise with the matching response line. Budgets, deadlines,
 * credentials and Jev validation all live in the executable; this module only
 * frames JSON.
 *
 * ```ts
 * import { Fabric } from './jev-fabric.ts';
 *
 * const fabric = await Fabric.open({ maxEvaluations: 10 });
 * const job = await fabric.start(['/bin/sh', '-c', 'npm run dev']);
 * await fabric.watch(job, 'ready', { timeoutMs: 30000 });
 * const answer = await fabric.jev(request);
 * await fabric.close();
 * ```
 */
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { createInterface } from 'node:readline';

export const PROTOCOL = 1;

export interface FabricOptions {
  /** Defaults to `$JEV_FABRIC_BIN` or `jev-fabric` on PATH. */
  binary?: string;
  /** Bounds the whole session; defaults to the CLI work default (one hour). */
  timeoutMs?: number;
  /** Jev evaluations for the whole session; defaults to 1, as for `jev`. */
  maxEvaluations?: number;
  /** Reported Jev tokens for the whole session; defaults to 100000. */
  maxTokens?: number;
  env?: NodeJS.ProcessEnv;
  cwd?: string;
}

export interface Ready {
  protocol: number;
  version: string;
  timeoutMs: number;
  maxEvaluations: number;
  maxTokens: number;
}

export interface Receipt {
  schemaVersion: number;
  state: 'exited' | 'failed' | 'timed_out' | 'cancelled';
  exitCode: number | null;
  timedOut: boolean;
  cancelled: boolean;
  stdout: string;
  stderr: string;
  truncated: { stdout: boolean; stderr: boolean };
}

export type JobState =
  | (Receipt & { id: string; spoolLimitBytes: number })
  | { schemaVersion: number; id: string; state: 'running'; spoolLimitBytes: number }
  | { schemaVersion: number; id: string; state: 'failed'; exitCode: null; error: string; spoolLimitBytes: number };

export interface JobEvent {
  sequence: number;
  type: string;
  data: unknown;
}

export interface MonitorRecord {
  type: 'monitor.batch' | 'monitor.loss' | 'monitor.end';
  [field: string]: unknown;
}

export type JevRequest = Record<string, unknown>;
export type JevAnswer = {
  model?: string;
  answers: Record<string, Record<string, unknown>>;
  usage?: { input_tokens: number; output_tokens: number };
};

/**
 * A request the session refused or could not complete. `code` follows the
 * CLI's exit codes: 2 for a malformed request, 22 for a rejected value, 124 for
 * an expired deadline, 1 otherwise.
 */
export class FabricError extends Error {
  readonly code: number;
  readonly op?: string;

  constructor(code: number, message: string, op?: string) {
    super(op ? `${op}: ${message}` : message);
    this.name = 'FabricError';
    this.code = code;
    this.op = op;
  }
}

interface Pending {
  op: string;
  resolve(value: any): void;
  reject(error: FabricError): void;
}

/**
 * One `jev-fabric -- serve` session. Requests may be issued concurrently;
 * the session answers them one at a time, in the order they were sent.
 */
export class Fabric {
  readonly ready: Ready;
  private readonly child: ChildProcessWithoutNullStreams;
  private readonly pending = new Map<number, Pending>();
  private nextId = 1;
  private readonly exited: Promise<number | null>;
  private readonly log: { text: string };
  private ended?: FabricError;

  private constructor(
    child: ChildProcessWithoutNullStreams,
    ready: Ready,
    lines: AsyncIterator<string>,
    exited: Promise<number | null>,
    log: { text: string },
  ) {
    this.child = child;
    this.ready = ready;
    this.exited = exited;
    this.log = log;
    void this.pump(lines);
  }

  static async open(options: FabricOptions = {}): Promise<Fabric> {
    const binary = options.binary ?? process.env.JEV_FABRIC_BIN ?? 'jev-fabric';
    const argv = ['--', 'serve'];
    if (options.timeoutMs !== undefined) argv.push('--timeout-ms', String(options.timeoutMs));
    const maxEvaluations = options.maxEvaluations ?? (options.maxTokens !== undefined ? 1 : undefined);
    if (maxEvaluations !== undefined) argv.push(String(maxEvaluations));
    if (options.maxTokens !== undefined) argv.push(String(options.maxTokens));
    const child = spawn(binary, argv, { env: options.env, cwd: options.cwd, stdio: 'pipe' });
    // serve writes to stderr only when it exits abnormally; keep it for the error.
    const log = { text: '' };
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', chunk => (log.text += chunk));
    const exited = new Promise<number | null>(done => child.once('close', code => done(code)));
    await new Promise<void>((resolve, reject) => {
      child.once('spawn', resolve);
      child.once('error', error => reject(new FabricError(1, `could not start ${binary}: ${error.message}`)));
    });
    const lines = createInterface({ input: child.stdout, crlfDelay: Infinity })[Symbol.asyncIterator]();
    const first = await lines.next();
    if (first.done) {
      const code = await exited;
      throw new FabricError(code || 1, log.text.trim() || `serve exited with code ${code}`);
    }
    const banner = JSON.parse(first.value);
    if (banner?.ready?.protocol !== PROTOCOL) {
      child.stdin.end();
      throw new FabricError(1, `unsupported serve protocol: ${first.value}`);
    }
    return new Fabric(child, banner.ready, lines, exited, log);
  }

  // -- processes -------------------------------------------------------------

  /** Runs literal argv to completion. A nonzero exit is a receipt, not an error. */
  exec(argv: string[], options: { stdin?: string; timeoutMs?: number } = {}): Promise<Receipt> {
    return this.call('exec', { argv, stdin: options.stdin, timeoutMs: options.timeoutMs });
  }

  /** Starts a detached job that outlives this session; resolves to its id. */
  async start(argv: string[], options: { timeoutMs?: number } = {}): Promise<string> {
    const started = await this.call<{ id: string }>('start', { argv, timeoutMs: options.timeoutMs });
    return started.id;
  }

  status(job: string): Promise<JobState> {
    return this.call('status', { job });
  }

  /** Retained events with a sequence above `after` (a bounded snapshot). */
  events(job: string, options: { after?: number } = {}): Promise<JobEvent[]> {
    return this.call('events', { job, after: options.after });
  }

  /** The final receipt, or the running state once `timeoutMs` passes. */
  wait(job: string, options: { timeoutMs?: number } = {}): Promise<JobState> {
    return this.call('wait', { job, timeoutMs: options.timeoutMs });
  }

  stop(job: string): Promise<JobState> {
    return this.call('stop', { job });
  }

  /** Live output lines containing `literal`, as monitor records. */
  watch(job: string, literal: string, options: { timeoutMs?: number } = {}): Promise<MonitorRecord[]> {
    return this.call('watch', { job, literal, timeoutMs: options.timeoutMs });
  }

  // -- Jev -------------------------------------------------------------------

  /** Strictly validates a Jev request offline, without credentials. */
  validate(request: JevRequest): Promise<JevRequest> {
    return this.call('validate', { request });
  }

  /** One explicit, billed evaluation against the session budget. */
  jev(request: JevRequest, options: { timeoutMs?: number } = {}): Promise<JevAnswer> {
    return this.call('jev', { request, timeoutMs: options.timeoutMs });
  }

  // -- session ---------------------------------------------------------------

  /** Ends the session by closing its input; resolves to the exit code. */
  close(): Promise<number | null> {
    if (!this.child.stdin.destroyed) this.child.stdin.end();
    return this.exited;
  }

  // -- framing ---------------------------------------------------------------

  private call<T>(op: string, fields: Record<string, unknown>): Promise<T> {
    if (this.ended) return Promise.reject(this.ended);
    const id = this.nextId++;
    const request: Record<string, unknown> = { id, op };
    for (const [key, value] of Object.entries(fields)) {
      if (value !== undefined) request[key] = value;
    }
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { op, resolve, reject });
      this.child.stdin.write(JSON.stringify(request) + '\n', error => {
        if (error && this.pending.delete(id)) reject(new FabricError(1, `serve input closed: ${error.message}`, op));
      });
    });
  }

  private async pump(lines: AsyncIterator<string>) {
    try {
      for (let next = await lines.next(); !next.done; next = await lines.next()) {
        const response = JSON.parse(next.value);
        const waiting = this.pending.get(response.id);
        if (!waiting) continue;
        this.pending.delete(response.id);
        if (response.ok) waiting.resolve(response.result);
        else waiting.reject(new FabricError(response.error?.code ?? 1, response.error?.message ?? 'request failed', waiting.op));
      }
    } finally {
      const code = await this.exited;
      this.ended = new FabricError(code || 1, this.log.text.trim() || `serve exited with code ${code}`);
      for (const [, waiting] of this.pending) {
        waiting.reject(new FabricError(this.ended.code, this.ended.message, waiting.op));
      }
      this.pending.clear();
    }
  }
}
