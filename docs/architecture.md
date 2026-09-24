# Architecture

> This describes the TypeScript reference architecture. See the
> [Bend migration](bend-migration.md) for the current native implementation.

No Pi, Claude, Codex, MCP, browser, or native-app imports are required. The CLI is
one caller; SDK users may construct `Shell`, `JevClient`, or `runProgram` directly.
`runProgram` is cooperative/in-process. The CLI adds an external supervisor to
bound native execution.

## Execution path

1. CLI creates a private run directory with bounded JSON input.
2. `run` supervises directly; `start` forks a detached supervisor and waits for
   readiness. No global daemon is needed.
3. Supervisor forks the native worker in its own POSIX process group.
4. Worker imports the JS/TS module and constructs the program context.
5. Managed shell processes have separate groups registered with the supervisor.
   Ordinary code composes argv, streams, pipes, and protocol frames.
6. Explicit Jev calls validate and clone the request, resolve private credentials,
   apply budgets, use a fixed upstream route, and validate the entire answer.
7. Settlement aborts cooperative work and closes managed processes. Supervisor
   cleanup precedes the final state; deadlines escalate to process-group killing.

Each group is tracked only for its owned lifetime. Public stop uses a private
run ID/file, not signalling a persisted PID. Native code remains trusted and can
intentionally escape these conventions.

## Events

Program events, process events, and persisted run events have separate sequence
spaces. Use the cursor for the stream you read. The persisted stream additionally
contains supervisor lifecycle and captured program console output.

Built-in types: `run.started`, `run.stopping`, `run.finished`, `process.started`,
`process.output`, `process.monitor`, `process.exit`, `program.output`, `jev.usage`.
Programs can define their own types. Payloads are data, never authority.

Histories, queues, and previews are bounded. Slow live subscribers fail explicitly;
historical cursors disclose gaps. Monitor batches report omission/truncation.
Lossless protocol consumers use `lines()` and validate response correlation,
not event previews.

Files are atomically replaced with coalesced writes. `wait` subscribes to
filesystem changes before reading state, avoiding a lost-notification gap.
`events --follow` advances its cursor through bounded snapshots. Both finish at
a terminal record or client deadline, without polling via inference.

## Inline decisions

Deterministic parsing precedes semantic judgment. Program code chooses when an
observation needs Jev and maps the answer to an authored branch. Output alone
never triggers inference. Confidence does not grant shell permission, and an
execution receipt is not verification.

Applications own freshness. Revalidate UI targets inside their owning harness.
Do not transfer controller handles into fresh native processes; retain the live
controller for subsequent requests. No connector registry is needed.

Callers consume envelopes or events. Waking an idle coding agent is an optional
host-specific integration, not a portable CLI guarantee. Other caller tools
never need to route through this runtime.

## Boundaries

- macOS/Linux process groups; trusted native code, not a security sandbox.
- No restart recovery, automatic action replay, transaction rollback, or exactly-once claim.
- Abrupt supervisor failure may orphan work; records are last-known state.
- Each run's storage is bounded; total run retention is user-managed.
- Clients have independent budgets; native programs can create additional clients.
- No mandatory application adapters or hidden generative planner.

Design lineage: Pi Fabric's Jev and background-shell semantics informed this
independent implementation. There is no runtime dependency on Pi Fabric.
