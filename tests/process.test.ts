import test from 'node:test';
import assert from 'node:assert/strict';
import { EventBus, Queue, Shell, runProgram, defineProgram } from '../src/index.js';
import { Monitor, LineFramer } from '../src/monitor.js';

const node = (code: string) => ({ command: process.execPath, args: ['-e', code] });

test('event history is bounded, replay gaps explicit, slow consumers fail', async () => {
  const bus = new EventBus(2);
  bus.emit('a'); bus.emit('b'); bus.emit('c');
  const stream = bus.subscribe();
  assert.equal((await stream.next()).value?.type, 'stream.gap');
  assert.equal((await stream.next()).value?.sequence, 2);
  await stream.return();
  const queue = new Queue<number>(1); queue.push(1); queue.push(2);
  await assert.rejects(queue.next(), /overflow/);
  assert.throws(() => bus.emit('large', 'x'.repeat(4097)), /exceeds/);
  bus.close();
});

test('incremental UTF-8 framing, monitor deduplication/coalescing and truncation', () => {
  const framed: string[] = [];
  const framer = new LineFramer(line => framed.push(line));
  const utf = Buffer.from('🙂 ready\n'); framer.append(utf.subarray(0, 2)); framer.append(utf.subarray(2)); framer.close();
  assert.deepEqual(framed, ['🙂 ready']);
  const bus = new EventBus();
  const monitor = new Monitor({ match: 'MATCH', intervalMs: 100 }, batch => bus.emit('batch', { ...batch }));
  monitor.framer.append(Buffer.from('ignore\nMATCH one\nMATCH one\n'));
  for (let i = 0; i < 12; i++) monitor.framer.append(Buffer.from(`MATCH ${i} ${'🙂'.repeat(2000)}\n`));
  monitor.close();
  const data = bus.snapshot().events[0]!.data as { lines: string[]; omitted: number };
  assert.equal(data.lines.length, 8); assert.equal(data.omitted, 5);
  assert.ok(data.lines.every(line => line.includes('[truncated]')));
});

test('argv is literal, stdin works, nonzero and missing executable are receipts', async () => {
  const shell = new Shell();
  try {
    const literal = await shell.exec({ command: process.execPath, args: ['-e', 'console.log(process.argv[1])', '$(must-not-execute)'] });
    assert.equal(literal.stdout.trim(), '$(must-not-execute)');
    const input = await shell.exec({ ...node("process.stdin.on('data', b => process.stdout.write(b))"), input: 'hello\n' });
    assert.equal(input.stdout, 'hello\n');
    const fail = await shell.exec(node('process.exit(7)')); assert.equal(fail.state, 'failed'); assert.equal(fail.exitCode, 7);
    assert.equal((await shell.exec({ command: '/nonexistent/jev-fabric-fixture' })).state, 'failed');
  } finally { await shell.close(); }
});

test('shell heredocs/pipelines and native process piping compose', async () => {
  const shell = new Shell();
  try {
    const script = await shell.script("cat <<'TEXT' | tr a-z A-Z\nhello\nTEXT");
    assert.equal(script.stdout, 'HELLO\n');
    const producer = shell.spawn(node("process.stdout.write('pipeline')"));
    const consumer = shell.spawn(node("process.stdin.on('data', b => process.stdout.write(b.toString().toUpperCase()))"));
    producer.pipeTo(consumer); producer.end();
    const [a, b] = await Promise.all([producer.wait(), consumer.wait()]);
    assert.equal(a.exitCode, 0); assert.equal(b.stdout, 'PIPELINE');
  } finally { await shell.close(); }
});

test('persistent JSONL subprocess retains state across requests', async () => {
  const shell = new Shell();
  try {
    const job = shell.spawn(node("let count=0; require('node:readline').createInterface({input:process.stdin}).on('line', s => console.log(JSON.stringify({request:JSON.parse(s),count:++count})))"));
    const replies = job.lines();
    await job.write('{"id":1}\n'); assert.equal(JSON.parse((await replies.next()).value!).count, 1);
    await job.write('{"id":2}\n'); assert.equal(JSON.parse((await replies.next()).value!).count, 2);
    job.end(); assert.equal((await job.wait()).state, 'exited');
    await replies.return();
  } finally { await shell.close(); }
});

test('output tails and protocol lines are bounded independently', async () => {
  const shell = new Shell();
  try {
    const job = shell.spawn(node("process.stdout.write('x'.repeat(200000)+'\\n')"));
    const lines = job.lines();
    const rejection = assert.rejects(lines.next(), /128 KiB/);
    const result = await job.wait(); await rejection;
    assert.ok(result.truncated.stdout); assert.ok(Buffer.byteLength(result.stdout) <= 32768);
  } finally { await shell.close(); }
});

test('monitor lifetime, cancellation, concurrency and start budgets are enforced', async () => {
  const shell = new Shell({ maxConcurrent: 1, maxStarts: 2 });
  try {
    const live = shell.spawn({ ...node('setInterval(()=>{},1000)'), monitor: { lifetimeMs: 80 } });
    assert.throws(() => shell.spawn(node('0')), /concurrency/);
    assert.equal((await live.wait()).state, 'timed_out');
    const second = shell.spawn(node('setInterval(()=>{},1000)')); second.stop();
    assert.equal((await second.wait()).state, 'cancelled');
    assert.throws(() => shell.spawn(node('0')), /budget/);
  } finally { await shell.close(); }
});

test('observer publication failures stop owned work instead of leaking it', async () => {
  const events = new EventBus(128, () => { throw new Error('fixture observer failed'); });
  const shell = new Shell({ events });
  try {
    const job = shell.spawn(node('setInterval(()=>{},1000)'));
    const result = await job.wait();
    assert.equal(result.state, 'failed'); assert.match(result.error!, /observer failed/);
  } finally { await shell.close(); }
  const registration = new Shell({ onProcess: () => { throw new Error('fixture registration failed'); } });
  try { assert.equal((await registration.exec(node('setInterval(()=>{},1000)'))).state, 'failed'); }
  finally { await registration.close(); }
});

test('coalesced output explicitly labels preview truncation', async () => {
  const shell = new Shell();
  try {
    const job = shell.spawn(node("process.stdout.write('x'.repeat(10000))"));
    await job.wait();
    const events = [];
    for await (const event of job.events()) events.push(event);
    const preview = events.find(event => event.type === 'process.output')!;
    assert.equal((preview.data as { truncated: boolean }).truncated, true);
  } finally { await shell.close(); }
});

test('program completion cleans up outstanding jobs; handoff is not success', async () => {
  let job: ReturnType<Shell['spawn']> | undefined;
  const result = await runProgram(defineProgram(async context => {
    job = context.shell.spawn(node('setInterval(()=>{},1000)'));
    context.emit('ready', { ok: true }); return { value: 42 };
  }));
  assert.equal(result.state, 'completed'); assert.equal((await job!.wait()).state, 'cancelled');
  assert.equal(result.evaluations, 0);
  const handoff = await runProgram(context => context.handoff('Needs a human decision', { ambiguous: true }));
  assert.equal(handoff.state, 'needs_attention');
  assert.equal((await runProgram(() => undefined as never)).state, 'failed');
});
