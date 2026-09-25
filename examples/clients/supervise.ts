// Supervise a server from TypeScript through one `jev-fabric -- serve` session.
//
//   bun examples/clients/supervise.ts          # offline: no credentials, no model call
//   bun examples/clients/supervise.ts --live   # one billed Jev call (needs credentials)
//
// Node 22.6+ runs it too (type stripping). Starts a detached job,
// watches for "ready", reads a bounded receipt, and turns the observation into
// a typed Jev request. Only --live sends it.
import { Fabric } from '../../clients/typescript/jev-fabric.ts';

const server = "echo booting; sleep 0.2; echo 'listening on :8080 ready'; sleep 0.2; echo 'warning: cache cold'";

const live = process.argv.includes('--live');
const fabric = await Fabric.open({ maxEvaluations: live ? 1 : 0 });
try {
  const job = await fabric.start(['/bin/sh', '-c', server]);
  await fabric.watch(job, 'ready', { timeoutMs: 10000 });
  const receipt = await fabric.wait(job, { timeoutMs: 10000 });
  if (receipt.state === 'running') throw new Error('server is still running');

  const request = await fabric.validate({
    state: { log: 'stdout' in receipt ? receipt.stdout : '', exitCode: receipt.exitCode },
    questions: {
      healthy: { type: 'noul', instructions: 'Did the server start and stay healthy?' },
      next: {
        type: 'choice',
        instructions: 'What should happen next?',
        criteria: { proceed: 'Start the test suite', investigate: 'Inspect the warning first' },
      },
    },
  });
  if (!live) {
    console.log(JSON.stringify({ job, state: receipt.state, validated: Object.keys(request.questions as object).sort() }));
  } else {
    const { answers } = await fabric.jev(request);
    // A typed answer picks a branch the program already wrote.
    console.log(JSON.stringify({ job, next: answers.next?.choice, healthy: answers.healthy?.noul }));
  }
} finally {
  await fabric.close();
}
