import Base
import ./Host.bend as Host
import ./Process.bend as Process
import ./Json.bend as Json
import ./Streams.bend as Streams

# Acceptance ledger: native self-spawn and detached lease; private bounded store;
# running/terminal/wait/stop idempotency; literal argv; live bounded replay; UTF-8
# boundaries; timeout and owned-group cleanup; no JS runtime. See jobs.test.ts.
# Policy bounds: 1024 stored jobs/root, 64 events/job, 2048 bytes/read,
# 1 MiB first-byte spool/stream, Process's final 32 KiB tail/stream, 1h deadline.
# Observations coalesce to the latest 2048 currently available bytes/stream/tick;
# omittedBytes discloses skips, sequence gaps disclose replay eviction, and
# process.spool_limit discloses reaching the first-byte cap (possibly clipped).
# No protocol-line monitor/filter API or semantic task-completion claims.
type Ring is Data:
  Ring{next: U32, newest: List<&2, String>}

def event(ring: Ring, kind: String, data: String) -> Ring:
  match ring:
    case Ring{+next, newest}:
      Ring{U32.inc(next), Con{"{\"sequence\":" ++ U32.show(next) ++ ",\"type\":" ++ Json.quote(kind) ++ ",\"data\":" ++ data ++ "}", List.take(&2, String, newest, 63n)}}

def lines(items: List<&2, String>) -> String:
  match items:
    case Nil{}:
      ""
    case Con{line, rest}:
      line ++ "\n" ++ lines(rest)

def save(id: String, ring: Ring) -> IO(Unit):
  match ring:
    case Ring{next, newest}:
      Host.write(id, "events.jsonl", lines(List.reverse(&2, String, newest)))

def output(ring: Ring, stream: String, offset: U32, count: U32, omitted: U32, text: String, changed: Bool) -> Ring:
  match changed:
    case False{}:
      ring
    case True{}:
      event(ring, "process.output", "{\"stream\":" ++ Json.quote(stream) ++ ",\"offset\":" ++ U32.show(offset) ++ ",\"bytes\":" ++ U32.show(count) ++ ",\"omittedBytes\":" ++ U32.show(omitted) ++ ",\"text\":" ++ Json.quote(text) ++ "}")

def with_id(id: String, receipt: String) -> String:
  match receipt:
    case SCon{head, tail}:
      "{\"id\":" ++ Json.quote(id) ++ ",\"spoolLimitBytes\":1048576," ++ tail
    case SNil{}:
      "{}"

def failed(id: String, message: String) -> String:
  with_id(id, "{\"schemaVersion\":1,\"state\":\"failed\",\"exitCode\":null,\"error\":" ++ Json.quote(message) ++ "}")

def running(id: String) -> String:
  "{\"schemaVersion\":1,\"id\":" ++ Json.quote(id) ++ ",\"state\":\"running\",\"spoolLimitBytes\":1048576}"

def failure_result(id: String, stopped: String) -> String:
  match stopped:
    case SNil{}:
      failed(id, "command launch failed")
    case SCon{head, tail}:
      with_id(id, Process.show(Process.Report{143, False{}, True{}, False{}, False{}, "", ""}))

def record_result(+id: String, result: Result<&1, &1, U32 & String, Process.Raw>) -> IO(Unit):
  match result:
    case Done{raw}:
      Host.write(id, "result.json", with_id(id, Process.show(Process.decode(raw))))
    case Fail{error}:
      do IO<Unit>:
        stopped : String <- Host.read(id, "stop", 16)
        Host.write(id, "result.json", failure_result(id, stopped))

def execute(+id: String, argv: List<String>, timeout: U32, out: File, err: File) -> IO(Unit):
  do IO<Unit>:
    result : Result<&1, &1, U32 & String, Process.Raw> <- Process.Native.exec_logged(argv, timeout, out, err)
    record_result(id, result)

type Cursor is Type:
  Cursor{file: File, offset: U32, decoder: Streams.Decoder}

type Chunk is Type:
  Chunk{cursor: Cursor, text: String, count: U32, offset: U32, omitted: U32}

def read_decoded(file: File, +offset: U32, +count: U32, omitted: U32, decoded: Streams.Decoder & String) -> Chunk:
  (decoder, text) = decoded
  Chunk{Cursor{file, U32.add(offset, count), decoder}, text, count, offset, omitted}

