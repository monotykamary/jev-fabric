import Base
import ./Process.bend as Process
import ./Time.bend as Time
import ./HttpCore.bend as Policy

def Response() -> Type:
  Result<&1, &1, U32 & String, List<&2, U32>>

# curl's 1 MiB --max-filesize body plus the "\n" and 3-digit status it writes after it.
def capture_limit() -> U32:
  1048580

# Pooled HTTPS POST through the system libcurl with a process-wide connection,
# TLS-session and DNS cache (native/http.c). Callers validate first.
def Native.http_post(
  url: String,
  key: String,
  body: String,
  timeout_ms: U32,
) -> IO(Policy.Pooled):
  import "./http.c"

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

def fallback(
  transport: Policy.Transport,
  url: String,
  key: String,
  body: String,
  timeout: U32,
  unavailable: Bool,
) -> IO(Response):
  match transport unavailable:
    case Policy.Auto{} True{}:
      execute(Policy.request(url, key, body, timeout))
    case Policy.Pooled{} True{}:
      IO.pure(Response, Policy.unavailable())
    case Policy.Exec{} True{}:
      IO.pure(Response, Policy.unavailable())
    case other False{}:
      IO.pure(Response, Policy.transport_failed())

def pooled_done(
  transport: Policy.Transport,
  url: String,
  key: String,
  body: String,
  timeout: U32,
  result: Policy.Pooled,
) -> IO(Response):
  match result:
    case Fail{(code, message)}:
      unavailable : Bool = U32.is_eq(code, Policy.unavailable_code())
      fallback(transport, url, key, body, timeout, unavailable)
    case Done{(status, bytes)}:
      IO.pure(Response, Policy.pooled_status(status, bytes))

def pooled(
  +transport: Policy.Transport,
  +url: String,
  +key: String,
  +body: String,
  +timeout: U32,
  valid: Bool,
) -> IO(Response):
  match valid:
    case False{}:
      execute(Policy.request(url, key, body, timeout))
    case True{}:
      do IO<Response>:
        result : Policy.Pooled <- Native.http_post(url, key, body, timeout)
        pooled_done(transport, url, key, body, timeout, result)

def send(
  selected: Result<&1, &1, U32 & String, Policy.Transport>,
  +url: String,
  +key: String,
  +body: String,
  +timeout: U32,
) -> IO(Response):
  match selected:
    case Fail{error}:
      IO.pure(Response, Fail{error})
    case Done{Policy.Exec{}}:
      execute(Policy.request(url, key, body, timeout))
    case Done{+transport}:
      pooled(transport, url, key, body, timeout, Policy.valid(url, key, body, timeout))

# JEV_FABRIC_HTTP selects the transport (see HttpCore.transport); both enforce
# the same request checks, HTTPS-only/no-redirect/no-proxy policy and bounds.
def post(url: String, key: String, body: String, timeout: U32) -> IO(Response):
  do IO<Response>:
    mode : String <- Time.env("JEV_FABRIC_HTTP")
    send(Policy.transport(mode), url, key, body, timeout)
