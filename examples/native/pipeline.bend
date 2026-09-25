import Base
import ../../native/Process.bend as Process

def main() -> IO(Unit):
  do IO<Unit>:
    result : Process.Report <- Process.run(["/bin/sh", "-c", "cat <<'TEXT' | tr a-z A-Z\nhello native bend\nTEXT"], "", 2000)
    IO.print(Process.show(result))
