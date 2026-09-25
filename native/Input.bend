import Base
import ./Process.bend as Process
import ./Codec.bend as Codec

# A cat child gives special files the same outside deadline as other subprocesses.
# Literal argv, bounded raw bytes, no stderr/content in failure messages.
def ready(bytes: List<&2, U32>, ok: Bool) -> Result<&1, &1, U32 & String, String>:
  match ok:
    case False{}:
      Fail{(1, "Unable to read bounded UTF-8 input file")}
    case True{}:
      Codec.decode_utf8(bytes)

def captured(
  result: Result<&1, &1, U32 & String, Process.RawBytes>,
) -> Result<&1, &1, U32 & String, String>:
  match result:
    case Fail{e}:
      Fail{(1, "Unable to read input file")}
    case Done{raw}:
      (code, (flags, (bytes, err))) = raw
      ready(bytes, U32.is_eq(code, 0) && U32.is_eq(flags, 0))

def read(path: String) -> IO(Result<&1, &1, U32 & String, String>):
  do IO<Result<&1, &1, U32 & String, String>>:
    result : Result<&1, &1, U32 & String, Process.RawBytes> <- Process.capture(
      ["/bin/cat", "--", path],
      "",
      5000,
      1048577,
    )
    return captured(result)
