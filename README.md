# jev-fabric

Process orchestration with Jev at decision boundaries, independent of Pi,
Codex, Claude, or any other harness.

**We are pivoting to native Bend. This is a working native spike, not yet a
feature-complete replacement for the TypeScript runtime.** The original
implementation remains available as a [reference](docs/typescript-reference.md)
until native parity is verified. Nothing is published.

## Native quickstart

Requires **Bend 2.0.27** and Clang (14+ for this CPU-only program).
The resulting executable needs neither Node nor Bun.

```sh
sh scripts/build-native.sh                 # or: bun run build
build/jev-fabric -- --help
build/jev-fabric -- exec 2000 /bin/echo hello
printf 'native stdin\n' | build/jev-fabric -- exec 2000 --stdin /bin/cat
build/jev-fabric -- exec 2000 /bin/sh -c 'printf hello | tr a-z A-Z'
```

The first `--` separates Bend runtime options from application arguments.
Shell syntax is interpreted only when you explicitly execute a shell.
This is **native-only**: compile with `-o`, rather than using Bend's default
JavaScript execution mode. There is no JavaScript foreign-effect twin.

Implemented in `native/`:

- **Bend:** budgets, terminal transitions, typed-value Choice/Noul/Score
  validation, literal monitor filtering/deduplication, bounded batches,
  JSON output, CLI control flow, and proof contracts.
- **C:** one POSIX process effect for argv/stdin, bounded output capture,
  asynchronous IO workers, deadlines, signals, and process-group cleanup.

A zero process exit is reported as `exited`, **not verified task completion**.
Native execution is trusted, not sandboxed. See the
[capability matrix, safety limits, and rollout blockers](docs/bend-migration.md).

## Verification

```sh
bun install --frozen-lockfile --ignore-scripts  # reference development dependencies
bun run test:native                           # Bend proofs, native binaries, Bun test driver
bun run test:reference                        # preserved TypeScript implementation
bun run test                                 # both
```

Bun is a development/test tool here, not a dependency of the native executable.
`build:reference`, the package SDK/bin entries, and `demo` retain the reference
implementation's compatibility surface; run `bun run build:reference` first.
The default `build` now builds Bend.

Local verification includes 23 core assertions, five proof contracts, three
native IO assertions, 12 native integration tests, and 26 reference tests.
The native CLI also passes checks under UBSan and C-effect-only ASan.
Whole-program ASan remains an unresolved compiler/runtime investigation; it
is **not** claimed green.

## What remains

Strict bounded JSON decoding and Jev HTTP/TLS/credential handling; persistent
JSONL and live output streams; detached start/status/events/wait/stop; durable
bounded event delivery; and supervision of arbitrary Bend programs.

Bend Base does not currently supply subprocess, HTTPS, or JSON APIs. The
confirmed route is **Bend-owned orchestration with a small native OS/TLS effect
layer**, not a TypeScript runner hidden behind Bend.

## Project history

- `ba74ea5`: verified original runtime, 26 tests passing.
- `2fa11e1`: Bun lockfile/workflow; project-local npm artifacts/cache removed.

The shared system npm installation/cache was intentionally not removed.
No real credentials were accessed during the Bend investigation.
