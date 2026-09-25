import Base
import ../../native/Jev.bend as Jev
import ../../native/Session.bend as Session
import ../../native/Codec.bend as Codec
import ../../native/Process.bend as Process

# Jev plays ViZDoom through a persistent bridge process. The bridge renders the
# structured game state as a Jev request line; this orchestrator makes the typed
# decision and writes back the chosen action.

def Error() -> Type:
  U32 & String

def Line() -> Type:
  Result<&1, &1, Error, List<&2, U32>>

def ends_line(bytes: List<&2, U32>) -> Bool:
  match bytes:
    case Nil{}:
      False{}
    case Con{b, rest}:
      U32.is_eq(b, 10)

# Reading one line: `pending` holds the bytes seen so far, newest first.
type Poll is Type:
  Waiting{session: Session.Session, offset: U32, pending: List<&2, U32>}
  Ready{session: Session.Session, offset: U32, line: Line}

def complete(session: Session.Session, +offset: U32, pending: List<&2, U32>, done: Bool) -> Poll:
  match done:
    case True{}:
      Ready{session, offset, Done{List.reverse(&2, U32, pending)}}
    case False{}:
      Waiting{session, offset, pending}

def received(pair: Session.Session & Session.Bytes, offset: U32, pending: List<&2, U32>) -> Poll:
  (session, bytes) = pair
  match bytes:
    case Fail{e}:
      Ready{session, offset, Fail{e}}
    case Done{+chunk}:
      +count : U32 = U32.from_nat(List.length(&2, U32, chunk))
      +next : List<&2, U32> = List.append(&2, U32, List.reverse(&2, U32, chunk), pending)
      complete(session, (offset + count : U32), next, ends_line(next))

def read_more(session: Session.Session, +offset: U32, pending: List<&2, U32>) -> IO(Poll):
  do IO<Poll>:
    pair : Session.Session & Session.Bytes <- Session.read_stdout(session, offset, 65536)
    return received(pair, offset, pending)

def settle(poll: Poll) -> IO(Poll):
  match poll:
    case Ready{session, offset, line}:
      IO.pure(Poll, Ready{session, offset, line})
    case Waiting{session, offset, pending}:
      do IO<Poll>:
        IO.sleep(1)
        return Waiting{session, offset, pending}

def poll(fuel: Nat, state: Poll) -> IO(Poll):
  match fuel state:
    case fuel Ready{session, offset, line}:
      IO.pure(Poll, Ready{session, offset, line})
    case 0n Waiting{session, offset, pending}:
      IO.pure(Poll, Ready{session, offset, Fail{(124, "bridge produced no line")}})
    case 1n+left Waiting{session, offset, pending}:
      do IO<Poll>:
        read : Poll <- read_more(session, offset, pending)
        next : Poll <- settle(read)
        poll(left, next)

def or_unknown(text: Result<&1, &1, Error, String>) -> String:
  match text:
    case Fail{e}:
      "?"
    case Done{s}:
      s

def text_of(value: Maybe<&2, Codec.Value>) -> String:
  match value:
    case None{}:
      "?"
    case Some{v}:
      or_unknown(Codec.encode(v))

def answer(+value: Codec.Value, key: String) -> Maybe<&2, Codec.Value>:
  do Maybe<&2, Codec.Value>:
    answers : Codec.Value <- Codec.field(value, "answers")
    action : Codec.Value <- Codec.field(answers, "action")
    Codec.field(action, key)

def action_of(+value: Codec.Value) -> Maybe<&2, String>:
  do Maybe<&2, String>:
    c : Codec.Value <- answer(value, "choice")
    Codec.text(c)

# Running totals: decisions, total Jev milliseconds, slowest call.
type Stats is Data:
  Stats{decisions: Nat, total_ms: Nat, max_ms: Nat}

def record(stats: Stats, +ms: Nat) -> Stats:
  match stats:
    case Stats{+decisions, total_ms, +max_ms}:
      Stats{1n+decisions, Nat.add(total_ms, ms), Bool.pick(Nat, Nat.is_gt(ms, max_ms), ms, max_ms)}

def show_stats(stats: Stats) -> String:
  match stats:
    case Stats{+decisions, total_ms, +max_ms}:
      "decisions=" ++ Nat.show(decisions) ++ " mean_ms=" ++ Nat.show(Nat.div(total_ms, Nat.add(decisions, Bool.pick(Nat, Nat.is_eq(decisions, 0n), 1n, 0n)))) ++ " max_ms=" ++ Nat.show(max_ms)

type Game is Type:
  Playing{session: Session.Session, client: Jev.Client, offset: U32, stats: Stats}
  Over{session: Session.Session, client: Jev.Client, stats: Stats, summary: String}

def written(pair: Session.Session & Session.Written, client: Jev.Client, +offset: U32, stats: Stats) -> Game:
  (session, result) = pair
  match result:
    case Fail{e}:
      Over{session, client, stats, "bridge write failed"}
    case Done{u}:
      Playing{session, client, offset, stats}

