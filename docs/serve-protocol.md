# The serve protocol

`jev-fabric -- serve` is a JSONL session over stdin and stdout for callers in any
language. One session holds one affine Jev client (its call and token budget, its
cached credential and its warm pooled HTTPS connection) and one deadline. Every
other operation reuses the CLI's contracts: the receipts, job records and monitor
records are the same JSON the CLI prints.

The protocol is the contract. [`clients/python/jev_fabric.py`](../clients/python/jev_fabric.py)
and [`clients/typescript/jev-fabric.ts`](../clients/typescript/jev-fabric.ts) are
thin convenience wrappers around it, and `native/tests/serve.test.ts` checks it
against the executable.

## Session

```sh
jev-fabric -- serve [--timeout-ms N] [max-evaluations [max-tokens]]
```

| Option | Default | Meaning |
| --- | --- | --- |
| `--timeout-ms N` | `JEV_FABRIC_TIMEOUT_MS`, else 1 hour | Deadline for the whole session, 1..3600000 ms |
| `max-evaluations` | 1 | Jev calls for the whole session, as `Jev.connect`. `0` disables Jev |
| `max-tokens` | 100000 | Reported Jev tokens for the whole session |

The budgets are explicit and session-wide. They are not renewed per request, and
failed dispatches still count. Invalid options, a malformed timer environment or
an invalid provider configuration exit (code 2 or 1) before the banner.

The first output line is the banner. Read it before sending requests:

```json
{"ready":{"protocol":1,"version":"0.3.1-native","timeoutMs":3600000,"maxEvaluations":1,"maxTokens":100000}}
```

The session ends when stdin closes (exit 0). It also ends when its deadline has
passed (exit 124), when a partial line grows beyond 1 MiB (exit 2), or after
16,777,216 reads of stdin (exit 1). Jobs started in a session keep running after it ends.

## Requests and responses

Each request is one line of strict JSON (UTF-8, at most 1 MiB, no duplicate keys),
terminated by `\n`. A trailing `\r` is ignored, blank lines are skipped, and an
unterminated last line is answered at end of input.

```json
{"id":1,"op":"exec","argv":["/bin/echo","hi"]}
```

`id` is optional: a string of at most 128 characters or a number, echoed verbatim.
`op` selects the operation. **Unknown fields are rejected**, so a misspelled option
never goes unnoticed.

Each request gets exactly one response line, in request order. Requests run one at
a time, so a client may pipeline them and match responses by `id`.

```json
{"id":1,"ok":true,"result":{...}}
{"id":2,"ok":false,"error":{"code":2,"message":"unknown request field: timeout"}}
```

A line that is not strict JSON is answered with `"id":null`. A failed request
never ends the session. Only the deadline, an oversized line or end of input do.

Error codes follow the CLI:

| Code | Meaning |
| --- | --- |
| 2 | Malformed request: unknown op or field, missing field, out-of-range value |
| 22 | Rejected value: invalid JSON limits, invalid Jev request, unsafe job access |
| 124 | The session deadline has passed |
| 1 | Anything else, for example `Jev budget exhausted` |
| other | The exit code of a failing CLI step |

## Operations

| `op` | Fields | Result |
| --- | --- | --- |
| `exec` | `argv`, `stdin?`, `timeoutMs?` | Process receipt, as `exec` |
| `start` | `argv`, `timeoutMs?` | `{"id": job}`, as `start` |
| `status` | `job` | Running state or final receipt |
| `events` | `job`, `after?` | Array of retained events with a sequence above `after` |
| `wait` | `job`, `timeoutMs?` | Final receipt, or the running state once `timeoutMs` passes |
| `stop` | `job` | Receipt or running state after a cooperative stop |
| `watch` | `job`, `literal`, `timeoutMs?` | Array of `monitor.batch`, `monitor.loss` and `monitor.end` records |
| `validate` | `request` | The validated Jev request, offline |
| `jev` | `request`, `timeoutMs?` | The validated Jev answer: `model`, `answers`, `usage` |

- `argv` is a literal array of 1..57 strings (the 64-entry process limit less the
  CLI prefix). Each entry is at most 4096 UTF-8 bytes. `argv[0]` must be non-empty.
  No shell is involved unless you name one.
- `stdin` is buffered input for `exec`, at most 128 KiB, closed after writing.
- `timeoutMs` is an integer. `watch` accepts 1..300000, the others 1..3600000.
  Defaults: `exec` runs until the session deadline; `start` uses the work
  default (1 hour) for the job's own lifetime; `wait` and `watch` use
  `JEV_FABRIC_WAIT_MS` (30 s) and `JEV_FABRIC_WATCH_MS` (5 s); `jev` uses the
  client's `JEV_FABRIC_JEV_TIMEOUT_MS` (30 s).
- `job` is an id returned by `start`. It must not be empty or start with `-`.
- `after` is an event sequence number, default 0.
- `request` is a Jev request object, validated exactly as `jev-fabric -- validate`.

A nonzero exit is a receipt with `"state":"failed"`, not an error. Errors mean the
operation itself could not run, for example a missing executable or an unknown job.

## Deadlines

The session deadline is checked before each request. Once less than two seconds
remain, requests are refused with code 124 and the session ends. The two seconds
are a receipt grace: `exec`, `wait` and `watch` get the requested (or default)
time, cut to the remaining session time less that grace, so their child always
has time to report. `status`, `events`, `stop` and `start`'s readiness handshake
each get at most 15 seconds. A job's own lifetime is not bounded by the session.

A request that is running is never interrupted by later input. Timers are
ceilings, not delays: completion returns immediately.

## How requests run

`validate` and `jev` run inside the session process, threading one affine
`Jev.Client` through every call, as a Bend program does. Its credential is
resolved on the first call and cached in that client, and HTTPS keeps its pooled
TLS connection between calls.

Every process and job operation runs the same executable as a child
(`jev-fabric -- exec …`, `-- start …`, …) under a deadline, and relays its JSON
output. So a command that cannot launch costs one error response, never the
session. It also means process operations pay one extra process start (tens of
milliseconds). Children inherit the session's environment, including
`JEV_FABRIC_HOME`, so job ids work across sessions and the CLI.

## Boundaries

- Trusted native execution, not a sandbox. `serve` runs commands with the
  caller's privileges, like the CLI.
- One request at a time per session. For parallel work, `start` jobs and watch them,
  or open more sessions. Each session has its own budget.
- Nothing calls Jev implicitly: only a `jev` request does.
- Output is bounded exactly as in the CLI (32 KiB receipt tails, 64 retained
  events, `watch` limits). Each CLI step's stdout is also capped at 1 MiB.
- stdin may be a pipe, a socket (as Node, Bun and libuv children get), a
  terminal or a file: `serve` reads a duplicate of its inherited descriptor.
