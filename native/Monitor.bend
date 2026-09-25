import Base
import ./Core.bend as Core
import ./Codec.bend as Codec
import ./Json.bend as Json
import ./Host.bend as Host
import ./vendor/strict-json/json.bend as J

# Bounded native watch. Pure framing/filter/dedup/batch policy is reusable; the
# watch <id> <duration-ms> <literal> producer reads live native job events
# until the job terminal receipt or its own deadline. Observations are lossy and
# sequence-cursored, never semantic task completion. No Jev calls or notifiers.
#
# Limits: 4096 UTF-8 chars/partial line, 32 lines/batch, 1024 emitted lines/stream (2048 maximum),
# 1..300000 ms watch, 1..256 char literal, 1 MiB events snapshot per poll.
# Sequence gaps (ring eviction) and omittedBytes reset affected partial lines
# and emit an explicit monitor.loss record before continuing.

type Line is Data:
  Line{text: String, clipped: Bool}

type Frame is Data:
  Frame{partial: String, clipped: Bool}

type Pending is Data:
  Pending{lines: List<&2, Line>, omitted: Nat, clipped: Nat}

type Channel is Data:
  Channel{frame: Frame, pending: Pending, previous: String, from: U32, to: U32, emitted: Nat, batches: Nat}

type Model is Data:
  Model{last: U32, out: Channel, err: Channel, losses: Nat, finished: Bool}

type Reading is Data:
  Reading{sequence: U32, kind: String, data: J.JSON}

type Framed is Data:
  Framed{frame: Frame, lines: List<&2, Line>}

type Produced is Data:
  Produced{channel: Channel, outs: List<&2, String>}

type Step is Data:
  Step{model: Model, outs: List<&2, String>}

type Summary is Data:
  Summary{model: Model, finished: Bool, lines: Nat, batches: Nat}

def framed_frame(value: Framed) -> Frame:
  match value:
    case Framed{frame, lines}:
      frame

def framed_lines(value: Framed) -> List<&2, Line>:
  match value:
    case Framed{frame, lines}:
      lines

def produced_channel(value: Produced) -> Channel:
  match value:
    case Produced{channel, outs}:
      channel

def produced_outs(value: Produced) -> List<&2, String>:
  match value:
    case Produced{channel, outs}:
      outs

def step_model(value: Step) -> Model:
  match value:
    case Step{model, outs}:
      model

def step_outs(value: Step) -> List<&2, String>:
  match value:
    case Step{model, outs}:
      outs

def nat_fst(pair: Nat & Nat) -> Nat:
  (a, b) = pair
  a

def nat_snd(pair: Nat & Nat) -> Nat:
  (a, b) = pair
  b

def line_max() -> Nat:
  4096n

def batch_max() -> Nat:
  32n

def total_max() -> Nat:
  1024n

def empty_channel() -> Channel:
  Channel{Frame{"", False{}}, Pending{Nil{}, 0n, 0n}, "", 0, 0, 0n, 0n}

def initial_model() -> Model:
  Model{0, empty_channel(), empty_channel(), 0n, False{}}

def fit(+text: String, +addition: String, max: Nat, fits: Bool) -> Line:
  match fits:
    case True{}:
      Line{String.concat([text, addition]), False{}}
    case False{}:
      Line{String.concat([text, String.take(addition, Nat.sub(max, String.length(text)))]), True{}}

def bounded(+text: String, clipped: Bool, +addition: String, +max: Nat) -> Line:
  match clipped:
    case True{}:
      Line{text, True{}}
    case False{}:
      fit(text, addition, max, Nat.is_le(Nat.add(String.length(text), String.length(addition)), max))

def frame_of(line: Line) -> Frame:
  match line:
    case Line{text, clipped}:
      Frame{text, clipped}