def act(session: Session.Session, client: Jev.Client, +offset: U32, stats: Stats, +tick: String, +ms: Nat, +value: Codec.Value, chosen: Maybe<&2, String>) -> IO(Game):
  match chosen:
    case None{}:
      IO.pure(Game, Over{session, client, stats, "Jev answer had no action"})
    case Some{+action}:
      do IO<Game>:
        IO.print("tick " ++ tick ++ " -> " ++ action ++ " confidence=" ++ text_of(answer(value, "confidence")) ++ " " ++ Nat.show(ms) ++ "ms")
        pair : Session.Session & Session.Written <- Session.write(session, action ++ "\n")
        return written(pair, client, offset, record(stats, ms))

def decided(session: Session.Session, returned: Jev.Returned, +offset: U32, stats: Stats, +tick: String, +ms: Nat) -> IO(Game):
  (client, result) = returned
  match result:
    case Fail{(code, message)}:
      IO.pure(Game, Over{session, client, stats, "Jev failed: " ++ message})
    case Done{+value}:
      act(session, client, offset, stats, tick, ms, value, action_of(value))

def decide(session: Session.Session, client: Jev.Client, +offset: U32, stats: Stats, +tick: String, request: Result<&1, &1, Error, String>) -> IO(Game):
  match request:
    case Fail{(code, message)}:
      IO.pure(Game, Over{session, client, stats, "bad bridge request: " ++ message})
    case Done{body}:
      do IO<Game>:
        +started : Nat <- IO.now()
        returned : Jev.Returned <- Jev.evaluate(client, body)
        +finished : Nat <- IO.now()
        decided(session, returned, offset, stats, tick, Nat.sub(finished, started))

def requested(session: Session.Session, client: Jev.Client, +offset: U32, stats: Stats, +message: Codec.Value, request: Maybe<&2, Codec.Value>) -> IO(Game):
  match request:
    case None{}:
      IO.pure(Game, Over{session, client, stats, "bridge: " ++ text_of(Some{message})})
    case Some{r}:
      decide(session, client, offset, stats, text_of(Codec.field(message, "tick")), Codec.encode(r))

def finished(session: Session.Session, client: Jev.Client, +offset: U32, stats: Stats, +message: Codec.Value, done: Maybe<&2, Codec.Value>) -> IO(Game):
  match done:
    case Some{summary}:
      IO.pure(Game, Over{session, client, stats, "done " ++ text_of(Some{summary})})
    case None{}:
      requested(session, client, offset, stats, message, Codec.field(message, "request"))

def parsed(session: Session.Session, client: Jev.Client, +offset: U32, stats: Stats, message: Result<&1, &1, Error, Codec.Value>) -> IO(Game):
  match message:
    case Fail{(code, text)}:
      IO.pure(Game, Over{session, client, stats, "bridge sent invalid JSON: " ++ text})
    case Done{+value}:
      finished(session, client, offset, stats, value, Codec.field(value, "done"))

def line_read(client: Jev.Client, stats: Stats, state: Poll) -> IO(Game):
  match state:
    case Waiting{session, offset, pending}:
      IO.pure(Game, Over{session, client, stats, "bridge line incomplete"})
    case Ready{session, offset, Fail{(code, text)}}:
      IO.pure(Game, Over{session, client, stats, "bridge read failed: " ++ text})
    case Ready{session, offset, Done{bytes}}:
      parsed(session, client, offset, stats, Codec.read_bytes(bytes))

def turn(session: Session.Session, client: Jev.Client, offset: U32, stats: Stats) -> IO(Game):
  do IO<Game>:
    state : Poll <- poll(30000n, Waiting{session, offset, Nil{}})
    line_read(client, stats, state)

def play(fuel: Nat, game: Game) -> IO(Game):
  match fuel game:
    case fuel Over{session, client, stats, summary}:
      IO.pure(Game, Over{session, client, stats, summary})
    case 0n Playing{session, client, offset, stats}:
      IO.pure(Game, Over{session, client, stats, "decision fuel exhausted"})
    case 1n+left Playing{session, client, offset, stats}:
      do IO<Game>:
        next : Game <- turn(session, client, offset, stats)
        play(left, next)

def report(game: Game) -> IO(Unit):
  match game:
    case Playing{session, client, offset, stats}:
      IO.print("unfinished")
    case Over{session, client, stats, summary}:
      do IO<Unit>:
        IO.print(summary)
        IO.print("jev " ++ show_stats(stats))
        outcome : Session.Outcome <- Session.wait(session)
        IO.print("bridge exited")

# DOOM_PYTHON selects an interpreter with `vizdoom` installed; see examples/doom/.
def bridge() -> List<String>:
  [
    "/bin/sh",
    "-c",
    "exec \"${DOOM_PYTHON:-python3}\" \"${DOOM_BRIDGE:-examples/doom/bridge.py}\"",
  ]

# Opt-in network demo: each decision is one billed Jev call (at most 400 here).
def main() -> IO(Unit):
  do IO<Unit>:
    client : Jev.Client <- IO.try(Jev.Client, Jev.connect(400, 2000000))
    session : Session.Session <- Session.open(bridge())
    game : Game <- play(400n, Playing{session, client, 0, Stats{0n, 0n, 0n}})
    report(game)
