# jev-fabric

**Process orchestration with typed System One decisions. No required agent harness or tool registry.**

The calling harness owns intent. Ordinary code owns execution. Jev supplies
small typed judgments only where a semantic decision is needed.

```text
Codex / Claude / Pi / shell
            │
    native JS/TS program
            │
  processes ↔ bounded events
            │
    optional Jev judgment
            │
 code-owned action or handoff
```

Initial local release: `private: true`, no publishing or automatic harness
installation. Requires **Node 24+ on macOS/Linux**, plus `bash` for shell scripts.
No runtime npm dependencies.

## Quickstart

```sh
bun install --frozen-lockfile
bun run build
node dist/src/cli.js run examples/pipeline.ts
node dist/src/cli.js run examples/persistent-rpc.ts
node dist/src/cli.js run examples/monitor.ts
bun run test
```

These examples and the test suite are offline: local fixture processes, no model
keys, browser, or native apps. The installed binary is `jev-fabric`; the
`node dist/src/cli.js` form works directly from the checkout.

## Ordinary programs

Programs default-export a function. `defineProgram` is an optional typing helper:

```ts
import { defineProgram } from 'jev-fabric';

export default defineProgram(async ({ shell, emit, handoff }) => {
  const receipt = await shell.exec({
    command: 'node', args: ['-e', 'console.log("ready")'],
  });
  if (receipt.exitCode !== 0) handoff('Command failed', { exitCode: receipt.exitCode });
  if (receipt.stdout.trim() !== 'ready') handoff('Unexpected result');
  emit('verified', { ready: true });
  return { ready: true };
});
```

Examples resolve the package self-reference after building. External projects
can install the checkout as a local dependency. Imports resolve from the program
file. TypeScript uses Node's built-in type stripping: use erasable syntax, not
enums or parameter properties. Stripping is **not typechecking**; typecheck
programs with their own project tooling. Validate input and postconditions in code.

Context:

- `input`: finite JSON from `--input file.json` / `--input -`, otherwise `null`.
- `shell.spawn(options)`: a live owned process; `shell.exec(options)` awaits it.
- `shell.script(source, options?)`: explicit `bash -euo pipefail -c` execution.
- `jev.evaluate({state, questions})`: typed judgments, never generated prose.
- `events.subscribe(after?)`: bounded runtime events with historical gap markers.
- `emit(type, data)`, `sleep(ms)`, `signal`: progress and cooperative cancellation.
- `handoff(reason, evidence?)`: terminal `needs_attention`, not successful completion.

Results must be finite JSON, at most 32 KiB; return `null`, not `undefined`.
Handoff evidence is capped at 16 KiB; input at 128 KiB. These are interface
bounds, **not native-code memory isolation**.

## Shells, pipes, heredocs, persistent subprocesses

`command` plus `args` executes without a shell; metacharacters stay literal.
Use `shell.script` when shell interpretation is intended. No application adapter
or automatic connection discovery is required.

```ts
const result = await shell.script("cat <<'TEXT' | tr a-z A-Z\nhello\nTEXT");
const child = shell.spawn({ command: 'some-jsonl-server', args: [] });
const replies = child.lines(); // subscribe BEFORE sending requests
await child.write(JSON.stringify({ id: 1, method: 'observe' }) + '\n');
const frame = await replies.next();
// Validate frame.done, JSON, response ID, and result/error against the server contract.
child.end();
const receipt = await child.wait();
```

Handles expose `write`, `end`, `pipeTo`, `lines`, `events`, `wait`, and `stop`.
`exec` closes stdin; `spawn` keeps it open unless `input` is supplied. `pipeTo`
streams stdout into another handle's stdin with Node backpressure. Check **each**
receipt in a pipeline. `env` overrides individual inherited environment entries.

`lines('stdout' | 'stderr', capacity?)` fails on overflow or lines over 128 KiB;
it never silently drops protocol messages. Final unterminated text is returned
as a line; protocols requiring newlines must account for this. Close abandoned
iterators. Bounded event previews are **not lossless RPC transports**.

A JavaScript module may also come from stdin:

```sh
node dist/src/cli.js run - <<'JS'
export default async ({ shell }) => {
  const result = await shell.script('printf "hello\\n"');
  return { output: result.stdout, exitCode: result.exitCode };
};
JS
```

Stdin modules are stored privately with the run. Their imports resolve from the
run directory, not the working directory; use a program file for local imports.
Shell commands still run in the caller's working directory. Program source and
JSON input cannot both consume stdin.

### Browser/macOS harness composition

Use their existing CLIs or libraries. An explicitly authorized browser snippet
can be passed as `input` to `shell.exec({command:'browser-harness-js',
input:snippet})`. Its existing daemon preserves the browser connection. Follow
its session/scope setup; jev-fabric never connects automatically.

For native AX, retain `shell.spawn({command:'macos-harness', args:['serve',
'--app','com.apple.TextEdit']})` and exchange JSON lines. Prefer its guarded
observe/act contract; a new process per action loses controller handles. These
are integration patterns, **not automatically executed commands**. Authorize
targets and permissions first. Existing guarded controllers need no registration
here. Raw access is not permission to bypass a denial.

## Background runs and monitors

```sh
node dist/src/cli.js start examples/monitor.ts
node dist/src/cli.js status <id>
node dist/src/cli.js events <id> --after 0 --follow
node dist/src/cli.js wait <id>
node dist/src/cli.js stop <id>
```

`start` returns after an independent supervisor is ready. It owns the worker and
managed process groups until settlement or deadline; the caller may exit. No
model waits for processes. `stop` addresses a private run handle, never an
arbitrary PID. Terminal stop/wait requests are idempotent.

