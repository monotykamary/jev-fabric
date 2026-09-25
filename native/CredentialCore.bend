import Base
import ./Codec.bend as Codec
import ./HttpCore.bend as Http

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

def captured(result: Result<&1, &1, Error, Http.RawBytes>) -> Result<&1, &1, Error, String>:
  match result:
    case Fail{e}:
      Fail{(1, "Private credential command failed")}
    case Done{raw}:
      (code, (flags, (bytes, err))) = raw
      output(bytes, U32.is_eq(code, 0) && U32.is_eq(flags, 0))

def argv_text(
  text: Maybe<&2, String>,
  acc: List<String>,
  rest: List<String> -> Result<&1, &1, Error, List<String>>,
) -> Result<&1, &1, Error, List<String>>:
  match text:
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
