import Base
import ./Core.bend as Core
import ./Codec.bend as Codec
import ./Wire.bend as Wire
import ./Credentials.bend as Credentials
import ./Http.bend as Http

def Error() -> Type:
  U32 & String

def Evaluation() -> Type:
  Result<&1, &1, Error, Codec.Value>

type Route is Data:
  Route{endpoint: String, key_env: String, model: String}

type Settings is Data:
  Settings{endpoint: String, model: String, command: String, timeout: U32}

# Affine ownership prevents overlapping evaluations of a single client/budget.
# Trusted native programs can inspect the fields; this is not a secret sandbox.
type Client is Type:
  Client{settings: Settings, budget: Core.Budget, key: String}

def Returned() -> Type:
  Client & Evaluation

def routes(typesafe: Bool, openrouter: Bool, vercel: Bool) -> Result<&1, &1, Error, Route>:
  match typesafe openrouter vercel:
    case True{} _ _:
      Done{Route{"https://api.typesafe.ai/v1/systemone", "TYPESAFE_API_KEY", "jev-latest"}}
    case False{} True{} _:
      Done{Route{"https://openrouter.ai/api/alpha/decisions", "OPENROUTER_API_KEY", "typesafe/jev-1.13"}}
    case False{} False{} True{}:
      Done{Route{"https://ai-gateway.vercel.sh/typesafe/v1/systemone", "AI_GATEWAY_API_KEY", "typesafe-ai/jev"}}
    case False{} False{} False{}:
      Fail{(1, "JEV_PROVIDER must be typesafe, openrouter, or vercel")}

def route(+provider: String) -> Result<&1, &1, Error, Route>:
  routes(String.is_empty(provider) || String.eq(provider, "typesafe"), String.eq(provider, "openrouter"), String.eq(provider, "vercel"))

def env_value(r: Result<&1, &1, Error, String>) -> String:
  match r:
    case Fail{e}:
      ""
    case Done{v}:
      v

def env(name: String) -> IO(String):
  do IO<String>:
    r : Result<&1, &1, Error, String> <- IO.get_env(name)
    return env_value(r)

def pick_model(override: String, fallback: String, empty: Bool) -> String:
  match empty:
    case True{}:
      fallback
    case False{}:
      override

def make(settings: Settings, key: String, calls: U32, tokens: U32, valid: Bool) -> Result<&1, &1, Error, Client>:
  match valid:
    case False{}:
      Fail{(1, "Invalid Jev timeout or model")}
    case True{}:
      Done{Client{settings, Core.Budget{U32.to_nat(calls), 0n, 0n, U32.to_nat(tokens)}, key}}

def load(selected: Result<&1, &1, Error, Route>, +timeout: U32, calls: U32, tokens: U32) -> IO(Result<&1, &1, Error, Client>):
  match selected:
    case Fail{e}:
      IO.pure(Result<&1, &1, Error, Client>, Fail{e})
    case Done{Route{endpoint, key_env, fallback}}:
      do IO<Result<&1, &1, Error, Client>>:
        +override : String <- env("JEV_MODEL")
        command : String <- env("JEV_CREDENTIAL_COMMAND")
        key : String <- env(key_env)
        +model : String = pick_model(override, fallback, String.is_empty(override))
        return make(Settings{endpoint, model, command, timeout}, key, calls, tokens,
          U32.is_ge(timeout, 1) && U32.is_le(timeout, 3600000) && Nat.is_le(String.length(model), 128n))

def from_env(timeout_ms: U32, max_evaluations: U32, max_tokens: U32) -> IO(Result<&1, &1, Error, Client>):
  do IO<Result<&1, &1, Error, Client>>:
    provider : String <- env("JEV_PROVIDER")
    load(route(provider), timeout_ms, max_evaluations, max_tokens)

def model(settings: Settings) -> String:
  match settings:
    case Settings{url, model, cmd, timeout}:
      model

def timeout(settings: Settings) -> U32:
  match settings:
    case Settings{url, model, cmd, timeout}:
      timeout

def command(settings: Settings) -> String:
  match settings:
    case Settings{url, model, cmd, timeout}:
      cmd

def endpoint(settings: Settings) -> String:
  match settings:
    case Settings{url, model, cmd, timeout}:
      url

def returned(settings: Settings, budget: Core.Budget, key: String, result: Evaluation) -> Returned:
  (Client{settings, budget, key}, result)

def accounted(settings: Settings, budget: Core.Budget, key: String, response: Codec.Value, allowed: Bool) -> Returned:
  match allowed:
    case True{}:
      returned(settings, budget, key, Done{response})
    case False{}:
      returned(settings, budget, key, Fail{(1, "Jev reported-token budget exceeded; final request may still be billed")})

def add_usage(settings: Settings, budget: Core.Budget, key: String, response: Codec.Value, input: Nat, output: Nat, oversized: Bool) -> Returned:
  match budget:
    case Core.Budget{remaining, used, spent, +limit}:
      match oversized:
        case True{}:
          # Saturating accounting avoids Nat overflow and prohibits subsequent calls.
          returned(settings, Core.Budget{0n, used, 1n+limit, limit}, key,
            Fail{(1, "Jev reported-token budget exceeded; final request may still be billed")})
        case False{}:
          +next = Core.account(Core.Budget{remaining, used, spent, limit}, Nat.add(input, output))
          accounted(settings, next, key, response, Core.within(next))

