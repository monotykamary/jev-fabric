import test from 'node:test';
import assert from 'node:assert/strict';
import { ByteTail, OutputBatch, type OutputPreview } from '../src/output.js';

/** The previous copy-everything tail, kept as the behavioral oracle for the ring. */
class ConcatTail {
  private buffer = Buffer.alloc(0);
  truncated = false;
  constructor(private readonly capacity: number) {}
  append(chunk: Buffer): void {
    const next = Buffer.concat([this.buffer, chunk]);
    this.truncated ||= next.length > this.capacity;
    this.buffer = next.subarray(Math.max(0, next.length - this.capacity));
  }
  bytes(): Buffer { return this.buffer; }
  text(): string { return this.buffer.toString('utf8'); }
}

function feed(capacity: number, chunks: Buffer[]): { ring: ByteTail; oracle: ConcatTail } {
  const ring = new ByteTail(capacity);
  const oracle = new ConcatTail(capacity);
  for (const chunk of chunks) {
    ring.append(chunk);
    oracle.append(chunk);
  }
  return { ring, oracle };
}

function assertSameTail(capacity: number, chunks: Buffer[]): ByteTail {
  const { ring, oracle } = feed(capacity, chunks);
  assert.deepEqual(ring.bytes(), oracle.bytes());
  assert.equal(ring.text(), oracle.text());
  assert.equal(ring.truncated, oracle.truncated);
  return ring;
}

const bytes = (text: string) => Buffer.from(text, 'utf8');

test('byte tail keeps everything below capacity and reports an empty tail as empty', () => {
  assert.equal(new ByteTail(8).text(), '');
  assert.equal(new ByteTail(8).truncated, false);
  const tail = assertSameTail(8, [bytes('ab'), Buffer.alloc(0), bytes('cde')]);
  assert.equal(tail.text(), 'abcde');
  assert.equal(tail.truncated, false);
});

test('byte tail at exactly capacity is not truncated; one more byte is', () => {
  const exact = assertSameTail(8, [bytes('abcd'), bytes('efgh')]);
  assert.equal(exact.text(), 'abcdefgh');
  assert.equal(exact.truncated, false);
  const single = assertSameTail(8, [bytes('abcdefgh')]);
  assert.equal(single.truncated, false);
  const over = assertSameTail(8, [bytes('abcdefgh'), bytes('i')]);
  assert.equal(over.text(), 'bcdefghi');
  assert.equal(over.truncated, true);
});

test('byte tail wraps around the ring and returns bytes oldest first', () => {
  const tail = assertSameTail(8, [bytes('abcdef'), bytes('ghij'), bytes('kl'), bytes('mnopq')]);
  assert.equal(tail.text(), 'jklmnopq');
  // Once truncated, the flag stays set even when later appends are small.
  const sticky = assertSameTail(4, [bytes('abcdef'), bytes('g')]);
  assert.equal(sticky.text(), 'defg');
  assert.equal(sticky.truncated, true);
});

test('byte tail keeps only the end of a chunk larger than capacity', () => {
  const alone = assertSameTail(8, [bytes('0123456789abcdef')]);
  assert.equal(alone.text(), '89abcdef');
  assert.equal(alone.truncated, true);
  // A large chunk arriving mid-ring must replace every retained byte.
  const midRing = assertSameTail(8, [bytes('abc'), bytes('0123456789abcdef'), bytes('XY')]);
  assert.equal(midRing.text(), 'abcdefXY');
});

test('byte tail cut inside multibyte UTF-8 decodes identically to the concatenating tail', () => {
  const emoji = bytes('🙂'); // four bytes
  for (let capacity = 1; capacity <= 9; capacity++) {
    for (let prefix = 0; prefix <= 3; prefix++) {
      const chunks = [bytes('x'.repeat(prefix)), emoji, bytes('é'), emoji];
      assertSameTail(capacity, chunks);
    }
  }
  // The cut lands on the third byte of the emoji: two orphan continuation bytes remain.
  const cut = assertSameTail(4, [bytes('ab'), emoji, bytes('cd')]);
  assert.equal(cut.text(), '\uFFFD\uFFFDcd');
  // A wrapped ring can split a sequence across its physical end; decoding sees it whole.
  const split = assertSameTail(8, [bytes('abcdefg'), emoji]);
  assert.equal(split.text(), 'defg🙂');
});

test('byte tail matches the concatenating tail on random chunk sequences at 32 KiB', () => {
  let seed = 7;
  const random = (limit: number) => {
    seed = (seed * 48271) % 2147483647;
    return seed % limit;
  };
  const alphabet = ['a', 'é', '🙂', '\n', '日'];
  const pool = bytes(Array.from({ length: 50000 }, () => alphabet[random(alphabet.length)]).join(''));
  for (let round = 0; round < 10; round++) {
    const chunks: Buffer[] = [];
    for (let i = 0; i < 80; i++) {
      // Mostly small chunks, some larger than the tail; byte offsets often fall inside characters.
      const size = random(3) === 0 ? random(40000) : random(3000);
      const offset = random(pool.length - size);
      chunks.push(pool.subarray(offset, offset + size));
    }
    assertSameTail(32768, chunks);
  }
});

test('output batch reports one bounded preview per stream, stdout first, then resets', () => {
  const batch = new OutputBatch();
  const reports: OutputPreview[] = [];
  const flush = () => batch.flush(preview => reports.push(preview));
  flush();
  assert.deepEqual(reports, []);
  batch.append('stderr', bytes('warn'));
  batch.append('stdout', bytes('a'.repeat(300)));
  batch.append('stdout', bytes('b'.repeat(300)));
  flush();
  assert.deepEqual(reports, [
    { stream: 'stdout', text: 'a'.repeat(212) + 'b'.repeat(300), bytes: 600, truncated: true },
    { stream: 'stderr', text: 'warn', bytes: 4, truncated: false },
  ]);
  assert.deepEqual(Object.keys(reports[0]!), ['stream', 'text', 'bytes', 'truncated']);
  flush();
  assert.equal(reports.length, 2);
  // Truncation compares bytes, so 512 multibyte characters under the limit are still complete.
  batch.append('stdout', bytes('é'.repeat(512)));
  flush();
  assert.deepEqual(reports[2], { stream: 'stdout', text: 'é'.repeat(512), bytes: 1024, truncated: false });
});
