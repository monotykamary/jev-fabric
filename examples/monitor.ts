import { defineProgram } from 'jev-fabric';

// Offline deterministic watch: an exact READY marker needs no model.
export default defineProgram(async ({ shell, emit }) => {
  const job = shell.spawn({ command: process.execPath, args: ['-e', `
    console.log('ordinary noise');
    console.log('STATUS: READY');
    console.log('STATUS: READY');
    setInterval(() => {}, 1000);
  `], monitor: { match: 'STATUS:', intervalMs: 25, lifetimeMs: 2000 } });
  for await (const event of job.events()) {
    if (event.type !== 'process.monitor') continue;
    const batch = event.data as { lines: string[]; omitted: number };
    if (batch.lines.includes('STATUS: READY')) {
      emit('service.ready', { processId: job.id });
      return { verified: true, ready: true }; // Settlement stops the owned fixture.
    }
  }
  throw new Error('Service never became ready');
});
