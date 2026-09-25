import { defineProgram } from 'jev-fabric';

// Offline: no credentials, inference, browser, or native application.
export default defineProgram(async ({ shell }) => {
  const producer = shell.spawn({
    command: process.execPath,
    args: ['-e', "process.stdout.write('hello from a pipeline\\n')"],
  });
  const consumer = shell.spawn({
    command: process.execPath,
    args: ['-e', "process.stdin.on('data', b => process.stdout.write(b.toString().toUpperCase()))"],
  });
  producer.pipeTo(consumer);
  producer.end();
  const [source, result] = await Promise.all([producer.wait(), consumer.wait()]);
  if (source.exitCode !== 0 || result.exitCode !== 0) throw new Error('Pipeline failed');
  if (result.stdout !== 'HELLO FROM A PIPELINE\n') throw new Error('Pipeline postcondition failed');
  return { verified: true, output: result.stdout };
});
