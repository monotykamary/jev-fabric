import Base
import ./Process.bend as Process

def finish(code: U32, ok: Bool) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, code, "subprocess did not complete successfully")

def launch(argv: List<String>, timeout: U32, inherit_stdin: Bool) -> IO(Process.Report):
  match inherit_stdin:
    case False{}:
      Process.run(argv, "", timeout)
    case True{}:
      Process.run_stdin(argv, timeout)

def execute(argv: List<String>, timeout: Maybe<&2, U32>, inherit_stdin: Bool) -> IO(Unit):
  match timeout:
    case None{}:
      IO.die(Unit, 2, "timeout must be an integer from 1 to 3600000 milliseconds")
    case Some{ms}:
      do IO<Unit>:
        +result : Process.Report <- launch(argv, ms, inherit_stdin)
        IO.print(Process.show(result))
        +code : U32 = Process.exit_code(result)
        finish(code, U32.is_eq(code, 0))

def usage() -> IO(Unit):
  IO.print("jev-fabric native Bend spike\nusage: build/jev-fabric -- exec <timeout-ms> [--stdin] <command> [args...]\nNo shell interpretation unless you explicitly execute a shell.\nFull run/start/status/events/wait/stop and Jev HTTP remain in the Bun-managed reference runtime.")

def dispatch(args: List<String>) -> IO(Unit):
  match args:
    case Nil{}:
      usage()
    case Con{"--help", Nil{}}:
      usage()
    case Con{"--version", Nil{}}:
      IO.print("0.1.0-native-spike (Bend 2.0.27)")
    case Con{"exec", Con{timeout, Con{"--stdin", Con{command, rest}}}}:
      execute(Con{command, rest}, U32.read(timeout), True{})
    case Con{"exec", Con{timeout, Con{command, rest}}}:
      execute(Con{command, rest}, U32.read(timeout), False{})
    case args:
      IO.die(Unit, 2, "unsupported native command; see --help")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    dispatch(args)
