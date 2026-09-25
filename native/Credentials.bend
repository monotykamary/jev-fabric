import Base
import ./Codec.bend as Codec
import ./Http.bend as Http
import ./Process.bend as Process

def Error() -> Type:
  U32 & String

def checked(key: String, valid: Bool) -> Result<&1, &1, Error, String>:
  match valid:
    case True{}:
      Done{key}
    case False{}:
      Fail{(1, "Invalid private credential")}

def check(raw: String) -> Result<&1, &1, Error, String>:
  +key = String.trim(raw)
  checked(key, Http.key_valid(key))

def decoded(result: Result<&1, &1, Error, String>) -> Result<&1, &1, Error, String>:
  match result:
    case Fail{e}:
      Fail{(1, "Private credential command returned invalid text")}
    case Done{key}:
      check(key)

def output(bytes: List<&2, U32>, ok: Bool) -> Result<&1, &1, Error, String>:
  match ok:
    case False{}:
      Fail{(1, "Private credential command failed")}
    case True{}:
      decoded(Codec.decode_utf8(bytes))

def captured(result: Result<&1, &1, Error, Process.RawBytes>) -> Result<&1, &1, Error, String>:
  match result:
    case Fail{e}:
      Fail{(1, "Private credential command failed")}
    case Done{raw}:
      (code, (flags, (bytes, err))) = raw
      output(bytes, U32.is_eq(code, 0) && U32.is_eq(flags, 0))

def argv_text(v: Maybe<&2, String>, acc: List<String>, rest: List<String> -> Result<&1, &1, Error, List<String>>) -> Result<&1, &1, Error, List<String>>:
  match v:
    case None{}:
      Fail{(1, "Credential command must be a JSON argv array")}
    case Some{s}:
      rest(Con{s, acc})

def argv(values: List<&2, Codec.Value>, acc: List<String>) -> Result<&1, &1, Error, List<String>>:
  match values:
    case Nil{}:
      Done{List.reverse(&1, String, acc)}
    case Con{v, tail}:
      argv_text(Codec.text(v), acc, next => argv(tail, next))

def array(value: Maybe<&2, List<&2, Codec.Value>>) -> Result<&1, &1, Error, List<String>>:
  match value:
    case None{}:
      Fail{(1, "Credential command must be a JSON argv array")}
    case Some{values}:
      argv(values, [])

def parsed(value: Result<&1, &1, Error, Codec.Value>) -> Result<&1, &1, Error, List<String>>:
  match value:
    case Fail{e}:
      Fail{(1, "Credential command must be a JSON argv array")}
    case Done{v}:
      array(Codec.array(v))

def execute(command: Result<&1, &1, Error, List<String>>, timeout: U32) -> IO(Result<&1, &1, Error, String>):
  match command:
    case Fail{e}:
      IO.pure(Result<&1, &1, Error, String>, Fail{e})
    case Done{args}:
      do IO<Result<&1, &1, Error, String>>:
        raw : Result<&1, &1, Error, Process.RawBytes> <- Process.capture(args, "", U32.min(timeout, 5000), 16384)
        return captured(raw)

def resolve_if(key: String, command: String, timeout: U32, direct: Bool, have_command: Bool) -> IO(Result<&1, &1, Error, String>):
  match direct have_command:
    case True{} other:
      IO.pure(Result<&1, &1, Error, String>, check(key))
    case False{} False{}:
      IO.pure(Result<&1, &1, Error, String>, Fail{(1, "Missing provider key or JEV_CREDENTIAL_COMMAND")})
    case False{} True{}:
      execute(parsed(Codec.read(command)), timeout)

def resolve(+key: String, +command: String, timeout: U32) -> IO(Result<&1, &1, Error, String>):
  resolve_if(key, command, timeout, Bool.not(String.is_empty(String.trim(key))), Bool.not(String.is_empty(command)))
