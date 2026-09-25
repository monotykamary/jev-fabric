import Base
import ./vendor/strict-json/json.bend as J

def Value() -> Data:
  J.JSON

def guard(ok: Bool, message: String) -> Result<&1, &1, U32 & String, Unit>:
  match ok:
    case True{}:
      Done{Unit{}}
    case False{}:
      Fail{(22, message)}

def width(+code: U32) -> U32:
  (1 + Bool.pick(U32, U32.is_ge(code, 128), 1, 0) + Bool.pick(U32, U32.is_ge(code, 2048), 1, 0) + Bool.pick(U32, U32.is_ge(code, 65536), 1, 0) : U32)

# Count bytes with a decreasing budget, rejecting invalid scalars before consumers.
def string_cost(s: String, +budget: U32) -> Result<&1, &1, U32 & String, U32>:
  match s:
    case SNil{}:
      Done{budget}
    case SCon{Chr{+code}, tail}:
      do Result<&1, &1, U32 & String, U32>:
        guard(J.JSON.is_scalar(code) && U32.is_ge(budget, width(code)), "JSON string/byte limit")
        string_cost(tail, U32.sub(budget, width(code)))

type Scan is Data:
  Scan{quoted: Bool, escaped: Bool, depth: U32, work: U32}

def scan_step(state: Scan, +c: Char) -> Scan:
  match state:
    case Scan{True{}, True{}, depth, work}:
      Scan{True{}, False{}, depth, work}
    case Scan{True{}, False{}, depth, work}:
      Scan{Bool.not(J.JSON.is_quote(c)), J.JSON.is_slash(c), depth, work}
    case Scan{False{}, escaped, depth, work}:
      Scan{J.JSON.is_quote(c), False{}, U32.sub(U32.add(depth, Bool.pick(U32, J.JSON.is_lbrk(c) || J.JSON.is_lbra(c), 1, 0)), Bool.pick(U32, J.JSON.is_rbrk(c) || J.JSON.is_rbra(c), 1, 0)), U32.add(work, Bool.pick(U32, J.JSON.is_ws(c), 0, 1))}

def scan_ok(state: Scan) -> Bool:
  match state:
    case Scan{quoted, escaped, depth, work}:
      U32.is_le(depth, 64) && U32.is_le(work, 32768)

def scan(s: String, state: Scan, +bytes: U32) -> Result<&1, &1, U32 & String, Unit>:
  match s:
    case SNil{}:
      Done{Unit{}}
    case SCon{+c, rest}:
      do Result<&1, &1, U32 & String, Unit>:
        guard(J.JSON.is_scalar(Char.to_u32(c)), "invalid Unicode scalar")
        guard(U32.is_ge(bytes, width(Char.to_u32(c))), "JSON exceeds 1 MiB")
        +next : Scan = scan_step(state, c)
        guard(scan_ok(next), "JSON depth/work limit")
        scan(rest, next, U32.sub(bytes, width(Char.to_u32(c))))

def contains(keys: List<&2, String>, +key: String) -> Bool:
  match keys:
    case Nil{}:
      False{}
    case Con{head, tail}:
      String.eq(head, key) || contains(tail, key)

type Job is Data:
  Val{value: J.JSON, depth: U32}
  Items{items: List<&2, J.JSON>, depth: U32}
  Fields{fields: List<&2, J.JSON>, depth: U32, seen: List<&2, String>, count: U32}

# Each job consumes fuel. Text and key-comparison work have independent budgets.
def number_matches(parsed: J.JSON, lex: String) -> Result<&1, &1, U32 & String, Unit>:
  match parsed:
    case J.Num{raw}:
      guard(String.eq(lex, raw), "invalid number lexeme")
    case other:
      Fail{(22, "invalid number lexeme")}

