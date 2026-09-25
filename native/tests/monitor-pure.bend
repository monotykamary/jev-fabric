import Base
import ../MonitorCore.bend as Monitor
import ../Json.bend as Json

def assert(ok: Bool, label: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, label)

def nl() -> String:
  String.from_list([Chr{10}])

def event(seq: U32, stream: String, text: String, omitted: U32) -> String:
  "{\"sequence\":" ++ U32.show(seq) ++ ",\"type\":\"process.output\",\"data\":{\"stream\":" ++ Json.quote(stream) ++ ",\"offset\":0,\"bytes\":0,\"omittedBytes\":" ++ U32.show(omitted) ++ ",\"text\":" ++ Json.quote(text) ++ "}}"

def summary_lines(value: Monitor.Summary) -> Nat:
  match value:
    case Monitor.Summary{model, finished, lines, batches}:
      lines

def step_lines(value: Monitor.Step) -> Nat:
  summary_lines(Monitor.summarize(Monitor.step_model(value)))

def summary_batches(value: Monitor.Summary) -> Nat:
  match value:
    case Monitor.Summary{model, finished, lines, batches}:
      batches

def step_batches(value: Monitor.Step) -> Nat:
  summary_batches(Monitor.summarize(Monitor.step_model(value)))

def any_contains(xs: List<&2, String>, +needle: String) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{+head, +tail}:
      Bool.or(String.contains(head, needle), any_contains(tail, needle))

def first_line(lines: List<&2, Monitor.Line>) -> String:
  match lines:
    case Nil{}:
      ""
    case Con{+head, +tail}:
      match head:
        case Monitor.Line{text, clipped}:
          text

def first_clipped(lines: List<&2, Monitor.Line>) -> Bool:
  match lines:
    case Nil{}:
      False{}
    case Con{+head, +tail}:
      match head:
        case Monitor.Line{text, clipped}:
          clipped

def close_ok(value: Maybe<&2, Monitor.Line>) -> Bool:
  match value:
    case Some{+line}:
      True{}
    case None{}:
      False{}

def check_split() -> Bool:
  +a = Monitor.frame_chunk(Monitor.Frame{"", False{}}, "hel", False{}, 100n)
  +b = Monitor.frame_chunk(Monitor.framed_frame(a), "lo" ++ nl() ++ "world" ++ nl(), False{}, 100n)
  +bl = Monitor.framed_lines(b)
  Bool.and(Nat.is_eq(List.length(&2, Monitor.Line, Monitor.framed_lines(a)), 0n),
    Bool.and(Nat.is_eq(List.length(&2, Monitor.Line, bl), 2n), String.eq(first_line(bl), "hello")))

def check_clip() -> Bool:
  +c = Monitor.frame_chunk(Monitor.Frame{"", False{}}, "abcdef" ++ nl(), False{}, 4n)
  +cl = Monitor.framed_lines(c)
  Bool.and(Nat.is_eq(String.length(first_line(cl)), 4n), first_clipped(cl))

def check_close() -> Bool:
  close_ok(Monitor.close_frame(Monitor.Frame{"tail", False{}}))

def check_dedup() -> Bool:
  +d = Monitor.consume([event(1, "stdout", "X" ++ nl() ++ "X" ++ nl(), 0)], Monitor.initial_model(), "X", 32n)
  Nat.is_eq(step_lines(d), 1n)

def check_split_events() -> Bool:
  +e = Monitor.consume([event(1, "stdout", "he", 0), event(2, "stdout", "llo" ++ nl(), 0)], Monitor.initial_model(), "he", 32n)
  Nat.is_eq(step_lines(e), 1n)

def check_filter() -> Bool:
  +f = Monitor.consume([event(1, "stdout", "alpha" ++ nl() ++ "beta" ++ nl(), 0)], Monitor.initial_model(), "beta", 32n)
  Nat.is_eq(step_lines(f), 1n)

def check_gap() -> Bool:
  +g = Monitor.consume([event(5, "stdout", "x" ++ nl(), 0)], Monitor.initial_model(), "x", 32n)
  any_contains(Monitor.step_outs(g), "replay-eviction")

def check_omitted() -> Bool:
  +h = Monitor.consume([event(1, "stdout", "", 7)], Monitor.initial_model(), "x", 32n)
  any_contains(Monitor.step_outs(h), "omitted-bytes")

def check_drain() -> Bool:
  +i = Monitor.consume([event(1, "stdout", "only" ++ nl(), 0)], Monitor.initial_model(), "only", 32n)
  +j = Monitor.drain(Monitor.step_model(i), "only", True{})
  Bool.and(any_contains(Monitor.step_outs(j), "monitor.batch"),
    Bool.not(any_contains(Monitor.step_outs(j), "monitor.end")))

def check_batch() -> Bool:
  +d = Monitor.consume([event(1, "stdout", "a" ++ nl() ++ "b" ++ nl() ++ "c" ++ nl(), 0)], Monitor.initial_model(), "", 2n)
  Bool.and(Nat.is_eq(step_batches(d), 1n), Nat.is_eq(step_lines(d), 3n))

def check_hard_cap() -> Bool:
  +full : Monitor.Channel = Monitor.Channel{Monitor.Frame{"", False{}}, Monitor.Pending{[], 0n, 0n}, "", 0, 0, 1024n, 32n}
  +result = Monitor.push("stdout", full, Monitor.Line{"MATCH", False{}}, 1, "MATCH", 32n)
  Nat.is_eq(Monitor.channel_count(Monitor.produced_channel(result)), 1024n) && Nat.is_eq(List.length(&2, String, Monitor.produced_outs(result)), 0n)

def all_checks() -> Bool:
  Bool.and(check_batch(),
    Bool.and(check_split(),
    Bool.and(check_clip(),
      Bool.and(check_close(),
        Bool.and(check_dedup(),
          Bool.and(check_split_events(),
            Bool.and(check_filter(),
              Bool.and(check_gap(),
                Bool.and(check_omitted(), check_drain())))))))))

def main() -> IO(Unit):
  do IO<Unit>:
    ok : Bool = all_checks()
    assert(ok && check_hard_cap(), "monitor pure assertions failed")
    IO.print("monitor pure assertions: 15")
