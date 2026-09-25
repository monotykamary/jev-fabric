import Base
import ./Core.bend as Core
import ./Codec.bend as Codec
import ./Wire.bend as Wire

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
