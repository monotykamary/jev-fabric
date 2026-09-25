# Timer ergonomics acceptance

- [x] Timer-free CLI forms for exec/run/start/jev/wait/watch, with prefix
  `--timeout-ms` overrides and legacy positional syntax retained.
- [x] Central finite defaults: work 1 hour, Jev 30 seconds, wait 30 seconds,
  watch 5 seconds. Four documented environment settings; invalid defaults fail
  before effects, explicit limits override the corresponding default.
- [x] Prefix parsing stops at the executable/source. Child arguments remain
  literal; command-local `--` escapes numeric and option-like executable names.
- [x] Timer-free Process/Session/Jev convenience APIs and a shared deadline
  budget for composed Bend workflows. Child calls sample remaining time, never
  a fresh full allowance. Local caps cannot extend the sampled budget.
- [x] Expired budgets prevent process/session launch, credential retrieval and
  Jev reservation/dispatch. Scoped Jev preserves its affine client's credential
  cache, call/token accounting and original per-request settings.
- [x] Pure parser/deadline policy, five checked definitional laws and trust
  registrations. No unsafe definitions, proof holes or new foreign primitives.
- [x] Updated help, primary documentation, demo and native examples; fresh full
  native and reference suites, direct examples, public-symbol and manifest checks.

## Verification

- `bun run test:native`: **94 pass, 0 fail**, 965 assertions across 10 files.
  Freshly built all fixtures. The safety gate checked **50 Bend modules**,
  including 12 pure production modules and three proof roots. There are 27
  explicit laws and the same eight foreign entrypoints; all three C files are
  unchanged. Evidence: `.tmp/timer-native-suite.log` (local, ignored).
- `bun run test:reference`: **31 pass, 0 fail**.
  Evidence: `.tmp/timer-reference-suite.log` (local, ignored).
- All three process examples were compiled and executed through timer-free
  `run`: shell pipeline, three-request persistent JSONL session, concurrent
  shared-budget calls. A separate source probe exercised `Process.exec_stdin`.
- Nine new integration tests plus 24 pure policy assertions cover defaults,
  configuration/override precedence, overflow rejection, literal argv, source
  args, detached observation, no-effect expiry, reaping, affine client caching
  and per-request limit restoration. HTTP/credential tests use local synthetic
  fixtures; no real API requests or credentials were used.
- Initial fake-curl log assertions incorrectly split curl's newline-bearing
  write-out argument. The fixture now records only the rounded max-time from
  private stdin; a separate slow-request test proves exact native ms enforcement.
- Explicit structural review: no JS/TS findings; Bend/C remain outside Contour's
  coverage. Manual execution-path inspection, stock Bend checks and behavioral
  probes supply that evidence instead. `git diff --check` passes.

## Deliberate boundaries

A deadline budget is not an isolated resource group. Cancellation remains
owning-native-process-wide and sticky. Cross-process automatic budget
inheritance is not promised: the outer `run` deadline is not automatically
inherited by `Scope.open` inside the program. Validation/scheduling/launch
latency is not a hard-real-time theorem. Native crashes/SIGKILL, daemon escape,
and the calling harness's independent limits remain outside this abstraction.

The raw explicit-time APIs and old CLI forms remain available. Defaults keep
the existing finite lifetime boundary; there is no unlimited/zero timeout mode.