def valid(fuel: Nat, jobs: List<&2, Job>, bytes: U32, +cost: U32) -> Result<&1, &1, U32 & String, Unit>:
  match fuel jobs:
    case _ Nil{}:
      Done{Unit{}}
    case 0n _:
      Fail{(22, "JSON node limit")}
    case 1n+f Con{job, rest}:
      match job:
        case Val{value, +depth}:
          match value:
            case J.Null{}:
              valid(f, rest, bytes, cost)
            case J.Boolean{b}:
              valid(f, rest, bytes, cost)
            case J.Str{s}:
              do Result<&1, &1, U32 & String, Unit>:
                left : U32 <- string_cost(s, bytes)
                valid(f, rest, left, cost)
            case J.Num{+lex}:
              do Result<&1, &1, U32 & String, Unit>:
                left : U32 <- string_cost(lex, bytes)
                guard(Nat.is_le(String.length(lex), 1024n), "JSON numeric lexeme limit")
                parsed : J.JSON <- J.JSON.read(lex)
                number_matches(parsed, lex)
                valid(f, rest, left, cost)
            case J.Arr{items}:
              do Result<&1, &1, U32 & String, Unit>:
                guard(U32.is_lt(depth, 64), "JSON depth limit")
                valid(f, Con{Items{items, U32.inc(depth)}, rest}, bytes, cost)
            case J.Obj{fields}:
              do Result<&1, &1, U32 & String, Unit>:
                guard(U32.is_lt(depth, 64), "JSON depth limit")
                valid(f, Con{Fields{fields, U32.inc(depth), Nil{}, 0}, rest}, bytes, cost)
            case J.Member{key, v}:
              Fail{(22, "member outside object")}
        case Items{items, +depth}:
          match items:
            case Nil{}:
              valid(f, rest, bytes, cost)
            case Con{head, tail}:
              valid(f, Con{Val{head, depth}, Con{Items{tail, depth}, rest}}, bytes, cost)
        case Fields{fields, +depth, +seen, +count}:
          match fields:
            case Nil{}:
              valid(f, rest, bytes, cost)
            case Con{J.Member{+key, value}, tail}:
              do Result<&1, &1, U32 & String, Unit>:
                left : U32 <- string_cost(key, bytes)
                +length : U32 = U32.from_nat(String.length(key))
                guard(U32.is_le(length, 256) && U32.is_lt(count, 256), "JSON key limit")
                +charge : U32 = U32.mul(U32.inc(length), U32.inc(count))
                guard(U32.is_ge(cost, charge), "JSON key comparison limit")
                guard(Bool.not(contains(seen, key)), "duplicate JSON key")
                valid(f, Con{Val{value, depth}, Con{Fields{tail, depth, Con{key, seen}, U32.inc(count)}, rest}}, left, U32.sub(cost, charge))
            case Con{other, tail}:
              Fail{(22, "object field is not a member")}

def validate(+value: J.JSON) -> Result<&1, &1, U32 & String, J.JSON>:
  do Result<&1, &1, U32 & String, J.JSON>:
    valid(32768n, [Val{value, 0}], 1048576, 1048576)
    return value

def read(+text: String) -> Result<&1, &1, U32 & String, J.JSON>:
  do Result<&1, &1, U32 & String, J.JSON>:
    scan(text, Scan{False{}, False{}, 0, 0}, 1048576)
    value : J.JSON <- J.JSON.read(text)
    validate(value)

def encode(value: J.JSON) -> Result<&1, &1, U32 & String, String>:
  do Result<&1, &1, U32 & String, String>:
    checked : J.JSON <- validate(value)
    +text : String <- J.JSON.write(checked)
    scan(text, Scan{False{}, False{}, 0, 0}, 1048576)
    return text

def field_pick(found: Bool, value: J.JSON, fallback: Maybe<&2, J.JSON>) -> Maybe<&2, J.JSON>:
  match found:
    case True{}:
      Some{value}
    case False{}:
      fallback

def find_field(fields: List<&2, J.JSON>, +key: String) -> Maybe<&2, J.JSON>:
  match fields:
    case Nil{}:
      None{}
    case Con{J.Member{name, +value}, tail}:
      field_pick(String.eq(name, key), value, find_field(tail, key))
    case Con{other, tail}:
      None{}

