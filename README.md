# jev-fabric

Native process orchestration with typed Jev decisions, independent of Pi, Codex,
Claude, or any other harness. Application logic is written in **Bend**; a small
POSIX bridge owns processes and private files. HTTPS uses system `curl` through
that same bridge, not another language runtime.

**The native executable needs neither Node nor Bun.** The preserved TypeScript
implementation is a [reference](docs/typescript-reference.md), not a dependency.
Native and reference APIs intentionally differ; this is not a drop-in SDK port.
Nothing is published.

## Quickstart

Build with **Bend 2.0.27**, Clang and Bun (for the build-time safety gate). Jev calls additionally require trusted `curl`
and a working system CA store. Source-program execution requires the toolchain;
precompiled programs and job controls do not.

```sh
sh scripts/build-native.sh                   # or bun run build
build/jev-fabric -- --help
build/jev-fabric -- exec /bin/echo hello
printf 'native stdin\n' | build/jev-fabric -- exec --stdin /bin/cat
build/jev-fabric -- run examples/native/pipeline.bend
build/jev-fabric -- run examples/native/persistent.bend
build/jev-fabric -- validate examples/native/request.json
```

The first `--` separates Bend runtime options from application arguments.
Shell syntax requires an explicitly invoked shell. Compile with `-o`: Bend's
JavaScript execution mode cannot run our native effects.

**Timers are optional.** Work defaults to a one-hour safety ceiling, Jev to 30
seconds, `wait` to 30 seconds and `watch` to five seconds. These are maximums,
not delays. Configure defaults once with `JEV_FABRIC_TIMEOUT_MS`,
`JEV_FABRIC_JEV_TIMEOUT_MS`, `JEV_FABRIC_WAIT_MS` and `JEV_FABRIC_WATCH_MS`, or
use a prefix override when needed: `exec --timeout-ms 5000 /bin/echo hello`.
Existing positional timeouts still work. For composed Bend programs,
[`Scope.open()` and `Scope.exec`](docs/native-api.md#scopebend-shared-deadline-budgets)
share one budget across operations; see `examples/native/scoped.bend`.

Background work survives its launcher:

```sh
build/jev-fabric -- start /bin/sh -c 'printf "ready\n"; sleep 10'
# Use the returned ID:
build/jev-fabric -- status <id>
build/jev-fabric -- events <id>                 # bounded JSONL replay
build/jev-fabric -- watch <id> ready            # live filtered line batches
build/jev-fabric -- wait <id>                   # wait does not cancel the job
build/jev-fabric -- stop <id>
```

Storage defaults to `.jev-fabric-native/`, or `JEV_FABRIC_HOME`. Roots and job
files are private; job IDs are not PIDs. Retention is bounded per job and by a
1024-directory limit per root. There is no automatic garbage collection.

## Explicit decisions

No output automatically triggers a model call. Native programs import
`native/Jev.bend` and thread an affine client through `Jev.evaluate`, or use:

```sh
# Opt-in network request; only the synthetic example is sent.
export JEV_PROVIDER=typesafe
export JEV_CREDENTIAL_COMMAND='["localterm","secret","get","typesafe_api_key"]'
build/jev-fabric -- jev examples/native/request.json 10000
```

Credentials resolve lazily from the provider environment variable or a bounded
literal argv command. They never enter curl argv or public receipts. HTTPS
verifies certificates/hostnames, rejects redirects, disables proxy/.curlrc
configuration, bounds output and time, and never retries automatically.
Provider responses pass strict JSON/UTF-8 and complete Choice/Noul/Score
validation; unrecognized response fields are stripped. Budgets bound calls and
reported tokens, not guaranteed billing: the final request can overshoot.

## Boundaries and verification

Project Bend code contains **no unsafe definitions**. Twelve pure policy modules
and three proof roots check without trust warnings; 27 explicit laws cover selected
runtime policy properties. Effect drivers retain an explicit foreign-code
boundary. See [safe Bend and proof coverage](docs/safe-bend.md)—this is not a
claim of whole-program formal verification.

Trusted native execution is **not a sandbox**. A zero exit means `exited`, not
verified task completion. Logs are bounded observations, not a lossless protocol;
no reboot resume, exactly-once execution, or protection from arbitrary native
code is promised. See the [native API](docs/native-api.md),
[acceptance ledger](docs/native-rewrite-ledger.md), and
[toolchain/migration limits](docs/bend-migration.md).

```sh
bun install --frozen-lockfile --ignore-scripts  # development only
bun run check:native-safety                   # also enforced by native builds
bun run test:native
bun run test:reference                         # needs Node 24+
bun run demo                                  # native; no model call
```

`package.json` registers `jev-fabric` as the built native executable and
`jev-fabric-reference` as the explicit reference CLI. Its JS exports remain the
reference compatibility SDK; native programs import `.bend` modules directly.
Build reference artifacts with `bun run build:reference` when needed.

System-wide npm and its shared cache remain untouched. The earlier cleanup was
project-local. No sibling project or compiler source is modified.
