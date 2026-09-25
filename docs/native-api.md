# Native API and execution contract

Use stock Bend 2.0.27 native compilation. Imports below are relative to your
source file; see `examples/native/`. Native code, PATH executables and imported
modules are trusted. Affine ownership is a programming discipline, not secret
isolation from the program that owns the client.

## CLI

All commands follow `build/jev-fabric --`:

| Command | Meaning |
| --- | --- |
| `exec [--timeout-ms N] [--stdin] [--] <command> [args...]` | Literal argv, owned process group, bounded final receipt |
| `run [--timeout-ms N] [--] <program.bend> [args...]` | Compile into a private directory, then run with inherited stdin; one outside deadline covers both |
| `validate <request.json>` | Strict UTF-8/JSON plus typed Jev request validation; no credentials/network |
| `jev [--timeout-ms N] <request.json> [max-tokens]` | One explicit evaluation; default 100000 reported tokens |
| `start [--timeout-ms N] [--] <command> [args...]` | Native detached worker; returns private job ID |
| `status <id>` | Running state or stable final receipt |
| `events <id> [after-sequence]` | Snapshot of bounded retained JSONL events |
| `wait [--timeout-ms N] <id>` | Poll until final receipt or client deadline; timeout returns running state |
| `stop <id>` | Idempotent cooperative stop through a private marker, never arbitrary PID signalling |
| `watch [--timeout-ms N] <id> <literal>` | Live bounded line batches, loss records and a final observation summary; duration 1..300000 ms |

Timers may be omitted. Defaults and configuration:

| Operations | Default maximum | Environment override |
| --- | --- | --- |
| `exec`, `run`, `start`, timer-free Process/Session APIs, `Scope.open` | 1 hour | `JEV_FABRIC_TIMEOUT_MS` |
| `jev`, `Jev.connect` | 30 seconds | `JEV_FABRIC_JEV_TIMEOUT_MS` |
| CLI `wait` | 30 seconds | `JEV_FABRIC_WAIT_MS` |
| CLI `watch` | 5 seconds | `JEV_FABRIC_WATCH_MS` |

Defaults are ceilings, not sleeps: completion returns immediately. Empty/unset
configuration uses the default; malformed values fail closed. Explicit limits
replace configuration for that call (even when that default is malformed).
`wait` and `watch` only bound observation: they neither cancel nor renew a job.
The calling harness still has its own shell-tool limits; a CLI default does not
extend those. Use `start` and subsequent controls for work that should outlive
a foreground tool call.
There is no unlimited/zero timeout mode. Limits are 1..3600000 ms, except `watch`
which permits 1..300000 ms.

Place `--timeout-ms N` and `--stdin` before the executable/source. Parsing stops
there: all subsequent arguments are literal child arguments, including strings
such as `--timeout-ms`. A command-local `--` ends option and legacy-number
parsing: `exec -- 123` executes a numeric command named `123` from PATH. It is
distinct from the initial Bend runtime `--`.

Legacy forms remain supported: `exec/run/start/jev <ms> ...`,
`exec <ms> --stdin ...`, `wait <id> <ms>`, `watch <id> <ms> <literal>`.
Do not specify both a timeout flag and a positional timeout.

Timeouts are 1..3600000 ms. Source compilation consumes the same `run` deadline
as execution. `run` returns a **process receipt**, not the reference program
context/envelope: stdout may contain your program's JSON result. It does not
interpret that output as a verified task outcome. Compile once yourself and use
`exec` or `start` to avoid repeated compilation.

The compiler can read arbitrary native source/imports and run arbitrary native
code. Private output paths do not make compilation sandboxed. Compiled artifacts
remain inside the checked storage root and count towards its directory cap.

## Scope.bend: shared deadline budgets

Use `examples/native/scoped.bend` as a complete timer-free composition example.

- `Scope.open() -> IO(Scope.Budget)` starts one configured work budget.
- `Scope.with_timeout(ms)` explicitly overrides that budget when needed.
- `Scope.exec(scope, argv)` / `Scope.run(scope, argv, input)` return process reports.
- `Scope.start(scope, argv) -> IO(Result<..., Session.Session>)` starts a session
  with the remaining budget. Close/wait the returned handle normally.