`run` cancels on SIGINT/SIGTERM. Cancelling `wait`/event following does **not** stop
the run. Their default client deadline is 30 seconds (`--timeout-ms` overrides
it); that never extends the program deadline.

```ts
const job = shell.spawn({
  command: './watch-build.sh',
  monitor: { match: 'STATUS:', intervalMs: 250, lifetimeMs: 300000 },
});
for await (const event of job.events()) {
  if (event.type !== 'process.monitor') continue;
  // Exact parsing first; explicitly call Jev only for a semantic question.
}
```

Monitors frame stdout incrementally, apply an optional **literal** match,
suppress adjacent duplicate matching lines, and batch at most eight previews.
Omissions and truncation are explicit. `intervalMs` is **delivery cadence**, not
the watched script's polling interval. Expiration stops the process. There is
no automatic renewal, restart, or inference. Stderr is captured separately;
quiet output does not prove a process is stuck.

`examples/monitor.ts` recognizes an exact READY marker without Jev.
`examples/semantic-monitor.ts` makes one real judgment over a synthetic build
failure and should hand back `needs_attention` (exit 3).

## Jev authentication and judgments

`JEV_PROVIDER`: `typesafe` (default), `openrouter`, or `vercel`. Keys:
`TYPESAFE_API_KEY`, `OPENROUTER_API_KEY`, or `AI_GATEWAY_API_KEY`, respectively.
`JEV_MODEL` can select a provider-appropriate model ID. Endpoints are fixed HTTPS
URLs; redirects are rejected.

Alternatively, explicitly configure a **trusted argv command**, not shell code:

```sh
export JEV_CREDENTIAL_COMMAND='["localterm","secret","get","typesafe_api_key"]'
node dist/src/cli.js evaluate --request examples/decision.json
node dist/src/cli.js run examples/semantic-monitor.ts --max-evaluations 1
```

These commands make **paid requests** over synthetic example data. No live calls
run in tests/CI. Help/status and deterministic programs never retrieve a key.
An SDK key or provider environment key takes precedence over the command. The
command executes only when needed, has a 5-second deadline and 16 KiB private
output limit, and caches its successful key per client. Keys never enter request
bodies, run records, or this client's diagnostics. Command errors and HTTP error
bodies are suppressed. Trusted native programs can access credentials themselves:
this is data hygiene, **not secret isolation**.

SDK: `new JevClient({provider, credentialCommand, maxEvaluations, maxTokens})`.
Tests can inject `fetch`; there is no implicit mock mode that could accidentally
execute real actions using fake judgments.

Questions share state and are independent; batch them when possible. Choice
selects supplied options. Noul returns a yes probability. Score is a weighted
position over 2–10 ordered levels, not necessarily 0–1. Confidence is neither
permission nor verification. Never evaluate model answers as shell code. State
goes to the selected provider: minimize it, exclude secrets, and obtain consent.

## Limits and output

Program defaults: **60 seconds, 100 evaluations, 100,000 reported tokens**.
Override with `--timeout-ms`, `--max-evaluations`, and `--max-tokens`. The supervisor
enforces the deadline outside the native worker, with up to 500 ms cancellation
grace before killing the worker and registered process groups. An infinite
synchronous loop cannot disable that supervisor deadline.

One evaluation per client can be in flight. Failed dispatches spend evaluation
budget. No inference or effect retries are automatic. Token usage arrives after
inference: the last request can exceed the threshold and still incur charges;
failed requests may also be billed. This is **not a hard dollar cap**.

Managed shell defaults: eight active processes, 1,000 starts, 32 KiB tail per
stdout/stderr with truncation flags. The run retains 128 events, each with at
most 4 KiB data; each process retains 64. Cursor gaps/overflow are explicit.
These are bounded previews, **not full-output archives**.

Results are JSON; `events --follow` is NDJSON. Program console output is captured
as events, not mixed into result stdout. CLI errors are JSON on stderr.

| Exit | Meaning |
| --- | --- |
| 0 | Command succeeded; `run`/`wait` completed |
| 1 | Program failed |
| 2 | CLI/input/transport error or client wait timeout |
| 3 | Caller attention needed |
| 124 | Run deadline exceeded |
| 130 | Run cancelled |

`status`, `events`, and `stop` report command success separately from run state.
Inspect `state`. Exit zero is not independent goal verification. Cancellation is
not rollback; inspect uncertain effects instead of blindly replaying them.

## Trust, storage, non-goals

**Native programs run with your OS permissions. This is not a sandbox, approval
engine, or replacement for your harness's restrictions.** Approving a launch is
not inspecting every nested effect. Do not launch untrusted programs. Output is
untrusted data, not instructions.

Storage: `--state-dir`, `JEV_FABRIC_STATE_DIR`, or
`${XDG_STATE_HOME:-~/.local/state}/jev-fabric`. Private run directories contain
atomic, owner-readable records. Input, stdin source, output, and explicit evidence
may be sensitive. There is no general DLP filter or automatic retention cleanup.
Remove old **terminal** directories per your retention policy; never delete active
state. A local package install does not modify any agent's configuration.

Records persist; running programs do **not** resume after crashes. Abrupt
supervisor death can leave orphaned processes and a last-known `running` record.
`status` is persisted state, not a distributed liveness proof. `wait`/`stop` are
bounded and never signal a potentially recycled PID to recover an abandoned run.
Unmanaged native subprocesses or daemonization can escape cleanup/accounting.
Windows, durable recovery, action replay, exactly-once guarantees, global daemons,
tool registries, implicit transcript access, and host-specific agent wakeups are
outside this initial release.

See [architecture](docs/architecture.md) and [acceptance](docs/acceptance.md).
