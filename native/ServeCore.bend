import Base
import ./Codec.bend as Codec
import ./Json.bend as Json
import ./Wire.bend as Wire
import ./Streams.bend as Streams
import ./TimeCore.bend as Time
import ./vendor/strict-json/json.bend as J

# Pure policy for `serve`: one JSON request per input line, one JSON response per
# output line. Serve.bend performs the reads, prints and subprocess calls.
def Error() -> Type:
  U32 & String

def protocol() -> U32:
  1

# A request line has the strict JSON bound; a longer partial line ends the session.
def line_max() -> U32:
  1048576

# stdout and stderr each capture up to this many bytes from a CLI child.
def capture_max() -> U32:
  1048577

# 64 argv entries per child, less the longest CLI prefix (exec's seven).
def argv_max() -> Nat:
  57n

# Time a CLI child keeps after its own deadline to print its receipt.
def grace() -> U32:
  2000

# Upper bound for status, events, stop and start's readiness handshake.
def control_max() -> U32:
  15000

# A session ends after this many input reads; each read returns at least one byte.
def reads_max() -> Nat:
  16777216n

# ---------------------------------------------------------------------------
# Line framing. `pending` holds the current partial line newest first.

type Framed is Data:
  Framed{lines: List<&2, List<&2, U32>>, pending: List<&2, U32>, size: U32}

# A finished line in reading order, without a CRLF carriage return.
def line(pending: List<&2, U32>) -> List<&2, U32>:
  match pending:
    case Con{13, rest}:
      List.reverse(&2, U32, rest)
    case other:
      List.reverse(&2, U32, other)

def frame(
  bytes: List<&2, U32>,
  pending: List<&2, U32>,
  +size: U32,
  done: List<&2, List<&2, U32>>,
) -> Framed:
  match bytes:
    case Nil{}:
      Framed{List.reverse(&2, List<&2, U32>, done), pending, size}
    case Con{10, rest}:
      frame(rest, Nil{}, 0, Con{line(pending), done})
    case Con{b, rest}:
      frame(rest, Con{b, pending}, (size + 1 : U32), done)

