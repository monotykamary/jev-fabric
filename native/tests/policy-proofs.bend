import Base
import ../Core.bend as Core
import ../MonitorCore.bend as Monitor
import ../HttpCore.bend as Http
import ../CredentialCore.bend as Credential
import ../JevCore.bend as Jev
import ../vendor/strict-json/json.bend as J

# These contracts concern the actual policy used by the effect interpreters.
# Base/compiler correctness and the honesty/liveness of IO are assumptions.
law denied_reservation_has_no_budget:
  for remaining: Nat
  for used: Nat
  for tokens: Nat
  for limit: Nat
  {Core.reserve_if(remaining, used, tokens, limit, False{}) == None{} : Maybe<&2, Core.Budget>}

def denied_reservation_has_no_budget(remaining, used, tokens, limit):
  {==}

law reservation_consumes_one:
  for remaining: Nat
  for used: Nat
  {Core.reserve(Core.Budget{1n+remaining, used, 0n, 1n}) == Some{Core.Budget{remaining, 1n+used, 0n, 1n}} : Maybe<&2, Core.Budget>}

def reservation_consumes_one(remaining, used):
  {==}

law zero_token_budget_blocks:
  for remaining: Nat
  for used: Nat
  {Core.reserve(Core.Budget{1n+remaining, used, 0n, 0n}) == None{} : Maybe<&2, Core.Budget>}

def zero_token_budget_blocks(remaining, used):
  {==}

law accounting_never_refunds_a_call:
  for remaining: Nat
  for used: Nat
  for tokens: Nat
  for limit: Nat
  for reported: Nat
  {Core.account(Core.Budget{remaining, used, tokens, limit}, reported) == Core.Budget{remaining, used, Nat.add(tokens, reported), limit} : Core.Budget}

def accounting_never_refunds_a_call(remaining, used, tokens, limit, reported):
  {==}

law failure_is_terminal:
  for result: Core.State
  {Core.settle(Core.Failed{}, result) == Core.Failed{} : Core.State}

def failure_is_terminal(result):
  {==}

law timeout_is_terminal:
  for result: Core.State
  {Core.settle(Core.TimedOut{}, result) == Core.TimedOut{} : Core.State}

def timeout_is_terminal(result):
  {==}

law terminal_monitor_never_polls:
  for lines: Nat
  for elapsed: Nat
  for duration: Nat
  {Monitor.terminal_decision(True{}, lines, elapsed, duration) == Monitor.Stop{"finished", True{}} : Monitor.Decision}

def terminal_monitor_never_polls(lines, elapsed, duration):
  {==}

law limited_monitor_never_polls:
  for elapsed: Nat
  for duration: Nat
  {Monitor.limit_decision(True{}, elapsed, duration) == Monitor.Stop{"output-limit", False{}} : Monitor.Decision}

def limited_monitor_never_polls(elapsed, duration):
  {==}

law expired_monitor_never_polls:
  {Monitor.deadline_decision(True{}) == Monitor.Stop{"deadline", False{}} : Monitor.Decision}

def expired_monitor_never_polls():
  {==}

law disabled_filter_emits_nothing:
  for text: String
  for literal: String
  for previous: String
  {Monitor.limited_match(text, literal, previous, False{}) == None{} : Maybe<&2, String>}

def disabled_filter_emits_nothing(text, literal, previous):
  {==}

law full_channel_cannot_emit:
  for stream: String
  for frame: Monitor.Frame
  for lines: List<&2, Monitor.Line>
  for omitted: Nat
  for clips: Nat
  for previous: String
  for from: U32
  for to: U32
  for batches: Nat
  for text: String
  for clipped: Bool
  for sequence: U32
  for literal: String
  for batch: Nat
  {Monitor.push(stream, Monitor.Channel{frame, Monitor.Pending{lines, omitted, clips}, previous, from, to, 1024n, batches}, Monitor.Line{text, clipped}, sequence, literal, batch) == Monitor.Produced{Monitor.Channel{frame, Monitor.Pending{lines, omitted, clips}, previous, from, to, 1024n, batches}, Nil{}} : Monitor.Produced}

def full_channel_cannot_emit(stream, frame, lines, omitted, clips, previous, from, to, batches, text, clipped, sequence, literal, batch):
  {==}

law encoding_without_fuel_fails:
  for value: J.JSON
  {J.JSON.write_with_fuel(0n, value) == Fail{(22, "JSON encoding work limit")} : Result<&1, &1, U32 & String, String>}

def encoding_without_fuel_fails(value):
  {==}

law rejected_http_has_no_request:
  for url: String
  for key: String
  for body: String
  for timeout: U32
  {Http.request_allowed(url, key, body, timeout, False{}) == Fail{(1, "Invalid HTTPS request configuration")} : Result<&1, &1, U32 & String, Http.Request>}

def rejected_http_has_no_request(url, key, body, timeout):
  {==}

law rejected_credential_exposes_no_key:
  for key: String
  {Credential.checked(key, False{}) == Fail{(1, "Invalid private credential")} : Result<&1, &1, U32 & String, String>}

def rejected_credential_exposes_no_key(key):
  {==}

law failed_transport_rejects_bytes:
  for bytes: List<&2, U32>
  {Http.capture_ok(bytes, False{}) == Fail{(1, "Jev transport failed, was interrupted, or exceeded its output bound")} : Result<&1, &1, U32 & String, List<&2, U32>>}

def failed_transport_rejects_bytes(bytes):
  {==}

law reported_overshoot_disables_calls:
  for settings: Jev.Settings
  for remaining: Nat
  for used: Nat
  for spent: Nat
  for limit: Nat
  for key: String
  for response: J.JSON
  for input: Nat
  for output: Nat
  {Jev.add_usage(settings, Core.Budget{remaining, used, spent, limit}, key, response, input, output, True{}) == (Jev.Client{settings, Core.Budget{0n, used, 1n+limit, limit}, key}, Fail{(1, "Jev reported-token budget exceeded; final request may still be billed")}) : Jev.Returned}

def reported_overshoot_disables_calls(settings, remaining, used, spent, limit, key, response, input, output):
  {==}

law invalid_typed_reply_stays_failed:
  for settings: Jev.Settings
  for budget: Core.Budget
  for key: String
  for error: U32 & String
  {Jev.response_ready(settings, budget, key, Fail{error}) == (Jev.Client{settings, budget, key}, Fail{(1, "Invalid typed Jev response")}) : Jev.Returned}

def invalid_typed_reply_stays_failed(settings, budget, key, error):
  {==}
