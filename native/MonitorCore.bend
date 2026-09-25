import Base
import ./Core.bend as Core
import ./Codec.bend as Codec
import ./Json.bend as Json
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
  Channel{
    frame: Frame,
    pending: Pending,
    previous: String,
    from: U32,
    to: U32,
    emitted: Nat,
    batches: Nat,
  }

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

def line_max() -> Nat:
  4096n

def batch_max() -> Nat:
  32n

def total_max() -> Nat:
  1024n

def duration_max() -> U32:
  300000

def literal_max() -> Nat:
  256n

def empty_frame() -> Frame:
  Frame{"", False{}}

def empty_channel() -> Channel:
  Channel{empty_frame(), Pending{Nil{}, 0n, 0n}, "", 0, 0, 0n, 0n}

def initial_model() -> Model:
  Model{0, empty_channel(), empty_channel(), 0n, False{}}

def fit(+text: String, +addition: String, max: Nat, fits: Bool) -> Line:
  match fits:
    case True{}:
      Line{String.concat([text, addition]), False{}}
    case False{}:
      Line{String.concat([text, String.take(addition, Nat.sub(max, String.length(text)))]), True{}}

# Append to a partial line, clipping at max chars. A clipped line ignores further input.
def bounded(+text: String, clipped: Bool, +addition: String, +max: Nat) -> Line:
  match clipped:
    case True{}:
      Line{text, True{}}
    case False{}:
      total = Nat.add(String.length(text), String.length(addition))
      fit(text, addition, max, Nat.is_le(total, max))

def frame_of(line: Line) -> Frame:
  match line:
    case Line{text, clipped}:
      Frame{text, clipped}

# Split pieces: every piece but the last completes a line; the last stays partial.
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
          +built = framed(rest, empty_frame(), max)
          Framed{framed_frame(built), Con{line, framed_lines(built)}}

def frame_chunk(frame: Frame, +text: String, loss: Bool, max: Nat) -> Framed:
  match loss:
    case True{}:
      framed(String.split(text, '\n'), empty_frame(), max)
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

def batch_json(
  stream: String,
  from: U32,
  to: U32,
  omitted: Nat,
  clipped: Nat,
  lines: List<&2, Line>,
) -> String:
  "{\"type\":\"monitor.batch\",\"stream\":" ++ Json.quote(stream)
    ++ ",\"first\":" ++ U32.show(from)
    ++ ",\"last\":" ++ U32.show(to)
    ++ ",\"omitted\":" ++ Nat.show(omitted)
    ++ ",\"clipped\":" ++ Nat.show(clipped)
    ++ ",\"lines\":" ++ lines_json(lines)
    ++ "}"

def loss_json(stream: String, reason: String, count: U32) -> String:
  "{\"type\":\"monitor.loss\",\"stream\":" ++ Json.quote(stream)
    ++ ",\"reason\":" ++ Json.quote(reason)
    ++ ",\"count\":" ++ U32.show(count)
    ++ "}"

# Emit any pending lines, oldest first, as one monitor.batch record.
def flush(stream: String, channel: Channel) -> Produced:
  match channel:
    case Channel{frame, Pending{lines, omitted, clipped}, previous, from, to, emitted, batches}:
      match lines:
        case Nil{}:
          Produced{
            Channel{frame, Pending{Nil{}, omitted, clipped}, previous, from, to, emitted, batches},
            Nil{},
          }
        case some:
          record = batch_json(stream, from, to, omitted, clipped, List.reverse(&2, Line, some))
          Produced{
            Channel{frame, Pending{Nil{}, 0n, 0n}, previous, 0, 0, emitted, Nat.add(batches, 1n)},
            [record],
          }

def finish_push(stream: String, channel: Channel, full: Bool) -> Produced:
  match full:
    case True{}:
      flush(stream, channel)
    case False{}:
      Produced{channel, Nil{}}

def limited_match(
  text: String,
  literal: String,
  previous: String,
  allowed: Bool,
) -> Maybe<&2, String>:
  match allowed:
    case True{}:
      Core.monitor(text, literal, previous)
    case False{}:
      None{}