# The unterminated last line at end of input, if any.
def last(pending: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match pending:
    case Nil{}:
      Nil{}
    case other:
      [line(other)]

# ---------------------------------------------------------------------------
# Session options: serve [max-evaluations [max-tokens]], defaults as for `jev`.

def counted(value: Maybe<&2, U32>) -> Result<&1, &1, Error, U32>:
  match value:
    case None{}:
      Fail{(2, "serve budgets must be integers: [max-evaluations [max-tokens]]")}
    case Some{n}:
      Done{n}

def count(raw: String) -> Result<&1, &1, Error, U32>:
  counted(U32.read(raw))

def budget(args: List<String>) -> Result<&1, &1, Error, U32 & U32>:
  match args:
    case Nil{}:
      Done{(1, 100000)}
    case Con{calls, Nil{}}:
      do Result<&1, &1, Error, U32 & U32>:
        n : U32 <- count(calls)
        return (n, 100000)
    case Con{calls, Con{tokens, Nil{}}}:
      do Result<&1, &1, Error, U32 & U32>:
        n : U32 <- count(calls)
        t : U32 <- count(tokens)
        return (n, t)
    case other:
      Fail{(2, "usage: serve [--timeout-ms N] [max-evaluations [max-tokens]]")}

def banner(version: String, +timeout: U32, +calls: U32, +tokens: U32) -> String:
  "{\"ready\":{\"protocol\":" ++ U32.show(protocol())
    ++ ",\"version\":" ++ Json.quote(version)
    ++ ",\"timeoutMs\":" ++ U32.show(timeout)
    ++ ",\"maxEvaluations\":" ++ U32.show(calls)
    ++ ",\"maxTokens\":" ++ U32.show(tokens)
    ++ "}}"

# ---------------------------------------------------------------------------
# Requests.

type Op is Data:
  Exec{argv: List<&2, String>, input: String, timeout: Maybe<&2, U32>}
  Start{argv: List<&2, String>, timeout: Maybe<&2, U32>}
  Status{job: String}
  Events{job: String, after: U32}
  Wait{job: String, timeout: Maybe<&2, U32>}
  Stop{job: String}
  Watch{job: String, literal: String, timeout: Maybe<&2, U32>}
  Validate{request: J.JSON}
  Evaluate{request: J.JSON, timeout: Maybe<&2, U32>}

def fail(message: String) -> Error:
  (2, message)

def object(value: J.JSON) -> Result<&1, &1, Error, List<&2, J.JSON>>:
  match value:
    case J.Obj{fields}:
      Done{fields}
    case other:
      Fail{fail("request must be a JSON object")}

# The id to echo: a string or number, else null. Validation reports a bad id.
def id_value(found: Maybe<&2, J.JSON>) -> J.JSON:
  match found:
    case Some{J.Str{s}}:
      J.Str{s}
    case Some{J.Num{lex}}:
      J.Num{lex}
    case other:
      J.Null{}

def id(value: J.JSON) -> J.JSON:
  id_value(Codec.field(value, "id"))

def id_valid(found: Maybe<&2, J.JSON>) -> Result<&1, &1, Error, Unit>:
  match found:
    case None{}:
      Done{Unit{}}
    case Some{J.Str{s}}:
      Codec.guard(Nat.is_le(String.length(s), 128n), "id must be at most 128 characters")
    case Some{J.Num{lex}}:
      Done{Unit{}}
    case other:
      Fail{fail("id must be a string or number")}

def found(value: Maybe<&2, J.JSON>, key: String) -> Result<&1, &1, Error, J.JSON>:
  match value:
    case None{}:
      Fail{fail("missing field: " ++ key)}
    case Some{v}:
      Done{v}

def need(fields: List<&2, J.JSON>, +key: String) -> Result<&1, &1, Error, J.JSON>:
  found(Codec.find_field(fields, key), key)

def string(value: J.JSON, +key: String) -> Result<&1, &1, Error, String>:
  match value:
    case J.Str{s}:
      Done{s}
    case other:
      Fail{fail(key ++ " must be a string")}

def text(fields: List<&2, J.JSON>, +key: String) -> Result<&1, &1, Error, String>:
  do Result<&1, &1, Error, String>:
    value : J.JSON <- need(fields, key)
    string(value, key)

def optional_text(found: Maybe<&2, J.JSON>, +key: String) -> Result<&1, &1, Error, String>:
  match found:
    case None{}:
      Done{""}
    case Some{value}:
      string(value, key)

def job_if(job: String, bad: Bool) -> Result<&1, &1, Error, String>:
  match bad:
    case True{}:
      Fail{fail("job must be an id returned by start")}
    case False{}:
      Done{job}

# An id can never start with "-", so it is never read as a CLI option.
def job_checked(+job: String) -> Result<&1, &1, Error, String>:
  job_if(job, String.is_empty(job) || String.starts_with(job, "-"))

def job(fields: List<&2, J.JSON>) -> Result<&1, &1, Error, String>:
  do Result<&1, &1, Error, String>:
    raw : String <- text(fields, "job")
    job_checked(raw)

def timeout_error(max: U32) -> Error:
  fail("timeoutMs must be an integer from 1 to " ++ U32.show(max))

def timeout_parsed(parsed: Result<&1, &1, Error, U32>, max: U32) -> Result<&1, &1, Error, Maybe<&2, U32>>:
  match parsed:
    case Fail{e}:
      Fail{timeout_error(max)}
    case Done{ms}:
      Done{Some{ms}}

def timeout_value(value: J.JSON, +max: U32) -> Result<&1, &1, Error, Maybe<&2, U32>>:
  match value:
    case J.Num{lex}:
      timeout_parsed(Time.parse(lex, max), max)
    case other:
      Fail{timeout_error(max)}

def timeout_found(value: Maybe<&2, J.JSON>, max: U32) -> Result<&1, &1, Error, Maybe<&2, U32>>:
  match value:
    case None{}:
      Done{None{}}
    case Some{v}:
      timeout_value(v, max)

def timeout(fields: List<&2, J.JSON>, max: U32) -> Result<&1, &1, Error, Maybe<&2, U32>>:
  timeout_found(Codec.find_field(fields, "timeoutMs"), max)

def cursor_error() -> Error:
  fail("after must be an event sequence number")

def cursor_fit(n: Nat, fits: Bool) -> Result<&1, &1, Error, U32>:
  match fits:
    case True{}:
      Done{U32.from_nat(n)}
    case False{}:
      Fail{cursor_error()}

def cursor_read(value: Maybe<&2, Nat>) -> Result<&1, &1, Error, U32>:
  match value:
    case Some{+n}:
      cursor_fit(n, Nat.is_le(n, 4294967295n))
    case None{}:
      Fail{cursor_error()}

def cursor_value(value: J.JSON) -> Result<&1, &1, Error, U32>:
  match value:
    case J.Num{lex}:
      cursor_read(Nat.read(lex))
    case other:
      Fail{cursor_error()}

def cursor_found(value: Maybe<&2, J.JSON>) -> Result<&1, &1, Error, U32>:
  match value:
    case None{}:
      Done{0}
    case Some{v}:
      cursor_value(v)

def cursor(fields: List<&2, J.JSON>) -> Result<&1, &1, Error, U32>:
  cursor_found(Codec.find_field(fields, "after"))

def strings(items: List<&2, J.JSON>) -> Result<&1, &1, Error, List<&2, String>>:
  match items:
    case Nil{}:
      Done{Nil{}}
    case Con{item, rest}:
      do Result<&1, &1, Error, List<&2, String>>:
        head : String <- string(item, "argv entries")
        tail : List<&2, String> <- strings(rest)
        return Con{head, tail}

def argv_error() -> Error:
  fail("argv must be an array of 1 to 57 strings")

def argv_named(argv: List<&2, String>, empty: Bool) -> Result<&1, &1, Error, List<&2, String>>:
  match empty:
    case True{}:
      Fail{fail("argv[0] must name a command")}
    case False{}:
      Done{argv}

def argv_sized(argv: List<&2, String>, fits: Bool) -> Result<&1, &1, Error, List<&2, String>>:
  match argv fits:
    case Con{+first, rest} True{}:
      argv_named(Con{first, rest}, String.is_empty(first))
    case _ _:
      Fail{argv_error()}

def argv_checked(+argv: List<&2, String>) -> Result<&1, &1, Error, List<&2, String>>:
  argv_sized(argv, Nat.is_le(List.length(&2, String, argv), argv_max()))

def argv_value(value: J.JSON) -> Result<&1, &1, Error, List<&2, String>>:
  match value:
    case J.Arr{items}:
      do Result<&1, &1, Error, List<&2, String>>:
        list : List<&2, String> <- strings(items)
        argv_checked(list)
    case other:
      Fail{argv_error()}

def argv(fields: List<&2, J.JSON>) -> Result<&1, &1, Error, List<&2, String>>:
  do Result<&1, &1, Error, List<&2, String>>:
    value : J.JSON <- need(fields, "argv")
    argv_value(value)

# The first member not named in `keys`, if any.
def unknown(fields: List<&2, J.JSON>, +keys: List<&2, String>) -> Maybe<&2, String>:
  match fields:
    case Nil{}:
      None{}
    case Con{J.Member{+key, value}, tail}:
      Bool.pick(Maybe<&2, String>, Codec.contains(keys, key), unknown(tail, keys), Some{key})
    case Con{other, tail}:
      Some{""}

def known(extra: Maybe<&2, String>) -> Result<&1, &1, Error, Unit>:
  match extra:
    case None{}:
      Done{Unit{}}
    case Some{key}:
      Fail{fail("unknown request field: " ++ key)}

# Unknown fields are rejected so that a misspelled option never goes unnoticed.
def allowed(fields: List<&2, J.JSON>, +keys: List<&2, String>) -> Result<&1, &1, Error, Unit>:
  known(unknown(fields, Con{"id", Con{"op", keys}}))

def exec_op(+fields: List<&2, J.JSON>) -> Result<&1, &1, Error, Op>:
  do Result<&1, &1, Error, Op>:
    allowed(fields, ["argv", "stdin", "timeoutMs"])
    command : List<&2, String> <- argv(fields)
    input : String <- optional_text(Codec.find_field(fields, "stdin"), "stdin")
    ms : Maybe<&2, U32> <- timeout(fields, 3600000)
    return Exec{command, input, ms}

def start_op(+fields: List<&2, J.JSON>) -> Result<&1, &1, Error, Op>:
  do Result<&1, &1, Error, Op>:
    allowed(fields, ["argv", "timeoutMs"])
    command : List<&2, String> <- argv(fields)
    ms : Maybe<&2, U32> <- timeout(fields, 3600000)
    return Start{command, ms}

def status_op(+fields: List<&2, J.JSON>) -> Result<&1, &1, Error, Op>:
  do Result<&1, &1, Error, Op>:
    allowed(fields, ["job"])
    id : String <- job(fields)
    return Status{id}

def events_op(+fields: List<&2, J.JSON>) -> Result<&1, &1, Error, Op>:
  do Result<&1, &1, Error, Op>:
    allowed(fields, ["job", "after"])
    id : String <- job(fields)
    after : U32 <- cursor(fields)
    return Events{id, after}

def wait_op(+fields: List<&2, J.JSON>) -> Result<&1, &1, Error, Op>:
  do Result<&1, &1, Error, Op>:
    allowed(fields, ["job", "timeoutMs"])
    id : String <- job(fields)
    ms : Maybe<&2, U32> <- timeout(fields, 3600000)
    return Wait{id, ms}

def stop_op(+fields: List<&2, J.JSON>) -> Result<&1, &1, Error, Op>:
  do Result<&1, &1, Error, Op>:
    allowed(fields, ["job"])
    id : String <- job(fields)
    return Stop{id}

def watch_op(+fields: List<&2, J.JSON>) -> Result<&1, &1, Error, Op>:
  do Result<&1, &1, Error, Op>:
    allowed(fields, ["job", "literal", "timeoutMs"])
    id : String <- job(fields)
    literal : String <- text(fields, "literal")
    ms : Maybe<&2, U32> <- timeout(fields, 300000)
    return Watch{id, literal, ms}

def validate_op(+fields: List<&2, J.JSON>) -> Result<&1, &1, Error, Op>:
  do Result<&1, &1, Error, Op>:
    allowed(fields, ["request"])
    request : J.JSON <- need(fields, "request")
    return Validate{request}

def jev_op(+fields: List<&2, J.JSON>) -> Result<&1, &1, Error, Op>:
  do Result<&1, &1, Error, Op>:
    allowed(fields, ["request", "timeoutMs"])
    request : J.JSON <- need(fields, "request")
    ms : Maybe<&2, U32> <- timeout(fields, 3600000)
    return Evaluate{request, ms}

def op(name: String, fields: List<&2, J.JSON>) -> Result<&1, &1, Error, Op>:
  match name:
    case "exec":
      exec_op(fields)
    case "start":
      start_op(fields)
    case "status":
      status_op(fields)
    case "events":
      events_op(fields)
    case "wait":
      wait_op(fields)
    case "stop":
      stop_op(fields)
    case "watch":
      watch_op(fields)
    case "validate":
      validate_op(fields)
    case "jev":
      jev_op(fields)
    case other:
      Fail{fail("unknown op: use exec, start, status, events, wait, stop, watch, validate or jev")}

def request(value: J.JSON) -> Result<&1, &1, Error, Op>:
  do Result<&1, &1, Error, Op>:
    +fields : List<&2, J.JSON> <- object(value)
    id_valid(Codec.find_field(fields, "id"))
    name : String <- text(fields, "op")
    op(name, fields)

# ---------------------------------------------------------------------------
# CLI child plans. Each process and job operation re-enters this executable, so
# a failing command costs one response, never the session.

type Defaults is Data:
  Defaults{work: U32, wait: U32, watch: U32}

type Call is Data:
  Call{argv: List<&2, String>, input: String, timeout: U32, many: Bool}

def expired() -> Error:
  (124, "serve deadline expired")

# The child's own deadline: the requested or default time, within the session's
# remaining time less the receipt grace. Zero means no time is left.
def or(value: Maybe<&2, U32>, fallback: U32) -> U32:
  match value:
    case None{}:
      fallback
    case Some{v}:
      v

def left(+remaining: U32) -> U32:
  Bool.pick(U32, U32.is_gt(remaining, grace()), U32.sub(remaining, grace()), 0)

def inner(requested: Maybe<&2, U32>, fallback: U32, remaining: U32) -> U32:
  U32.min(or(requested, fallback), left(remaining))

def timed_if(argv: List<&2, String>, input: String, ms: U32, many: Bool, zero: Bool) -> Result<&1, &1, Error, Call>:
  match zero:
    case True{}:
      Fail{expired()}
    case False{}:
      Done{Call{argv, input, (ms + grace() : U32), many}}

def timed(argv: List<&2, String>, input: String, +ms: U32, many: Bool) -> Result<&1, &1, Error, Call>:
  timed_if(argv, input, ms, many, U32.is_eq(ms, 0))

def control_if(argv: List<&2, String>, remaining: U32, many: Bool, ok: Bool) -> Result<&1, &1, Error, Call>:
  match ok:
    case True{}:
      Done{Call{argv, "", U32.min(remaining, control_max()), many}}
    case False{}:
      Fail{expired()}

def control(argv: List<&2, String>, +remaining: U32, many: Bool) -> Result<&1, &1, Error, Call>:
  control_if(argv, remaining, many, U32.is_gt(remaining, grace()))

# Process effects take an affine argv list.
def owned(args: List<&2, String>) -> List<String>:
  match args:
    case Nil{}:
      Nil{}
    case Con{head, tail}:
      Con{head, owned(tail)}

def cli(self: String, args: List<&2, String>) -> List<&2, String>:
  Con{self, Con{"--", args}}

def work(defaults: Defaults) -> U32:
  match defaults:
    case Defaults{work, wait, watch}:
      work

def wait(defaults: Defaults) -> U32:
  match defaults:
    case Defaults{work, wait, watch}:
      wait

def watch(defaults: Defaults) -> U32:
  match defaults:
    case Defaults{work, wait, watch}:
      watch

def plan(+self: String, op: Op, defaults: Defaults, +remaining: U32) -> Result<&1, &1, Error, Call>:
  match op:
    case Exec{argv, input, requested}:
      +ms : U32 = inner(requested, 3600000, remaining)
      prefix : List<&2, String> = ["exec", "--timeout-ms", U32.show(ms), "--stdin", "--"]
      timed(cli(self, List.append(&2, String, prefix, argv)), input, ms, False{})
    case Start{argv, requested}:
      lifetime : U32 = or(requested, work(defaults))
      prefix : List<&2, String> = ["start", "--timeout-ms", U32.show(lifetime), "--"]
      control(cli(self, List.append(&2, String, prefix, argv)), remaining, False{})
    case Status{job}:
      control(cli(self, ["status", job]), remaining, False{})
    case Events{job, after}:
      control(cli(self, ["events", job, U32.show(after)]), remaining, True{})
    case Wait{job, requested}:
      +ms : U32 = inner(requested, wait(defaults), remaining)
      timed(cli(self, ["wait", "--timeout-ms", U32.show(ms), job]), "", ms, False{})
    case Stop{job}:
      control(cli(self, ["stop", job]), remaining, False{})
    case Watch{job, literal, requested}:
      +ms : U32 = inner(requested, watch(defaults), remaining)
      timed(cli(self, ["watch", "--timeout-ms", U32.show(ms), job, literal]), "", ms, True{})
    case Validate{request}:
      Fail{fail("validate runs in process")}
    case Evaluate{request, requested}:
      Fail{fail("jev runs in process")}

# ---------------------------------------------------------------------------
# CLI child output: JSON lines on stdout, or an error on stderr.

def values(lines: List<&2, List<&2, U32>>) -> Result<&1, &1, Error, List<&2, J.JSON>>:
  match lines:
    case Nil{}:
      Done{Nil{}}
    case Con{Nil{}, rest}:
      values(rest)
    case Con{bytes, rest}:
      do Result<&1, &1, Error, List<&2, J.JSON>>:
        head : J.JSON <- Codec.read_bytes(bytes)
        tail : List<&2, J.JSON> <- values(rest)
        return Con{head, tail}

def message_if(text: String, empty: Bool) -> String:
  match empty:
    case True{}:
      "jev-fabric command failed"
    case False{}:
      String.take(text, 1024n)

def message_text(+text: String) -> String:
  message_if(text, String.is_empty(text))

def message(err: List<&2, U32>) -> String:
  message_text(String.trim(Streams.finish(Streams.feed(err, Streams.empty()))))

def failed(+code: U32, err: List<&2, U32>) -> Result<&1, &1, Error, String>:
  Fail{(Bool.pick(U32, U32.is_eq(code, 0), 1, code), message(err))}

def result(items: List<&2, J.JSON>, many: Bool, +code: U32, err: List<&2, U32>) -> Result<&1, &1, Error, String>:
  match items many:
    case all True{}:
      Codec.encode(J.Arr{all})
    case Con{first, rest} False{}:
      Codec.encode(first)
    case Nil{} False{}:
      failed(code, err)

def framed_output(framed: Framed, +code: U32, err: List<&2, U32>, many: Bool) -> Result<&1, &1, Error, String>:
  match framed:
    case Framed{lines, pending, size}:
      do Result<&1, &1, Error, String>:
        items : List<&2, J.JSON> <- values(List.append(&2, List<&2, U32>, lines, last(pending)))
        result(items, many, code, err)

def output(code: U32, out: List<&2, U32>, err: List<&2, U32>, many: Bool) -> Result<&1, &1, Error, String>:
  framed_output(frame(out, Nil{}, 0, Nil{}), code, err, many)

def flagged(
  code: U32,
  out: List<&2, U32>,
  err: List<&2, U32>,
  many: Bool,
  clean: Bool,
  timed_out: Bool,
) -> Result<&1, &1, Error, String>:
  match clean timed_out:
    case True{} _:
      output(code, out, err, many)
    case False{} True{}:
      Fail{expired()}
    case False{} False{}:
      Fail{(1, "jev-fabric command output exceeded 1 MiB")}

# Flag bits from posix.c: 1 timed out, 2 stdout cut, 4 stderr cut, 8 cancelled.
def outcome(raw: Result<&1, &1, Error, U32 & (U32 & (List<&2, U32> & List<&2, U32>))>, many: Bool) -> Result<&1, &1, Error, String>:
  match raw:
    case Fail{e}:
      (code, text) = e
      Fail{(code, "jev-fabric could not run the request: " ++ text)}
    case Done{captured}:
      (code, (+flags, (out, err))) = captured
      flagged(code, out, err, many, U32.is_eq(flags, 0), U32.is_ne((flags .&. 1 : U32), 0))

# ---------------------------------------------------------------------------
# In-process operations and responses.

def unreadable(value: Result<&1, &1, Error, J.JSON>) -> Result<&1, &1, Error, J.JSON>:
  match value:
    case Fail{e}:
      (code, message) = e
      Fail{(code, "request line is not strict JSON: " ++ message)}
    case Done{v}:
      Done{v}

def validated(request: J.JSON) -> Result<&1, &1, Error, String>:
  do Result<&1, &1, Error, String>:
    checked : J.JSON <- Wire.validate_request(request)
    Codec.encode(checked)

def encoded_or_null(value: Result<&1, &1, Error, String>) -> String:
  match value:
    case Fail{e}:
      "null"
    case Done{text}:
      text

def encoded(value: J.JSON) -> String:
  encoded_or_null(Codec.encode(value))

def respond(id: J.JSON, result: Result<&1, &1, Error, String>) -> String:
  match result:
    case Done{text}:
      "{\"id\":" ++ encoded(id) ++ ",\"ok\":true,\"result\":" ++ text ++ "}"
    case Fail{e}:
      (code, message) = e
      "{\"id\":" ++ encoded(id) ++ ",\"ok\":false,\"error\":{\"code\":" ++ U32.show(code)
        ++ ",\"message\":" ++ Json.quote(message) ++ "}}"
