import Base
import ./TimeCore.bend as Time

# Normalize public conveniences into the stable positional dispatcher.
# Parse only a prefix. After the command/source, all arguments remain literal.
def Error() -> Type:
  U32 & String

def version() -> String:
  "0.3.0-native"

type Options is Type:
  Options{args: List<String>, timeout: Maybe<&2, U32>, input: Bool, literal: Bool}

type Plan is Type:
  Timed{command: String, args: List<String>, timeout: Maybe<&2, U32>, input: Bool}
  Pass{args: List<String>}

def max(command: String) -> U32:
  match command:
    case "watch":
      300000
    case other:
      3600000

def unique(previous: Maybe<&2, U32>, value: U32) -> Result<&1, &1, Error, U32>:
  match previous:
    case None{}:
      Done{value}
    case Some{old}:
      Fail{(2, "specify the timeout only once")}

def input_allowed(allowed: Bool, duplicate: Bool) -> Result<&1, &1, Error, Unit>:
  match allowed duplicate:
    case True{} False{}:
      Done{Unit{}}
    case _ _:
      Fail{(2, "--stdin is supported once, for exec only")}

def first_option(
  args: List<String>,
  timeout: Maybe<&2, U32>,
  input: Bool,
  bad: Bool,
) -> Result<&1, &1, Error, Options>:
  match bad:
    case True{}:
      Fail{(2, "unknown option; use -- before a literal command")}
    case False{}:
      Done{Options{args, timeout, input, False{}}}

def options(
  args: List<String>,
  timeout: Maybe<&2, U32>,
  +input: Bool,
  +allow_input: Bool,
  +limit: U32,
) -> Result<&1, &1, Error, Options>:
  match args:
    case Con{"--timeout-ms", Con{raw, rest}}:
      do Result<&1, &1, Error, Options>:
        value : U32 <- Time.parse(raw, limit)
        chosen : U32 <- unique(timeout, value)
        options(rest, Some{chosen}, input, allow_input, limit)
    case Con{"--timeout-ms", Nil{}}:
      Fail{(2, "--timeout-ms requires milliseconds")}
    case Con{"--stdin", rest}:
      do Result<&1, &1, Error, Options>:
        input_allowed(allow_input, input)
        options(rest, timeout, True{}, allow_input, limit)
    case Con{"--", rest}:
      Done{Options{rest, timeout, input, True{}}}
    case Con{+first, rest}:
      first_option(Con{first, rest}, timeout, input, String.starts_with(first, "-"))
    case Nil{}:
      Done{Options{Nil{}, timeout, input, False{}}}

def digits(text: String) -> Bool:
  match text:
    case SNil{}:
      True{}
    case SCon{c, rest}:
      Char.is_digit(c) && digits(rest)

def legacy_exec(args: List<String>, ms: U32, +input: Bool) -> Result<&1, &1, Error, Plan>:
  match args:
    case Con{"--stdin", rest}:
      do Result<&1, &1, Error, Plan>:
        input_allowed(True{}, input)
        return Timed{"exec", rest, Some{ms}, True{}}
    case other:
      Done{Timed{"exec", other, Some{ms}, input}}

def legacy_plan(
  command: String,
  args: List<String>,
  ms: U32,
  input: Bool,
) -> Result<&1, &1, Error, Plan>:
  match command:
    case "exec":
      legacy_exec(args, ms, input)
    case other:
      Done{Timed{other, args, Some{ms}, input}}

# Legacy positional syntax carries the timeout as a bare millisecond argument.
def legacy(
  +command: String,
  args: List<String>,
  timeout: Maybe<&2, U32>,
  input: Bool,
  raw: String,
) -> Result<&1, &1, Error, Plan>:
  do Result<&1, &1, Error, Plan>:
    value : U32 <- Time.parse(raw, max(command))
    ms : U32 <- unique(timeout, value)
    legacy_plan(command, args, ms, input)

def launch_first(
  +command: String,
  first: String,
  rest: List<String>,
  timeout: Maybe<&2, U32>,
  input: Bool,
  numeric: Bool,
) -> Result<&1, &1, Error, Plan>:
  match numeric:
    case True{}:
      legacy(command, rest, timeout, input, first)
    case False{}:
      Done{Timed{command, Con{first, rest}, timeout, input}}