def framed(parts: List<&2, String>, frame: Frame, +max: Nat) -> Framed:
  match parts:
    case Nil{}:
      Framed{frame, Nil{}}
    case Con{+part, Nil{}}:
      match frame:
        case Frame{partial, clipped}:
          Framed{frame_of(bounded(partial, clipped, part, max)), Nil{}}
    case Con{+part, +rest}:
      match frame:
        case Frame{partial, clipped}:
          +line = bounded(partial, clipped, part, max)
          +built = framed(rest, Frame{"", False{}}, max)
          Framed{framed_frame(built), Con{line, framed_lines(built)}}

def frame_chunk(frame: Frame, +text: String, loss: Bool, max: Nat) -> Framed:
  match loss:
    case True{}:
      framed(String.split(text, '\n'), Frame{"", False{}}, max)
    case False{}:
      framed(String.split(text, '\n'), frame, max)

def line_json(line: Line) -> String:
  match line:
    case Line{text, clipped}:
      "{\"text\":" ++ Json.quote(text) ++ ",\"clipped\":" ++ Json.boolean(clipped) ++ "}"

def rest_json(lines: List<&2, Line>) -> String:
  match lines:
    case Nil{}:
      ""
    case Con{+head, +tail}:
      "," ++ line_json(head) ++ rest_json(tail)

def lines_json(lines: List<&2, Line>) -> String:
  match lines:
    case Nil{}:
      "[]"
    case Con{+head, +tail}:
      "[" ++ line_json(head) ++ rest_json(tail) ++ "]"

def batch_json(stream: String, from: U32, to: U32, omitted: Nat, clipped: Nat, lines: List<&2, Line>) -> String:
  "{\"type\":\"monitor.batch\",\"stream\":" ++ Json.quote(stream) ++ ",\"first\":" ++ U32.show(from) ++ ",\"last\":" ++ U32.show(to) ++ ",\"omitted\":" ++ Nat.show(omitted) ++ ",\"clipped\":" ++ Nat.show(clipped) ++ ",\"lines\":" ++ lines_json(lines) ++ "}"

def loss_json(stream: String, reason: String, count: U32) -> String:
  "{\"type\":\"monitor.loss\",\"stream\":" ++ Json.quote(stream) ++ ",\"reason\":" ++ Json.quote(reason) ++ ",\"count\":" ++ U32.show(count) ++ "}"

def flush(stream: String, channel: Channel) -> Produced:
  match channel:
    case Channel{frame, Pending{lines, omitted, clipped}, previous, from, to, emitted, batches}:
      match lines:
        case Nil{}:
          Produced{Channel{frame, Pending{Nil{}, omitted, clipped}, previous, from, to, emitted, batches}, Nil{}}
        case some:
          Produced{Channel{frame, Pending{Nil{}, 0n, 0n}, previous, 0, 0, emitted, Nat.add(batches, 1n)},
            Con{batch_json(stream, from, to, omitted, clipped, List.reverse(&2, Line, some)), Nil{}}}

def finish_push(stream: String, channel: Channel, full: Bool) -> Produced:
  match full:
    case True{}:
      flush(stream, channel)
    case False{}:
      Produced{channel, Nil{}}

def limited_match(text: String, literal: String, previous: String, allowed: Bool) -> Maybe<&2, String>:
  match allowed:
    case True{}:
      Core.monitor(text, literal, previous)
    case False{}:
      None{}

def accepted(stream: String, frame: Frame, lines: List<&2, Line>, omitted: Nat, clipped_count: Nat, previous: String, +from: U32, to: U32, +emitted: Nat, batches: Nat, +clipped: Bool, +sequence: U32, batch: Nat, hit: Maybe<&2, String>) -> Produced:
  match hit:
    case None{}:
      Produced{Channel{frame, Pending{lines, omitted, clipped_count}, previous, from, to, emitted, batches}, Nil{}}
    case Some{+kept}:
      +next = {Con{Line{kept, clipped}, lines} : List<&2, Line>}
      +c = Nat.add(clipped_count, Core.bit(clipped))
      +f = Bool.pick(U32, U32.is_zero(from), sequence, from)
      +count = List.length(&2, Line, next)
      +more : Channel = Channel{frame, Pending{next, omitted, c}, kept, f, sequence, Nat.add(emitted, 1n), batches}
      finish_push(stream, more, Nat.is_ge(count, batch))

