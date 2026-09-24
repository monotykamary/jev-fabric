import { StringDecoder } from 'node:string_decoder';
import { integer } from './util.js';

export interface MonitorOptions { match?: string; intervalMs?: number; lifetimeMs?: number }
export interface MonitorBatch { lines: string[]; omitted: number }

export class LineFramer {
  private decoder = new StringDecoder('utf8');
  private line = '';
  private truncated = false;
  constructor(private readonly emit: (line: string, truncated: boolean) => void, readonly maxBytes = 2048) {}
  append(data: Buffer): void { this.accept(this.decoder.write(data)); }
  private accept(text: string): void {
    const parts = text.split('\n');
    for (let i = 0; i < parts.length; i++) {
      if (!this.truncated) {
        const next = this.line + parts[i]!;
        if (Buffer.byteLength(next) > this.maxBytes) {
          this.line = Buffer.from(next).subarray(0, this.maxBytes).toString('utf8');
          while (Buffer.byteLength(this.line) > this.maxBytes) this.line = this.line.slice(0, -1);
          this.truncated = true;
        } else this.line = next;
      }
      if (i < parts.length - 1) this.flush();
    }
  }
  private flush(): void { this.emit(this.line.replace(/\r$/, ''), this.truncated); this.line = ''; this.truncated = false; }
  close(): void { this.accept(this.decoder.end()); if (this.line || this.truncated) this.flush(); }
}

/** Filtering is deterministic; intervalMs is delivery cadence, not a polling interval. */
export class Monitor {
  private previous: string | undefined;
  private lines: string[] = [];
  private omitted = 0;
  private timer: ReturnType<typeof setTimeout> | undefined;
  readonly framer: LineFramer;
  constructor(readonly options: MonitorOptions, private readonly emit: (batch: MonitorBatch) => void) {
    integer(options.intervalMs ?? 250, 'monitor interval', 10, 60000);
    integer(options.lifetimeMs ?? 300000, 'monitor lifetime', 1, 1800000);
    if (options.match !== undefined && (!options.match || options.match.length > 256)) throw new Error('Monitor match must be a 1..256 character literal');
    this.framer = new LineFramer((line, truncated) => {
      line = line.replace(/[\u0000-\u001f\u007f-\u009f]/g, ' ').trim();
      if (!line || (options.match && !line.includes(options.match)) || line === this.previous) return;
      this.previous = line;
      if (this.lines.length === 8) { this.lines.shift(); this.omitted++; }
      this.lines.push(line.slice(0, 100) + (truncated || line.length > 100 ? ' [truncated]' : ''));
      if (!this.timer) this.timer = setTimeout(() => this.flush(), options.intervalMs ?? 250);
    });
  }
  private flush(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = undefined;
    if (this.lines.length) this.emit({ lines: this.lines, omitted: this.omitted });
    this.lines = []; this.omitted = 0;
  }
  close(): void { this.framer.close(); this.flush(); }
}
