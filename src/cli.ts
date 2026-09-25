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

const COMMANDS = ['run', 'start', 'status', 'events', 'wait', 'stop', 'evaluate'];
const MAX_INPUT_BYTES = 131072;
const MAX_STDOUT_QUEUE_BYTES = 1048576;
const MAX_NUMERIC_OPTION = 86400000;
const MAX_EVALUATIONS_OPTION = 100000;
const EVALUATE_TIMEOUT_MS = 15000;
const RUN_TIMEOUT_MS = 60000;
const CLIENT_TIMEOUT_MS = 30000;
const DEFAULT_MAX_EVALUATIONS = 100;
const DEFAULT_MAX_TOKENS = 100000;

const output = (value: unknown) => {
  if (process.stdout.writableLength > MAX_STDOUT_QUEUE_BYTES) {
    throw new Error('CLI output queue exceeded 1 MiB; resume from the last event cursor');
  }
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
  switch (run.state) {
    case 'completed': return 0;
    case 'needs_attention': return 3;
    case 'cancelled': return 130;
    case 'timed_out': return 124;
    default: return 1;
  }
}
async function readBoundedFile(path: string, maxBytes: number, signal?: AbortSignal): Promise<string> {
  const info = await stat(path);
  if (!info.isFile() || info.size > maxBytes) {
    throw new Error(`Input must be a file no larger than ${maxBytes} bytes`);
  }
  const content = await readFile(path, { encoding: 'utf8', signal });
  if (Buffer.byteLength(content) > maxBytes) throw new Error('Input grew beyond its size limit');
  return content;
}
async function readBoundedStdin(maxBytes: number, signal?: AbortSignal): Promise<string> {
  const chunks: Buffer[] = [];
  let bytes = 0;
  const abort = () => process.stdin.destroy(new Error('Interrupted while reading stdin'));
  signal?.addEventListener('abort', abort, { once: true });
  try {
    for await (const part of process.stdin) {
      const chunk = Buffer.from(part);
      bytes += chunk.length;
      if (bytes > maxBytes) throw new Error(`stdin exceeds ${maxBytes} bytes`);
      chunks.push(chunk);
    }
    signal?.throwIfAborted();
    return Buffer.concat(chunks).toString('utf8');
  } finally {
    signal?.removeEventListener('abort', abort);
  }
}
async function readBounded(path: string, maxBytes = MAX_INPUT_BYTES, signal?: AbortSignal): Promise<string> {
  signal?.throwIfAborted();
  if (path !== '-') return readBoundedFile(path, maxBytes, signal);
  return readBoundedStdin(maxBytes, signal);
}
async function readJson(path: string, signal?: AbortSignal): Promise<Json> {
  const text = await readBounded(path, MAX_INPUT_BYTES, signal);
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    throw new Error('Input is not valid JSON');
  }
  return asJson(value);
}

function parseCli(argv: string[]) {
  return parseArgs({ args: argv, allowPositionals: true, strict: true, options: {
    help: { type: 'boolean', short: 'h' },
    version: { type: 'boolean' },
    json: { type: 'boolean' },
    'state-dir': { type: 'string' },
    input: { type: 'string' },
    request: { type: 'string' },
    provider: { type: 'string' },
    'timeout-ms': { type: 'string' },
    'max-evaluations': { type: 'string' },
    'max-tokens': { type: 'string' },
    after: { type: 'string' },
    follow: { type: 'boolean' },
  } });
}
type CliValues = ReturnType<typeof parseCli>['values'];
type NumericOption = 'timeout-ms' | 'max-evaluations' | 'max-tokens' | 'after';
type NumberOption = (name: NumericOption, fallback: number, min?: number, max?: number) => number;
interface CommandContext {
  values: CliValues;
  argument: string | undefined;
  number: NumberOption;
  signal: AbortSignal;
}

async function evaluateCommand({ values, number, signal }: CommandContext): Promise<number> {
  const request = await readJson(values.request ?? '-', signal);
  const client = new JevClient({
    provider: values.provider as JevProvider | undefined,
    signal,
    timeoutMs: number('timeout-ms', EVALUATE_TIMEOUT_MS),
    maxTokens: number('max-tokens', DEFAULT_MAX_TOKENS),
  });
  output(await client.evaluate(request as never));
  return 0;
}