def push(stream: String, channel: Channel, line: Line, sequence: U32, literal: String, batch: Nat) -> Produced:
  match channel:
    case Channel{frame, Pending{lines, omitted, clipped_count}, +previous, +from, to, +emitted, batches}:
      match line:
        case Line{text, +clipped}:
          accepted(stream, frame, lines, omitted, clipped_count, previous, from, to, emitted, batches, clipped, sequence, batch, limited_match(text, literal, previous, Nat.is_lt(emitted, total_max())))

def channel_count(channel: Channel) -> Nat:
  match channel:
    case Channel{frame, pending, previous, from, to, emitted, batches}:
      emitted

def concat(a: List<&2, String>, b: List<&2, String>) -> List<&2, String>:
  match a:
    case Nil{}:
      b
    case Con{+head, +tail}:
      Con{head, concat(tail, b)}

def push_all(lines: List<&2, Line>, +stream: String, channel: Channel, +sequence: U32, +literal: String, +batch: Nat) -> Produced:
  match lines:
    case Nil{}:
      Produced{channel, Nil{}}
    case Con{+line, +rest}:
      +first = push(stream, channel, line, sequence, literal, batch)
      +next = push_all(rest, stream, produced_channel(first), sequence, literal, batch)
      Produced{produced_channel(next), concat(produced_outs(first), produced_outs(next))}

def feed(stream: String, channel: Channel, text: String, sequence: U32, literal: String, batch: Nat, loss: Bool) -> Produced:
  match channel:
    case Channel{frame, pending, previous, from, to, emitted, batches}:
      +split = frame_chunk(frame, text, loss, line_max())
      push_all(framed_lines(split), stream, Channel{framed_frame(split), pending, previous, from, to, emitted, batches}, sequence, literal, batch)

def reset_frame(channel: Channel) -> Channel:
  match channel:
    case Channel{frame, pending, previous, from, to, emitted, batches}:
      Channel{Frame{"", False{}}, pending, previous, from, to, emitted, batches}

def mark(model: Model) -> Model:
  match model:
    case Model{last, out, err, losses, finished}:
      Model{last, out, err, losses, True{}}

def add_loss(model: Model) -> Model:
  match model:
    case Model{last, out, err, losses, finished}:
      Model{last, out, err, Nat.add(losses, 1n), finished}

def parse_u32(parsed: Maybe<&2, U32>) -> U32:
  match parsed:
    case Some{+n}:
      n
    case None{}:
      0

def num(value: J.JSON) -> U32:
  match value:
    case J.Num{lex}:
      parse_u32(U32.read(lex))
    case other:
      0

def pick_num(found: Maybe<&2, J.JSON>) -> U32:
  match found:
    case Some{+value}:
      num(value)
    case None{}:
      0

def number_field(record: J.JSON, key: String) -> U32:
  pick_num(Codec.field(record, key))

def pick_str(found: Maybe<&2, String>) -> String:
  match found:
    case Some{+s}:
      s
    case None{}:
      ""

def pick_text(found: Maybe<&2, J.JSON>) -> String:
  match found:
    case Some{+value}:
      pick_str(Codec.text(value))
    case None{}:
      ""

def text_field(record: J.JSON, key: String) -> String:
  pick_text(Codec.field(record, key))

def pick_json(found: Maybe<&2, J.JSON>) -> J.JSON:
  match found:
    case Some{+value}:
      value
    case None{}:
      J.Null{}

def field_or_null(record: J.JSON, key: String) -> J.JSON:
  pick_json(Codec.field(record, key))

