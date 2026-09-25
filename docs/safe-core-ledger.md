# Safe Bend core acceptance ledger

- [x] No unsafe annotations or question-mark definition sugar in native Bend, including vendor/tests/examples.
- [x] Replace encoder recursion with finite fuel; preserve exact numbers, errors and byte limits.
- [x] Split pure monitor transitions from foreign IO and make both loops structurally decreasing.
- [x] Declare pure roots and an explicit effect-driver/foreign allowlist; check transitive imports, incomplete proofs and compiler trust reports.
- [x] Extend checked laws for real runtime budget/dispatch/monitor/codec policy; document exact guarantees, not whole-program correctness.
- [x] Negative tests show the gate rejects unsafe, holes and effect contamination.
- [x] Fresh native aggregate: 85 tests / 796 expectations pass, including the 10 new safety cases. The later qualified-IO-alias regression adds one more focused expectation (10 cases / 18 expectations pass).
- [x] Final gate after the qualified-IO check passes: all 42 Bend modules typecheck; ten pure modules and both proof roots have clean trust verdicts; exactly eight foreign declarations are allowlisted. Completed in 79 seconds with per-module progress.
- [x] Reference aggregate resolved: 31/31 pass after fixing pre-reap worker-group signalling. The original 25/26 result and diagnostics remain part of checkpoint `f0f0685`. The macOS zombie-group reproduction and its red/green tests were recorded in `docs/reference-cleanup-ledger.md`, removed with the TypeScript reference (see git history).

Evidence: `.tmp/safe-final.log` (fresh native suite and reference failure),
`.tmp/safe-targeted.log` (23 monitor/codec cases), and `.tmp/safety-gate.log`
(final gate). Logs are local/ignored; this ledger records the durable outcome.
A separate gate command with a 60-second whole-command limit timed out without
per-module progress; that timeout is not counted as success.

The existing compiler/runtime/Base, C effects, OS, curl and network remain trusted.
Removing unsafe is not a proof of wall-clock termination of foreign operations.
