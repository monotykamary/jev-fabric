# Acceptance ledger

> This ledger covers the preserved TypeScript reference. Native Bend coverage
> and outstanding work are tracked in [the native rewrite ledger](native-rewrite-ledger.md).

The initial release is a trusted, native process orchestrator, not a tool registry,
sandbox, chat agent, or restart-resumable workflow engine. No Pi dependency or
changes to the sibling projects are required.

Execution path: CLI → supervisor → isolated native worker → program context →
managed processes / explicit Jev client → bounded events → terminal result.
Detached runs have their own supervisor. Stop requests address private run
handles, never user-supplied PIDs. The supervisor enforces the wall-clock limit
outside the worker so a synchronous loop cannot disable it.

Checks to close before handoff:

- [x] Public package exports and executable CLI build and typecheck.
- [x] Choice/Noul/Score requests and complete answers validate; malformed answers fail closed.
- [x] Fixed upstream routes, private credentials, cancellation, request limits, and explicit budgets.
- [x] Argv, shell/heredoc, stdin, pipes, nonzero exit, and persistent JSONL composition work.
- [x] Managed process trees terminate on completion, cancellation, and deadline.
- [x] Output/event history, queues, lines, and process concurrency stay bounded; loss is explicit.
- [x] Monitors filter, coalesce, deduplicate, and expire without implicit inference.
- [x] Native JS/TS programs return finite JSON or an explicit needs_attention handoff.
- [x] Background start/status/events/wait/stop work across CLI processes without PID signalling.
- [x] An infinite synchronous program is stopped by its supervisor deadline.
- [x] Deterministic examples run without credentials; model examples are explicitly opt-in.
- [x] Documentation describes trust, data sharing, ownership, portability, and non-goals.

The default suite uses synthetic HTTP responses and local child processes only.
After explicit authorization, two live Jev requests used synthetic build text
and a private Localterm credential resolver. No personal browser/app control,
global installation, publishing, or sibling-project edits occurred.

See [verification evidence](verification.md) for commands and outcomes.