def parsed_event(parsed: Result<&1, &1, U32 & String, J.JSON>) -> Maybe<&2, Reading>:
  match parsed:
    case Fail{error}:
      None{}
    case Done{+value}:
      Some{Reading{number_field(value, "sequence"), text_field(value, "type"), field_or_null(value, "data")}}

def read_event(line: String) -> Maybe<&2, Reading>:
  parsed_event(Codec.read(line))

@unsafe
def clean_feed(+is_err: Bool, +last: U32, +out: Channel, +err: Channel, +losses: Nat, +finished: Bool, +text: String, +rest: List<&2, String>, +literal: String, +batch: Nat) -> Step:
  match is_err:
    case True{}:
      +r = feed("stderr", err, text, last, literal, batch, False{})
      +c = consume(rest, Model{last, out, produced_channel(r), losses, finished}, literal, batch)
      Step{step_model(c), concat(produced_outs(r), step_outs(c))}
    case False{}:
      +r = feed("stdout", out, text, last, literal, batch, False{})
      +c = consume(rest, Model{last, produced_channel(r), err, losses, finished}, literal, batch)
      Step{step_model(c), concat(produced_outs(r), step_outs(c))}

@unsafe
def lossy_feed(+is_err: Bool, +last: U32, +out: Channel, +err: Channel, +losses: Nat, +finished: Bool, +text: String, +omitted: U32, +rest: List<&2, String>, +literal: String, +batch: Nat) -> Step:
  match is_err:
    case True{}:
      +r = feed("stderr", err, text, last, literal, batch, True{})
      +c = consume(rest, Model{last, out, produced_channel(r), Nat.add(losses, 1n), finished}, literal, batch)
      Step{step_model(c), concat(Con{loss_json("stderr", "omitted-bytes", omitted), produced_outs(r)}, step_outs(c))}
    case False{}:
      +r = feed("stdout", out, text, last, literal, batch, True{})
      +c = consume(rest, Model{last, produced_channel(r), err, Nat.add(losses, 1n), finished}, literal, batch)
      Step{step_model(c), concat(Con{loss_json("stdout", "omitted-bytes", omitted), produced_outs(r)}, step_outs(c))}

@unsafe
def route_omitted(+is_err: Bool, +last: U32, +out: Channel, +err: Channel, +losses: Nat, +finished: Bool, +text: String, +omitted: U32, +rest: List<&2, String>, +literal: String, +batch: Nat, none_omitted: Bool) -> Step:
  match none_omitted:
    case True{}:
      clean_feed(is_err, last, out, err, losses, finished, text, rest, literal, batch)
    case False{}:
      lossy_feed(is_err, last, out, err, losses, finished, text, omitted, rest, literal, batch)

@unsafe
def output_channel(is_err: Bool, model: Model, text: String, +omitted: U32, rest: List<&2, String>, literal: String, batch: Nat) -> Step:
  match model:
    case Model{last, out, err, losses, finished}:
      route_omitted(is_err, last, out, err, losses, finished, text, omitted, rest, literal, batch, U32.is_zero(omitted))

@unsafe
def route_stream(stream: String, +model: Model, +text: String, +omitted: U32, +rest: List<&2, String>, +literal: String, +batch: Nat) -> Step:
  match stream:
    case "stderr":
      output_channel(True{}, model, text, omitted, rest, literal, batch)
    case "stdout":
      output_channel(False{}, model, text, omitted, rest, literal, batch)
    case other:
      consume(rest, model, literal, batch)

@unsafe
def dispatch_output(model: Model, +data: J.JSON, rest: List<&2, String>, literal: String, batch: Nat) -> Step:
  +stream = text_field(data, "stream")
  +text = text_field(data, "text")
  +omitted = number_field(data, "omittedBytes")
  route_stream(stream, model, text, omitted, rest, literal, batch)

