import Base
import ./Json.bend as Json

def Raw() -> Type:
  U32 & (U32 & (String & String))

# This is the only custom foreign effect. It is native C, not JavaScript.
def Native.exec(argv: List<String>, input: String, timeout_ms: U32, inherit_stdin: Bool) -> IO(Result<&1, &1, U32 & String, Raw>):
  import "./posix.c"

type Report is Data:
  Report{code: U32, timed_out: Bool, cancelled: Bool, stdout_cut: Bool, stderr_cut: Bool, stdout: String, stderr: String}

def decode(raw: Raw) -> Report:
  (code, (+flags, (stdout, stderr))) = raw
  Report{code, U32.is_ne((flags .&. 1 : U32), 0), U32.is_ne((flags .&. 8 : U32), 0), U32.is_ne((flags .&. 2 : U32), 0), U32.is_ne((flags .&. 4 : U32), 0), stdout, stderr}

def run(argv: List<String>, input: String, timeout_ms: U32) -> IO(Report):
  do IO<Report>:
    raw : Raw <- IO.try(Raw, Native.exec(argv, input, timeout_ms, False{}))
    return decode(raw)

def run_stdin(argv: List<String>, timeout_ms: U32) -> IO(Report):
  do IO<Report>:
    raw : Raw <- IO.try(Raw, Native.exec(argv, "", timeout_ms, True{}))
    return decode(raw)

def state_code(success: Bool) -> String:
  match success:
    case True{}:
      "exited"
    case False{}:
      "failed"

def state(code: U32, timed_out: Bool, cancelled: Bool) -> String:
  match timed_out cancelled:
    case True{} cancelled:
      "timed_out"
    case False{} True{}:
      "cancelled"
    case False{} False{}:
      state_code(U32.is_eq(code, 0))

def show(report: Report) -> String:
  match report:
    case Report{+code, +timed_out, +cancelled, out_cut, err_cut, stdout, stderr}:
      "{\"schemaVersion\":1,\"state\":" ++ Json.quote(state(code, timed_out, cancelled)) ++
      ",\"exitCode\":" ++ U32.show(code) ++ ",\"timedOut\":" ++ Json.boolean(timed_out) ++
      ",\"cancelled\":" ++ Json.boolean(cancelled) ++ ",\"stdout\":" ++ Json.quote(stdout) ++
      ",\"stderr\":" ++ Json.quote(stderr) ++ ",\"truncated\":{\"stdout\":" ++ Json.boolean(out_cut) ++
      ",\"stderr\":" ++ Json.boolean(err_cut) ++ "}}"

def exit_code(report: Report) -> U32:
  match report:
    case Report{code, timed_out, cancelled, out_cut, err_cut, stdout, stderr}:
      code
