import Base
import ../TimeCore.bend as Time
import ../Cli.bend as Cli

def ms_is(result: Result<&1, &1, U32 & String, U32>, expected: U32) -> Bool:
  match result:
    case Fail{error}:
      False{}
    case Done{actual}:
      U32.is_eq(actual, expected)

def bad_ms(result: Result<&1, &1, U32 & String, U32>) -> Bool:
  match result:
    case Fail{error}:
      True{}
    case Done{actual}:
      False{}

def bad_cli(result: Result<&1, &1, U32 & String, Cli.Plan>) -> Bool:
  match result:
    case Fail{error}:
      True{}
    case Done{plan}:
      False{}

def check(tests: List<&2, Bool>, n: Nat) -> IO(Unit):
  match tests:
    case Nil{}:
      IO.print("native timer policy assertions: " ++ Nat.show(n))
    case Con{True{}, rest}:
      check(rest, 1n+n)
    case Con{False{}, rest}:
      IO.die(Unit, 1, "timer policy failed at " ++ Nat.show(n))

def main() -> IO(Unit):
  check([
    U32.is_eq(Time.work_default(), 3600000),
    U32.is_eq(Time.jev_default(), 30000),
    U32.is_eq(Time.wait_default(), 30000),
    U32.is_eq(Time.watch_default(), 5000),
    ms_is(Time.config("", 50, 100), 50),
    ms_is(Time.parse("00060", 100), 60),
    ms_is(Time.parse("3600000", 3600000), 3600000),
    bad_ms(Time.parse("0", 3600000)),
    bad_ms(Time.parse("-1", 3600000)),
    bad_ms(Time.parse("1.5", 3600000)),
    bad_ms(Time.parse("3600001", 3600000)),
    bad_ms(Time.parse("4294967297", 3600000)),
    bad_ms(Time.parse("300001", 300000)),
    Nat.is_eq(Time.remaining(Time.Budget{100n, 300n}, 200n), 200n),
    Nat.is_eq(Time.remaining(Time.Budget{100n, 300n}, 400n), 0n),
    Nat.is_eq(Time.remaining(Time.Budget{100n, 300n}, 500n), 0n),
    U32.is_eq(Time.cap(200n, 50), 50),
    U32.is_eq(Time.cap(50n, 200), 50),
    U32.is_eq(Time.cap(Nat.add(4294967295n, 2n), 100), 100),
    bad_cli(Cli.parse(["exec", "--timeout-ms", "3", "--timeout-ms", "4", "/bin/echo"])),
    bad_cli(Cli.parse(["exec", "--timeout-ms", "3", "4", "/bin/echo"])),
    bad_cli(Cli.parse(["start", "--stdin", "/bin/echo"])),
    bad_cli(Cli.parse(["exec", "--timeout-ms"])),
    bad_cli(Cli.parse(["watch", "id", "300001", "ready"]))
  ], 0n)
