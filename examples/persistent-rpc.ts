import { defineProgram } from 'jev-fabric';

// The same pattern works with `macos-harness serve --app <authorized app>`.
// This fixture only talks to a local Node process and touches no application.
export default defineProgram(async ({ shell }) => {
  const child = shell.spawn({ command: process.execPath, args: ['-e', `
    let count = 0;
    require('node:readline').createInterface({ input: process.stdin }).on('line', line => {
      console.log(JSON.stringify({ id: JSON.parse(line).id, count: ++count }));
    });
  `] });
  const replies = child.lines();
  const counts: number[] = [];
  for (const id of [1, 2, 3]) {
    await child.write(JSON.stringify({ id }) + '\n');
    const frame = await replies.next();
    if (frame.done) throw new Error('RPC transport closed');
    const reply = JSON.parse(frame.value);
    if (reply.id !== id || reply.count !== id) throw new Error('RPC response mismatch');
    counts.push(reply.count);
  }
  child.end();
  const receipt = await child.wait();
  if (receipt.exitCode !== 0) throw new Error('RPC process failed');
  return { verified: true, counts };
});
