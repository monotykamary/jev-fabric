import Base

# Raw boundary representation, not evidence that the transport honored it.
def RawBytes() -> Type:
  U32 & (U32 & (List<&2, U32> & List<&2, U32>))


# Curl config is not JSON. Only these escapes have curl-config semantics.
def escaped(c: Char) -> String:
  match c:
    case '"':
      "\\\""
    case '\\':
      "\\\\"
    case '\n':
      "\\n"
    case '\r':
      "\\r"
    case '\t':
      "\\t"
    case '\u{b}':
      "\\v"
    case other:
      SCon{other, SNil{}}

# Accumulates escaped characters in reverse, then reverses once at the end.
def config_body(s: String, acc: List<&2, Char>) -> String:
  match s:
    case SNil{}:
      String.from_list(List.reverse(&2, Char, acc))
    case SCon{head, tail}:
      escaped_reversed = List.reverse(&2, Char, String.to_list(escaped(head)))
      config_body(tail, List.append(&2, Char, escaped_reversed, acc))

def quote(s: String) -> String:
  "\"" ++ config_body(s, []) ++ "\""

def visible(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{h, t}:
      +n = Char.to_u32(h)
      U32.is_ge(n, 33) && U32.is_le(n, 126) && visible(t)

def no_nul(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{h, t}:
      U32.is_ne(Char.to_u32(h), 0) && no_nul(t)

def key_valid(+key: String) -> Bool:
  Bool.not(String.is_empty(key)) && Nat.is_le(String.length(key), 16384n) && visible(key)

def config(url: String, key: String, body: String, +ms: U32) -> String:
  seconds = U32.div(U32.add(ms, 999), 1000)
  "url = " ++ quote(url) ++ "\nrequest = \"POST\"\n" ++
  "header = \"Content-Type: application/json\"\n" ++
  "header = " ++ quote("Authorization: Bearer " ++ key) ++ "\n" ++
  "data-binary = " ++ quote(body) ++ "\nmax-time = " ++ U32.show(seconds) ++ "\n"

def digit(+n: U32) -> Bool:
  U32.is_ge(n, 48) && U32.is_le(n, 57)

def http_status(
  code: U32,
  bytes: List<&2, U32>,
  ok: Bool,
) -> Result<&1, &1, U32 & String, List<&2, U32>>:
  match ok:
    case True{}:
      Done{List.reverse(&2, U32, bytes)}
    case False{}:
      Fail{(1, "Jev HTTP " ++ U32.show(code) ++ "; no automatic retry")}

def status_digits(
  a: U32,
  b: U32,
  c: U32,
  bytes: List<&2, U32>,
  valid: Bool,
) -> Result<&1, &1, U32 & String, List<&2, U32>>:
  match valid:
    case False{}:
      Fail{(1, "Invalid HTTP transport status")}
    case True{}:
      hundreds = U32.mul(U32.sub(a, 48), 100)
      tens = U32.mul(U32.sub(b, 48), 10)
      +code = U32.add(U32.add(hundreds, tens), U32.sub(c, 48))
      http_status(code, bytes, U32.is_ge(code, 200) && U32.is_lt(code, 300))

# curl's --write-out appends "\n%{http_code}", so the reversed capture starts with
# the status digits (last digit first) followed by that newline.
def status(bytes: List<&2, U32>) -> Result<&1, &1, U32 & String, List<&2, U32>>:
  match bytes:
    case Con{+c, Con{+b, Con{+a, Con{nl, rest}}}}:
      status_digits(a, b, c, rest, digit(a) && digit(b) && digit(c) && U32.is_eq(nl, 10))
    case other:
      Fail{(1, "Missing HTTP transport status")}

def capture_ok(bytes: List<&2, U32>, ok: Bool) -> Result<&1, &1, U32 & String, List<&2, U32>>:
  match ok:
    case False{}:
      Fail{(1, "Jev transport failed, was interrupted, or exceeded its output bound")}
    case True{}:
      status(List.reverse(&2, U32, bytes))

def captured(
  result: Result<&1, &1, U32 & String, RawBytes>,
) -> Result<&1, &1, U32 & String, List<&2, U32>>:
  match result:
    case Fail{error}:
      Fail{(1, "Jev transport could not start")}
    case Done{raw}:
      (code, (flags, (bytes, errors))) = raw
      capture_ok(bytes, U32.is_eq(code, 0) && U32.is_eq(flags, 0))

type Request is Data:
  Request{config: String, timeout: U32}

# There are no caller/credential inputs to argv construction.
def argv() -> List<String>:
  ["curl", "--disable", "--silent", "--show-error", "--globoff", "--proto", "=https",
   "--proxy", "", "--noproxy", "*", "--connect-timeout", "10", "--max-filesize", "1048576",
   "--write-out", "\n%{http_code}", "--config", "-"]

def request_allowed(
  url: String,
  key: String,
  body: String,
  +timeout: U32,
  allowed: Bool,
) -> Result<&1, &1, U32 & String, Request>:
  match allowed:
    case False{}:
      Fail{(1, "Invalid HTTPS request configuration")}
    case True{}:
      Done{Request{config(url, key, body, timeout), timeout}}

def request(
  +url: String,
  +key: String,
  +body: String,
  +timeout: U32,
) -> Result<&1, &1, U32 & String, Request>:
  request_allowed(
    url,
    key,
    body,
    timeout,
    String.starts_with(url, "https://")
      && visible(url)
      && Nat.is_le(String.length(url), 4096n)
      && key_valid(key)
      && String.starts_with(body, "{")
      && no_nul(body)
      && Nat.is_le(String.length(body), 1048576n)
      && U32.is_ge(timeout, 1)
      && U32.is_le(timeout, 3600000),
  )
