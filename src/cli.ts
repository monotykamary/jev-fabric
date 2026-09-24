#!/usr/bin/env node
import { readFile, stat } from 'node:fs/promises';
import { writeFileSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { parseArgs } from 'node:util';
import { JevClient, type JevProvider } from './jev.js';
import { atomic, createPlan, readEvents, readRun, runDirectory, stateRoot, waitForRun } from './store.js';
import { startDetached, supervise } from './supervisor.js';
import { asJson, integer, message } from './util.js';
import type { Json, RunRecord } from './types.js';

const help = `jev-fabric — process orchestration with typed System One decisions

Usage:
  jev-fabric run <program.js|program.ts|-> [--input input.json]
  jev-fabric start <program.js|program.ts|-> [--input input.json]
  jev-fabric status <id>
  jev-fabric events <id> [--after N] [--follow]
  jev-fabric wait <id>
  jev-fabric stop <id>
  jev-fabric evaluate [--request request.json|-] [--provider typesafe|openrouter|vercel]

Options:
  --state-dir PATH        Private run storage (or JEV_FABRIC_STATE_DIR)
  --timeout-ms N          Run deadline (default 60000); wait/follow deadline (30000)
  --max-evaluations N     Per-program judgment budget (default 100)
  --max-tokens N          Reported-token budget (default 100000; not a hard spend cap)
  --json                 Accepted explicitly; output is always JSON/NDJSON
  --help, --version

Programs default-export an async function receiving { input, shell, jev, events,
signal, emit, sleep, handoff }. '-' reads a JavaScript module from stdin.
Native programs have your OS permissions: this is NOT a sandbox. Only explicit
jev.evaluate calls use inference. start owns an independent bounded supervisor;
wait cancellation does not stop it. macOS/Linux, Node 24+.
`;
const output = (value: unknown) => {
  if (process.stdout.writableLength > 1048576) throw new Error('CLI output queue exceeded 1 MiB; resume from the last event cursor');
  return process.stdout.write(JSON.stringify(value) + '\n');
};
// A downstream consumer may intentionally close a pipeline (for example, head).
// CLI stdout is only used after foreground settlement or for detached-run inspection.
process.stdout.on('error', error => {
  if ((error as NodeJS.ErrnoException).code === 'EPIPE') process.exit(0);
  process.stderr.write(JSON.stringify({ error: 'CLI stdout failed' }) + '\n');
  process.exit(2);
});
function terminalCode(run: RunRecord): number {
  return run.state === 'completed' ? 0 : run.state === 'needs_attention' ? 3 : run.state === 'cancelled' ? 130 : run.state === 'timed_out' ? 124 : 1;
}
async function readBounded(path: string, maxBytes = 131072, signal?: AbortSignal): Promise<string> {
  signal?.throwIfAborted();
  if (path !== '-') {
    const info = await stat(path);
    if (!info.isFile() || info.size > maxBytes) throw new Error(`Input must be a file no larger than ${maxBytes} bytes`);
    const content = await readFile(path, { encoding: 'utf8', signal });
    if (Buffer.byteLength(content) > maxBytes) throw new Error('Input grew beyond its size limit');
    return content;
  }
  const chunks: Buffer[] = []; let bytes = 0;
  const abort = () => process.stdin.destroy(new Error('Interrupted while reading stdin'));
  signal?.addEventListener('abort', abort, { once: true });
  try {
    for await (const part of process.stdin) {
      const chunk = Buffer.from(part); bytes += chunk.length;
      if (bytes > maxBytes) throw new Error(`stdin exceeds ${maxBytes} bytes`);
      chunks.push(chunk);
    }
    signal?.throwIfAborted();
    return Buffer.concat(chunks).toString('utf8');
  } finally { signal?.removeEventListener('abort', abort); }
}
async function readJson(path: string, signal?: AbortSignal): Promise<Json> {
  const text = await readBounded(path, 131072, signal);
  let value: unknown;
  try { value = JSON.parse(text); } catch { throw new Error('Input is not valid JSON'); }
  return asJson(value);
}

export async function main(argv = process.argv.slice(2)): Promise<number> {
  const { values, positionals } = parseArgs({ args: argv, allowPositionals: true, strict: true, options: {
    help: { type: 'boolean', short: 'h' }, version: { type: 'boolean' }, json: { type: 'boolean' },
    'state-dir': { type: 'string' }, input: { type: 'string' }, request: { type: 'string' }, provider: { type: 'string' },
    'timeout-ms': { type: 'string' }, 'max-evaluations': { type: 'string' }, 'max-tokens': { type: 'string' },
    after: { type: 'string' }, follow: { type: 'boolean' },
  } });
  if (values.version) { process.stdout.write('0.1.0\n'); return 0; }
  if (values.help || !positionals.length) { process.stdout.write(help); return 0; }
  const [command, argument] = positionals;
  if (!['run', 'start', 'status', 'events', 'wait', 'stop', 'evaluate'].includes(command!)) throw new Error(`Unknown command: ${command}`);
  if (positionals.length !== (command === 'evaluate' ? 1 : 2)) throw new Error('Unexpected or missing positional argument; see --help');
  const number = (name: 'timeout-ms' | 'max-evaluations' | 'max-tokens' | 'after', fallback: number, min = 1, max = 86400000) => integer(values[name] === undefined ? fallback : Number(values[name]), name, min, max);
  const controller = new AbortController();
  const interrupt = () => controller.abort(new Error('Interrupted'));
  process.once('SIGINT', interrupt); process.once('SIGTERM', interrupt);
  try {
    if (command === 'evaluate') {
      const request = await readJson(values.request ?? '-', controller.signal);
      const client = new JevClient({ provider: values.provider as JevProvider | undefined, signal: controller.signal,
        timeoutMs: number('timeout-ms', 15000), maxTokens: number('max-tokens', 100000) });
      output(await client.evaluate(request as never)); return 0;
    }
    const root = stateRoot(values['state-dir']);
    if (command === 'run' || command === 'start') {
      if (argument === '-' && values.input === '-') throw new Error('Program and input cannot both consume stdin');
      let program = resolve(argument!);
      let source: string | undefined;
      if (argument === '-') source = await readBounded('-', 131072, controller.signal);
      else if (!(await stat(program)).isFile()) throw new Error('Program must be a file');
      const plan = createPlan(root, {
        program, cwd: process.cwd(), input: values.input ? await readJson(values.input, controller.signal) : null,
        timeoutMs: number('timeout-ms', 60000), maxEvaluations: number('max-evaluations', 100, 1, 100000), maxTokens: number('max-tokens', 100000),
      });
      if (source !== undefined) {
        program = join(plan.directory, 'program.mjs'); writeFileSync(program, source, { mode: 0o600 });
        plan.program = program; atomic(plan.directory, 'plan.json', plan);
      }
      if (command === 'start') {
        await startDetached(plan, controller.signal);
        output({ schemaVersion: 1, id: plan.id, state: readRun(plan.directory).state }); return 0;
      }
      const run = await supervise(plan, controller.signal); output(run); return terminalCode(run);
    }
    const directory = runDirectory(root, argument!);
    if (command === 'status') { output(readRun(directory)); return 0; }
    const signal = AbortSignal.any([controller.signal, AbortSignal.timeout(number('timeout-ms', 30000))]);
    if (command === 'events') {
      let cursor = number('after', 0, 0, Number.MAX_SAFE_INTEGER);
      if (!values.follow) {
        const snapshot = readEvents(directory);
        output({ ...snapshot, events: snapshot.events.filter(event => event.sequence > cursor), gap: Math.max(0, snapshot.firstSequence - cursor - 1) }); return 0;
      }
      const flush = () => {
        const snapshot = readEvents(directory);
        if (cursor < snapshot.firstSequence - 1) {
          output({ runId: argument, type: 'stream.gap', omitted: snapshot.firstSequence - cursor - 1 });
          cursor = snapshot.firstSequence - 1;
        }
        for (const event of snapshot.events) if (event.sequence > cursor) { output({ runId: argument, ...event }); cursor = event.sequence; }
      };
      await waitForRun(directory, signal, flush); return 0;
    }
    if (command === 'stop' && readRun(directory).state === 'running') writeFileSync(join(directory, 'stop-request'), '', { mode: 0o600 });
    const run = await waitForRun(directory, signal); output(run);
    return command === 'stop' ? 0 : terminalCode(run);
  } finally { process.off('SIGINT', interrupt); process.off('SIGTERM', interrupt); }
}

try { process.exitCode = await main(); }
catch (error) { process.stderr.write(JSON.stringify({ error: message(error) }) + '\n'); process.exitCode = 2; }
