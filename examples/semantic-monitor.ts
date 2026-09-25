import { defineProgram } from 'jev-fabric';

// OPT-IN LIVE INFERENCE: one judgment over synthetic text, not real app state.
// Expected outcome: needs_attention (CLI exit 3), not task completion.
export default defineProgram(async ({ shell, jev, emit, handoff }) => {
  const job = shell.spawn({
    command: process.execPath,
    args: ['-e', `
      console.log('STATUS: Build failed because a required dependency is missing.');
    `],
    monitor: { match: 'STATUS:', intervalMs: 25, lifetimeMs: 2000 },
  });
  for await (const event of job.events()) {
    if (event.type !== 'process.monitor') continue;
    const batch = event.data as { lines: string[]; omitted: number };
    const incomplete = batch.omitted || batch.lines.some(line => line.includes('[truncated]'));
    if (incomplete) handoff('Incomplete observation; inspect the source');
    const decision = await jev.evaluate({
      state: { output: batch.lines },
      questions: {
        next: {
          type: 'choice',
          instructions: 'Given this build output, should the caller inspect a failure, '
            + 'or continue because there is no failure?',
          criteria: {
            inspect: 'A build failure needs investigation.',
            continue: 'No build failure is reported.',
          },
        },
      },
    });
    const { choice, confidence } = decision.answers.next;
    emit('decision', { selected: choice, confidence });
    if (confidence < 0.7) handoff('Uncertain classification; inspect the source');
    if (choice === 'inspect') handoff('Investigate the missing dependency', { output: batch.lines });
    throw new Error('Synthetic live probe did not identify the explicit failure');
  }
  throw new Error('No observation received');
});
