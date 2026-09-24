# Native Bend migration

## Decision

A native executable is feasible and demonstrated. A literally all-`.bend`
implementation is not available using Bend 2.0.27 Base alone: it has files,
sockets, clocks, channels, and concurrent IO, but no subprocess, HTTPS, or JSON
API. JSON can be a Bend library; process/TLS facilities need foreign effects
or additions to the language runtime. We do not modify Bend itself.

The implementation is a native **vertical slice**, not a completed rewrite.
`src/` is the working TypeScript reference. Default builds now target Bend;
reference builds are explicit. Keeping the reference prevents silently losing
background control, typed wire validation, and credential handling.

## Acceptance ledger

| Check | Status / evidence |
| --- | --- |
| Preserve a green baseline before the pivot | `ba74ea5`, 26 reference tests |
| Remove active project npm usage/artifacts | `2fa11e1`, `bun.lock`; local npm installations, tarballs, reports and cache cleared |
| Native binary with no JS foreign twin | `native/main.bend` + `native/posix.c`; restricted-PATH execution test |
| Typed policy and bounded observations | `native/Core.bend`; 23 compiled core assertions |
| Explicit proof scope | Five checked contracts in `native/tests/proofs.bend` |
| Real native IO, not synchronous event-loop blocking | Two dependent subprocesses launched through `IO.fork`; three IO assertions |
| Literal argv, Unicode, JSON escaping, heredocs and pipes | Native integration tests |
| Buffered stdin and direct stdin passthrough | Native IO and integration tests |
| Exit receipts, tails, timeout and cancellation | Native integration tests; exited is not completed |
| Owned-work cleanup on a foreign failure | Native fail-fast fixture and PID liveness check |
| Existing behavior remains usable | `bun run test:reference`, 26 tests |
| Native ABI under UBSan | 12 CLI integration tests with the instrumented CLI; IO fixtures use normal native builds |
| Pinned compiler acquisition | Published archive checksum verified; macOS execution blocked by invalid upstream signature |
| Custom C effect under ASan | 12 CLI checks pass with generated runtime functions explicitly excluded; IO fixtures use normal builds |
| Whole-program ASan | **Blocked/investigating**; Base-only dispatch reproducer also faults |
| Linux CI | Configured with checksum-pinned Bend; not executed remotely in this session |
| Complete native feature parity | **Not yet implemented**, matrix below |

Verification was local on macOS arm64 with the installed Bend 2.0.27, Apple
Clang 21, and Bun 1.4.2. The pinned macOS archive was not used successfully to
run the suite; its hash passing is not the same as its executable working.

## Capability matrix

| Capability | Native slice | Reference |
| --- | --- | --- |
| Budget reservation and token accounting | Bend policy functions | Yes |
| Terminal-state transitions | Bend policy functions | Yes |
| Choice/Noul/Score numeric/distribution rules | Typed-value validators | Full request/response wire validation |
| Jev HTTPS, private credentials, redirect policy | Pending | Yes |
| Strict bounded JSON decoding | Pending; encoder only | Yes |
| Command argv, explicit shell, heredocs/pipelines | Yes | Yes |
| Concurrent commands and bounded capture | Yes | Yes |
| Buffered stdin / direct inherited stdin | Yes | Yes |
| Persistent handles, live streams, JSONL protocol | Pending | Yes |
| Filtering/deduplication and bounded batches | Pure Bend functions; not a live monitor engine | Yes |
| Detached lifecycle commands and durable events | Pending | Yes |
| Arbitrary program runner with outside deadline | Pending; compile Bend programs explicitly | JS/TS runner |
| Harness-specific session wakeup | Not implicit | Optional explicit notifier command |

## Native effect contract

`Process.Native.exec` is the single custom effect. `Process.run` supplies
bounded buffered input; `Process.run_stdin` explicitly inherits descriptor 0.
The helper thread uses POSIX spawn/poll/wait. It never evaluates Bend terms:
argv is decoded on the IO loop, then the receipt is packed there after work
completes. The C entrypoint is registered with `io_eff(CID_NATIVE_EXEC, ...)`.
There is no `.js` companion, embedded Node, Bun, or TypeScript interpreter.

A launched command returns a JSON receipt even when it exits nonzero. Pre-launch
validation/spawn failures currently use sanitized stderr and a nonzero CLI
status, not a JSON receipt; this is another explicit native/reference difference.

Limits are per native process:

- At most eight concurrent child commands; excess requests fail closed.
- Up to 64 argv elements including the executable, 4096 UTF-8 bytes each;
  embedded NUL is rejected.
