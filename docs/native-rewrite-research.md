# Native rewrite research

> Historical feasibility checkpoint before implementation. The adopted design
> and current verification are in [the native rewrite ledger](native-rewrite-ledger.md).

## Decision

**A complete port of the harness/application logic to native Bend looks feasible.**
Stock Bend 2.0.27 still needs an OS boundary for subprocess management. There is
no reason to keep a JavaScript runtime merely for JSON, UTF-8, framing, budgets,
Jev wire validation, event records, or monitor policy.

The smallest practical first HTTP backend is the existing process effect plus
`curl`, with private configuration on stdin. This adds **zero HTTP-specific C**
to our bridge, but does depend on the curl executable. A libcurl effect is an
alternative if eliminating that executable dependency matters more than reducing
our host code. Neither approach makes TLS itself pure Bend.

At this research/feasibility checkpoint, no dependency had been adopted and no
production runtime code changed. These probes established feasibility, not
feature parity. Toolchain signing and whole-program ASan limitations remain.

## Acceptance ledger

| Question | Evidence / outcome |
| --- | --- |
| Can useful third-party Bend code compile on our stock compiler? | JSON and UTF-8 candidates compiled and ran with installed Bend 2.0.27 on macOS arm64 |
| Can JSON decoding stay entirely in Bend? | Stronger candidate passed nine targeted checks, including malformed syntax, exact number lexemes, and surrogate-pair decoding |
| Can byte handling stay in Bend? | Codec passed six Unicode checks; a 10-line owned-stdin effect reused Base `File.read_bytes` for one-byte reads of `A🙂B`, producing the expected checksum, 813 |
| Can we avoid writing an HTTP bridge? | Native Bend called the unchanged `Process.run` with curl; a loopback server verified POST, JSON body, and a synthetic Bearer header delivered through stdin configuration |
| Did that prove HTTPS/Jev parity? | **No.** The transport probe used loopback HTTP, synthetic credentials, and a small successful response; TLS, redirects, hostile bodies, provider schemas, and live Jev were not exercised |
| Were remote source pins checked? | Downloaded package manifests matched their content-addressed identifiers; selected files matched their full SHA-256 manifest entries |
| Was the existing bridge actually shrunk? | **No.** `native/posix.c` remains 211 physical lines; the smaller adapter proves descriptor reuse, not a replacement process supervisor |

Research scripts, downloaded sources, and binaries are in ignored
`.tmp/rewrite-research/`. These are local experiments, not installed dependencies
or a new project test suite. `assert-probes.ts` checks both JSON candidates, the
codec, and the descriptor checksum; `test-curl.ts` checks the local transport.
No real credentials were used by these probes.

## Existing implementations worth using

### JSON and Unicode: no custom C required

