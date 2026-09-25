import Base
import ../Monitor.bend as Monitor

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    Monitor.command(args)
