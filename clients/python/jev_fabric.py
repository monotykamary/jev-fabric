"""A thin client for `jev-fabric -- serve`, the JSONL session protocol.

One file, standard library only, Python 3.9+. Copy it next to your code, or
import it from ``~/.local/share/jev-fabric/current/clients/python``.

The client starts one ``serve`` child, writes one request line per call and
reads the matching response line. Budgets, deadlines, credentials and Jev
validation all live in the executable; this module only frames JSON.

    from jev_fabric import Fabric

    with Fabric(max_evaluations=10) as fabric:
        job = fabric.start(["/bin/sh", "-c", "npm run dev"])
        fabric.watch(job, "ready", timeout_ms=30000)
        answer = fabric.jev(request)
"""

from __future__ import annotations

import itertools
import json
import os
import subprocess
import threading
from typing import Any, Dict, List, Mapping, Optional, Sequence

__all__ = ["Fabric", "FabricError", "PROTOCOL"]

PROTOCOL = 1

Json = Dict[str, Any]


class FabricError(Exception):
    """A request the session refused or could not complete.

    ``code`` follows the CLI's exit codes: 2 for a malformed request, 22 for a
    rejected value, 124 for an expired deadline, 1 otherwise.
    """

    def __init__(self, code: int, message: str, op: Optional[str] = None) -> None:
        super().__init__(f"{op}: {message}" if op else message)
        self.code = code
        self.message = message
        self.op = op


class Fabric:
    """One ``jev-fabric -- serve`` session.

    ``timeout_ms`` bounds the whole session (default: the CLI work default, one
    hour). ``max_evaluations`` and ``max_tokens`` bound Jev calls for the whole
    session (defaults: 1 evaluation, 100000 reported tokens, as for ``jev``).
    ``binary`` defaults to ``$JEV_FABRIC_BIN`` or ``jev-fabric`` on PATH.

    Calls run one at a time; a lock makes the object safe to share between
    threads, but requests never overlap.
    """

    def __init__(
        self,
        *,
        binary: Optional[str] = None,
        timeout_ms: Optional[int] = None,
        max_evaluations: Optional[int] = None,
        max_tokens: Optional[int] = None,
        env: Optional[Mapping[str, str]] = None,
        cwd: Optional[str] = None,
    ) -> None:
        executable = binary or os.environ.get("JEV_FABRIC_BIN") or "jev-fabric"
        argv = [executable, "--", "serve"]
        if timeout_ms is not None:
            argv += ["--timeout-ms", str(timeout_ms)]
        if max_tokens is not None and max_evaluations is None:
            max_evaluations = 1
        if max_evaluations is not None:
            argv.append(str(max_evaluations))
        if max_tokens is not None:
            argv.append(str(max_tokens))
        self._process = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=None if env is None else dict(env),
            cwd=cwd,
        )
        self._ids = itertools.count(1)
        self._lock = threading.Lock()
        banner = self._read_line()
        ready = banner.get("ready")
        if not isinstance(ready, dict) or ready.get("protocol") != PROTOCOL:
            self.close()
            raise FabricError(1, f"unsupported serve protocol: {banner!r}")
        self.ready: Json = ready

    # -- processes -----------------------------------------------------------

    def exec(
        self,
        argv: Sequence[str],
        *,
        stdin: Optional[str] = None,
        timeout_ms: Optional[int] = None,
    ) -> Json:
        """Run literal argv to completion and return its bounded receipt.

        A nonzero exit is a receipt with ``state: "failed"``, not an error.
        """
        return self._call("exec", argv=list(argv), stdin=stdin, timeoutMs=timeout_ms)

    def start(self, argv: Sequence[str], *, timeout_ms: Optional[int] = None) -> str:
        """Start a detached job that outlives this session; returns its id."""
        return self._call("start", argv=list(argv), timeoutMs=timeout_ms)["id"]

    def status(self, job: str) -> Json:
        return self._call("status", job=job)

    def events(self, job: str, *, after: int = 0) -> List[Json]:
        """Retained events with a sequence above ``after`` (a bounded snapshot)."""
        return self._call("events", job=job, after=after)

    def wait(self, job: str, *, timeout_ms: Optional[int] = None) -> Json:
        """The final receipt, or the running state once ``timeout_ms`` passes."""
        return self._call("wait", job=job, timeoutMs=timeout_ms)

    def stop(self, job: str) -> Json:
        return self._call("stop", job=job)

    def watch(self, job: str, literal: str, *, timeout_ms: Optional[int] = None) -> List[Json]:
        """Live output lines containing ``literal``, as monitor records."""
        return self._call("watch", job=job, literal=literal, timeoutMs=timeout_ms)

    # -- Jev -----------------------------------------------------------------

    def validate(self, request: Json) -> Json:
        """Strictly validate a Jev request offline, without credentials."""
        return self._call("validate", request=request)

    def jev(self, request: Json, *, timeout_ms: Optional[int] = None) -> Json:
        """One explicit, billed evaluation against the session budget."""
        return self._call("jev", request=request, timeoutMs=timeout_ms)

    # -- session -------------------------------------------------------------

    def close(self, timeout: float = 10.0) -> int:
        """End the session by closing its input; returns the exit code."""
        process = self._process
        if process.stdin and not process.stdin.closed:
            try:
                process.stdin.close()
            except BrokenPipeError:
                pass
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            process.kill()
            return process.wait()

    def __enter__(self) -> "Fabric":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    # -- framing -------------------------------------------------------------

    def _call(self, op: str, **fields: Any) -> Any:
        with self._lock:
            request_id = next(self._ids)
            request = {"id": request_id, "op": op}
            request.update((k, v) for k, v in fields.items() if v is not None)
            line = json.dumps(request, ensure_ascii=False, separators=(",", ":"))
            try:
                assert self._process.stdin is not None
                self._process.stdin.write(line.encode("utf-8") + b"\n")
                self._process.stdin.flush()
            except (BrokenPipeError, ValueError):
                raise self._ended(op) from None
            response = self._read_line(op)
        if response.get("id") != request_id:
            raise FabricError(1, f"response id {response.get('id')!r} does not match {request_id}", op)
        if response.get("ok"):
            return response["result"]
        error = response.get("error") or {}
        raise FabricError(int(error.get("code", 1)), str(error.get("message", "request failed")), op)

    def _read_line(self, op: Optional[str] = None) -> Json:
        assert self._process.stdout is not None
        line = self._process.stdout.readline()
        if not line:
            raise self._ended(op)
        return json.loads(line)

    def _ended(self, op: Optional[str]) -> FabricError:
        code = self._process.wait()
        stderr = self._process.stderr.read().decode("utf-8", "replace").strip() if self._process.stderr else ""
        return FabricError(code or 1, stderr or f"serve exited with code {code}", op)
