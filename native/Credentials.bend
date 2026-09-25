import Base
import ./Codec.bend as Codec
import ./CredentialCore.bend as Policy
import ./Process.bend as Process

def Error() -> Type:
  U32 & String

def Resolved() -> Type:
  Result<&1, &1, Error, String>

# The credential command runs for at most 5 s and may print at most 16 KiB.
def execute(command: Result<&1, &1, Error, List<String>>, timeout: U32) -> IO(Resolved):
  match command:
    case Fail{e}:
      IO.pure(Resolved, Fail{e})
    case Done{args}:
      do IO<Resolved>:
        raw : Result<&1, &1, Error, Process.RawBytes> <- Process.capture(
          args,
          "",
          U32.min(timeout, 5000),
          16384,
        )
        return Policy.captured(raw)

def resolve_if(
  key: String,
  command: String,
  timeout: U32,
  direct: Bool,
  have_command: Bool,
) -> IO(Resolved):
  match direct have_command:
    case True{} other:
      IO.pure(Resolved, Policy.check(key))
    case False{} False{}:
      IO.pure(Resolved, Fail{(1, "Missing provider key or JEV_CREDENTIAL_COMMAND")})
    case False{} True{}:
      execute(Policy.parsed(Codec.read(command)), timeout)

# A non-blank direct key wins over JEV_CREDENTIAL_COMMAND.
def resolve(+key: String, +command: String, timeout: U32) -> IO(Resolved):
  direct : Bool = Bool.not(String.is_empty(String.trim(key)))
  have_command : Bool = Bool.not(String.is_empty(command))
  resolve_if(key, command, timeout, direct, have_command)
