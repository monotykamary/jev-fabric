# Safe Bend and the trusted boundary

## What is established

There are **zero unsafe definitions** in the project's native Bend, vendored
Bend, probes, tests or native examples: neither `@unsafe` nor `def f?` is used.
Every such module is checked by stock Bend 2.0.27. No proof holes or unimplemented
laws are permitted. No C, runtime or compiler changes were used to achieve this.

`native/trust.json` declares twelve pure production modules, three proof roots and
thirteen effect-driver modules. Each pure module and each proof root must report
exactly **`All terms check.`**. Their transitive project dependencies cannot
include drivers, foreign imports, or explicit Base IO/handle capabilities.

These are termination/typechecking and **specified-property** guarantees under
the trusted compiler/Base model. They are not a proof of every application
behavior, of the code generator, or of runtime memory safety.

## Actual execution boundary

- `Core`, `Json`, `Codec`, `Wire`, `Streams`, and the vendored strict JSON module
  supply pure budgets, bounded validation, exact wire arithmetic and framing.
- `MonitorCore` turns raw event snapshots into bounded observations and typed
  `Poll`/`Stop` decisions. `Monitor` interprets them with reads, writes and sleep.
- `HttpCore` validates inputs and constructs a typed request plan. `Http`
  interprets only successful plans. Curl argv construction has **no inputs**;
  credentials and bodies are supplied through private stdin, never argv.
- `CredentialCore` validates credential output/argv. `Credentials` owns the
  effectful lookup. `JevCore` owns routing, response normalization and budget
  accounting; `Jev` threads an affine client through the external operations.
- `TimeCore` owns bounded defaults, integer validation and remaining-budget
  arithmetic; `Cli` parses prefix options and legacy syntax into typed plans.
  `Time` resolves environment settings; `Scope` samples the clock and dispatches
  using the remaining budget, without adding a foreign primitive.
- The remaining drivers coordinate process/session/job lifecycles, input and
  source compilation. Their foreign-dependent behavior is **conditional**, not
  certified by the pure proofs. This is not an assertion that all orchestration
  behavior has been modeled or proved.

The exact eight foreign declarations are allowlisted in `native/trust.json`:
six in `Process.bend`, two in `Host.bend`. Their implementations total
1126 physical C lines. IO wrappers still legitimately produce Bend's combined
"unsafe or foreign code" warning; with no project unsafe definitions remaining,
the project boundary is foreign code. We do not suppress that warning.

## Terminating implementations, not relocated unsafe

Monitor event handlers now process **one event**, without recursion. One outer
fold consumes the input list. The effect interpreter separately consumes Nat
fuel, just as the job controller already does. Stopping decisions are data, not
callbacks that can re-enter a non-decreasing loop.

The encoder expands **one worklist item** per step and consumes Nat fuel in one
outer loop. Numeric validation is ordered after the parser, eliminating the
unsafe forward reference. The vendor writer now has a 131072-job ceiling;
`JSON.write_with_fuel` makes exhaustion explicit. Public `Codec.encode` still
validates its AST with 32768 jobs, checks exact number lexemes and bounds the
encoded output. Exhaustion is an error, never a successful truncated encoding.

Both loops remain finite even if external observations report no progress.
However, a bound on Bend steps is not a bound on foreign-call wall-clock time.

## Exact checked contracts

`native/tests/proofs.bend` contains the five original laws: exhausted evaluation
budgets refuse reservations; completed/cancelled states absorb later results;
unknown receipts require inspection; execution requires verification.

`native/tests/policy-proofs.bend` adds seventeen laws over the runtime policies:

- denied reservation returns no budget;
- a permitted reservation with zero spent tokens and token limit one consumes
  exactly one call (this theorem is deliberately not stated for arbitrary
  already-spent token budgets);
- a zero token budget blocks a reservation;
- token accounting never refunds a call;
- failed and timed-out Core states are absorbing;
- terminal, output-limited and expired monitor decisions do not request polling;
- a disabled filter emits nothing;
- pushing to a channel at the 1024-line cap preserves the entire channel and
  emits nothing, for arbitrary framing/pending contents and input line;
- encoding any value with zero fuel fails;
- rejected HTTP configuration produces no request plan;
- rejected credentials return a fixed error without the key;
- failed/truncated transport rejects its bytes;
- reported usage marked oversized returns a disabled client budget;
- an invalid typed reply remains a sanitized failure.

`native/tests/time-proofs.bend` adds five definitional policy contracts:
denied timeout validation remains an error; omitted configuration uses its
fallback; elapsed time is subtracted rather than renewed; the local cap is
applied before U32 narrowing; duplicate timeout specifications are rejected.
These do not prove clock honesty, scheduler latency or process-tree cleanup.

These are **27 explicit laws**, not 27 proofs of whole modules. In particular,
there is not yet a complete JSON round-trip proof, a general wire-schema
soundness theorem, an aggregate monitor-size induction, or a proof that actual
OS processes obey the reported lifecycle. The pure architecture enables further
proofs without first importing foreign operations into their dependencies.

## Build/CI enforcement

```sh
bun run check:native-safety
bun run build
bun run test:native
```

Ordinary native builds run `scripts/check-native-safety.ts`; native CI runs the
same build path. The gate lexes all native/example Bend, checks classifications,
local transitive imports, explicit IO capabilities, the exact foreign allowlist,
unsafe spellings, proof holes and missing law bodies. It then checks **every
module** with the pinned compiler, rejecting trust/incomplete verdicts in the
pure closure. Imports are checked even when currently unused.

The lexer/manifest checks supplement the compiler; they are not a new proof
kernel or a formally verified purity checker. Adversarial tests exercise unsafe
syntax, holes, missing laws, foreign imports, indirect driver dependencies,
Base IO, missing/escaping imports and compiler verdict rejection. Compiled
native edge probes separately test encoder fuel and request/monitor gates.

## Trusted assumptions and limits

Bend's checker, compiler, runtime and Base implementation remain trusted. So do
the C effects, OS, scheduler, filesystem ownership model, system curl/CA store
and deployment PATH. Bend cannot prove that a foreign call returns, that a
clock advances, or that an observed receipt describes reality. Owned-process
supervision and external deadlines provide operational defenses, not proofs of
those assumptions. Existing toolchain/ASan caveats still apply.

Jev's judgment truth and semantic task completion are outside these proofs.
This is not a sandbox: trusted callers can construct values or call low-level
effects directly, and the source-program runner can execute user-provided Bend
outside this repository's audited source set. No proof or safety claim for such
programs is implied by a successful build of jev-fabric.
