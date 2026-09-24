import Base
import ../Process.bend as Process

def fail_fast(+marker: String) -> IO(Unit):
  do IO<Unit>:
    child : Chan(Process.Report) <- IO.fork(Process.Report, Process.run(["/bin/sh", "-c", "printf '%s\\n' \"$$\" > \"$1\"; exec sleep 60", "sh", marker], "", 60000))
    ready : Process.Report <- Process.run(["/bin/sh", "-c", "while [ ! -s \"$1\" ]; do sleep 0.01; done", "sh", marker], "", 1500)
    failure : Process.Report <- Process.run(["/jev-fabric-native-intentionally-missing"], "", 1000)
    IO.die(Unit, 1, "unreachable: missing command should fail")

def args(values: List<String>) -> IO(Unit):
  match values:
    case Con{marker, Nil{}}:
      fail_fast(marker)
    case values:
      IO.die(Unit, 2, "expected an owned marker path")

def main() -> IO(Unit):
  do IO<Unit>:
    values : List<String> <- IO.args()
    args(values)