def accepted(
  stream: String,
  frame: Frame,
  lines: List<&2, Line>,
  omitted: Nat,
  clipped_count: Nat,
  previous: String,
  +from: U32,
  to: U32,
  +emitted: Nat,
  batches: Nat,
  +clipped: Bool,
  +sequence: U32,
  batch: Nat,
  hit: Maybe<&2, String>,
) -> Produced:
  match hit:
    case None{}:
      Produced{
        Channel{frame, Pending{lines, omitted, clipped_count}, previous, from, to, emitted, batches},
        Nil{},
      }
    case Some{+kept}:
      +next = {Con{Line{kept, clipped}, lines} : List<&2, Line>}
      +c = Nat.add(clipped_count, Core.bit(clipped))
      +f = Bool.pick(U32, U32.is_zero(from), sequence, from)
      +count = List.length(&2, Line, next)
      +more : Channel = Channel{
        frame,
        Pending{next, omitted, c},
        kept,
        f,
        sequence,
        Nat.add(emitted, 1n),
        batches,
      }
      finish_push(stream, more, Nat.is_ge(count, batch))

def push(
  stream: String,
  channel: Channel,
  line: Line,
  sequence: U32,
  literal: String,
  batch: Nat,
) -> Produced:
  match channel:
    case Channel{frame, Pending{lines, omitted, clipped_count}, +previous, +from, to, +emitted, batches}:
      match line:
        case Line{text, +clipped}:
          accepted(
            stream,
            frame,
            lines,
            omitted,
            clipped_count,
            previous,
            from,
            to,
            emitted,
            batches,
            clipped,
            sequence,
            batch,
            limited_match(text, literal, previous, Nat.is_lt(emitted, total_max())),
          )

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

def push_all(
  lines: List<&2, Line>,
  +stream: String,
  channel: Channel,
  +sequence: U32,
  +literal: String,
  +batch: Nat,
) -> Produced:
  match lines:
    case Nil{}:
      Produced{channel, Nil{}}
    case Con{+line, +rest}:
      +first = push(stream, channel, line, sequence, literal, batch)
      +next = push_all(rest, stream, produced_channel(first), sequence, literal, batch)
      Produced{produced_channel(next), concat(produced_outs(first), produced_outs(next))}

def feed(
  stream: String,
  channel: Channel,
  text: String,
  sequence: U32,
  literal: String,
  batch: Nat,
  loss: Bool,
) -> Produced:
  match channel:
    case Channel{frame, pending, previous, from, to, emitted, batches}:
      +split = frame_chunk(frame, text, loss, line_max())
      reframed : Channel = Channel{
        framed_frame(split),
        pending,
        previous,
        from,
        to,
        emitted,
        batches,
      }
      push_all(framed_lines(split), stream, reframed, sequence, literal, batch)

def reset_frame(channel: Channel) -> Channel:
  match channel:
    case Channel{frame, pending, previous, from, to, emitted, batches}:
      Channel{empty_frame(), pending, previous, from, to, emitted, batches}

def mark(model: Model) -> Model:
  match model:
    case Model{last, out, err, losses, finished}:
      Model{last, out, err, losses, True{}}

def add_loss(model: Model) -> Model:
  match model:
    case Model{last, out, err, losses, finished}:
      Model{last, out, err, Nat.add(losses, 1n), finished}

def model_last(model: Model) -> U32:
  match model:
    case Model{last, out, err, losses, finished}:
      last

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
      +sequence = number_field(value, "sequence")
      Some{Reading{sequence, text_field(value, "type"), field_or_null(value, "data")}}

def read_event(line: String) -> Maybe<&2, Reading>:
  parsed_event(Codec.read(line))

def stream_label(is_err: Bool) -> String:
  match is_err:
    case True{}:
      "stderr"
    case False{}:
      "stdout"

def model_channel(is_err: Bool, model: Model) -> Channel:
  match is_err:
    case True{}:
      match model:
        case Model{last, out, err, losses, finished}:
          err
    case False{}:
      match model:
        case Model{last, out, err, losses, finished}:
          out

def with_channel(is_err: Bool, model: Model, channel: Channel) -> Model:
  match is_err:
    case True{}:
      match model:
        case Model{last, out, err, losses, finished}:
          Model{last, out, channel, losses, finished}
    case False{}:
      match model:
        case Model{last, out, err, losses, finished}:
          Model{last, channel, err, losses, finished}

def count_loss(model: Model, lossy: Bool) -> Model:
  match lossy:
    case True{}:
      add_loss(model)
    case False{}:
      model

def omitted_notice(
  stream: String,
  omitted: U32,
  lossy: Bool,
  outs: List<&2, String>,
) -> List<&2, String>:
  match lossy:
    case True{}:
      Con{loss_json(stream, "omitted-bytes", omitted), outs}
    case False{}:
      outs

