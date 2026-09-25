"""Supervise a server from Python through one `jev-fabric -- serve` session.

    python3 examples/clients/supervise.py          # offline: no credentials, no model call
    python3 examples/clients/supervise.py --live   # one billed Jev call (needs credentials)

Starts a detached job, watches for "ready", reads a bounded receipt, and turns
the observation into a typed Jev request. Only --live sends it.
"""

import json
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(here, "..", "..", "clients", "python"))

from jev_fabric import Fabric  # noqa: E402

SERVER = "echo booting; sleep 0.2; echo 'listening on :8080 ready'; sleep 0.2; echo 'warning: cache cold'"

live = "--live" in sys.argv[1:]
with Fabric(max_evaluations=1 if live else 0) as fabric:
    job = fabric.start(["/bin/sh", "-c", SERVER])
    fabric.watch(job, "ready", timeout_ms=10000)
    receipt = fabric.wait(job, timeout_ms=10000)

    request = fabric.validate({
        "state": {"log": receipt["stdout"], "exitCode": receipt["exitCode"]},
        "questions": {
            "healthy": {"type": "noul", "instructions": "Did the server start and stay healthy?"},
            "next": {
                "type": "choice",
                "instructions": "What should happen next?",
                "criteria": {"proceed": "Start the test suite", "investigate": "Inspect the warning first"},
            },
        },
    })
    if not live:
        print(json.dumps({"job": job, "state": receipt["state"], "validated": sorted(request["questions"])}))
    else:
        answers = fabric.jev(request)["answers"]
        # A typed answer picks a branch the program already wrote.
        print(json.dumps({"job": job, "next": answers["next"]["choice"], "healthy": answers["healthy"]["noul"]}))
