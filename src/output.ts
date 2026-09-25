export type OutputStream = 'stdout' | 'stderr';
export type OutputPreview = { stream: OutputStream; text: string; bytes: number; truncated: boolean };

export const OUTPUT_PREVIEW_CHARS = 512;
export const OUTPUT_FLUSH_MS = 100;

const STREAMS = ['stdout', 'stderr'] as const;

/**
 * Keeps the last `capacity` bytes written, in a fixed ring, so each append copies only the new bytes.
 * `text()` decodes exactly the retained bytes in order, so a cut inside a multibyte UTF-8 sequence
 * decodes the same way as slicing the full output would.
 */
export class ByteTail {
  private ring: Buffer | undefined;
  /** Ring index of the oldest retained byte. */
  private start = 0;
  private length = 0;
  /** True once more than `capacity` bytes have been appended in total. */
  truncated = false;

  constructor(private readonly capacity: number) {}

  append(chunk: Buffer): void {
    if (chunk.length === 0) return;
    const capacity = this.capacity;
    const ring = (this.ring ??= Buffer.allocUnsafe(capacity));
    this.truncated ||= this.length + chunk.length > capacity;
    // Only the final `capacity` bytes of a chunk can survive this append.
    const kept = chunk.subarray(Math.max(0, chunk.length - capacity));
    const end = (this.start + this.length) % capacity;
    const beforeWrap = Math.min(kept.length, capacity - end);
    kept.copy(ring, end, 0, beforeWrap);
    kept.copy(ring, 0, beforeWrap);
    const total = this.length + kept.length;
    if (total > capacity) {
      // The oldest bytes were overwritten; the new oldest byte follows the last one written.
      this.start = (this.start + total - capacity) % capacity;
      this.length = capacity;
    } else {
      this.length = total;
    }
  }

  /** A copy of the retained bytes, oldest first. */
  bytes(): Buffer {
    if (!this.ring) return Buffer.alloc(0);
    const end = this.start + this.length;
    if (end <= this.capacity) return Buffer.from(this.ring.subarray(this.start, end));
    const head = this.ring.subarray(this.start);
    const wrapped = this.ring.subarray(0, end - this.capacity);
    return Buffer.concat([head, wrapped]);
  }

  text(): string { return this.bytes().toString('utf8'); }
}

/**
 * Coalesces output chunks into one bounded preview per stream between flushes. Callers own the flush
 * schedule; `flush` reports stdout before stderr and skips streams that received no bytes.
 */
export class OutputBatch {
  private readonly pending = { stdout: { text: '', bytes: 0 }, stderr: { text: '', bytes: 0 } };

  append(stream: OutputStream, chunk: Buffer): void {
    const pending = this.pending[stream];
    pending.bytes += chunk.length;
    pending.text = (pending.text + chunk.toString('utf8')).slice(-OUTPUT_PREVIEW_CHARS);
  }

  flush(report: (preview: OutputPreview) => void): void {
    for (const stream of STREAMS) {
      const pending = this.pending[stream];
      if (pending.bytes) {
        const truncated = pending.bytes > Buffer.byteLength(pending.text);
        report({ stream, text: pending.text, bytes: pending.bytes, truncated });
      }
      pending.text = '';
      pending.bytes = 0;
    }
  }
}
