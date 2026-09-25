import Base
import ../Codec.bend as Codec
import ../Wire.bend as Wire
import ../vendor/strict-json/json.bend as J

def ok(value: Result<&1, &1, U32 & String, J.JSON>) -> Bool:
  match value:
    case Done{v}:
      True{}
    case Fail{e}:
      False{}

def number(value: Result<&1, &1, U32 & String, Nat>, expected: Nat) -> Bool:
  match value:
    case Done{v}:
      Nat.is_eq(v, expected)
    case Fail{e}:
      False{}

def numeric(text: String, scale: Nat, maximum: Nat) -> Result<&1, &1, U32 & String, Nat>:
  do Result<&1, &1, U32 & String, Nat>:
    value : J.JSON <- Codec.read(text)
    Wire.scalar(value, scale, maximum)

def request_text() -> String:
  "{\"state\":{},\"questions\":{\"q\":{\"type\":\"noul\",\"instructions\":\"x\"}}}"

def response_text(n: String) -> String:
  "{\"model\":\"jev\",\"answers\":{\"q\":{\"type\":\"noul\",\"noul\":" ++ n ++ "}},\"usage\":{\"input_tokens\":1,\"output_tokens\":2}}"

def response(text: String) -> Result<&1, &1, U32 & String, J.JSON>:
  do Result<&1, &1, U32 & String, J.JSON>:
    req : J.JSON <- Wire.request(request_text())
    Wire.response(text, req)

def check(tests: List<&2, Bool>, n: Nat) -> IO(Unit):
  match tests:
    case Nil{}:
      IO.print("native wire assertions: " ++ Nat.show(n))
    case Con{True{}, tail}:
      check(tail, 1n+n)
    case Con{False{}, tail}:
      IO.die(Unit, 1, "native wire assertion failed at " ++ Nat.show(n))

def main() -> IO(Unit):
  check([
    ok(Wire.request(request_text())),
    Bool.not(ok(Wire.request("{}"))),
    Bool.not(ok(Wire.request("{\"state\":null,\"questions\":{}}"))),
    Bool.not(ok(Wire.request("{\"state\":{},\"questions\":{}}"))),
    ok(Wire.request("{\"state\":[],\"questions\":{\"q\":{\"type\":\"choice\",\"instructions\":{},\"criteria\":{\"a\":null}}}}")),
    ok(Wire.request("{\"state\":[],\"questions\":{\"q\":{\"type\":\"score\",\"instructions\":{},\"criteria\":[\"a\",{}]}}}")),
    Bool.not(ok(Wire.request("{\"state\":[],\"questions\":{\"q\":{\"type\":\"score\",\"instructions\":{},\"criteria\":[\"a\"]}}}"))),
    Bool.not(ok(Wire.request("{\"state\":[],\"questions\":{\"q\":{\"type\":\"text\",\"instructions\":{}}}}"))),
    number(numeric("0.125", 12n, Wire.unit()), Nat.mul(125000n, 1000000n)),
    number(numeric("1e0", 12n, Wire.unit()), Wire.unit()),
    number(numeric("1000e-3", 12n, Wire.unit()), Wire.unit()),
    number(numeric("-0.000e-1000", 12n, Wire.unit()), 0n),
    Bool.not(number(numeric("-1e-1000", 12n, Wire.unit()), 0n)),
    Bool.not(number(numeric("1.000000000000000000001", 12n, Wire.unit()), Wire.unit())),
    Bool.not(number(numeric("1.000000000001", 12n, Wire.unit()), Wire.unit())),
    number(numeric("16777217", 0n, Nat.read.max()), 16777217n),
    number(numeric("16777217.000", 0n, Nat.read.max()), 16777217n),
    Bool.not(number(numeric("16777217.00000001", 0n, Nat.read.max()), 16777217n)),
    Bool.not(number(numeric("281474976710656", 0n, Nat.read.max()), 0n)),
    number(numeric("281474976710655", 0n, Nat.read.max()), Nat.read.max()),
    Bool.not(number(numeric("9007199254740992", 0n, Nat.read.max()), 0n)),
    Bool.not(number(numeric("1e999999999999", 0n, Nat.read.max()), 0n)),
    ok(response(response_text("0.1"))), ok(response(response_text("1"))),
    Bool.not(ok(response(response_text("-1e-1000")))),
    Bool.not(ok(response(response_text("1.0000000000000000000001")))),
    Bool.not(ok(response(response_text("true")))),
    Bool.not(ok(response("{\"model\":42,\"answers\":{},\"usage\":{\"input_tokens\":1,\"output_tokens\":2}}")))
  ], 0n)
