import Base
import ./Codec.bend as Codec
import ./CredentialCore.bend as Policy
import ./Process.bend as Process

def Error() -> Type:
  U32 & String

def execute(command: Result<&1, &1, Error, List<String>>, timeout: U32) -> IO(Result<&1, &1, Error, String>):
  match command:
    case Fail{e}:
      IO.pure(Result<&1, &1, Error, String>, Fail{e})
    case Done{args}:
      do IO<Result<&1, &1, Error, String>>:
        raw : Result<&1, &1, Error, Process.RawBytes> <- Process.capture(args, "", U32.min(timeout, 5000), 16384)
        return Policy.captured(raw)

def resolve_if(key: String, command: String, timeout: U32, direct: Bool, have_command: Bool) -> IO(Result<&1, &1, Error, String>):
  match direct have_command:
    case True{} other:
      IO.pure(Result<&1, &1, Error, String>, Policy.check(key))
    case False{} False{}:
      IO.pure(Result<&1, &1, Error, String>, Fail{(1, "Missing provider key or JEV_CREDENTIAL_COMMAND")})
    case False{} True{}:
      execute(Policy.parsed(Codec.read(command)), timeout)

def resolve(+key: String, +command: String, timeout: U32) -> IO(Result<&1, &1, Error, String>):
  resolve_if(key, command, timeout, Bool.not(String.is_empty(String.trim(key))), Bool.not(String.is_empty(command)))
