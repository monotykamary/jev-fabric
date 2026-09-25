import Base
import ./ServeCore.bend as Core
import ./Cli.bend as Cli
import ./Codec.bend as Codec
import ./Scope.bend as Scope
import ./Jev.bend as Jev
import ./Host.bend as Host
import ./Process.bend as Process
import ./Time.bend as Time
import ./vendor/strict-json/json.bend as J

# `serve`: a JSONL session over stdin/stdout for callers in any language. One
# affine Jev client (and its warm connection) and one deadline span the session.
# Requests run one at a time, in order. End the session by closing stdin.

def Read() -> Type:
  File & Result<&1, &1, U32 & String, List<&2, U32>>

def Answered() -> Type:
  Jev.Client & Result<&1, &1, U32 & String, String>

# Fixed for the session: this executable, its deadline and the CLI defaults.
type Context is Data:
  Context{self: String, scope: Scope.Budget, defaults: Core.Defaults}

type Loop is Type:
  Serving{input: File, client: Jev.Client, pending: List<&2, U32>, size: U32}
  Ended{code: U32, message: String}

def self(context: Context) -> String:
  match context:
    case Context{self, scope, defaults}:
      self

def scope(context: Context) -> Scope.Budget:
  match context:
    case Context{self, scope, defaults}:
      scope

def defaults(context: Context) -> Core.Defaults:
  match context:
    case Context{self, scope, defaults}:
      defaults

def evaluated(result: Jev.Returned) -> IO(Answered):
  (client, response) = result
  match response:
    case Fail{e}:
      IO.pure(Answered, (client, Fail{e}))
    case Done{value}:
      IO.pure(Answered, (client, Codec.encode(value)))

# Validated here for a precise error; Jev.evaluate validates again before dispatch.
def evaluate_checked(
  +context: Context,
  client: Jev.Client,
  checked: Result<&1, &1, U32 & String, String>,
  +cap: U32,
) -> IO(Answered):
  match checked:
    case Fail{e}:
      IO.pure(Answered, (client, Fail{e}))
    case Done{request}:
      do IO<Answered>:
        result : Jev.Returned <- Scope.evaluate_for(scope(context), client, request, cap)
        evaluated(result)

def run_call(call: Core.Call) -> IO(Result<&1, &1, U32 & String, String>):
  match call:
    case Core.Call{argv, input, timeout, many}:
      do IO<Result<&1, &1, U32 & String, String>>:
        raw : Result<&1, &1, U32 & String, Process.RawBytes> <- Process.capture(
          Core.owned(argv),
          input,
          timeout,
          Core.capture_max(),
        )
        return Core.outcome(raw, many)

def subprocess(client: Jev.Client, plan: Result<&1, &1, U32 & String, Core.Call>) -> IO(Answered):
  match plan:
    case Fail{e}:
      IO.pure(Answered, (client, Fail{e}))
    case Done{call}:
      do IO<Answered>:
        result : Result<&1, &1, U32 & String, String> <- run_call(call)
        return (client, result)

def dispatch(+context: Context, client: Jev.Client, op: Core.Op, +remaining: U32) -> IO(Answered):
  match op:
    case Core.Validate{request}:
      IO.pure(Answered, (client, Core.validated(request)))
    case Core.Evaluate{request, requested}:
      evaluate_checked(context, client, Core.validated(request), Core.or(requested, Time.max_timeout()))
    case other:
      subprocess(client, Core.plan(self(context), other, defaults(context), remaining))

def reply(+id: J.JSON, answered: Answered, expired: Bool) -> IO(Jev.Client & Bool):
  (client, result) = answered
  do IO<Jev.Client & Bool>:
    IO.print(Core.respond(id, result))
    return (client, expired)

# The session deadline is checked before each request; once less than the
# receipt grace remains, that request is refused and the session ends.
def timed(
  +context: Context,
  client: Jev.Client,
  +id: J.JSON,
  op: Core.Op,
  +remaining: U32,
  expired: Bool,
) -> IO(Jev.Client & Bool):
  match expired:
    case True{}:
      reply(id, (client, Fail{Core.expired()}), True{})
    case False{}:
      do IO<Jev.Client & Bool>:
        answered : Answered <- dispatch(context, client, op, remaining)
        reply(id, answered, False{})

def parsed(
  +context: Context,
  client: Jev.Client,
  +id: J.JSON,
  request: Result<&1, &1, U32 & String, Core.Op>,
) -> IO(Jev.Client & Bool):
  match request:
    case Fail{e}:
      reply(id, (client, Fail{e}), False{})
    case Done{op}:
      do IO<Jev.Client & Bool>:
        +remaining : U32 <- Scope.remaining(scope(context), Time.max_timeout())
        timed(context, client, id, op, remaining, Bool.not(U32.is_gt(remaining, Core.grace())))

def decoded(
  +context: Context,
  client: Jev.Client,
  value: Result<&1, &1, U32 & String, J.JSON>,
) -> IO(Jev.Client & Bool):
  match value:
    case Fail{e}:
      reply(J.Null{}, (client, Fail{e}), False{})
    case Done{+request}:
      parsed(context, client, Core.id(request), Core.request(request))

def answer(+context: Context, client: Jev.Client, line: List<&2, U32>) -> IO(Jev.Client & Bool):
  match line:
    case Nil{}:
      IO.pure(Jev.Client & Bool, (client, False{}))
    case bytes:
      decoded(context, client, Core.unreadable(Codec.read_bytes(bytes)))