async function launchCommand(
  command: 'run' | 'start',
  root: string,
  { values, argument, number, signal }: CommandContext,
): Promise<number> {
  if (argument === '-' && values.input === '-') throw new Error('Program and input cannot both consume stdin');
  let program = resolve(argument!);
  let source: string | undefined;
  if (argument === '-') source = await readBounded('-', MAX_INPUT_BYTES, signal);
  else if (!(await stat(program)).isFile()) throw new Error('Program must be a file');
  const input = values.input ? await readJson(values.input, signal) : null;
  const plan = createPlan(root, {
    program,
    cwd: process.cwd(),
    input,
    timeoutMs: number('timeout-ms', RUN_TIMEOUT_MS),
    maxEvaluations: number('max-evaluations', DEFAULT_MAX_EVALUATIONS, 1, MAX_EVALUATIONS_OPTION),
    maxTokens: number('max-tokens', DEFAULT_MAX_TOKENS),
  });
  if (source !== undefined) {
    // Stdin modules are stored privately with the run and executed from there.
    program = join(plan.directory, 'program.mjs');
    writeFileSync(program, source, { mode: 0o600 });
    plan.program = program;
    atomic(plan.directory, 'plan.json', plan);
  }
  if (command === 'start') {
    await startDetached(plan, signal);
    output({ schemaVersion: 1, id: plan.id, state: readRun(plan.directory).state });
    return 0;
  }
  const run = await supervise(plan, signal);
  output(run);
  return terminalCode(run);
}

async function eventsCommand(
  directory: string,
  runId: string,
  follow: boolean,
  cursor: number,
  signal: AbortSignal,
): Promise<number> {
  if (!follow) {
    const snapshot = readEvents(directory);
    const events = snapshot.events.filter(event => event.sequence > cursor);
    const gap = Math.max(0, snapshot.firstSequence - cursor - 1);
    output({ ...snapshot, events, gap });
    return 0;
  }
  const flush = () => {
    const snapshot = readEvents(directory);
    const lastOmitted = snapshot.firstSequence - 1;
    if (cursor < lastOmitted) {
      output({ runId, type: 'stream.gap', omitted: lastOmitted - cursor });
      cursor = lastOmitted;
    }
    for (const event of snapshot.events) {
      if (event.sequence > cursor) {
        output({ runId, ...event });
        cursor = event.sequence;
      }
    }
  };
  await waitForRun(directory, signal, flush);
  return 0;
}

export async function main(argv = process.argv.slice(2)): Promise<number> {
  const { values, positionals } = parseCli(argv);
  if (values.version) {
    process.stdout.write('0.1.0\n');
    return 0;
  }
  if (values.help || !positionals.length) {
    process.stdout.write(help);
    return 0;
  }
  const [command, argument] = positionals;
  if (!COMMANDS.includes(command!)) throw new Error(`Unknown command: ${command}`);
  const expectedPositionals = command === 'evaluate' ? 1 : 2;
  if (positionals.length !== expectedPositionals) {
    throw new Error('Unexpected or missing positional argument; see --help');
  }
  const number: NumberOption = (name, fallback, min = 1, max = MAX_NUMERIC_OPTION) => {
    const value = values[name] === undefined ? fallback : Number(values[name]);
    return integer(value, name, min, max);
  };
  const controller = new AbortController();
  const interrupt = () => controller.abort(new Error('Interrupted'));
  process.once('SIGINT', interrupt);
  process.once('SIGTERM', interrupt);
  const context: CommandContext = { values, argument, number, signal: controller.signal };
  try {
    if (command === 'evaluate') return await evaluateCommand(context);
    const root = stateRoot(values['state-dir']);
    if (command === 'run' || command === 'start') return await launchCommand(command, root, context);
    const directory = runDirectory(root, argument!);
    if (command === 'status') {
      output(readRun(directory));
      return 0;
    }
    const clientDeadline = AbortSignal.timeout(number('timeout-ms', CLIENT_TIMEOUT_MS));
    const signal = AbortSignal.any([controller.signal, clientDeadline]);
    if (command === 'events') {
      const cursor = number('after', 0, 0, Number.MAX_SAFE_INTEGER);
      return await eventsCommand(directory, argument!, Boolean(values.follow), cursor, signal);
    }
    if (command === 'stop' && readRun(directory).state === 'running') {
      writeFileSync(join(directory, 'stop-request'), '', { mode: 0o600 });
    }
    const run = await waitForRun(directory, signal);
    output(run);
    return command === 'stop' ? 0 : terminalCode(run);
  } finally {
    process.off('SIGINT', interrupt);
    process.off('SIGTERM', interrupt);
  }
}

try {
  process.exitCode = await main();
} catch (error) {
  process.stderr.write(JSON.stringify({ error: message(error) }) + '\n');
  process.exitCode = 2;
}
