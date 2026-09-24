import Base
import ../Core.bend as Core
import ../Json.bend as Json

def some(value: Maybe<&2, Core.Budget>) -> Bool:
  match value:
    case None{}:
      False{}
    case Some{budget}:
      True{}

def has_line(value: Maybe<&2, String>) -> Bool:
  match value:
    case None{}:
      False{}
    case Some{text}:
      True{}

def batch_ok(batch: Core.Batch) -> Bool:
  match batch:
    case Core.Batch{lines, omitted, clipped}:
      Nat.is_eq(List.length(&2, String, lines), 2n) && Nat.is_eq(omitted, 1n) && Nat.is_eq(clipped, 0n)

def clipping_ok(batch: Core.Batch) -> Bool:
  match batch:
    case Core.Batch{Con{line, Nil{}}, omitted, clipped}:
      Nat.is_eq(String.length(line), 100n) && Nat.is_eq(omitted, 0n) && Nat.is_eq(clipped, 1n)
    case batch:
      False{}

def check(tests: List<&2, Bool>, n: Nat) -> IO(Unit):
  match tests:
    case Nil{}:
      IO.print("native core assertions: " ++ Nat.show(n))
    case Con{True{}, tail}:
      check(tail, 1n+n)
    case Con{False{}, tail}:
      IO.die(Unit, 1, "native core assertion failed at " ++ Nat.show(n))

def main() -> IO(Unit):
  check([
    Bool.not(some(Core.reserve(Core.Budget{0n, 4n, 0n, 10n}))),
    Bool.not(some(Core.reserve(Core.Budget{1n, 0n, 10n, 10n}))),
    some(Core.reserve(Core.Budget{1n, 0n, 9n, 10n})),
    Bool.not(Core.within(Core.account(Core.Budget{1n, 0n, 9n, 10n}, 2n))),
    Core.noul(0.0), Core.noul(1.0), Bool.not(Core.probability(F32.neg(0.1))),
    Bool.not(Core.probability(1.1)),
    Bool.not(Core.probability(F32.div(0.0, 0.0))),
    Bool.not(Core.probability(F32.div(1.0, 0.0))),
    Core.choice(["a", "b"], "a", 0.9, [Core.Probability{"a", 0.75}, Core.Probability{"b", 0.25}]),
    Bool.not(Core.choice(["a", "b"], "missing", 0.9, [Core.Probability{"a", 0.75}, Core.Probability{"b", 0.25}])),
    Bool.not(Core.choice(["a", "b"], "a", 0.9, [Core.Probability{"a", 0.75}, Core.Probability{"a", 0.25}])),
    Bool.not(Core.choice(["a"], "a", 1.0, [Core.Probability{"a", 0.2}])),
    Core.score(2n, 0.8, 0.7, [Core.Probability{"0", 0.2}, Core.Probability{"1", 0.8}]),
    Bool.not(Core.score(2n, 2.0, 0.7, [Core.Probability{"0", 0.2}, Core.Probability{"1", 0.8}])),
    Bool.not(has_line(Core.monitor("quiet", "STATUS:", ""))),
    Bool.not(has_line(Core.monitor("STATUS: ready", "STATUS:", "STATUS: ready"))),
    has_line(Core.monitor("STATUS: ready", "STATUS:", "")),
    batch_ok(Core.batch_push(Core.Batch{["b", "a"], 0n, 0n}, "c", 2n)),
    clipping_ok(Core.batch_push(Core.Batch{Nil{}, 0n, 0n}, "01234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789", 2n)),
    String.eq(Json.quote("a\"b\\c\n"), "\"a\\\"b\\\\c\\u000a\""),
    String.eq(Json.quote("🙂"), "\"🙂\"")
  ], 0n)
