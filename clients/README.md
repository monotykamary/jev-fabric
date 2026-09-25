# serve clients

Single-file clients for [`jev-fabric -- serve`](../docs/serve-protocol.md), the
JSONL session protocol. Each one starts a `serve` child, writes one request line
per call and returns the matching response. Neither holds policy: budgets,
deadlines, credentials and validation stay in the executable.

| Client | Requires | Import |
| --- | --- | --- |
| [`python/jev_fabric.py`](python/jev_fabric.py) | Python 3.9+, stdlib only | `from jev_fabric import Fabric` |
| [`typescript/jev-fabric.ts`](typescript/jev-fabric.ts) | Bun, Deno or Node 22.6+, `node:` built-ins only | `import { Fabric } from './jev-fabric.ts'` |

Copy the file into your project, or import it from
`~/.local/share/jev-fabric/current/clients/` after installing a release. Both
find the executable through `binary`, then `$JEV_FABRIC_BIN`, then `jev-fabric`
on PATH.

Both expose the same operations: `exec`, `start`, `status`, `events`, `wait`,
`stop`, `watch`, `validate`, `jev` and `close`. A refused request raises
`FabricError` with the protocol's `code` and `message`. Examples:
[`examples/clients/`](../examples/clients/).

Tests run against the real executable as part of `bun run test:native`
(`native/tests/clients.test.ts` runs `python/test_jev_fabric.py` too).