- [Standalone JSON package](https://hub.bend-lang.com/0xda09635d9d188749939d77eb0a5769b8):
  Apache-2.0, adapted from H4ad's library. An explicit parser-state/stack machine
  consumes the input structurally. Numbers retain their lexical representation,
  avoiding premature float rounding. On our targeted corpus it rejected missing
  commas/colons, trailing commas, bare words, unknown escapes, and leading zeros;
  `\uD83D\uDE42` decoded correctly. This is a **candidate, not a parser audit**.
  It still needs our byte/depth/token limits, duplicate-key policy, schema checks,
  and adversarial tests. Its encoder contains `@unsafe` definitions; successful
  parser probes do not establish encoder termination or correctness.
- [bend-codec-lib](https://hub.bend-lang.com/0x888714bde93f46c139372bb9fdc57a19):
  pure Bend byte/UTF-8 operations. Tested valid emoji and rejection of overlong
  encodings, surrogate code points, truncation, out-of-range scalars, and stray
  continuation bytes. Retain bytes across reads and decode complete frames;
  invoking a text decoder independently on every chunk loses split characters.
- [Bolt/LSP package](https://hub.bend-lang.com/0x729eecea86ea5a2cdba3a2856a313bca):
  useful examples of pure JSON, byte-counted framing, explicit transport state,
  and a tiny descriptor adapter. **Do not adopt its JSON parser unchanged:** the
  native probe confirmed it accepts all six malformed cases above and does not
  combine the surrogate pair correctly. Its small checker subprocess adapter
  also lacks our deadline/output-bound guarantees.

Preserve license/provenance and pin source before adoption. The inspected JSON
package includes an Apache license; do not assume every hub package has the same
license. A bounded input and a decreasing parser loop do not automatically bound
AST depth, downstream traversals, or memory overhead.

### HTTP: choose where the complexity lives

| Option | Our additional HTTP host code | Trade-off |
| --- | --- | --- |
| Existing process effect + curl | None | Extra executable; requires careful private config encoding and status/output handling |
| [libcurl effect package](https://hub.bend-lang.com/0x39cbd6b8923682f1e4deba6ee6056b43) | 296 physical C lines if adopted unchanged | Mature HTTP/TLS implementation behind a small effect; requires curl headers and a runtime libcurl |
| [Bend HTTP/1.1 stack](https://hub.bend-lang.com/0xbf477e663cf4acb1369a68e0f0fa713b) | Its wire adapter is 671 C lines | More protocol logic in Bend, but also DNS, HTTP framing, decompression, and a runtime OpenSSL dependency |

The libcurl package source enables peer/hostname verification, disables redirect
following, bounds received output, and performs the request through `io_work`.
Those are source observations, not an integration/security audit. Its generic
API permits HTTP as well as HTTPS; our authenticated Jev layer must require
HTTPS and an approved endpoint. Cancellation, resolver behavior, library loading,
proxy policy, and secret-safe errors still require tests.

For the curl backend, retain an explicit argv with `--disable` first so ambient
`.curlrc` cannot change policy. Feed config/body through private stdin, not
credential-bearing argv, shell interpolation, or event logs. Implement a real
curl-config value encoder rather than assuming JSON string escaping is identical.
Restrict authenticated requests to HTTPS, retain certificate verification, do not
follow redirects, reject non-success HTTP status and truncated bodies, and bound
time/body/header sizes. Test malicious config characters and error paths before
using a real credential. Our loopback probe is not that production client.

## What the local Bend checkout tells us

`bend/guide/GUIDE.md` documents affine `File`/`Socket` handles, `IO.fork`, channels,
and one interleaved IO scheduler. Existing IO should be reused, not rebuilt in C.
`bend/bend2/effs/file_read.c` already marshals raw bytes into Bend lists.

However, that file also shows a blocking `read` on a helper thread. It has no
per-read deadline/cancellation argument. A ten-line `fcntl(F_DUPFD_CLOEXEC)`
adapter can return an independently owned `File`, but it does **not** establish
cancellable process streaming. Nonblocking pipe reads/readiness with deadlines,
process-group control, and guaranteed cleanup still need a host mechanism.
Duplicating an inherited descriptor is preferable to forging multiple affine
handles around the same raw descriptor.

The [H4ad/bend-stdlib upstream README](https://github.com/H4ad/bend-stdlib)
explicitly distinguishes stock-compatible byte/integer/JSON packages from
HTTP/TLS/crypto packages requiring a compiler fork and added native effects.
Its TLS surface wraps OpenSSL; it is not evidence for zero-C TLS on stock Bend.
Its Node/pnpm linker is also unnecessary for our chosen pinned standalone-source
route. We should not fork the compiler or restore a Node runtime just to use it.

Useful Bend-specific patterns from the inspected code:

- Consume an input list/string with an explicit state/stack rather than hide
  parser control flow in foreign code.
- Put the decreasing fuel/input argument **before** changing handles/state;
  Bend checks structural descent left to right. The descriptor probe verified
  this restriction directly.
- Use `match` or delayed branches for guards. Ordinary `Bool.pick`, `Bool.and`,
  and `Bool.or` evaluate their arguments; they are not lazy safety gates.
- Keep raw bytes until a complete frame is available. A `String` transport is
  not a substitute for byte-exact IO.
- Separate pure policy/proofs from foreign effects; proofs do not establish
  correctness of a C adapter, TLS library, or subprocess cleanup.

## Recommended minimal boundary and port order

Keep only OS mechanisms at the boundary: spawn/owned descriptors, process-group
signal/reap, deadline-aware byte IO, and any missing secure filesystem operations
needed for durable jobs. Keep emergency cleanup in the host where Bend tasks
cannot guarantee it. Move framing, capture policy, request/response validation,
monitor rules, budgets, state transitions, and serialization to Bend.

Use scope-owned children and deterministic cleanup rather than fire-and-forget
forks; [Eio's process API](https://ocaml-multicore.github.io/eio/eio/Eio/Process/index.html)
is a useful established pattern. If HTTP volume later requires libcurl multi,
its [official integration model](https://curl.se/libcurl/c/libcurl-multi.html)
shows how readiness/timer events fit an existing loop instead of creating a
second application scheduler.

1. Pin/review the pure JSON and UTF-8 candidates; add limits and Jev schema tests.
2. Implement native Jev with a bounded curl transport and private credential
   resolution using the existing process primitive. Keep request budgets and
   secret-safe failures in Bend.
3. Introduce owned stream primitives; implement incremental framing and bounded
   channel/backpressure policy in Bend, with deadline/cancellation probes.
4. Port durable events, detached workers, status/wait/stop, and monitor behavior.
5. Retire the TypeScript reference only after semantic parity and lifecycle tests.

A complete bridge may exceed today's 211 lines because the native slice lacks
major capabilities. Minimize **host-owned responsibility**, not line count at the
expense of process ownership, bounds, TLS verification, or cleanup. Moving C into
a compiler fork or a dependency does not remove it from the trusted computing base.
