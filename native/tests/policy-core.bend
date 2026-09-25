import Base
import ../vendor/strict-json/json.bend as J
import ../Codec.bend as Codec
import ../HttpCore.bend as Http
import ../MonitorCore.bend as Monitor

def rejected(value: Result<&1, &1, U32 & String, String>) -> Bool:
  match value:
    case Fail{error}:
      True{}
    case Done{text}:
      False{}

def equals(value: Result<&1, &1, U32 & String, String>, expected: String) -> Bool:
  match value:
    case Fail{error}:
      False{}
    case Done{text}:
      String.eq(text, expected)

def invalid_http(value: Result<&1, &1, U32 & String, Http.Request>) -> Bool:
  match value:
    case Fail{error}:
      True{}
    case Done{plan}:
      False{}

def stopped(decision: Monitor.Decision) -> Bool:
  match decision:
    case Monitor.Stop{reason, terminal}:
      True{}
    case Monitor.Poll{}:
      False{}

def check(tests: List<&2, Bool>, n: Nat) -> IO(Unit):
  match tests:
    case Nil{}:
      IO.print("native safe policy assertions: " ++ Nat.show(n))
    case Con{True{}, rest}:
      check(rest, 1n+n)
    case Con{False{}, rest}:
      IO.die(Unit, 1, "safe policy assertion failed at " ++ Nat.show(n))

def main() -> IO(Unit):
  check([
    rejected(J.JSON.write_with_fuel(0n, J.Null{})),
    equals(J.JSON.write_with_fuel(1n, J.Null{}), "null"),
    rejected(J.JSON.write_with_fuel(2n, J.Arr{[]})),
    equals(J.JSON.write_with_fuel(3n, J.Arr{[]}), "[]"),
    equals(J.JSON.write_with_fuel(6n, J.Obj{[J.Member{"n", J.Num{"1e-999"}}]}), "{\"n\":1e-999}"),
    rejected(Codec.encode(J.Num{" 1 "})),
    rejected(J.JSON.write_with_fuel(1n, J.Num{"not-a-number"})),
    invalid_http(Http.request("http://example.invalid", "synthetic", "{}", 1000)),
    invalid_http(Http.request("https://example.invalid", "line\nbreak", "{}", 1000)),
    stopped(Monitor.terminal_decision(False{}, 1024n, 0n, 1000n))
  ], 0n)