- `Scope.evaluate(scope, client, request)` returns the threaded affine Jev client
  and evaluation result, like `Jev.evaluate`.
- `run_for(scope, argv, input, cap_ms)`, `start_for(scope, argv, cap_ms)` and
  `evaluate_for(scope, client, request, cap_ms)` add optional shorter local caps.

Pass the **same** budget to successive or concurrent calls. Each operation uses
remaining time, capped by any local limit; Jev additionally retains its client's
per-request maximum. Creating a new budget for each call defeats this sharing.
Session reads/writes do not refresh its lifetime. Jev credential acquisition and
HTTP share the capped request deadline; the original client settings and updated
credential cache/call accounting are preserved afterward.

Expired process calls return a timed-out report (124) without launching.
Expired session/evaluation calls return recoverable errors (124); Jev does not
retrieve credentials, reserve a call or dispatch HTTP in this case.

**A budget is not an isolated resource/cancellation group.** `Process.cancel`
still cancels the owning executable's entire native process scope. Budgets are
sampled at dispatch; validation/scheduling/launch latency is not a real-time
theorem. They are explicitly passed, not ambient: `run`'s external compile/
execution limit is **not automatically inherited** by a new budget inside the
program. Cross-process hierarchical cancellation and cleanup after a native
crash or SIGKILL are not promised. Low-level explicit-time APIs remain available
to trusted programs. An outer timeout is not proof of cleanup of nested groups.

## Process.bend

- `Process.exec(argv) -> IO(Process.Report)` uses the configured work default.
- `Process.exec_input(argv, buffered_stdin)` uses the same default with input.
- `Process.exec_stdin(argv)` inherits fd 0 with the configured default.
- `Process.run(argv, buffered_stdin, timeout_ms) -> IO(Process.Report)`
- `Process.run_stdin(argv, timeout_ms) -> IO(Process.Report)` inherits fd 0.
- `Process.capture(argv, buffered_stdin, timeout_ms, cap) -> IO(Result<..., RawBytes>)`
  is recoverable and byte-preserving. Used for private HTTP and credentials;
  it does not emit events or public receipts.
- `Process.run_logged(argv, timeout_ms, stdout_file, stderr_file)` consumes
  owned file descriptors and writes bounded raw spools while returning a report.
- `Process.cancel(signal)` cancels the **whole owning native process scope**,
  not an independently addressable child. The cancellation flag is sticky;
  the current effect marks scope cancellation as SIGTERM regardless of that
  argument. The supervisor then force-kills owned groups; this is not a child
  SIGTERM/graceful-shutdown guarantee.
- `Process.show(report)` serializes a receipt; `Process.exit_code(report)`
  preserves nonzero/timeout/cancel outcomes.

Eight concurrent child commands per native process, 64 argv entries (including
executable), 4096 UTF-8 bytes per entry, no embedded NUL. Normal buffered input
is 128 KiB; inherited input streams through the OS. Private capture permits a
larger bounded buffer for HTTP. Reports retain 32 KiB tails per stream and flag
truncation; text receipts may replace malformed UTF-8. Binary consumers must use
capture or raw spool reads instead. Spools preserve the **first** 1 MiB; overflow
is disclosed and draining continues so a full log does not deadlock its child.

`IO.fork`/`IO.join` compose native effects. Shells, pipelines and heredocs are
ordinary explicitly invoked executables; there is no hidden shell expansion.
SIGINT/SIGTERM and foreign failures clean up owned groups and reap direct
children. Intentionally escaped daemons, SIGKILL/native crashes or overridden
signal handlers are outside the guarantee. Side effects are never rolled back.

## Session.bend: interactive native handles

- `open(argv) -> IO(Session)` chooses the configured default once at startup.
- `start(argv, timeout_ms) -> IO(Session)` explicitly sets that lifetime. Both
  return before completion; neither refreshes the clock on reads/writes.