@unsafe
def dispatch(+model: Model, kind: String, +data: J.JSON, +rest: List<&2, String>, +literal: String, +batch: Nat) -> Step:
  match kind:
    case "process.output":
      dispatch_output(model, data, rest, literal, batch)
    case "job.finished":
      consume(rest, mark(model), literal, batch)
    case "process.spool_limit":
      +stream = text_field(data, "stream")
      +c = consume(rest, add_loss(model), literal, batch)
      Step{step_model(c), Con{loss_json(stream, "spool-limit", 0), step_outs(c)}}
    case other:
      consume(rest, model, literal, batch)

@unsafe
def handle_gap(+sequence: U32, +last: U32, +out: Channel, +err: Channel, +losses: Nat, +finished: Bool, +kind: String, +data: J.JSON, +rest: List<&2, String>, +literal: String, +batch: Nat, gap: Bool) -> Step:
  match gap:
    case True{}:
      +skipped = U32.sub(sequence, U32.add(last, 1))
      +base : Model = Model{sequence, reset_frame(out), reset_frame(err), Nat.add(losses, 1n), finished}
      +c = dispatch(base, kind, data, rest, literal, batch)
      Step{step_model(c), Con{loss_json("*", "replay-eviction", skipped), step_outs(c)}}
    case False{}:
      dispatch(Model{sequence, out, err, losses, finished}, kind, data, rest, literal, batch)

@unsafe
def handle_fresh(+sequence: U32, +last: U32, +out: Channel, +err: Channel, +losses: Nat, +finished: Bool, +kind: String, +data: J.JSON, +rest: List<&2, String>, +literal: String, +batch: Nat, fresh: Bool) -> Step:
  match fresh:
    case False{}:
      consume(rest, Model{last, out, err, losses, finished}, literal, batch)
    case True{}:
      handle_gap(sequence, last, out, err, losses, finished, kind, data, rest, literal, batch, U32.is_gt(sequence, U32.add(last, 1)))

@unsafe
def handle(model: Model, reading: Reading, rest: List<&2, String>, literal: String, batch: Nat) -> Step:
  match model:
    case Model{+last, out, err, losses, finished}:
      match reading:
        case Reading{+sequence, kind, data}:
          handle_fresh(sequence, last, out, err, losses, finished, kind, data, rest, literal, batch, U32.is_gt(sequence, last))

@unsafe
def consume_parsed(+rest: List<&2, String>, +model: Model, +literal: String, +batch: Nat, parsed: Maybe<&2, Reading>) -> Step:
  match parsed:
    case None{}:
      +c = consume(rest, add_loss(model), literal, batch)
      Step{step_model(c), Con{loss_json("*", "invalid-event", 0), step_outs(c)}}
    case Some{reading}:
      handle(model, reading, rest, literal, batch)

@unsafe
def consume_line(line: String, +rest: List<&2, String>, +model: Model, +literal: String, +batch: Nat, empty: Bool) -> Step:
  match empty:
    case True{}:
      consume(rest, model, literal, batch)
    case False{}:
      consume_parsed(rest, model, literal, batch, read_event(line))

@unsafe
def consume(raw: List<&2, String>, +model: Model, +literal: String, +batch: Nat) -> Step:
  match raw:
    case Nil{}:
      Step{model, Nil{}}
    case Con{+line, +rest}:
      consume_line(line, rest, model, literal, batch, String.is_empty(line))

def close_partial(partial: String, clipped: Bool, empty: Bool) -> Maybe<&2, Line>:
  match empty:
    case True{}:
      None{}
    case False{}:
      Some{Line{partial, clipped}}

def close_frame(frame: Frame) -> Maybe<&2, Line>:
  match frame:
    case Frame{+partial, clipped}:
      close_partial(partial, clipped, String.is_empty(partial))

