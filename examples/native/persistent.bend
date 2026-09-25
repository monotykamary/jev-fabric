import Base
import ../../native/Session.bend as Session
import ../../native/Process.bend as Process

def written(pair: Session.Session & Result<&1, &1, U32 & String, Unit>) -> IO(Session.Session):
  (session, result) = pair
  do IO<Session.Session>:
    IO.pass(Unit, result)
    return session

def send(session: Session.Session, text: String) -> IO(Session.Session):
  do IO<Session.Session>:
    pair : Session.Session & Result<&1, &1, U32 & String, Unit> <- Session.write(session, text)
    written(pair)

# One persistent native child keeps state across three JSONL requests.
# Protocol clients should correlate/validate replies and stay below spool limits.
def main() -> IO(Unit):
  do IO<Unit>:
    first : Session.Session <- Session.open(["/bin/sh", "-c", "i=0; while IFS= read -r value; do i=$((i+1)); printf '{\"count\":%s,\"value\":%s}\\n' \"$i\" \"$value\"; done"])
    second : Session.Session <- send(first, "10\n")
    third : Session.Session <- send(second, "20\n")
    fourth : Session.Session <- send(third, "30\n")
    report : Process.Report <- IO.try(Process.Report, Session.wait(fourth))
    IO.print(Process.show(report))
