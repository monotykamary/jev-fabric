# Verification evidence

> Historical evidence for the TypeScript baseline. Current native coverage and
> limitations are recorded in [the native rewrite ledger](native-rewrite-ledger.md).

Initial implementation verified on 2026-09-24.

## Offline

- `npm test`: **26 passed, 0 failed** on Node 26.5.0.
- Node 24: initial complete 25-test suite plus CLI regressions passed. The added
  pre-launch SIGINT regression also passed after replacing a timing-dependent
  test signal with an explicit stdin-reader readiness handshake.
- All four TypeScript examples typechecked against the package's public exports.
- `pipeline.ts`: verified uppercase output, zero evaluations.
- `persistent-rpc.ts`: verified response correlation and persistent counts
  `[1, 2, 3]`, zero evaluations.
- `monitor.ts`: verified exact READY detection and owned-process cleanup,
  zero evaluations.
- Local tarball installed into ignored scratch space with scripts disabled and
  no global installation. Its real bin and an external program importing
  `defineProgram` completed a verified subprocess probe.
- Package inspection confirmed the CLI entry, declaration exports, included
  docs, and excluded test artifacts. Linux/macOS Node 24 CI is configured;
  Linux CI has not been executed in this local session.

Offline coverage lives in `tests/jev.test.ts`, `tests/process.test.ts`, and
`tests/cli.test.ts`: typed validation, budgets, credential-error redaction,
request cloning/cancellation, event loss, shell/heredoc/pipeline composition,
persistent JSONL, monitor expiry, process cleanup on observer failure, detached
control, wait independence, private records, and an external deadline killing
an infinite synchronous worker plus its managed process.

## Authorized live probes

Exactly **two** requests, synthetic text only, TypeSafe route, model `jev-1.13.0`.
The credential resolver executed `localterm secret get typesafe_api_key`
privately; its output was neither displayed nor written to artifacts.

1. `evaluate --request examples/decision.json`: Choice selected `inspect`, Noul
   returned `0.99` for explicit failure, Score returned `2` (build blocked).
   Usage: 408 input / 61 output tokens.
2. `run examples/semantic-monitor.ts --max-evaluations 1`: monitored a synthetic
   shell failure, made one judgment, then returned `needs_attention` with
   `Investigate the missing dependency` (expected exit 3).
   Usage: 349 input / 31 output tokens.

No automatic retries, screenshots, browser connections, or native application
control were involved. These are wire/composition probes, not a general model
accuracy, latency, or GUI-reliability benchmark.
