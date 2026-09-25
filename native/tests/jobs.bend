import Base
import ../Jobs.bend as Jobs

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    Jobs.command(args)
