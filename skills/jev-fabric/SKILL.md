---
name: jev-fabric
description: Run, supervise and observe native processes with bounded receipts, durable background jobs and live filtered watches, and make explicit typed Jev decisions (choice, noul, score) from structured state. Use when a task needs a long-running or detached command that outlives the shell tool call, bounded log observation instead of tailing everything, or a fast typed judgment over an observation rather than generated text. Also use it when Python, TypeScript or other code should drive processes and Jev calls through one budgeted JSONL session (`serve`).
---

# jev-fabric

`jev-fabric` is a single native executable (written in Bend, no Node or Python at
runtime). It owns child processes in their own process groups, keeps bounded
receipts and event logs, and makes **explicit** typed Jev decisions. No output ever
triggers a model call by itself: you decide when to ask.

The first `--` separates Bend runtime options from application arguments. Every
command starts with `jev-fabric --`.

## Check the install

```bash
jev-fabric -- --version        # 0.3.1-native (Bend 2.0.27)
```

If it is missing, install the release binary (macOS universal, Linux x64/arm64):

```bash
curl -fsSL https://raw.githubusercontent.com/monotykamary/jev-fabric/main/install.sh | sh
```

It installs to `~/.local/bin/jev-fabric` and the Bend library to
`~/.local/share/jev-fabric/current/native/`. `jev-fabric -- update` reruns that
installer for the latest release. Ask before installing or updating.

## Run something once

```bash
jev-fabric -- exec /bin/echo hello                       # literal argv, no shell
jev-fabric -- exec --timeout-ms 5000 -- make test        # bounded ceiling
printf 'input\n' | jev-fabric -- exec --stdin /bin/cat   # forward stdin
jev-fabric -- exec /bin/sh -c 'ls | wc -l'               # shells are explicit
```

The receipt is one JSON line: `state` (`exited`, `failed`, `timed_out`,
`cancelled`), `exitCode`, `timedOut`, bounded `stdout`/`stderr` tails (32 KiB) and
`truncated` flags. `exited` means the process exited, **not** that the task
succeeded: read the output and verify.

## Background jobs that outlive the tool call

```bash
id=$(jev-fabric -- start /bin/sh -c 'npm run dev' | jq -r .id)
jev-fabric -- status "$id"             # running state or final receipt
jev-fabric -- watch "$id" ready        # lines containing "ready" until exit or 5 s
jev-fabric -- events "$id"             # bounded JSONL replay (last 64 events)
jev-fabric -- events "$id" 12          # only events after sequence 12
jev-fabric -- wait --timeout-ms 60000 "$id"   # waiting never cancels the job
jev-fabric -- stop "$id"               # idempotent cooperative stop
```

- Job IDs are random, not PIDs. Storage is `.jev-fabric-native/` in the current
  directory, or `JEV_FABRIC_HOME`. Run controls from the same directory/home.
- `watch` returns `monitor.batch` lines (≤32 per batch), `monitor.loss` records when
  output was dropped, and a final `monitor.end` summary. A match is an observation,
  not proof of completion.
- Prefer `watch <id> <literal>` over repeatedly dumping `events` when you only need
  a signal such as `listening on`, `error` or `PASS`.

## Timers are ceilings, not delays

Defaults: work 1 h, Jev 30 s, `wait` 30 s, `watch` 5 s. Completion returns
immediately. Override once per call with `--timeout-ms N` placed **before** the
command, or globally with `JEV_FABRIC_TIMEOUT_MS`, `JEV_FABRIC_JEV_TIMEOUT_MS`,
`JEV_FABRIC_WAIT_MS`, `JEV_FABRIC_WATCH_MS`. Everything after the command is passed
through literally. Your own shell tool still has its own limit: use `start` for
anything longer than it.

## Typed Jev decisions

Jev answers structured questions about a state with typed values, not prose:

- `choice`: one key out of 1..255 described options, plus probabilities
- `noul`: a probability that a yes/no statement holds
- `score`: an ordinal position on 2..10 described levels

```bash
jev-fabric -- validate request.json                  # offline, no credentials
jev-fabric -- jev request.json 10000                 # one call, ≤10000 reported tokens
```

Provider and credentials come from the environment and are never printed:

```bash
export JEV_PROVIDER=typesafe          # or openrouter | vercel
export TYPESAFE_API_KEY=...           # or a literal argv resolver:
export JEV_CREDENTIAL_COMMAND='["pass","show","typesafe"]'
```

Rules:

- **Only call Jev when the user has authorized network model calls.** Each call is
  billed. Never loop Jev calls without a call budget.
- Validate first. Deterministic checks (exit codes, parsers, tests) come before any
  judgment; use Jev for the fuzzy part only.
- An answer is a decision input, not permission: confidence never widens what you
  are allowed to do, and an executed action still needs verification.
- No automatic retries. A failed dispatch still counts as a call.

See [references/jev-requests.md](references/jev-requests.md) for the request
schema, limits and patterns (including choosing among more than 255 options).

## Sessions from Python, TypeScript or any language

When code (not you, turn by turn) makes many calls, one `serve` session beats
repeated CLI invocations: one Jev client, so the call/token budget spans the
session, the credential resolves once and the TLS connection stays warm.

```bash
jev-fabric -- serve --timeout-ms 600000 20 50000   # 10 min, ≤20 Jev calls, ≤50000 tokens
```

Write one JSON request per line; read one response per line, in order:

```text
← {"ready":{"protocol":1,"version":"0.3.1-native",...}}
→ {"id":1,"op":"start","argv":["/bin/sh","-c","npm run dev"]}
← {"id":1,"ok":true,"result":{"id":"<job>"}}
→ {"id":2,"op":"watch","job":"<job>","literal":"ready","timeoutMs":30000}
← {"id":2,"ok":true,"result":[{"type":"monitor.batch",...},{"type":"monitor.end",...}]}
→ {"id":3,"op":"jev","request":{"state":...,"questions":{...}}}
← {"id":3,"ok":false,"error":{"code":1,"message":"Jev budget exhausted"}}
```

Ops: `exec` (`argv`, `stdin?`), `start` (`argv`), `status`/`stop` (`job`),
`events` (`job`, `after?`), `wait` (`job`), `watch` (`job`, `literal`),
`validate`/`jev` (`request`); most take `timeoutMs?`. Unknown fields are
rejected. Close stdin to end the session. Ready-made single-file clients live in
`~/.local/share/jev-fabric/current/clients/` (`python/jev_fabric.py`,
`typescript/jev-fabric.ts`). The protocol reference is `docs/serve-protocol.md`
in the repository.

## Composed programs in Bend

For loops that need persistent interactive child sessions, concurrent effects or
shared deadline scopes (a game bot, a crawler, a supervisor), write a Bend
program against the library and run it:

```bash
jev-fabric -- run program.bend arg1 arg2     # compiles (needs `bend` 2.0.27), then runs
```

HTTPS keeps one pooled TLS connection per process, so a Bend program or a
`serve` session making many calls is much faster than repeated `jev` CLI
invocations. See
[references/bend-api.md](references/bend-api.md).

## Boundaries

- Trusted native execution, **not a sandbox**. Commands run with your privileges.
- Shell syntax only happens when you invoke a shell explicitly.
- Logs are bounded observations: the first 1 MiB per stream is spooled, receipts
  keep 32 KiB tails, events keep the latest 64. Disclosed loss, never silent.
- No restart recovery, exactly-once execution or rollback. A crashed worker is
  reported failed, not resumed.