# Omitted spool bytes break line framing: the partial line is dropped, one loss is
# counted and a monitor.loss record precedes the batches produced from this chunk.
def output_channel(
  +is_err: Bool,
  +model: Model,
  text: String,
  +omitted: U32,
  literal: String,
  batch: Nat,
) -> Step:
  +lossy = Bool.not(U32.is_zero(omitted))
  +stream = stream_label(is_err)
  source = model_channel(is_err, model)
  +fed = feed(stream, source, text, model_last(model), literal, batch, lossy)
  updated = with_channel(is_err, count_loss(model, lossy), produced_channel(fed))
  Step{updated, omitted_notice(stream, omitted, lossy, produced_outs(fed))}

def route_stream(
  stream: String,
  +model: Model,
  +text: String,
  +omitted: U32,
  +literal: String,
  +batch: Nat,
) -> Step:
  match stream:
    case "stderr":
      output_channel(True{}, model, text, omitted, literal, batch)
    case "stdout":
      output_channel(False{}, model, text, omitted, literal, batch)
    case other:
      Step{model, Nil{}}

def dispatch_output(model: Model, +data: J.JSON, literal: String, batch: Nat) -> Step:
  +stream = text_field(data, "stream")
  +text = text_field(data, "text")
  +omitted = number_field(data, "omittedBytes")
  route_stream(stream, model, text, omitted, literal, batch)

def dispatch(+model: Model, kind: String, +data: J.JSON, +literal: String, +batch: Nat) -> Step:
  match kind:
    case "process.output":
      dispatch_output(model, data, literal, batch)
    case "job.finished":
      Step{mark(model), Nil{}}
    case "process.spool_limit":
      +stream = text_field(data, "stream")
      Step{add_loss(model), [loss_json(stream, "spool-limit", 0)]}
    case other:
      Step{model, Nil{}}

# Move the cursor to sequence. A gap means the job's event ring evicted records:
# both partial lines are dropped and one loss is counted.
def advance(model: Model, +sequence: U32, gap: Bool) -> Model:
  match model:
    case Model{last, out, err, losses, finished}:
      match gap:
        case True{}:
          Model{sequence, reset_frame(out), reset_frame(err), Nat.add(losses, 1n), finished}
        case False{}:
          Model{sequence, out, err, losses, finished}

def gap_notice(skipped: U32, gap: Bool, outs: List<&2, String>) -> List<&2, String>:
  match gap:
    case True{}:
      Con{loss_json("*", "replay-eviction", skipped), outs}
    case False{}:
      outs

# Only events past the cursor are applied; replays of older sequences are ignored.
def handle_fresh(
  +sequence: U32,
  +last: U32,
  +model: Model,
  +kind: String,
  +data: J.JSON,
  +literal: String,
  +batch: Nat,
  fresh: Bool,
) -> Step:
  match fresh:
    case False{}:
      Step{model, Nil{}}
    case True{}:
      +expected = U32.add(last, 1)
      +gap = U32.is_gt(sequence, expected)
      +result = dispatch(advance(model, sequence, gap), kind, data, literal, batch)
      Step{step_model(result), gap_notice(U32.sub(sequence, expected), gap, step_outs(result))}

def handle(+model: Model, reading: Reading, literal: String, batch: Nat) -> Step:
  match reading:
    case Reading{+sequence, kind, data}:
      +last = model_last(model)
      handle_fresh(sequence, last, model, kind, data, literal, batch, U32.is_gt(sequence, last))

def consume_parsed(
  +model: Model,
  +literal: String,
  +batch: Nat,
  parsed: Maybe<&2, Reading>,
) -> Step:
  match parsed:
    case None{}:
      Step{add_loss(model), [loss_json("*", "invalid-event", 0)]}
    case Some{reading}:
      handle(model, reading, literal, batch)

def consume_line(line: String, +model: Model, +literal: String, +batch: Nat, empty: Bool) -> Step:
  match empty:
    case True{}:
      Step{model, Nil{}}
    case False{}:
      consume_parsed(model, literal, batch, read_event(line))

def consume(raw: List<&2, String>, +model: Model, +literal: String, +batch: Nat) -> Step:
  match raw:
    case Nil{}:
      Step{model, Nil{}}
    case Con{+line, rest}:
      +first = consume_line(line, model, literal, batch, String.is_empty(line))
      +next = consume(rest, step_model(first), literal, batch)
      Step{step_model(next), concat(step_outs(first), step_outs(next))}

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

