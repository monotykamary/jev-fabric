import { EventBus } from './events.js';
import { JevClient, type JevOptions } from './jev.js';
import { Shell, type ShellOptions } from './process.js';
import type { FabricEvent, Json, RunState } from './types.js';
import { asJson, message, sleep } from './util.js';

export interface ProgramContext {
  readonly input: Json;
  readonly signal: AbortSignal;
  readonly shell: Shell;
  readonly jev: JevClient;
  readonly events: EventBus;
  emit(type: string, data?: Json): void;
  sleep(ms: number): Promise<void>;
  handoff(reason: string, evidence?: Json): never;
}
export type Program = (context: ProgramContext) => Json | Promise<Json>;
export function defineProgram(program: Program): Program { return program; }
class Handoff extends Error {
  constructor(readonly evidence: Json, reason: string) { super(reason); }
}
export interface ProgramOptions {
  input?: Json;
  signal?: AbortSignal;
  cwd?: string;
  jev?: Omit<JevOptions, 'signal' | 'onUsage'>;
  onEvent?: (event: FabricEvent) => void;
  onProcess?: ShellOptions['onProcess'];
}
export interface ProgramOutcome {
  state: Exclude<RunState, 'running'>;
  result?: Json;
  error?: string;
  evaluations: number;
  usage: { input_tokens: number; output_tokens: number };
}
/** In-process library API. Use the CLI supervisor for a hard wall-clock limit on native code. */
export async function runProgram(program: Program, options: ProgramOptions = {}): Promise<ProgramOutcome> {
  const controller = new AbortController();
  const signal = options.signal ? AbortSignal.any([options.signal, controller.signal]) : controller.signal;
  const events = new EventBus(128, options.onEvent);
  const shell = new Shell({ signal, cwd: options.cwd, events, onProcess: options.onProcess });
  const jev = new JevClient({ ...options.jev, signal, onUsage: stats => events.emit('jev.usage', stats) });
  let outcome: Omit<ProgramOutcome, 'usage' | 'evaluations'>;
  try {
    signal.throwIfAborted();
    const result = await program({
      input: asJson(options.input ?? null), signal, shell, jev, events,
      emit: (type, data = null) => { signal.throwIfAborted(); events.emit(type, data); },
      sleep: ms => sleep(ms, signal),
      handoff: (reason, evidence = null) => {
        if (!reason || reason.length > 2000) throw new Error('Handoff reason must be 1..2000 characters');
        throw new Handoff(asJson(evidence, 16384), reason);
      },
    });
    signal.throwIfAborted();
    outcome = { state: 'completed', result: asJson(result, 32768) };
  } catch (error) {
    outcome = signal.aborted ? { state: 'cancelled' }
      : error instanceof Handoff ? { state: 'needs_attention', result: { reason: error.message, evidence: error.evidence } }
      : { state: 'failed', error: message(error) };
  } finally {
    controller.abort(new Error('Program settled'));
    await shell.close();
    events.close();
  }
  return { ...outcome, evaluations: jev.evaluations, usage: { ...jev.usage } };
}