def launch(
  command: String,
  args: List<String>,
  timeout: Maybe<&2, U32>,
  input: Bool,
  literal: Bool,
) -> Result<&1, &1, Error, Plan>:
  match args:
    case Nil{}:
      Fail{(2, "command or file is required")}
    case Con{+first, rest}:
      numeric = Bool.not(literal) && Bool.not(String.is_empty(first)) && digits(first)
      launch_first(command, first, rest, timeout, input, numeric)

def wait_args(args: List<String>, timeout: Maybe<&2, U32>) -> Result<&1, &1, Error, Plan>:
  match args:
    case Con{id, Nil{}}:
      Done{Timed{"wait", [id], timeout, False{}}}
    case Con{id, Con{raw, Nil{}}}:
      legacy("wait", [id], timeout, False{}, raw)
    case other:
      Fail{(2, "usage: wait [--timeout-ms N] <id> [legacy-ms]")}

def watch_args(args: List<String>, timeout: Maybe<&2, U32>) -> Result<&1, &1, Error, Plan>:
  match args:
    case Con{id, Con{text, Nil{}}}:
      Done{Timed{"watch", [id, text], timeout, False{}}}
    case Con{id, Con{raw, Con{text, Nil{}}}}:
      legacy("watch", [id, text], timeout, False{}, raw)
    case other:
      Fail{(2, "usage: watch [--timeout-ms N] <id> <literal>")}

def select_command(
  command: String,
  args: List<String>,
  timeout: Maybe<&2, U32>,
  input: Bool,
  literal: Bool,
) -> Result<&1, &1, Error, Plan>:
  match command:
    case "wait":
      wait_args(args, timeout)
    case "watch":
      watch_args(args, timeout)
    case "serve":
      Done{Timed{"serve", args, timeout, False{}}}
    case other:
      launch(other, args, timeout, input, literal)

def selected(parsed: Options, command: String) -> Result<&1, &1, Error, Plan>:
  match parsed:
    case Options{args, timeout, input, literal}:
      select_command(command, args, timeout, input, literal)

def parse_timed(+command: String, args: List<String>) -> Result<&1, &1, Error, Plan>:
  do Result<&1, &1, Error, Plan>:
    parsed : Options <- options(args, None{}, False{}, String.eq(command, "exec"), max(command))
    selected(parsed, command)

def route(+command: String, args: List<String>, timed: Bool) -> Result<&1, &1, Error, Plan>:
  match timed:
    case True{}:
      parse_timed(command, args)
    case False{}:
      Done{Pass{Con{command, args}}}

# Commands that accept timeout options; every other command passes through unchanged.
def accepts_timeout(command: String) -> Bool:
  match command:
    case "exec":
      True{}
    case "run":
      True{}
    case "start":
      True{}
    case "jev":
      True{}
    case "wait":
      True{}
    case "watch":
      True{}
    case "serve":
      True{}
    case other:
      False{}

def parse(args: List<String>) -> Result<&1, &1, Error, Plan>:
  match args:
    case Nil{}:
      Done{Pass{Nil{}}}
    case Con{+command, rest}:
      route(command, rest, accepts_timeout(command))

def exec_args(args: List<String>, ms: U32, input: Bool) -> List<String>:
  match input:
    case True{}:
      Con{"exec", Con{U32.show(ms), Con{"--stdin", args}}}
    case False{}:
      Con{"exec", Con{U32.show(ms), args}}

def canonical(command: String, args: List<String>, ms: U32, input: Bool) -> List<String>:
  match command:
    case "exec":
      exec_args(args, ms, input)
    case "wait":
      match args:
        case Con{id, rest}:
          ["wait", id, U32.show(ms)]
        case Nil{}:
          ["wait"]
    case "watch":
      match args:
        case Con{id, rest}:
          Con{"watch", Con{id, Con{U32.show(ms), rest}}}
        case Nil{}:
          ["watch"]
    case other:
      Con{other, Con{U32.show(ms), args}}
