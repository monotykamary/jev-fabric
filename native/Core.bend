import Base

def bit(value: Bool) -> Nat:
  match value:
    case False{}:
      0n
    case True{}:
      1n

type Budget is Data:
  Budget{remaining: Nat, evaluations: Nat, tokens: Nat, limit: Nat}

def reserve_if(remaining: Nat, used: Nat, tokens: Nat, limit: Nat, allowed: Bool) -> Maybe<&2, Budget>:
  match allowed:
    case False{}:
      None{}
    case True{}:
      Some{Budget{remaining, 1n+used, tokens, limit}}

def reserve(budget: Budget) -> Maybe<&2, Budget>:
  match budget:
    case Budget{0n, used, tokens, limit}:
      None{}
    case Budget{1n+remaining, used, +tokens, +limit}:
      reserve_if(remaining, used, tokens, limit, Nat.is_lt(tokens, limit))

def account(budget: Budget, reported: Nat) -> Budget:
  match budget:
    case Budget{remaining, used, tokens, limit}:
      Budget{remaining, used, Nat.add(tokens, reported), limit}

def within(budget: Budget) -> Bool:
  match budget:
    case Budget{remaining, used, tokens, limit}:
      Nat.is_le(tokens, limit)

type State is Data:
  Running{}
  Completed{}
  Attention{}
  Failed{}
  Cancelled{}
  TimedOut{}

def settle(state: State, result: State) -> State:
  match state:
    case Running{}:
      result
    case Completed{}:
      Completed{}
    case Attention{}:
      Attention{}
    case Failed{}:
      Failed{}
    case Cancelled{}:
      Cancelled{}
    case TimedOut{}:
      TimedOut{}

type Receipt is Data:
  Executed{}
  Stale{}
  Blocked{}
  Unknown{}

type Next is Data:
  Verify{}
  Reobserve{}
  Escalate{}
  Inspect{}

def after(receipt: Receipt) -> Next:
  match receipt:
    case Executed{}:
      Verify{}
    case Stale{}:
      Reobserve{}
    case Blocked{}:
      Escalate{}
    case Unknown{}:
      Inspect{}

def probability(+n: F32) -> Bool:
  F32.is_ge(n, 0.0) && F32.is_le(n, 1.0)

def noul(value: F32) -> Bool:
  probability(value)

type Probability is Data:
  Probability{key: String, value: F32}

def count(keys: List<&2, String>, +key: String) -> Nat:
  match keys:
    case Nil{}:
      0n
    case Con{head, tail}:
      Nat.add(bit(String.eq(head, key)), count(tail, key))

def unique(keys: List<&2, String>) -> Bool:
  match keys:
    case Nil{}:
      True{}
    case Con{head, +tail}:
      Nat.is_eq(count(tail, head), 0n) && unique(tail)

def names(rows: List<&2, Probability>) -> List<&2, String>:
  match rows:
    case Nil{}:
      Nil{}
    case Con{Probability{key, value}, tail}:
      Con{key, names(tail)}

def all_probabilities(rows: List<&2, Probability>) -> Bool:
  match rows:
    case Nil{}:
      True{}
    case Con{Probability{key, value}, tail}:
      probability(value) && all_probabilities(tail)

def mass(rows: List<&2, Probability>) -> F32:
  match rows:
    case Nil{}:
      0.0
    case Con{Probability{key, value}, tail}:
      F32.add(value, mass(tail))

def covered(keys: List<&2, String>, +actual: List<&2, String>) -> Bool:
  match keys:
    case Nil{}:
      True{}
    case Con{head, tail}:
      Nat.is_eq(count(actual, head), 1n) && covered(tail, actual)

def distribution(+keys: List<&2, String>, +rows: List<&2, Probability>) -> Bool:
  +actual = names(rows)
  unique(keys) && unique(actual) &&
  Nat.is_eq(List.length(&2, String, keys), List.length(&2, String, actual)) &&
  covered(keys, actual) && all_probabilities(rows) &&
  F32.is_le(F32.abs(F32.sub(mass(rows), 1.0)), 0.02)

def choice(+keys: List<&2, String>, selected: String, confidence: F32, rows: List<&2, Probability>) -> Bool:
  Nat.is_ge(List.length(&2, String, keys), 1n) &&
  Nat.is_le(List.length(&2, String, keys), 255n) &&
  Nat.is_eq(count(keys, selected), 1n) && probability(confidence) && distribution(keys, rows)

def indexes(n: Nat) -> List<&2, String>:
  match n:
    case 0n:
      Nil{}
    case 1n+predecessor:
      +p = predecessor
      Con{Nat.show(p), indexes(p)}

def score(+levels: Nat, +value: F32, confidence: F32, rows: List<&2, Probability>) -> Bool:
  Nat.is_ge(levels, 2n) && Nat.is_le(levels, 10n) &&
  F32.is_ge(value, 0.0) && F32.is_le(value, F32.from_nat(Nat.sub(levels, 1n))) &&
  probability(confidence) && distribution(indexes(levels), rows)

def keep(line: String, wanted: Bool) -> Maybe<&2, String>:
  match wanted:
    case False{}:
      None{}
    case True{}:
      Some{line}

def monitor(line: String, literal: String, previous: String) -> Maybe<&2, String>:
  +text = String.trim(line)
  keep(text, Bool.not(String.is_empty(text)) && String.contains(text, literal) && Bool.not(String.eq(text, previous)))

type Batch is Data:
  Batch{lines: List<&2, String>, omitted: Nat, clipped: Nat}

def batch_push(batch: Batch, +line: String, +capacity: Nat) -> Batch:
  match batch:
    case Batch{lines, omitted, clipped}:
      +next = {Con{String.take(line, 100n), lines} : List<&2, String>}
      Batch{List.take(&2, String, next, capacity), Nat.add(omitted, bit(Nat.is_gt(List.length(&2, String, next), capacity))), Nat.add(clipped, bit(Nat.is_gt(String.length(line), 100n)))}