def account(settings: Settings, +budget: Core.Budget, key: String, response: Codec.Value, +input: Nat, +output: Nat) -> Returned:
  Core.Budget{r, u, s, +limit} = budget
  add_usage(settings, budget, key, response, input, output, Nat.is_gt(input, limit) || Nat.is_gt(output, limit))

def usage_ready(settings: Settings, budget: Core.Budget, key: String, response: Codec.Value, usage: Result<&1, &1, Error, Nat & Nat>) -> Returned:
  match usage:
    case Fail{e}:
      returned(settings, budget, key, Fail{(1, "Invalid Jev usage")})
    case Done{counts}:
      (input, output) = counts
      account(settings, budget, key, response, input, output)

def response_ready(settings: Settings, budget: Core.Budget, key: String, response: Evaluation) -> Returned:
  match response:
    case Fail{e}:
      returned(settings, budget, key, Fail{(1, "Invalid typed Jev response")})
    case Done{+value}:
      usage_ready(settings, budget, key, value, Wire.usage(value))

def decoded(settings: Settings, budget: Core.Budget, key: String, request: Codec.Value, text: Result<&1, &1, Error, String>) -> Returned:
  match text:
    case Fail{e}:
      returned(settings, budget, key, Fail{(1, "Invalid UTF-8 Jev response")})
    case Done{s}:
      response_ready(settings, budget, key, Wire.response(s, request))

def received(settings: Settings, budget: Core.Budget, key: String, request: Codec.Value, raw: Result<&1, &1, Error, List<&2, U32>>) -> Returned:
  match raw:
    case Fail{e}:
      returned(settings, budget, key, Fail{e})
    case Done{bytes}:
      decoded(settings, budget, key, request, Codec.decode_utf8(bytes))

def send(+settings: Settings, reserved: Core.Budget, +key: String, request: Codec.Value, body: String, remaining_ms: U32) -> IO(Returned):
  do IO<Returned>:
    raw : Result<&1, &1, Error, List<&2, U32>> <- Http.post(endpoint(settings), key, body, remaining_ms)
    return received(settings, reserved, key, request, raw)

def timed(settings: Settings, original: Core.Budget, reserved: Core.Budget, key: String, request: Codec.Value, body: String, remaining_ms: U32, expired: Bool) -> IO(Returned):
  match expired:
    case True{}:
      IO.pure(Returned, returned(settings, original, key, Fail{(1, "Jev request timed out before dispatch")}))
    case False{}:
      send(settings, reserved, key, request, body, remaining_ms)

def credential_ready(+settings: Settings, original: Core.Budget, reserved: Core.Budget, request: Codec.Value, body: String, started: Nat, result: Result<&1, &1, Error, String>) -> IO(Returned):
  match result:
    case Fail{e}:
      IO.pure(Returned, returned(settings, original, "", Fail{e}))
    case Done{key}:
      do IO<Returned>:
        now : Nat <- IO.now()
        +elapsed : Nat = Nat.sub(now, started)
        +limit : Nat = U32.to_nat(timeout(settings))
        timed(settings, original, reserved, key, request, body, U32.from_nat(Nat.sub(limit, elapsed)), Nat.is_ge(elapsed, limit))

def reserved(+settings: Settings, budget: Core.Budget, key: String, request: Codec.Value, body: String, next: Maybe<&2, Core.Budget>) -> IO(Returned):
  match next:
    case None{}:
      IO.pure(Returned, returned(settings, budget, key, Fail{(1, "Jev budget exhausted")}))
    case Some{reservation}:
      do IO<Returned>:
        started : Nat <- IO.now()
        result : Result<&1, &1, Error, String> <- Credentials.resolve(key, command(settings), timeout(settings))
        credential_ready(settings, budget, reservation, request, body, started, result)

def body_ready(settings: Settings, +budget: Core.Budget, key: String, request: Codec.Value, body: Result<&1, &1, Error, String>) -> IO(Returned):
  match body:
    case Fail{e}:
      IO.pure(Returned, returned(settings, budget, key, Fail{(1, "Invalid Jev request model")}))
    case Done{s}:
      reserved(settings, budget, key, request, s, Core.reserve(budget))

def begin(client: Client, +request: Codec.Value) -> IO(Returned):
  match client:
    case Client{+settings, budget, key}:
      body_ready(settings, budget, key, request, Wire.body(request, model(settings)))

def request_ready(client: Client, value: Evaluation) -> IO(Returned):
  match value:
    case Fail{e}:
      IO.pure(Returned, (client, Fail{(1, "Invalid Jev request")}))
    case Done{v}:
      begin(client, v)

# No implicit retries. Thread the returned client into the next evaluation.
# Failed dispatches consume a call; invalid requests and credentials do not.
def evaluate(client: Client, request_json: String) -> IO(Returned):
  request_ready(client, Wire.request(request_json))
