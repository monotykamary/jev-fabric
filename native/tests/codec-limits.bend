import Base
import ../Codec.bend as Codec
import ../vendor/strict-json/json.bend as J

def reusable(+value: Codec.Value) -> List<&2, Codec.Value>:
  [value, value]

def depth(n: Nat) -> Codec.Value:
  match n:
    case 0n:
      J.Null{}
    case 1n+p:
      J.Arr{[depth(p)]}

def bytes(n: Nat) -> List<&2, U32>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      Con{65, bytes(p)}

def nodes(n: Nat) -> List<&2, Codec.Value>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      Con{J.Null{}, nodes(p)}

def rejected(value: Result<&1, &1, U32 & String, Codec.Value>) -> Bool:
  match value:
    case Done{v}:
      False{}
    case Fail{e}:
      True{}

def text_rejected(value: Result<&1, &1, U32 & String, String>) -> Bool:
  match value:
    case Done{s}:
      False{}
    case Fail{e}:
      True{}

def text_size(value: Result<&1, &1, U32 & String, String>, size: Nat) -> Bool:
  match value:
    case Done{s}:
      Nat.is_eq(String.length(s), size)
    case Fail{e}:
      False{}

# One scalar at each UTF-8 length boundary:
# U+0000 U+007F U+0080 U+07FF U+0800 U+FFFF U+10000 U+10FFFF.
def boundary_scalars() -> List<&2, U32>:
  [
    0, 127,
    194, 128, 223, 191,
    224, 160, 128, 239, 191, 191,
    240, 144, 128, 128, 244, 143, 191, 191
  ]

def check(tests: List<&2, Bool>, n: Nat) -> IO(Unit):
  match tests:
    case Nil{}:
      IO.print("native codec resource assertions: " ++ Nat.show(n))
    case Con{True{}, tail}:
      check(tail, 1n+n)
    case Con{False{}, tail}:
      IO.die(Unit, 1, "native codec resource assertion failed at " ++ Nat.show(n))

def main() -> IO(Unit):
  check([
    Nat.is_eq(List.length(&2, Codec.Value, reusable(J.Null{})), 2n),
    rejected(Codec.read("\"" ++ String.repeat("a", 1048575n) ++ "\"")),
    rejected(Codec.read(String.repeat(" ", 1048577n))),
    rejected(Codec.read("\"" ++ String.repeat("🙂", 262144n) ++ "\"")),
    text_rejected(Codec.decode_utf8(bytes(1048577n))),
    text_size(Codec.decode_utf8(bytes(1048576n)), 1048576n),
    text_rejected(Codec.encode(J.Str{String.repeat("a", 1048576n)})),
    text_rejected(Codec.encode(J.Str{String.repeat(SCon{Chr{1}, SNil{}}, 200000n)})),
    text_rejected(Codec.encode(depth(200n))),
    text_rejected(Codec.encode(J.Arr{nodes(20000n)})),
    text_size(Codec.decode_utf8(boundary_scalars()), 8n),
    text_rejected(Codec.decode_utf8([224, 159, 191])),
    text_rejected(Codec.decode_utf8([240, 143, 191, 191])),
    text_rejected(Codec.decode_utf8([245, 128, 128, 128])),
    text_rejected(Codec.decode_utf8([239, 300, 128]))
  ], 0n)
