import Base
import ./Process.bend as Process
import ./HttpCore.bend as Policy

def Response() -> Type:
  Result<&1, &1, U32 & String, List<&2, U32>>

# curl's 1 MiB --max-filesize body plus the "\n" and 3-digit status it writes after it.
def capture_limit() -> U32:
  1048580

# The driver interprets a checked request; key/body cannot enter its fixed argv.
def execute(plan: Result<&1, &1, U32 & String, Policy.Request>) -> IO(Response):
  match plan:
    case Fail{error}:
      IO.pure(Response, Fail{error})
    case Done{Policy.Request{config, +timeout}}:
      do IO<Response>:
        result : Result<&1, &1, U32 & String, Process.RawBytes> <- Process.capture(
          Policy.argv(),
          config,
          timeout,
          capture_limit(),
        )
        return Policy.captured(result)

# Public compatibility helpers delegate to the pure policy module.
def key_valid(key: String) -> Bool:
  Policy.key_valid(key)

def post(url: String, key: String, body: String, timeout: U32) -> IO(Response):
  execute(Policy.request(url, key, body, timeout))