- Buffered input up to 128 KiB. Inherited stdin is streamed by the OS and is
  **not** subject to that buffering cap.
- Separate 32 KiB stdout/stderr tails, with explicit truncation flags.
- Timeout range 1..3,600,000 ms, measured after spawn returns. Kernel spawn,
  arbitrary Bend computation, and foreign calls are not a whole-program deadline.
- Up to 100 ms final drain; held-open pipes are closed with truncation disclosed.

SIGINT/SIGTERM mark cancellation; helper threads terminate their owned groups
and reap direct children. Exit cleanup also handles another effect failing.
Signal handling is currently process-wide; this is not a general embeddable
signal broker. Deliberately escaped daemons, SIGKILL, or a native crash require
outside supervision. This is trusted native execution, **not a security sandbox**.
External side effects are not rolled back. Text decoding uses Bend's UTF-8
replacement behavior; the capture API is not a lossless binary transport.

## Proof and numerical boundaries

The five proof contracts establish exhaustion refusal, completed/cancelled
terminal absorption, and conservative next steps for executed/unknown receipts.
They are implementation contracts, not fabricated human-authored `LAWS.bend`
requirements. They do not prove the C implementation, compiler correctness,
security isolation, provider semantics, or task completion. Bend correctly
reports foreign-code reliance in the CLI and IO fixtures.

The current typed validators use F32. They match the reference's basic ranges,
key coverage and mass tolerance for representable values, not every JavaScript
Number boundary. A future decoder must validate exact numeric bounds before
conversion, plus question IDs, metadata, token counts, duplicate keys, byte/depth
limits, Unicode and complete response coverage. These functions must not be
mistaken for an already-complete safe HTTP response decoder.

## Toolchain findings

The official 2.0.27 macOS arm64 archive matches the checksum advertised by the
installer, but macOS kills its executable and `codesign --verify --strict`
reports an invalid signature. We do not re-sign it or bypass system checks.
Native CI is Linux-only for now; reference CI retains Linux/macOS coverage.
The installer script validates macOS signatures rather than hiding this issue.
A working, trusted local Bend 2.0.27 installation was used for local native tests.

ASan builds of the dispatch program fault before executing our subprocess
effect. `native/probes/asan-dispatch.bend` reproduces the failure using only
Base, without project imports or custom C. A simpler Base-only argv program
passes ASan, so the problem is not universal and remains unresolved. Preserving
ASan's handlers in generated scratch C located the failure in `corpus_eval`.
A combined ASan/UBSan minimal Base IO probe also reports null-pointer arithmetic
in generated C. We do not alter the compiler or claim an ASan pass.

To reproduce the dispatch finding (generated output stays ignored):

```sh
mkdir -p build
bend native/probes/asan-dispatch.bend -o build/asan-dispatch.c
clang -std=c11 -O1 -g -fsanitize=address build/asan-dispatch.c -lpthread -lm -o build/asan-dispatch
ASAN_OPTIONS=detect_leaks=0 build/asan-dispatch -- --help
```

The CLI's 12 checks also pass with **only `native/posix.c` instrumented by ASan**:
generated runtime functions were explicitly marked `no_sanitize("address")` in
scratch C, leaving the verbatim custom effect instrumented. This is useful C
boundary evidence, not a whole-program ASan pass. Leak detection was disabled;
the separate IO/fail-fast fixture executables were normal builds.

The normal CLI passes all 12 integration tests under UBSan alone. The test
harness supports `JEV_NATIVE_BIN` for such diagnostic binaries. Diagnostic
failures are recorded, not silently converted into successful verification.

## Remaining migration order

1. Build a bounded JSON parser and strict wire validator in Bend. Decide exact
   decimal/UTF-8 handling rather than relying on lossy F32/text conversion.
2. Add private credential resolution and fixed-route HTTPS effects, keeping
   secrets out of argv, events, errors and returned state. Re-run synthetic live
   Jev probes only after this boundary is covered.
3. Replace capture-only commands with owned affine stream/session handles,
   persistent JSONL, cancellation, quotas and cleanup; keep filtering in Bend.
4. Implement durable bounded events, detached workers and external deadlines.
   Port all reference lifecycle tests before making the native CLI a replacement.
5. Resolve compiler packaging/sanitizer findings, verify supported platforms,
   then remove the reference implementation in a separate deliberate commit.

The shared system npm binary and cache were left untouched. This migration
removed project-local npm material, not unrelated tools or other repositories.
