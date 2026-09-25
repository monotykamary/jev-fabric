import Base
import ./Process.bend as Process
import ./HttpCore.bend as Policy

# The driver interprets a checked request; key/body cannot enter its fixed argv.
def execute(plan: Result<&1, &1, U32 & String, Policy.Request>) -> IO(Result<&1, &1, U32 & String, List<&2, U32>>):
  match plan:
    case Fail{error}:
      IO.pure(Result<&1, &1, U32 & String, List<&2, U32>>, Fail{error})
    case Done{Policy.Request{config, +timeout}}:
      do IO<Result<&1, &1, U32 & String, List<&2, U32>>>:
        result : Result<&1, &1, U32 & String, Process.RawBytes> <- Process.capture(Policy.argv(), config, timeout, 1048580)
        return Policy.captured(result)

# Public compatibility helpers delegate to the pure policy module.
def key_valid(key: String) -> Bool:
  Policy.key_valid(key)

def post(url: String, key: String, body: String, timeout: U32) -> IO(Result<&1, &1, U32 & String, List<&2, U32>>):
  execute(Policy.request(url, key, body, timeout))