- `write(session, text) -> IO(Session & Result<..., Unit>)` preserves ownership
  even on EPIPE; at most 65536 Unicode characters per write.
- `close_input(session) -> IO(Session)` sends EOF and is idempotent.
- `read_stdout` / `read_stderr(session, offset, max)` return the updated session
  and recoverable raw bytes; offset <= 1048576 and max <= 65536.
- `status(session)` returns the session and current stdout/stderr spool sizes.
- `wait(session)` closes stdin, joins the owned supervisor, closes readers and
  returns a recoverable process report or launch error.
- `cancel_scope()` cancels **all** native children in the owning process, not
  just one session; cancellation is sticky.

Use returned handles in subsequent calls. Empty live reads are not EOF. Each
spool retains only its first 1 MiB; a size at `spool_limit()` means it may be
clipped. Correlate/validate protocol replies and stop/restart before that cap if
you need lossless protocol semantics. Final tails and truncation are separate.
Start uses checked private storage and the same 1024-directory retention cap.
A write may be buffered before an asynchronous launch failure becomes visible;
`wait` remains authoritative. Child deadlines unblock a writer if its peer is
not reading. Always close/wait sessions; affine ownership alone is not an
implicit join or destructor. `examples/native/persistent.bend` keeps one child
alive across three stateful JSONL requests, with no JS runtime.

The only additional primitive is a CLOEXEC pipe returned as stock Base File
handles (`native/pipe.c`); the existing process supervisor consumes its reader.
Launch validation, quota and spawn failure paths close transferred descriptors.

## Monitor.bend: explicit bounded observations

`Monitor.command` exposes `watch <id> <duration-ms> <literal>`; literal length is
1..256 characters. It polls retained job events every 25 ms, preserves partial
lines separately by stream, trims/filters/deduplicates, emits at most 32 lines
per batch and clips partial lines at 4096 characters. A 1024-line combined
stopping threshold is checked after each snapshot; hard caps of 1024 per stream
bound a single snapshot overshoot to **2048 total lines maximum**.

Output is JSONL: `monitor.batch`, `monitor.loss`, `monitor.end`. Sequence gaps,
omitted bytes and spool caps reset framing and disclose loss instead of joining
unrelated partial lines. `outputLimitReached` warns that output may be omitted,
including when a terminal receipt arrives in the same snapshot. Finishing a
watch at its deadline does not stop the job; matches are observations, not
semantic completion. There are no automatic Jev calls or host-agent wakeups.
Stock Bend IO parking flushes live records; no monitor-specific C is required.

## Pure policy and trust

`TimeCore` and `Cli` hold timer/configuration/argument policy.
`MonitorCore`, `HttpCore`, `CredentialCore` and `JevCore` hold the other pure policies;
the original module names remain effectful entrypoints. `Jev.Client` and
`Jev.Returned` remain public affine type aliases; their constructors live in
`JevCore`. `Http.post`, `Credentials.resolve` and `Monitor.command` retain their
interfaces. The pure monitor helpers are now imported from `MonitorCore`.

Every native build checks `native/trust.json`, including transitive pure imports,
unsafe spellings and proof holes. Pure roots have no trust warnings; foreign IO
drivers still do. See [exact proof coverage and assumptions](safe-bend.md).

## Codec.bend and Wire.bend

`Codec.Value() -> Data` aliases the pinned strict JSON AST. `read`, `read_bytes`,
`decode_utf8`, and `encode` return recoverable `Result` values. `field`, `text`,
and `array` are typed accessors. `Wire.request`, `body`, `response`, and `usage`
implement Jev's complete typed wire contract.

The boundary rejects malformed UTF-8, duplicate object keys, unknown request
fields, incomplete JSON, malformed numbers, invalid IDs, missing answers,
extra answer/probability keys and non-finite/out-of-range values. JSON limits:
1 MiB encoded UTF-8, depth 64, 32768 AST/work units, 256 keys/object and Unicode
scalars/key, and 1 MiB cumulative key-comparison charge. Requests require
Choice criteria objects (1..255), Noul instructions, or Score criteria arrays
(2..10), not a `choices` or `scale` field. See `examples/native/request.json`.