def next(pair: Jev.Client & Bool, k: Jev.Client -> Bool -> IO(Jev.Client & Bool)) -> IO(Jev.Client & Bool):
  (client, stop) = pair
  k(client, stop)

# Answers each complete line in order; after an expiry the rest are dropped.
def answer_all(
  lines: List<&2, List<&2, U32>>,
  +context: Context,
  client: Jev.Client,
  stop: Bool,
) -> IO(Jev.Client & Bool):
  match lines stop:
    case _ True{}:
      IO.pure(Jev.Client & Bool, (client, True{}))
    case Nil{} False{}:
      IO.pure(Jev.Client & Bool, (client, False{}))
    case Con{line, rest} False{}:
      do IO<Jev.Client & Bool>:
        pair : Jev.Client & Bool <- answer(context, client, line)
        next(pair, c => s => answer_all(rest, context, c, s))

def overflowed(input: File, client: Jev.Client, pending: List<&2, U32>, size: U32, over: Bool) -> IO(Loop):
  match over:
    case True{}:
      do IO<Loop>:
        File.close(input)
        IO.print(Core.respond(J.Null{}, Fail{(2, "request line exceeds 1 MiB")}))
        return Ended{2, "request line exceeds 1 MiB"}
    case False{}:
      IO.pure(Loop, Serving{input, client, pending, size})

# A partial line longer than any valid request cannot be answered in order, so
# the session ends instead of resynchronizing.
def continued(input: File, pair: Jev.Client & Bool, pending: List<&2, U32>, +size: U32) -> IO(Loop):
  (client, stop) = pair
  match stop:
    case True{}:
      do IO<Loop>:
        File.close(input)
        return Ended{124, "serve deadline expired"}
    case False{}:
      overflowed(input, client, pending, size, U32.is_gt(size, Core.line_max()))

def framed(+context: Context, input: File, client: Jev.Client, framed: Core.Framed) -> IO(Loop):
  match framed:
    case Core.Framed{lines, pending, size}:
      do IO<Loop>:
        pair : Jev.Client & Bool <- answer_all(lines, context, client, False{})
        continued(input, pair, pending, size)

# End of input answers an unterminated last line, then ends the session.
def finished(input: File, pair: Jev.Client & Bool) -> IO(Loop):
  (client, stop) = pair
  do IO<Loop>:
    File.close(input)
    return Bool.pick(Loop, stop, Ended{124, "serve deadline expired"}, Ended{0, ""})

def chunk(
  +context: Context,
  input: File,
  client: Jev.Client,
  pending: List<&2, U32>,
  +size: U32,
  bytes: List<&2, U32>,
) -> IO(Loop):
  match bytes:
    case Nil{}:
      do IO<Loop>:
        pair : Jev.Client & Bool <- answer_all(Core.last(pending), context, client, False{})
        finished(input, pair)
    case more:
      framed(context, input, client, Core.frame(more, pending, size, Nil{}))

def received(+context: Context, pair: Read, client: Jev.Client, pending: List<&2, U32>, +size: U32) -> IO(Loop):
  (input, result) = pair
  match result:
    case Fail{e}:
      do IO<Loop>:
        File.close(input)
        return Ended{1, "serve could not read its input"}
    case Done{bytes}:
      chunk(context, input, client, pending, size, bytes)

def step(+context: Context, input: File, client: Jev.Client, pending: List<&2, U32>, +size: U32) -> IO(Loop):
  do IO<Loop>:
    pair : Read <- File.read_bytes(input, 65536)
    received(context, pair, client, pending, size)

def ended(code: U32, message: String) -> IO(Unit):
  match code:
    case 0:
      IO.pure(Unit, Unit{})
    case failed:
      IO.die(Unit, failed, message)

def loop(fuel: Nat, +context: Context, state: Loop) -> IO(Unit):
  match fuel state:
    case _ Ended{code, message}:
      ended(code, message)
    case 0n Serving{input, client, pending, size}:
      do IO<Unit>:
        File.close(input)
        IO.die(Unit, 1, "serve read limit reached; start a new session")
    case 1n+left Serving{input, client, pending, size}:
      do IO<Unit>:
        next : Loop <- step(context, input, client, pending, size)
        loop(left, context, next)

def launch(+ms: U32, budget: U32 & U32) -> IO(Unit):
  (+calls, +tokens) = budget
  do IO<Unit>:
    budget : Scope.Budget <- Scope.with_timeout(ms)
    client : Jev.Client <- IO.try(Jev.Client, Jev.connect(calls, tokens))
    executable : String <- Host.self()
    work : U32 <- Time.work()
    wait : U32 <- Time.wait()
    watch : U32 <- Time.watch()
    input : File <- IO.try(File, File.open("/dev/stdin", "r"))
    context : Context = Context{executable, budget, Core.Defaults{work, wait, watch}}
    IO.print(Core.banner(Cli.version(), ms, calls, tokens))
    loop(Core.reads_max(), context, Serving{input, client, Nil{}, 0})

def serve(timeout: Maybe<&2, U32>, args: List<String>) -> IO(Unit):
  match timeout:
    case None{}:
      IO.die(Unit, 2, "serve timeout must be 1..3600000 milliseconds")
    case Some{ms}:
      do IO<Unit>:
        budget : U32 & U32 <- IO.pass(U32 & U32, Core.budget(args))
        launch(ms, budget)
