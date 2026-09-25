import Base
import ./Process.bend as Process
import ./Jobs.bend as Jobs
import ./Monitor.bend as Monitor
import ./Runner.bend as Runner
import ./Input.bend as Input
import ./Codec.bend as Codec
import ./Wire.bend as Wire
import ./Jev.bend as Jev

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

def print_value(value: Codec.Value) -> IO(Unit):
  do IO<Unit>:
    text : String <- IO.pass(String, Codec.encode(value))
    IO.print(text)

def evaluated(result: Jev.Returned) -> IO(Unit):
  (client, response) = result
  do IO<Unit>:
    value : Codec.Value <- IO.pass(Codec.Value, response)
    print_value(value)

def evaluate_file(path: String, timeout: Maybe<&2, U32>, tokens: Maybe<&2, U32>) -> IO(Unit):
  match timeout tokens:
    case Some{ms} Some{limit}:
      do IO<Unit>:
        request : String <- IO.try(String, Input.read(path))
        client : Jev.Client <- IO.try(Jev.Client, Jev.from_env(ms, 1, limit))
        result : Jev.Returned <- Jev.evaluate(client, request)
        evaluated(result)
    case _ _:
      IO.die(Unit, 2, "Jev timeout and token limit must be integers")

def validate_file(path: String) -> IO(Unit):
  do IO<Unit>:
    text : String <- IO.try(String, Input.read(path))
    value : Codec.Value <- IO.pass(Codec.Value, Wire.request(text))
    print_value(value)

def usage() -> IO(Unit):
  IO.print("jev-fabric native Bend\nusage: build/jev-fabric -- <command>\n  exec <timeout-ms> [--stdin] <command> [args...]\n  run <timeout-ms> <program.bend> [args...]\n  validate <request.json>\n  jev <timeout-ms> <request.json> [max-tokens]\n  start <timeout-ms> <command> [args...]\n  status <id> | events <id> [after-sequence]\n  watch <id> <duration-ms> <literal>\n  wait <id> <wait-timeout-ms> | stop <id>\nNative trusted code, not a sandbox. Shell interpretation is explicit.\nJev uses provider environment credentials or JEV_CREDENTIAL_COMMAND, private curl stdin, and no automatic retries.")

def dispatch(args: List<String>) -> IO(Unit):
  match args:
    case Nil{}:
      usage()
    case Con{"--help", Nil{}}:
      usage()
    case Con{"--version", Nil{}}:
      IO.print("0.1.0-native (Bend 2.0.27)")
    case Con{"exec", Con{timeout, Con{"--stdin", Con{command, rest}}}}:
      execute(Con{command, rest}, U32.read(timeout), True{})
    case Con{"exec", Con{timeout, Con{command, rest}}}:
      execute(Con{command, rest}, U32.read(timeout), False{})
    case Con{"run", Con{timeout, Con{source, rest}}}:
      Runner.run(U32.read(timeout), source, rest)
    case Con{"watch", rest}:
      Monitor.command(Con{"watch", rest})
    case Con{"validate", Con{path, Nil{}}}:
      validate_file(path)
    case Con{"jev", Con{timeout, Con{path, Nil{}}}}:
      evaluate_file(path, U32.read(timeout), Some{100000})
    case Con{"jev", Con{timeout, Con{path, Con{tokens, Nil{}}}}}:
      evaluate_file(path, U32.read(timeout), U32.read(tokens))
    case args:
      Jobs.command(args)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    dispatch(args)
