import Base
import ../Http.bend as Http

def show(result: Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(Unit):
  match result:
    case Fail{error}:
      IO.print("error")
    case Done{bytes}:
      IO.print("ok:" ++ Nat.show(List.length(&2, U32, bytes)))

def dispatch(args: List<String>) -> IO(Unit):
  match args:
    case Con{url, Con{body, Nil{}}}:
      do IO<Unit>:
        r : Result<&1, &1, U32 & String, List<&2, U32>> <- Http.post(url, "SYNTHETIC_NOT_A_SECRET", body, 1500)
        show(r)
    case other:
      IO.die(Unit, 2, "expected URL and JSON body")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    dispatch(args)