# On a terminal drain the unterminated partial line is filtered as a final line
# (at the channel's last sequence) before the remaining batch is flushed.
def drain_close(
  +stream: String,
  +cleared: Channel,
  +to: U32,
  +literal: String,
  +batch: Nat,
  closed: Maybe<&2, Line>,
) -> Produced:
  match closed:
    case None{}:
      flush(stream, cleared)
    case Some{+line}:
      +pushed = push(stream, cleared, line, to, literal, batch)
      +flushed = flush(stream, produced_channel(pushed))
      Produced{produced_channel(flushed), concat(produced_outs(pushed), produced_outs(flushed))}

def drain_channel(
  stream: String,
  channel: Channel,
  literal: String,
  batch: Nat,
  terminal: Bool,
) -> Produced:
  match channel:
    case Channel{frame, pending, previous, from, +to, emitted, batches}:
      match terminal:
        case True{}:
          cleared : Channel = Channel{empty_frame(), pending, previous, from, to, emitted, batches}
          drain_close(stream, cleared, to, literal, batch, close_frame(frame))
        case False{}:
          flush(stream, Channel{empty_frame(), pending, previous, from, to, emitted, batches})

def drain(model: Model, +literal: String, +terminal: Bool) -> Step:
  match model:
    case Model{last, out, err, losses, finished}:
      +drained_out = drain_channel("stdout", out, literal, batch_max(), terminal)
      +drained_err = drain_channel("stderr", err, literal, batch_max(), terminal)
      outs = concat(produced_outs(drained_out), produced_outs(drained_err))
      Step{
        Model{last, produced_channel(drained_out), produced_channel(drained_err), losses, finished},
        outs,
      }

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

def end_json(
  reason: String,
  terminal: Bool,
  +lines: Nat,
  batches: Nat,
  losses: Nat,
  elapsed: Nat,
) -> String:
  "{\"type\":\"monitor.end\",\"reason\":" ++ Json.quote(reason)
    ++ ",\"terminal\":" ++ Json.boolean(terminal)
    ++ ",\"lines\":" ++ Nat.show(lines)
    ++ ",\"batches\":" ++ Nat.show(batches)
    ++ ",\"losses\":" ++ Nat.show(losses)
    ++ ",\"elapsedMs\":" ++ Nat.show(elapsed)
    ++ ",\"outputLimitReached\":" ++ Json.boolean(Nat.is_ge(lines, total_max()))
    ++ ",\"note\":\"matched lines are observations, not semantic completion\"}"

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
      sized = Bool.and(
        Bool.not(String.is_empty(literal)),
        Nat.is_le(String.length(literal), literal_max()),
      )
      check_literal(raw, sized)

def parse_duration(literal: String, parsed: Maybe<&2, U32>) -> Maybe<&2, Nat>:
  match parsed:
    case None{}:
      None{}
    case Some{+raw}:
      check_range(raw, literal, Bool.and(U32.is_ge(raw, 1), U32.is_le(raw, duration_max())))

def validate(ms: String, literal: String) -> Maybe<&2, Nat>:
  parse_duration(literal, U32.read(ms))

def fuel(duration: Nat) -> Nat:
  Nat.add(Nat.div(duration, 25n), 64n)

# The driver interprets these decisions; policy has no IO or foreign imports.
type Decision is Data:
  Poll{}
  Stop{reason: String, terminal: Bool}

def deadline_decision(expired: Bool) -> Decision:
  match expired:
    case True{}:
      Stop{"deadline", False{}}
    case False{}:
      Poll{}

def limit_decision(over: Bool, elapsed: Nat, duration: Nat) -> Decision:
  match over:
    case True{}:
      Stop{"output-limit", False{}}
    case False{}:
      deadline_decision(Nat.is_ge(elapsed, duration))

def terminal_decision(terminal: Bool, lines: Nat, elapsed: Nat, duration: Nat) -> Decision:
  match terminal:
    case True{}:
      Stop{"finished", True{}}
    case False{}:
      limit_decision(Nat.is_ge(lines, total_max()), elapsed, duration)

def decide(summary: Summary, receipt: String, elapsed: Nat, duration: Nat) -> Decision:
  match summary:
    case Summary{model, finished, lines, batches}:
      done = Bool.or(finished, Bool.not(String.is_empty(receipt)))
      terminal_decision(done, lines, elapsed, duration)
