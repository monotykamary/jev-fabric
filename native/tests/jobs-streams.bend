import Base
import ../Streams.bend as Streams

def assert(ok: Bool) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "incremental UTF-8 assertion failed")

def resume(first: Streams.Decoder & String, rest: List<&2, U32>) -> String:
  (decoder, text) = first
  text ++ Streams.finish(Streams.feed(rest, decoder))

def decode(bytes: List<&2, U32>) -> String:
  Streams.finish(Streams.feed(bytes, Streams.empty()))

def main() -> IO(Unit):
  do IO<Unit>:
    assert(String.eq(decode([65, 0, 66]), "A\u{0}B"))
    assert(String.eq(decode([240, 159, 153, 130]), "🙂"))
    # U+1F642 split across two reads: the first holds back its incomplete prefix.
    split : Streams.Decoder & String = Streams.take(Streams.feed([65, 240, 159], Streams.empty()))
    assert(String.eq(resume(split, [153, 130, 66]), "A🙂B"))
    assert(String.eq(decode([240, 159]), "�"))
    assert(String.eq(decode([255, 65]), "�A"))
    assert(String.eq(decode([237, 160, 128]), "�"))
    assert(String.eq(decode([244, 144, 128, 128]), "�"))
    assert(String.eq(decode([226, 65]), "�A"))
    IO.print("jobs incremental UTF-8 assertions: 8")