def drain_close(+stream: String, +pending: Pending, +previous: String, +from: U32, +to: U32, +emitted: Nat, +batches: Nat, +literal: String, +batch: Nat, closed: Maybe<&2, Line>) -> Produced:
  match closed:
    case None{}:
      flush(stream, Channel{Frame{"", False{}}, pending, previous, from, to, emitted, batches})
    case Some{+line}:
      +p = push(stream, Channel{Frame{"", False{}}, pending, previous, from, to, emitted, batches}, line, to, literal, batch)
      +f = flush(stream, produced_channel(p))
      Produced{produced_channel(f), concat(produced_outs(p), produced_outs(f))}

def drain_channel(stream: String, channel: Channel, literal: String, batch: Nat, terminal: Bool) -> Produced:
  match channel:
    case Channel{frame, pending, previous, from, to, emitted, batches}:
      match terminal:
        case True{}:
          drain_close(stream, pending, previous, from, to, emitted, batches, literal, batch, close_frame(frame))
        case False{}:
          flush(stream, Channel{Frame{"", False{}}, pending, previous, from, to, emitted, batches})

def drain(model: Model, +literal: String, +terminal: Bool) -> Step:
  match model:
    case Model{last, out, err, losses, finished}:
      +o = drain_channel("stdout", out, literal, batch_max(), terminal)
      +e = drain_channel("stderr", err, literal, batch_max(), terminal)
      Step{Model{last, produced_channel(o), produced_channel(e), losses, finished}, concat(produced_outs(o), produced_outs(e))}

def counts(out: Channel, err: Channel) -> Nat & Nat:
  match out:
    case Channel{frame, pending, previous, from, to, emitted, batches}:
      match err:
        case Channel{frame2, pending2, previous2, from2, to2, emitted2, batches2}:
          (Nat.add(emitted, emitted2), Nat.add(batches, batches2))

def summary_of(model: Model, finished: Bool, totals: Nat & Nat) -> Summary:
  (lines, batches) = totals
  Summary{model, finished, lines, batches}

def summarize(model: Model) -> Summary:
  match model:
    case Model{+last, +out, +err, +losses, +finished}:
      summary_of(Model{last, out, err, losses, finished}, finished, counts(out, err))

def end_json(reason: String, terminal: Bool, +lines: Nat, batches: Nat, losses: Nat, elapsed: Nat) -> String:
  "{\"type\":\"monitor.end\",\"reason\":" ++ Json.quote(reason) ++ ",\"terminal\":" ++ Json.boolean(terminal) ++ ",\"lines\":" ++ Nat.show(lines) ++ ",\"batches\":" ++ Nat.show(batches) ++ ",\"losses\":" ++ Nat.show(losses) ++ ",\"elapsedMs\":" ++ Nat.show(elapsed) ++ ",\"outputLimitReached\":" ++ Json.boolean(Nat.is_ge(lines, total_max())) ++ ",\"note\":\"matched lines are observations, not semantic completion\"}"

def print_lines(lines: List<&2, String>) -> IO(Unit):
  match lines:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{+line, +rest}:
      do IO<Unit>:
        IO.print(line)
        print_lines(rest)

def emit(step: Step) -> IO(Model):
  match step:
    case Step{model, outs}:
      do IO<Model>:
        print_lines(outs)
        return model

def emit_end(summary: Summary, reason: String, terminal: Bool, elapsed: Nat) -> IO(Unit):
  match summary:
    case Summary{model, finished, lines, batches}:
      match model:
        case Model{last, out, err, losses, finished2}:
          IO.print(end_json(reason, terminal, lines, batches, losses, elapsed))

def finalize(model: Model, literal: String, started: Nat, reason: String, +terminal: Bool) -> IO(Unit):
  do IO<Unit>:
    drained : Model <- emit(drain(model, literal, terminal))
    now : Nat <- IO.now()
    emit_end(summarize(drained), reason, terminal, Nat.sub(now, started))

def check_literal(+raw: U32, ok: Bool) -> Maybe<&2, Nat>:
  match ok:
    case False{}:
      None{}
    case True{}:
      Some{U32.to_nat(raw)}

