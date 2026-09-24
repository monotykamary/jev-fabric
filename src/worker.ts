import { pathToFileURL } from 'node:url';
import { runProgram } from './program.js';
import type { RunPlan } from './types.js';
import { message } from './util.js';

const controller = new AbortController();
let pending = 0;
function notify(value: unknown): void {
  if (!process.connected) return;
  if (pending >= 256) throw new Error('Supervisor IPC queue exhausted');
  pending++;
  process.send!(value as object, () => { pending--; });
}
process.on('SIGTERM', () => controller.abort(new Error('Supervisor cancelled run')));
process.on('disconnect', () => controller.abort(new Error('Supervisor disconnected')));
process.on('message', value => {
  if ((value as { kind?: string }).kind === 'cancel') controller.abort(new Error('Run stopped'));
});
process.once('message', async value => {
  if ((value as { kind?: string }).kind !== 'run') return;
  const plan = (value as { plan: RunPlan }).plan;
  let outcome;
  try {
    const module = await import(pathToFileURL(plan.program).href);
    if (typeof module.default !== 'function') throw new Error('Program must default-export a function');
    outcome = await runProgram(module.default, {
      input: plan.input, signal: controller.signal, cwd: plan.cwd,
      jev: { maxEvaluations: plan.maxEvaluations, maxTokens: plan.maxTokens },
      onEvent: event => notify({ kind: 'event', event }),
      onProcess: (action, pid) => notify({ kind: 'process', action, pid }),
    });
  } catch (error) {
    outcome = { state: controller.signal.aborted ? 'cancelled' : 'failed', error: message(error), evaluations: 0, usage: { input_tokens: 0, output_tokens: 0 } };
  }
  if (process.connected) process.send!({ kind: 'result', outcome }, () => process.disconnect());
});
