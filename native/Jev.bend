import Base
import ./Core.bend as Core
import ./Codec.bend as Codec
import ./Wire.bend as Wire
import ./JevCore.bend as Policy
import ./Credentials.bend as Credentials
import ./Http.bend as Http
import ./Time.bend as Time

# Public affine client/result aliases; constructors and pure logic live in JevCore.
def Client() -> Type:
  Policy.Client

def Returned() -> Type:
  Policy.Returned

def Evaluation() -> Type:
  Policy.Evaluation

def Error() -> Type:
  Policy.Error

def Connected() -> Type:
  Result<&1, &1, Policy.Error, Policy.Client>

def env(name: String) -> IO(String):
  do IO<String>:
    value : Result<&1, &1, Policy.Error, String> <- IO.get_env(name)
    return Policy.env_value(value)

def settings_valid(+timeout: U32, model: String) -> Bool:
  U32.is_ge(timeout, 1)
    && U32.is_le(timeout, Time.max_timeout())
    && Nat.is_le(String.length(model), 128n)

def load(
  selected: Result<&1, &1, Policy.Error, Policy.Route>,
  +timeout: U32,
  calls: U32,
  tokens: U32,
) -> IO(Connected):
  match selected:
    case Fail{e}:
      IO.pure(Connected, Fail{e})
    case Done{Policy.Route{endpoint, key_env, fallback}}:
      do IO<Connected>:
        +override : String <- env("JEV_MODEL")
        command : String <- env("JEV_CREDENTIAL_COMMAND")
        key : String <- env(key_env)
        +model : String = Policy.pick_model(override, fallback, String.is_empty(override))
        settings : Policy.Settings = Policy.Settings{endpoint, model, command, timeout}
        return Policy.make(settings, key, calls, tokens, settings_valid(timeout, model))

def from_env(timeout_ms: U32, max_evaluations: U32, max_tokens: U32) -> IO(Connected):
  do IO<Connected>:
    provider : String <- env("JEV_PROVIDER")
    load(Policy.route(provider), timeout_ms, max_evaluations, max_tokens)

# Evaluation/token budgets remain explicit; only the timer gets a default.
def connect(max_evaluations: U32, max_tokens: U32) -> IO(Connected):
  do IO<Connected>:
    ms : U32 <- Time.jev()
    from_env(ms, max_evaluations, max_tokens)

# Answer without dispatching, handing the client back with `budget`.
def refuse(
  settings: Policy.Settings,
  budget: Core.Budget,
  key: String,
  message: String,
) -> IO(Policy.Returned):
  IO.pure(Policy.Returned, Policy.returned(settings, budget, key, Fail{(1, message)}))

def send(
  +settings: Policy.Settings,
  reserved: Core.Budget,
  +key: String,
  request: Codec.Value,
  body: String,
  remaining_ms: U32,
) -> IO(Policy.Returned):
  do IO<Policy.Returned>:
    raw : Result<&1, &1, Policy.Error, List<&2, U32>> <- Http.post(
      Policy.endpoint(settings),
      key,
      body,
      remaining_ms,
    )
    return Policy.received(settings, reserved, key, request, raw)

def timed(
  settings: Policy.Settings,
  original: Core.Budget,
  reserved: Core.Budget,
  key: String,
  request: Codec.Value,
  body: String,
  remaining_ms: U32,
  expired: Bool,
) -> IO(Policy.Returned):
  match expired:
    case True{}:
      refuse(settings, original, key, "Jev request timed out before dispatch")
    case False{}:
      send(settings, reserved, key, request, body, remaining_ms)

# Credential resolution spends from the same per-request timeout as the HTTP call.
def credential_ready(
  +settings: Policy.Settings,
  original: Core.Budget,
  reserved: Core.Budget,
  request: Codec.Value,
  body: String,
  started: Nat,
  result: Result<&1, &1, Policy.Error, String>,
) -> IO(Policy.Returned):
  match result:
    case Fail{e}:
      IO.pure(Policy.Returned, Policy.returned(settings, original, "", Fail{e}))
    case Done{key}:
      do IO<Policy.Returned>:
        now : Nat <- IO.now()
        +elapsed : Nat = Nat.sub(now, started)
        +limit : Nat = U32.to_nat(Policy.timeout(settings))
        remaining : U32 = U32.from_nat(Nat.sub(limit, elapsed))
        expired : Bool = Nat.is_ge(elapsed, limit)
        timed(settings, original, reserved, key, request, body, remaining, expired)

def reserved(
  +settings: Policy.Settings,
  budget: Core.Budget,
  key: String,
  request: Codec.Value,
  body: String,
  next: Maybe<&2, Core.Budget>,
) -> IO(Policy.Returned):
  match next:
    case None{}:
      refuse(settings, budget, key, "Jev budget exhausted")
    case Some{reservation}:
      do IO<Policy.Returned>:
        started : Nat <- IO.now()
        result : Result<&1, &1, Policy.Error, String> <- Credentials.resolve(
          key,
          Policy.command(settings),
          Policy.timeout(settings),
        )
        credential_ready(settings, budget, reservation, request, body, started, result)

def body_ready(
  settings: Policy.Settings,
  +budget: Core.Budget,
  key: String,
  request: Codec.Value,
  body: Result<&1, &1, Policy.Error, String>,
) -> IO(Policy.Returned):
  match body:
    case Fail{e}:
      refuse(settings, budget, key, "Invalid Jev request model")
    case Done{text}:
      reserved(settings, budget, key, request, text, Core.reserve(budget))

def begin(client: Policy.Client, +request: Codec.Value) -> IO(Policy.Returned):
  match client:
    case Policy.Client{+settings, budget, key}:
      body_ready(settings, budget, key, request, Wire.body(request, Policy.model(settings)))

def request_ready(client: Policy.Client, value: Policy.Evaluation) -> IO(Policy.Returned):
  match value:
    case Fail{e}:
      IO.pure(Policy.Returned, (client, Fail{(1, "Invalid Jev request")}))
    case Done{v}:
      begin(client, v)

# No implicit retries. Thread the returned client into the next evaluation.
# Failed dispatches consume a call; invalid requests and credentials do not.
def evaluate(client: Policy.Client, request_json: String) -> IO(Policy.Returned):
  request_ready(client, Wire.request(request_json))
