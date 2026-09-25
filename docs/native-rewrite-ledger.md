# Native rewrite acceptance ledger

This records the original rewrite checkpoint (`1188cbe`). The subsequent no-unsafe
refactor and its current verification status are tracked in
[safe-core-ledger.md](safe-core-ledger.md) and [safe-bend.md](safe-bend.md).

Execution path: native CLI → Bend runner / detached worker → owned POSIX process
scope → private byte capture/spools → Bend UTF-8/JSON/wire validation → explicit
Jev client → bounded receipt/events. No Node/Bun is in this runtime path.

| Check | Implementation / evidence |
| --- | --- |
| Strict bounded JSON, UTF-8, duplicate keys, resource bounds | Codec + pinned vendor; 35 codec / 15 resource assertions, adversarial corpus |
| Complete Choice/Noul/Score contracts, exact decimals, safe output stripping | Wire; 28 compiled assertions plus malformed/fraction/exponent corpus |
| HTTPS only, verified CA/hostname, no redirects/proxies/.curlrc | Http; five local TLS behavior cases passed, including byte bound and timeout |
| Private env/literal-argv credentials, sanitized failures, cache | Credentials/Jev; seven synthetic client cases passed; no keys in argv/output |
| Affine client, reservation, failed-call accounting, overflow-safe reported-token limits | Jev client tests passed; invalid requests/credentials and exhausted budgets never dispatch |
| Native JSON validation/Jev public CLI and examples | Registered in main; real request-file checks passed with no JS runtime on PATH |
| Literal argv, shells/heredocs, binary private capture, outside deadlines | Process, Input, Runner; prior process tests plus new actual CLI probes |
| Native source runner, stdin/argv, private artifacts, synchronous loop supervision | Six CLI cases verified, including compiled-loop execution and compile timeout |
| Durable native jobs, private FS, idempotent stop, live events and bounded replay | Jobs/Host; 15 behavior cases verified; Streams has 8 native assertions |
| Live line monitoring | Monitor; 15 pure assertions, eight behavior cases; hard per-stream caps and explicit loss/limit disclosure |
| Interactive owned sessions | Session + small pipe effect; seven cases cover stateful live JSONL, EOF, binary IO, limits, concurrent sessions, cancellation, blocked writers and 96 failed launches under fd limit64 |
| Native package bin/default demo, explicit reference compatibility | package.json + CLI registration test; frozen Bun lockfile check |
| Preserved TypeScript reference | Typecheck and all 26 reference tests passed after integration |
| Complete native aggregate regression | `bun run test`: **75 native cases / 779 expects, 26 reference cases; zero failures**, from 14 freshly rebuilt native fixtures |
| Linux CI | Configured; not executed remotely in this session |
| Whole-program ASan | Known compiler/runtime blocker; not claimed green |

## Final integrated verification

`bun run test` passed on the complete patch: 75 native cases across eight suites,
779 Bun assertions, all 26 reference cases, five proof contracts, and the
compiled native assertion fixtures. The native CLI, opt-in judgment example and
persistent-session example typecheck. The deterministic pipeline and persistent
JSONL examples also execute natively.

Fixture compilation inside Bun test hooks stalled during integration. The final
runner builds all 14 fixtures fresh **before** the test phase, using the native
supervisor's 90-second process-group deadline per compilation and explicit phase
logging. Standalone hook fallbacks use that supervisor too. The full successful
build/test run took about 403 seconds; the native behavior phase took 45 seconds.
No failed/timed-out run is counted as passing, and no stale binary is accepted as
the aggregate build's evidence.

Final review additionally fixed a transferred-stdin descriptor leak on invalid
session launches, bounded directory enumeration, a transient inheritable
iteration descriptor, and the monitor's within-snapshot emission overshoot.
Session failure cleanup was exercised 96 times under an fd limit of 64. The
monitor's hard limit is 1024 lines per stream (2048 combined); a 1024-line
combined stopping threshold and `outputLimitReached` disclose bounded overshoot.

The custom OS bridge totals **1461 physical C lines** across `posix.c`, `host.c`,
the 26-line `pipe.c` and `http.c`, which loads and configures the system libcurl
for pooled HTTPS. There is no custom HTTP/TLS implementation; system libcurl and
the curl executable fallback are explicit.
Bend owns the application and wire policy. Contour structural review covered the
JS/TS tests with an advisory fixture-helper branch count; it does not cover or
certify Bend/C. Those boundaries were inspected and behavior-tested directly.

## Authorized live native smoke test

One additional request on 2026-09-24, only `examples/native/request.json` synthetic
build text. `localterm secret get typesafe_api_key` resolved privately; the key
was neither inspected nor printed/stored. Actual compiled native CLI used real
curl/TLS and TypeSafe model `jev-1.13.0`:

- Noul healthy: `0.95`.
- Choice next: `verify`, complete distribution.
- Score confidence: `1.0`, complete legend/distribution.
- Reported usage: **380 input / 61 output tokens**.

No automatic retry, screenshots, app/browser control, publishing, or unrelated
repository edits. This validates wire/composition, not model accuracy generally.
The two earlier live reference requests were recorded in `docs/verification.md`,
removed with the TypeScript reference (see git history).

## Explicit differences

Native source/module/CLI APIs are not the JS SDK. Exact decimal validation and
48-bit usage counts have documented limits. Spools/replay are bounded observations
rather than lossless RPC; there is no reboot resume, SIGKILL orphan guarantee,
automatic GC or host-agent notification. A zero process exit is `exited`, not
verified task completion. Detailed contracts: `native-api.md`.
