import Base
import ../../native/Scope.bend as Scope
import ../../native/Process.bend as Process

# Both operations share the same budget; neither restarts its clock.
# This budget is not a separate OS cancellation group.
def main() -> IO(Unit):
  do IO<Unit>:
    +scope : Scope.Budget <- Scope.open()
    first : Chan(Process.Report) <- IO.fork(Process.Report, Scope.exec(scope, ["/bin/echo", "first"]))
    second : Process.Report <- Scope.exec(scope, ["/bin/echo", "second"])
    result : Process.Report <- IO.join(Process.Report, first)
    IO.print(Process.show(result))
    IO.print(Process.show(second))
