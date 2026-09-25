import Base
import ../../native/Process.bend as Process

def main() -> IO(Unit):
  do IO<Unit>:
    result : Process.Report <- Process.exec(["/bin/sh", "-c", "cat <<'TEXT' | tr a-z A-Z\nhello native bend\nTEXT"])
    IO.print(Process.show(result))
