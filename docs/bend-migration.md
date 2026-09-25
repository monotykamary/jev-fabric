# Native Bend migration

## Result and scope

The original process-only spike has become a native application path: strict
JSON/UTF-8, complete Jev wire validation, private credential resolution and
verified HTTPS, affine client budgets, source compilation/execution, detached
workers, live spools, atomic receipts, and bounded JSONL replay are implemented
in `native/`. See the [acceptance ledger](native-rewrite-ledger.md) and
[native API](native-api.md) for exact contracts and tested limits.

This is **not a drop-in TypeScript SDK rewrite**. Native programs use Bend IO,
source imports and explicit argv rather than `defineProgram`/Promise contexts.
Successful commands return `exited`, not inferred semantic completion. The
reference remains under `src/` with separate build/test commands, not hidden
behind the native executable. Interactive affine sessions and bounded line monitoring are also implemented;
exact limits and integrated evidence are tracked in the acceptance ledger.

## Minimal practical bridge

Stock Bend 2.0.27 has native files, sockets, clocks, channels and concurrent IO,
but no child-process ownership or HTTPS stack. Pure Bend libraries supply the
JSON/UTF-8 and typed decision logic; the system libcurl supplies verified,
pooled TLS in-process (`native/http.c` only loads and configures it), with the
system curl executable over the **existing process bridge** as the fallback. There
is no custom HTTP/TLS implementation or compiler fork. Research and source links: [native rewrite research](native-rewrite-research.md).

`native/posix.c` handles literal argv, POSIX spawn/poll/wait, owned groups,
cancellable IO, bounded raw capture/spools, signals and descriptor cleanup.
`native/host.c` handles private no-follow filesystem operations, atomic file
replacement, random job IDs, advisory ownership leases, self-executable lookup
and detached spawn. A 26-line `native/pipe.c` supplies owned pipe descriptors,
and `native/http.c` (330 lines) drives the system libcurl for pooled HTTPS.
Together these are 1461 physical C lines; none parses Jev JSON or decides
application policy.

Bend owns credentials, provider routes, curl config escaping, deadlines/budgets,
request/response validation, job state transitions, output framing, event
retention and polling. Base File handles are reused rather than wrapping a
second file IO implementation. The bridge is larger than the experimental
10-line fd adapter because safe lifecycle ownership and checked filesystem
access cannot be dropped merely to minimize line count.

## Differences and trust boundaries

- Native CLI syntax, receipts, modules and budget APIs differ from the reference.
- Wire numeric checks use exact decimals; native usage counts are 48-bit Nat,
  not every JavaScript-safe integer. Limits are explicit in the native API.
- Logs/replay are bounded and may coalesce/evict observations; not lossless RPC.
- No restart/reboot resume, automatic action replay, exactly-once promise or GC.
- No portable host-agent wakeup is implicit; callers integrate explicitly.
- Scope cancellation is process-wide. SIGKILL/crashes/escaped daemons can orphan
  work; native execution is trusted, **not a security sandbox**.
- Compiler invocations and source programs have an outside deadline. Individual
  in-process IO functions do not bound arbitrary Bend computation unless called
  inside such supervision.
- System libcurl/curl, compiler, imported native programs, PATH and CA
  configuration are trusted. Keys stay out of argv/logs but are accessible to their owning process.

## Toolchain findings retained from the spike

Local verification uses a working Bend 2.0.27 installation, macOS arm64, Apple
Clang 21 and Bun as a development driver. Linux native CI is configured but has
not been executed remotely in this session. Node 24+ is only for the reference.

The official 2.0.27 macOS arm64 archive matches its published checksum but fails
`codesign --verify --strict` and is killed by macOS. We do not re-sign it or bypass
system checks. `scripts/setup-bend-ci.sh` checks the archive hash and validates
macOS signatures; native CI currently targets Linux. A checksum match alone is
not a working compiler test.

**Whole-program ASan remains blocked**, not green. Base-only
`native/probes/asan-dispatch.bend` reproduces a failure without project imports
or custom C; a simpler argv probe passes. Historical scratch diagnostics found
`corpus_eval` failure and null-pointer arithmetic in generated Base IO C. We do
not patch the compiler to hide this finding.

```sh
mkdir -p build
bend native/probes/asan-dispatch.bend -o build/asan-dispatch.c
clang -std=c11 -O1 -g -fsanitize=address build/asan-dispatch.c -lpthread -lm -o build/asan-dispatch
ASAN_OPTIONS=detect_leaks=0 build/asan-dispatch -- --help
```

The earlier 12-test process spike passed UBSan and **C-effect-only** ASan with
generated runtime functions excluded and leak detection disabled. That is
historical evidence, not a blanket sanitizer claim for this expanded rewrite.
Current checks and live probes belong in the acceptance ledger.

The [safe-core refactor](safe-bend.md) eliminates project unsafe definitions and
checks 22 explicit policy laws across two proof roots. These include budget
rules, terminal decisions, encoder exhaustion and full-channel non-emission.
They do not prove C, compiler correctness, TLS security, model semantics or task
completion. Foreign-dependent drivers retain honest compiler trust warnings. The old
F32 helpers in Core are policy examples, **not** the wire-security boundary;
Wire's exact decimal validator is used for every Jev response.

## History

- `ba74ea5`: verified TypeScript baseline (26 tests).
- `2fa11e1`: Bun workflow and project-local npm artifact/cache removal.
- `bf74935`: native process spike.

System-wide npm/shared cache and sibling projects remain untouched. Removal of
the reference and broader distribution/platform claims should be separate,
deliberate decisions after native deployment evidence.
