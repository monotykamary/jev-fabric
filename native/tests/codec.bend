import Base
import ../Codec.bend as Codec
import ../vendor/strict-json/json.bend as J

def ok(value: Result<&1, &1, U32 & String, J.JSON>) -> Bool:
  match value:
    case Done{v}:
      True{}
    case Fail{e}:
      False{}

def encoded(value: Result<&1, &1, U32 & String, String>, expected: String) -> Bool:
  match value:
    case Done{text}:
      String.eq(text, expected)
    case Fail{e}:
      False{}

def roundtrip(text: String) -> Result<&1, &1, U32 & String, String>:
  do Result<&1, &1, U32 & String, String>:
    value : J.JSON <- Codec.read(text)
    Codec.encode(value)

def check(tests: List<&2, Bool>, n: Nat) -> IO(Unit):
  match tests:
    case Nil{}:
      IO.print("native codec assertions: " ++ Nat.show(n))
    case Con{True{}, tail}:
      check(tail, 1n+n)
    case Con{False{}, tail}:
      IO.die(Unit, 1, "native codec assertion failed at " ++ Nat.show(n))

def main() -> IO(Unit):
  check([
    ok(Codec.read("null")), ok(Codec.read("[]")), ok(Codec.read("{}")),
    encoded(
      roundtrip("{\"n\":-1.2300E+003,\"s\":\"\\uD83D\\uDE42\"}"),
      "{\"n\":-1.2300E+003,\"s\":\"🙂\"}"
    ),
    Bool.not(ok(Codec.read("[1.]"))), Bool.not(ok(Codec.read("[1e]"))),
    Bool.not(ok(Codec.read("[1e+]"))), Bool.not(ok(Codec.read("[-]"))),
    Bool.not(ok(Codec.read("[01]"))), Bool.not(ok(Codec.read("[true false]"))),
    Bool.not(ok(Codec.read("{\"a\" 1}"))), Bool.not(ok(Codec.read("[1,]"))),
    Bool.not(ok(Codec.read("{\"a\":1,}"))), Bool.not(ok(Codec.read("NaN"))),
    Bool.not(ok(Codec.read("\"\\x00\""))), Bool.not(ok(Codec.read("\"\\uD800\""))),
    Bool.not(ok(Codec.read("\"\\uDC00\""))), Bool.not(ok(Codec.read("\"\\uD800\\u0041\""))),
    Bool.not(ok(Codec.read("{\"a\":1,\"\\u0061\":2}"))),
    Bool.not(ok(Codec.read("[null]x"))),
    ok(Codec.read_bytes([34, 240, 159, 153, 130, 34])),
    Bool.not(ok(Codec.read_bytes([34, 192, 128, 34]))),
    Bool.not(ok(Codec.read_bytes([34, 237, 160, 128, 34]))),
    Bool.not(ok(Codec.read_bytes([34, 244, 144, 128, 128, 34]))),
    Bool.not(ok(Codec.read_bytes([34, 128, 34]))),
    Bool.not(ok(Codec.read_bytes([34, 240, 159]))),
    Bool.not(ok(Codec.read_bytes([256]))),
    Bool.not(ok(Codec.read(SCon{'"', SCon{Chr{55296}, SCon{'"', SNil{}}}}))),
    Bool.not(encoded(Codec.encode(J.Str{SCon{Chr{1114112}, SNil{}}}), "")),
    Bool.not(encoded(Codec.encode(J.Num{"1."}), "1.")),
    Bool.not(encoded(Codec.encode(J.Member{"a", J.Null{}}), "")),
    Bool.not(encoded(Codec.encode(J.Obj{[J.Null{}]}), "")),
    Bool.not(encoded(
      Codec.encode(J.Obj{[J.Member{"a", J.Null{}}, J.Member{"a", J.Null{}}]}),
      ""
    )),
    encoded(
      roundtrip("[9007199254740993,1e-1000,1.000000000000000001]"),
      "[9007199254740993,1e-1000,1.000000000000000001]"
    ),
    encoded(Codec.encode(J.Str{"\n\t\r\"\\"}), "\"\\n\\t\\r\\\"\\\\\"")
  ], 0n)