Numbers retain their original lexemes. Wire validation uses **exact decimal
arithmetic**, not F32: probability bounds and mass tolerance [0.98,1.02] include
long fractions and tiny exponents without rounding invalid values into range.
Numeric lexemes are capped at 1024 characters, exponent magnitude 4096, and
usage counts at the native 48-bit Nat maximum (281474976710655). These limits
intentionally differ from the JS reference. Generic bounded JSON can preserve
larger numeric lexemes; wire numeric operations impose the tighter bounds.

Vendoring, patches, license and hashes: `native/vendor/PROVENANCE.md`.

## Jev.bend

```text
Jev.connect(max_evaluations, max_tokens)
  -> IO(Result<..., Jev.Client>)  # configured request-time default
Jev.from_env(timeout_ms, max_evaluations, max_tokens)
  -> IO(Result<..., Jev.Client>)
Jev.evaluate(client, request_json)
  -> IO(Jev.Client & Result<..., Codec.Value>)
```

Thread the returned client into the next call. The affine type prevents
accidental overlapping evaluations of the same client. Trusted native code can
construct additional clients; budgets are not a security policy against it.

Provider configuration:

| JEV_PROVIDER | Key environment variable | Default model |
| --- | --- | --- |
| `typesafe` (default) | `TYPESAFE_API_KEY` | `jev-latest` |
| `openrouter` | `OPENROUTER_API_KEY` | `typesafe/jev-1.13` |
| `vercel` | `AI_GATEWAY_API_KEY` | `typesafe-ai/jev` |

Routes are fixed in `Jev.route`; `JEV_MODEL` overrides the default. A request's
explicit model takes precedence. `JEV_CREDENTIAL_COMMAND` is a JSON argv array,
not a shell fragment. It has a 5-second maximum (or the shorter request time),
16 KiB output bound, strict UTF-8 and printable single-line credential checks.
Resolver failures are sanitized. Successful credentials cache only in the
threaded affine client; nothing writes them into job metadata.

The request is validated before resolution. Exhausted budgets prevent even the
credential command. Invalid requests/credentials consume no call; dispatched
HTTP failures do consume a call and are not retried. Credential time is deducted
from the same monotonic HTTP deadline. Reported token overshoot blocks later
calls with overflow-safe accounting; missing usage counts as zero. The final
request may still be billed above the token limit. Use call limits as well.

`Http.post` is a lower-level explicit URL API for trusted programs. It validates
HTTPS, keeps key/body in escaped private stdin config, disables curl startup
config and proxies, rejects redirects, verifies TLS, and bounds byte capture.
System curl/CA configuration and PATH remain trusted deployment dependencies.

## Durable observations

`Jobs.command` owns native lifecycle/control flow; `Host.bend` wraps the checked
filesystem boundary. Storage root is `JEV_FABRIC_HOME` or `.jev-fabric-native`.
Roots/job directories require owner-only permissions. Directory traversal,
symlink components, unsafe marker files and non-private files fail closed.
Writes are atomic and bounded. Workers hold a live advisory lease; no persisted
PID is treated as authority. A dead worker can be reported failed, but execution
is not resumed after a crash/reboot.

Each job retains 64 events, at most two 1 MiB first-byte raw spools, and final
32 KiB tails. Output previews coalesce to the latest 2048 available bytes per
stream/tick, reporting `offset`, `bytes`, `omittedBytes`, and decoded `text`.
UTF-8 partial characters carry across adjacent chunks and reset across loss.
`process.spool_limit` discloses the hard spool cap. Cursors are monotonically
increasing within a job; if the first returned sequence skips your cursor,
older events were evicted. `events` is a snapshot, not a lossless subscriber.
A recovered crash receipt does not synthesize a missing final replay event.

Deleting old directories is an explicit user retention decision. Never delete
an active job's directory. There is a 1024-directory cap, not automatic GC.