def field(value: J.JSON, key: String) -> Maybe<&2, J.JSON>:
  match value:
    case J.Obj{fields}:
      find_field(fields, key)
    case other:
      None{}

def text(value: J.JSON) -> Maybe<&2, String>:
  match value:
    case J.Str{s}:
      Some{s}
    case other:
      None{}

def array(value: J.JSON) -> Maybe<&2, List<&2, J.JSON>>:
  match value:
    case J.Arr{items}:
      Some{items}
    case other:
      None{}

type UTF8 is Data:
  UTF8{remaining: U32, code: U32, minimum: U32, reversed: String}

def utf8_lead(+b: U32, reversed: String) -> Result<&1, &1, U32 & String, UTF8>:
  do Result<&1, &1, U32 & String, UTF8>:
    guard(U32.is_ge(b, 194) && U32.is_le(b, 244), "invalid UTF-8 lead")
    return UTF8{Bool.pick(U32, U32.is_lt(b, 224), 1, Bool.pick(U32, U32.is_lt(b, 240), 2, 3)), U32.mod(b, Bool.pick(U32, U32.is_lt(b, 224), 32, Bool.pick(U32, U32.is_lt(b, 240), 16, 8))), Bool.pick(U32, U32.is_lt(b, 224), 128, Bool.pick(U32, U32.is_lt(b, 240), 2048, 65536)), reversed}

def utf8_start(b: U32, reversed: String, ascii: Bool) -> Result<&1, &1, U32 & String, UTF8>:
  match ascii:
    case True{}:
      Done{UTF8{0, 0, 0, SCon{Chr{b}, reversed}}}
    case False{}:
      utf8_lead(b, reversed)

def utf8_continue(remaining: U32, +code: U32, minimum: U32, reversed: String, last: Bool) -> Result<&1, &1, U32 & String, UTF8>:
  match last:
    case False{}:
      Done{UTF8{remaining, code, minimum, reversed}}
    case True{}:
      do Result<&1, &1, U32 & String, UTF8>:
        guard(U32.is_ge(code, minimum) && J.JSON.is_scalar(code), "noncanonical UTF-8 scalar")
        return UTF8{0, 0, 0, SCon{Chr{code}, reversed}}

def utf8_step(state: UTF8, +b: U32) -> Result<&1, &1, U32 & String, UTF8>:
  match state:
    case UTF8{0, code, minimum, reversed}:
      utf8_start(b, reversed, U32.is_lt(b, 128))
    case UTF8{+remaining, code, minimum, reversed}:
      do Result<&1, &1, U32 & String, UTF8>:
        guard(U32.is_ge(b, 128) && U32.is_le(b, 191), "invalid UTF-8 continuation")
        utf8_continue(U32.sub(remaining, 1), U32.add(U32.mul(code, 64), U32.sub(b, 128)), minimum, reversed, U32.is_eq(remaining, 1))

def utf8(fuel: Nat, bytes: List<&2, U32>, state: UTF8) -> Result<&1, &1, U32 & String, String>:
  match fuel bytes:
    case _ Nil{}:
      match state:
        case UTF8{0, code, minimum, reversed}:
          Done{String.reverse(reversed)}
        case other:
          Fail{(22, "truncated UTF-8")}
    case 0n _:
      Fail{(22, "UTF-8 exceeds 1 MiB")}
    case 1n+f Con{b, tail}:
      do Result<&1, &1, U32 & String, String>:
        next : UTF8 <- utf8_step(state, b)
        utf8(f, tail, next)

def decode_utf8(bytes: List<&2, U32>) -> Result<&1, &1, U32 & String, String>:
  utf8(1048576n, bytes, UTF8{0, 0, 0, SNil{}})

def read_bytes(bytes: List<&2, U32>) -> Result<&1, &1, U32 & String, J.JSON>:
  do Result<&1, &1, U32 & String, J.JSON>:
    decoded : String <- decode_utf8(bytes)
    read(decoded)
