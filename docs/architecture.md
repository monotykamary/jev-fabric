# Architecture

One native executable, written in Bend, owns processes, observations and Jev
calls. There is no daemon, no Node or Python at runtime, and no dependency on a
particular agent harness.

```text
 shell / agent tool call        Python / TypeScript / any language       Bend program
          │                                  │                               │
 jev-fabric -- <verb>            jev-fabric -- serve (JSONL)        jev-fabric -- run
          │                                  │                               │
          └──────────────┬───────────────────┴───────────────┬───────────────┘
                         │                                   │
          processes, jobs, watches                 one affine Jev client
      (owned process groups, deadlines,         (budget, cached credential,
       bounded receipts, spools, events)          pooled HTTPS connection)
```

## Three ways in

- **CLI verbs** (`exec`, `start`, `status`, `events`, `watch`, `wait`, `stop`,
  `validate`, `jev`) are one-shot. Each prints JSON and exits. Anything that can run
  a process can drive them. Each `jev` invocation is a fresh client: one call
  budget, one TLS handshake.
- **`serve`** is a session. One JSONL request per line, one response per line,
  over one process. It threads a single Jev client through every `jev` request,
  so budgets are session-wide and the connection stays warm. Process and job
  operations re-enter the executable as CLI children, so they share the CLI's
  exact receipts and a failing command cannot end the session. See the
  [protocol](serve-protocol.md) and the thin clients in `clients/`.
- **Bend programs** (`run`, or `import` from `native/`) get the full library:
  shared deadline scopes, persistent interactive sessions, concurrent effects and
  the checked pure policy modules. See the [native API](native-api.md).

## Modules

Each concern splits into a pure policy module and an effect driver
(`native/trust.json` lists them):

| Concern | Pure policy | Driver |
| --- | --- | --- |
| Arguments and timers | `Cli`, `TimeCore` | `Time`, `Scope`, `main` |
| JSON, UTF-8, Jev wire | `Codec`, `Json`, `Wire`, vendored strict JSON | |
| Jev client, HTTPS, credentials | `JevCore`, `HttpCore`, `CredentialCore`, `Core` | `Jev`, `Http`, `Credentials` |
| Processes and sessions | | `Process`, `Session`, `Input`, `Runner` |
| Durable jobs | `Streams` | `Jobs`, `Host` |
| Watches | `MonitorCore` | `Monitor` |
| JSONL sessions | `ServeCore` | `Serve` |

Pure modules typecheck with no trust warnings and may not import drivers, foreign
code or IO capabilities. Ten foreign C functions (`posix.c`, `host.c`, `pipe.c`,
`http.c`) are the only effects beyond stock Bend Base. See
[Safe Bend](safe-bend.md) for the exact guarantees.

## Execution

- Every child gets its own POSIX process group and a deadline. Deadlines escalate
  to killing the group; signals and foreign failures clean up owned groups.
- `start` forks a detached worker that re-enters the executable, holds an advisory
  lease on a private job directory, spools the first 1 MiB per stream and keeps the
  latest 64 events. Controls address the private job id, never a PID.
- `watch` polls those retained events and emits bounded, deduplicated line batches
  with explicit loss records.
- Jev requests are validated before credentials are resolved. Budgets are reserved
  before dispatch, answers are validated completely, and nothing is retried.

## Boundaries

- Trusted native code, not a security sandbox.
- No restart recovery, action replay, rollback or exactly-once claim. A crashed
  worker is reported failed, not resumed.
- Output, events and watches are bounded observations; loss is disclosed.
- Nothing calls Jev implicitly. A typed answer selects a branch the caller wrote,
  and an executed action still needs verification.

Design lineage: Pi Fabric's Jev and background-shell semantics informed this
independent implementation. There is no runtime dependency on Pi Fabric.