def check_range(+raw: U32, +literal: String, in_range: Bool) -> Maybe<&2, Nat>:
  match in_range:
    case False{}:
      None{}
    case True{}:
      check_literal(raw, Bool.and(Bool.not(String.is_empty(literal)), Nat.is_le(String.length(literal), 256n)))

def parse_duration(literal: String, parsed: Maybe<&2, U32>) -> Maybe<&2, Nat>:
  match parsed:
    case None{}:
      None{}
    case Some{+raw}:
      check_range(raw, literal, Bool.and(U32.is_ge(raw, 1), U32.is_le(raw, 300000)))

def validate(ms: String, literal: String) -> Maybe<&2, Nat>:
  parse_duration(literal, U32.read(ms))

def fuel(duration: Nat) -> Nat:
  Nat.add(Nat.div(duration, 25n), 64n)

@unsafe
def branch_deadline(expired: Bool, +rest: Nat, +model3: Model, +id: String, +literal: String, +started: Nat, +duration: Nat) -> IO(Unit):
  match expired:
    case True{}:
      finalize(model3, literal, started, "deadline", False{})
    case False{}:
      do IO<Unit>:
        IO.sleep(25)
        loop(rest, model3, id, literal, started, duration)

def branch_limit(over: Bool, +rest: Nat, +model3: Model, +id: String, +literal: String, +started: Nat, +duration: Nat) -> IO(Unit):
  match over:
    case True{}:
      finalize(model3, literal, started, "output-limit", False{})
    case False{}:
      do IO<Unit>:
        now : Nat <- IO.now()
        branch_deadline(Nat.is_ge(Nat.sub(now, started), duration), rest, model3, id, literal, started, duration)

def decide_terminal(terminal: Bool, +model3: Model, +rest: Nat, +id: String, +literal: String, +started: Nat, +duration: Nat, +lines_total: Nat) -> IO(Unit):
  match terminal:
    case True{}:
      finalize(model3, literal, started, "finished", True{})
    case False{}:
      branch_limit(Nat.is_ge(lines_total, total_max()), rest, model3, id, literal, started, duration)

def branch_terminal(summary: Summary, +receipt: String, +rest: Nat, +id: String, +literal: String, +started: Nat, +duration: Nat) -> IO(Unit):
  match summary:
    case Summary{model, finished, lines, batches}:
      decide_terminal(Bool.or(finished, Bool.not(String.eq(receipt, ""))), model, rest, id, literal, started, duration, lines)

def loop(remaining: Nat, +model: Model, +id: String, +literal: String, +started: Nat, +duration: Nat) -> IO(Unit):
  match remaining:
    case 0n:
      finalize(model, literal, started, "fuel", False{})
    case 1n+rest:
      do IO<Unit>:
        events : String <- Host.read(id, "events.jsonl", 1048576)
        model2 : Model <- emit(consume(String.split(events, '\n'), model, literal, batch_max()))
        receipt : String <- Host.read(id, "receipt.json", 1048576)
        branch_terminal(summarize(model2), receipt, rest, id, literal, started, duration)

def watch_parsed(+id: String, +literal: String, parsed: Maybe<&2, Nat>) -> IO(Unit):
  match parsed:
    case None{}:
      IO.die(Unit, 2, "usage: watch <id> <duration-ms> <literal>; duration 1..300000, literal 1..256 chars")
    case Some{+duration}:
      do IO<Unit>:
        started : Nat <- IO.now()
        loop(fuel(duration), initial_model(), id, literal, started, duration)

def watch(id: String, ms: String, +literal: String) -> IO(Unit):
  watch_parsed(id, literal, validate(ms, literal))

def command(args: List<String>) -> IO(Unit):
  match args:
    case Con{"watch", Con{id, Con{ms, Con{literal, Nil{}}}}}:
      watch(id, ms, literal)
    case other:
      IO.die(Unit, 2, "usage: watch <id> <duration-ms> <literal>")