def read_result(offset: U32, omitted: U32, decoder: Streams.Decoder, pair: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(Chunk):
  (file, result) = pair
  do IO<Chunk>:
    +bytes : List<&2, U32> <- IO.pass(List<&2, U32>, result)
    count : U32 = U32.from_nat(List.length(&2, U32, bytes))
    return read_decoded(file, offset, count, omitted, Streams.take(Streams.feed(bytes, decoder)))

def reset(decoder: Streams.Decoder, skipped: Bool) -> Streams.Decoder:
  match skipped:
    case True{}:
      Streams.empty()
    case False{}:
      decoder

def read_sized(+previous: U32, decoder: Streams.Decoder, pair: File & Result<&1, &1, U32 & String, U32>) -> IO(Chunk):
  (file, result) = pair
  do IO<Chunk>:
    +size : U32 <- IO.pass(U32, result)
    +bounded : U32 = Bool.pick(U32, U32.is_gt(size, 1048576), 1048576, size)
    +tail : U32 = Bool.pick(U32, U32.is_gt(bounded, 2048), U32.sub(bounded, 2048), 0)
    +offset : U32 = Bool.pick(U32, U32.is_gt(tail, previous), tail, previous)
    +omitted : U32 = U32.sub(offset, previous)
    pair : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_at(file, offset, 2048)
    read_result(offset, omitted, reset(decoder, U32.is_ne(omitted, 0)), pair)

def read(cursor: Cursor) -> IO(Chunk):
  match cursor:
    case Cursor{file, offset, decoder}:
      do IO<Chunk>:
        pair : File & Result<&1, &1, U32 & String, U32> <- File.size(file)
        read_sized(offset, decoder, pair)

def spool_limit(ring: Ring, stream: String, reached: Bool) -> Ring:
  match reached:
    case False{}:
      ring
    case True{}:
      event(ring, "process.spool_limit", "{\"stream\":" ++ Json.quote(stream) ++ ",\"limitBytes\":1048576,\"mayBeTruncated\":true}")

def observed(ring: Ring, +stream: String, chunk: Chunk) -> Cursor & (Ring & U32):
  match chunk:
    case Chunk{cursor, text, +count, +offset, omitted}:
      ring = output(ring, stream, offset, count, omitted, text, U32.is_ne(count, 0))
      (cursor, (spool_limit(ring, stream, U32.is_ne(count, 0) && U32.is_ge(U32.add(offset, count), 1048576)), count))

def observe(cursor: Cursor, ring: Ring, stream: String) -> IO(Cursor & (Ring & U32)):
  do IO<Cursor & (Ring & U32)>:
    chunk : Chunk <- read(cursor)
    return observed(ring, stream, chunk)

def close(cursor: Cursor, ring: Ring, stream: String) -> IO(Ring):
  match cursor:
    case Cursor{file, offset, decoder}:
      do IO<Ring>:
        File.close(file)
        +text : String = Streams.finish(decoder)
        return output(ring, stream, offset, 0, 0, text, Bool.not(String.eq(text, "")))

def cancel(stopped: String) -> IO(Unit):
  match stopped:
    case SNil{}:
      IO.pure(Unit, Unit{})
    case SCon{head, tail}:
      Process.cancel(15)

def persist_changed(id: String, ring: Ring, changed: Bool) -> IO(Unit):
  match changed:
    case True{}:
      save(id, ring)
    case False{}:
      IO.pure(Unit, Unit{})

def pause(terminal: Bool) -> IO(Unit):
  match terminal:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.sleep(25)

def terminal(+id: String, +receipt: String, out: Cursor, err: Cursor, ring: Ring) -> IO(Unit):
  do IO<Unit>:
    ring : Ring <- close(out, ring, "stdout")
    ring : Ring <- close(err, ring, "stderr")
    # Publish terminal last: once visible, the event snapshot is final too.
    save(id, event(ring, "job.finished", "{\"receiptAvailable\":true}"))
    Host.write(id, "receipt.json", receipt)

type Turn is Type:
  Again{out: Cursor, err: Cursor, ring: Ring}
  End{out: Cursor, err: Cursor, ring: Ring, receipt: String}

def turn(out: Cursor, err: Cursor, ring: Ring, receipt: String, done: Bool) -> Turn:
  match done:
    case True{}:
      End{out, err, ring, receipt}
    case False{}:
      Again{out, err, ring}

def tick_finish(id: String, +receipt: String, out: Cursor, out_count: U32, pair: Cursor & (Ring & U32)) -> IO(Turn):
  (err, payload) = pair
  (ring, err_count) = payload
  +ring = {ring : Ring}
  +done = Bool.not(String.eq(receipt, ""))
  +changed = U32.is_ne(out_count, 0) || U32.is_ne(err_count, 0)
  do IO<Turn>:
    persist_changed(id, ring, changed)
    pause(done)
    return turn(out, err, ring, receipt, done && Bool.not(changed))

def tick_err(id: String, receipt: String, err: Cursor, pair: Cursor & (Ring & U32)) -> IO(Turn):
  (out, (ring, out_count)) = pair
  do IO<Turn>:
    pair : Cursor & (Ring & U32) <- observe(err, ring, "stderr")
    tick_finish(id, receipt, out, out_count, pair)

def tick(+id: String, out: Cursor, err: Cursor, ring: Ring) -> IO(Turn):
  do IO<Turn>:
    stopped : String <- Host.read(id, "stop", 16)
    cancel(stopped)
    receipt : String <- Host.read(id, "result.json", 1048576)
    pair : Cursor & (Ring & U32) <- observe(out, ring, "stdout")
    tick_err(id, receipt, err, pair)

def control(fuel: Nat, +id: String, turn: Turn) -> IO(Unit):
  match fuel turn:
    case fuel End{out, err, ring, receipt}:
      terminal(id, receipt, out, err, ring)
    case 0n Again{out, err, ring}:
      do IO<Unit>:
        Process.cancel(15)
        ring : Ring <- close(out, ring, "stdout")
        ring : Ring <- close(err, ring, "stderr")
        IO.die(Unit, 1, "job controller fuel exhausted")
    case 1n+rest Again{out, err, ring}:
      do IO<Unit>:
        next : Turn <- tick(id, out, err, ring)
        control(rest, id, next)

def worker_run(+id: String, argv: List<String>, +timeout: U32) -> IO(Unit):
  do IO<Unit>:
    out : File <- Host.spool(id, "stdout.bin", True{})
    err : File <- Host.spool(id, "stderr.bin", True{})
    out_read : File <- Host.spool(id, "stdout.bin", False{})
    err_read : File <- Host.spool(id, "stderr.bin", False{})
    +ring : Ring = event(Ring{1, Nil{}}, "job.started", "{\"id\":" ++ Json.quote(id) ++ "}")
    save(id, ring)
    Host.write(id, "ready", "ready")
    work : Chan(Unit) <- IO.fork(Unit, execute(id, argv, timeout, out, err))
    control(U32.to_nat(U32.add(U32.div(timeout, 25), 4096)), id, Again{Cursor{out_read, 0, Streams.empty()}, Cursor{err_read, 0, Streams.empty()}, ring})
    IO.join(Unit, work)

def worker_fresh(id: String, argv: List<String>, timeout: U32, fresh: Bool) -> IO(Unit):
  match fresh:
    case True{}:
      worker_run(id, argv, timeout)
    case False{}:
      IO.die(Unit, 1, "job already started or terminal")

def worker(+id: String, argv: List<String>, timeout: U32) -> IO(Unit):
  do IO<Unit>:
    Host.claim(id)
    ready : String <- Host.read(id, "ready", 16)
    receipt : String <- Host.read(id, "receipt.json", 1048576)
    worker_fresh(id, argv, timeout, String.eq(ready, "") && String.eq(receipt, ""))

# Lease probing never sends a signal. Re-read after a dead lease to avoid
# overwriting a receipt published between the first read and the probe.
def recover(+id: String, receipt: String) -> IO(String):
  match receipt:
    case SNil{}:
      do IO<String>:
        +receipt : String = failed(id, "worker exited without a terminal receipt")
        Host.write(id, "receipt.json", receipt)
        return receipt
    case SCon{head, tail}:
      IO.pure(String, SCon{head, tail})

def liveness(+id: String, alive: Bool) -> IO(String):
  match alive:
    case True{}:
      IO.pure(String, "")
    case False{}:
      do IO<String>:
        receipt : String <- Host.read(id, "receipt.json", 1048576)
        recover(id, receipt)

def receipt(+id: String, current: String) -> IO(String):
  match current:
    case SNil{}:
      do IO<String>:
        alive : Bool <- Host.alive(id)
        liveness(id, alive)
    case SCon{head, tail}:
      IO.pure(String, SCon{head, tail})

def status_read(+id: String) -> IO(String):
  do IO<String>:
    current : String <- Host.read(id, "receipt.json", 1048576)
    receipt(id, current)

def show_status(id: String, text: String) -> IO(Unit):
  match text:
    case SNil{}:
      IO.print(running(id))
    case SCon{head, tail}:
      IO.print(SCon{head, tail})

def wait_loop(fuel: Nat, +id: String, text: String) -> IO(Unit):
  match fuel text:
    case fuel SCon{head, tail}:
      IO.print(SCon{head, tail})
    case 0n SNil{}:
      IO.print(running(id))
    case 1n+rest SNil{}:
      do IO<Unit>:
        IO.sleep(25)
        text : String <- status_read(id)
        wait_loop(rest, id, text)

def wait(fuel: Nat, +id: String) -> IO(Unit):
  do IO<Unit>:
    text : String <- status_read(id)
    wait_loop(fuel, id, text)

def stop_current(+id: String, text: String) -> IO(Unit):
  match text:
    case SNil{}:
      do IO<Unit>:
        Host.write(id, "stop", "stop")
        wait(80n, id)
    case SCon{head, tail}:
      IO.print(SCon{head, tail})

def ready(fuel: Nat, +id: String, text: String) -> IO(Unit):
  match fuel text:
    case fuel SCon{head, tail}:
      IO.print("{\"id\":" ++ Json.quote(id) ++ "}")
    case 0n SNil{}:
      do IO<Unit>:
        Host.write(id, "stop", "stop")
        IO.die(Unit, 1, "native job did not become ready")
    case 1n+rest SNil{}:
      do IO<Unit>:
        IO.sleep(25)
        text : String <- Host.read(id, "ready", 16)
        ready(rest, id, text)

def spawned(+id: String, result: Result<&1, &1, U32 & String, String>) -> IO(Unit):
  match result:
    case Fail{error}:
      do IO<Unit>:
        Host.write(id, "receipt.json", failed(id, "worker launch failed"))
        IO.die(Unit, 1, "native worker launch failed")
    case Done{ignored}:
      ready(200n, id, "")

def start(argv: List<String>, +timeout: U32) -> IO(Unit):
  do IO<Unit>:
    self : String <- Host.self()
    +id : String <- Host.create(1024)
    result : Result<&1, &1, U32 & String, String> <- Host.spawn(Con{self, Con{"--", Con{"__job-worker", Con{id, Con{U32.show(timeout), argv}}}}})
    spawned(id, result)

def first(items: List<&2, String>) -> String:
  match items:
    case Nil{}:
      ""
    case Con{head, tail}:
      head

def replay_keep(line: String, keep: Bool) -> IO(Unit):
  match keep:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      IO.print(line)

def replay_line(line: String, after: U32, sequence: Maybe<&2, U32>) -> IO(Unit):
  match sequence:
    case None{}:
      IO.pure(Unit, Unit{})
    case Some{number}:
      replay_keep(line, U32.is_gt(number, after))

def replay(items: List<&2, String>, +after: U32) -> IO(Unit):
  match items:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{+line, rest}:
      do IO<Unit>:
        replay_line(line, after, U32.read(String.drop(first(String.split(line, ',')), 12n)))
        replay(rest, after)

def events(id: String, after: U32) -> IO(Unit):
  do IO<Unit>:
    text : String <- Host.read(id, "events.jsonl", 1048576)
    replay(String.split(text, '\n'), after)

def event_after(id: String, after: Maybe<&2, U32>) -> IO(Unit):
  match after:
    case None{}:
      IO.die(Unit, 2, "after-sequence must be a U32")
    case Some{number}:
      events(id, number)

def timed_action(action: String, id: String, argv: List<String>, ms: U32) -> IO(Unit):
  match action:
    case "start":
      start(argv, ms)
    case "__job-worker":
      worker(id, argv, ms)
    case other:
      wait(U32.to_nat(U32.div(U32.add(ms, 24), 25)), id)

def timed(action: String, id: String, argv: List<String>, ms: U32, valid: Bool) -> IO(Unit):
  match valid:
    case False{}:
      IO.die(Unit, 2, "timeout must be 1..3600000 milliseconds")
    case True{}:
      timed_action(action, id, argv, ms)

def timeout(action: String, id: String, argv: List<String>, parsed: Maybe<&2, U32>) -> IO(Unit):
  match parsed:
    case None{}:
      IO.die(Unit, 2, "timeout must be 1..3600000 milliseconds")
    case Some{+ms}:
      timed(action, id, argv, ms, U32.is_ge(ms, 1) && U32.is_le(ms, 3600000))

# Public dispatcher; main forwards these complete argument lists unchanged.
def command(args: List<String>) -> IO(Unit):
  match args:
    case Con{"start", Con{ms, Con{command, rest}}}:
      timeout("start", "", Con{command, rest}, U32.read(ms))
    case Con{"__job-worker", Con{id, Con{ms, Con{command, rest}}}}:
      timeout("__job-worker", id, Con{command, rest}, U32.read(ms))
    case Con{"status", Con{+id, Nil{}}}:
      do IO<Unit>:
        text : String <- status_read(id)
        show_status(id, text)
    case Con{"wait", Con{id, Con{ms, Nil{}}}}:
      timeout("wait", id, Nil{}, U32.read(ms))
    case Con{"stop", Con{+id, Nil{}}}:
      do IO<Unit>:
        text : String <- status_read(id)
        stop_current(id, text)
    case Con{"events", Con{id, Nil{}}}:
      events(id, 0)
    case Con{"events", Con{id, Con{after, Nil{}}}}:
      event_after(id, U32.read(after))
    case other:
      IO.die(Unit, 2, "usage: start <timeout-ms> <command> [args...] | status <id> | events <id> [after-sequence] | wait <id> <wait-timeout-ms> | stop <id>")
