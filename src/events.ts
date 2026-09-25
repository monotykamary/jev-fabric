import type { FabricEvent, Json } from './types.js';
import { asJson, integer } from './util.js';

const MAX_QUEUE_CAPACITY = 4096;
const MAX_EVENT_CAPACITY = 1024;
const MAX_EVENT_TYPE_LENGTH = 80;
const MAX_EVENT_DATA_BYTES = 4096;
const MAX_SUBSCRIBERS = 16;

/** Bounded, loss-intolerant subscriber. Overflow fails rather than silently corrupting a protocol. */
export class Queue<T> implements AsyncIterableIterator<T> {
  private values: T[] = [];
  private pending: { resolve: (value: IteratorResult<T>) => void; reject: (error: Error) => void } | undefined;
  private ended = false;
  private error: Error | undefined;
  constructor(readonly capacity = 128, private readonly cleanup: () => void = () => {}) {
    integer(capacity, 'queue capacity', 1, MAX_QUEUE_CAPACITY);
  }
  push(value: T): void {
    if (this.ended) return;
    if (this.pending) {
      const waiter = this.pending;
      this.pending = undefined;
      waiter.resolve({ value, done: false });
    } else if (this.values.length >= this.capacity) {
      this.fail(new Error('Subscriber queue overflow; resubscribe from fresh evidence'));
    } else {
      this.values.push(value);
    }
  }
  fail(error: Error): void {
    this.error = error;
    this.values = [];
    this.close();
  }
  close(): void {
    if (this.ended) return;
    this.ended = true;
    this.cleanup();
    if (this.pending) {
      const waiter = this.pending;
      this.pending = undefined;
      if (this.error) waiter.reject(this.error);
      else waiter.resolve({ value: undefined, done: true });
    }
  }
  next(): Promise<IteratorResult<T>> {
    if (this.error) return Promise.reject(this.error);
    if (this.values.length) return Promise.resolve({ value: this.values.shift()!, done: false });
    if (this.ended) return Promise.resolve({ value: undefined, done: true });
    if (this.pending) return Promise.reject(new Error('Only one pending next() per subscription'));
    return new Promise((resolve, reject) => {
      this.pending = { resolve, reject };
    });
  }
  async return(): Promise<IteratorResult<T>> {
    this.values = [];
    this.close();
    return { value: undefined, done: true };
  }
  [Symbol.asyncIterator](): AsyncIterableIterator<T> { return this; }
}

export class EventBus {
  private sequence = 0;
  private history: FabricEvent[] = [];
  private subscribers = new Set<Queue<FabricEvent>>();
  private closed = false;
  constructor(readonly capacity = 128, private readonly onEvent?: (event: FabricEvent) => void) {
    integer(capacity, 'event capacity', 1, MAX_EVENT_CAPACITY);
  }
  emit(type: string, data: Json = null): FabricEvent {
    if (this.closed) throw new Error('Event stream is closed');
    if (!type || type.length > MAX_EVENT_TYPE_LENGTH) throw new Error('Event type must be 1..80 characters');
    const event = {
      sequence: ++this.sequence,
      at: new Date().toISOString(),
      type,
      data: asJson(data, MAX_EVENT_DATA_BYTES),
    };
    this.history.push(event);
    if (this.history.length > this.capacity) this.history.shift();
    for (const queue of this.subscribers) queue.push(event);
    this.onEvent?.(event);
    return event;
  }
  snapshot() {
    return {
      firstSequence: this.history[0]?.sequence ?? this.sequence + 1,
      nextSequence: this.sequence + 1,
      events: [...this.history],
    };
  }
  subscribe(after = 0): Queue<FabricEvent> {
    integer(after, 'event cursor', 0, Number.MAX_SAFE_INTEGER);
    if (this.subscribers.size >= MAX_SUBSCRIBERS) throw new Error('Subscriber limit reached');
    const queue = new Queue<FabricEvent>(this.capacity + 1, () => this.subscribers.delete(queue));
    const snapshot = this.snapshot();
    const lastOmitted = snapshot.firstSequence - 1;
    if (after < lastOmitted) {
      queue.push({
        sequence: lastOmitted,
        at: new Date().toISOString(),
        type: 'stream.gap',
        data: { omitted: lastOmitted - after },
      });
    }
    for (const event of this.history) if (event.sequence > after) queue.push(event);
    if (this.closed) queue.close();
    else this.subscribers.add(queue);
    return queue;
  }
  close(): void {
    this.closed = true;
    for (const queue of this.subscribers) queue.close();
    this.subscribers.clear();
  }
}
