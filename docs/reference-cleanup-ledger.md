# Reference process-group cleanup acceptance

- [x] Safe-Bend checkpoint committed separately as `f0f0685` with the failure documented.
- [x] Explain/reproduce EPERM at the owned worker exit boundary, not just rerun until green.
- [x] Deterministic regression for the observed race and genuine permission failures.
- [x] Preserve descendant cleanup, cancellation, deadlines and handoff exit/state.
- [x] No blanket EPERM suppression or signalling unowned/arbitrary processes.
- [x] Targeted and full reference checks pass, with direct repeated handoff probes.

## Cause and fix

A direct owned-child C probe on macOS reproduced this eight times: after the
child exits but before `waitpid`, group signal-zero and SIGKILL both fail with
EPERM, while the leader's signal-zero succeeds. After reaping, the same absent
group reports ESRCH. A zombie-only group can therefore look like a permission
failure; the handoff message can arrive before the parent's child-exit callback.

`supervise` previously signalled the worker's group immediately on its result
(or forced deadline), then again in the exit callback. The first call could hit
that zombie window. Its exception was thrown again by the error path, crashing
the CLI instead of preserving the handoff receipt.

The first termination now uses `worker.kill('SIGKILL')`, the owned ChildProcess
handle. The existing exit callback still signals the **group after reaping** to
clean up surviving descendants. Managed process groups retain their existing
cleanup; `killGroup` still throws genuine EPERM and ignores only ESRCH. This
fix does not introduce blanket permission-error suppression or a new guarantee
that arbitrary privileged/uncooperative descendants can always be terminated.

## Verification

Three deterministic integration cases inject EPERM if the worker group is
signalled before the leader has been reaped. All three failed against the old
implementation and pass with the fix: handoff, forced deadline, and a surviving
inherited descendant. The fixture tracks owned worker PIDs over private IPC so
its deliberately failing version can still be cleaned up.

A helper regression checks that real permission failures are not swallowed.
An uninstrumented public-CLI probe runs 24 handoffs across four concurrent lanes;
every invocation must return exit 3 and `needs_attention`. It uses no preload or
extra IPC channel. The complete reference suite passes **31/31** after a fresh
TypeScript build. Existing stop/wait, infinite-worker deadline and managed-child
reaping tests also pass. Native source/effects are unchanged from the verified
safe-core checkpoint (85 native tests, 42 checked Bend modules, 22 laws).

Local evidence: `.tmp/group-exit-probe.c` and `.tmp/reference-fixed.log`.
