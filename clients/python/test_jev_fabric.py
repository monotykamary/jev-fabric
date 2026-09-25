"""Offline tests for the Python serve client.

    JEV_FABRIC_BIN=build/jev-fabric python3 clients/python/test_jev_fabric.py

native/tests/clients.test.ts runs this file as part of the native suite.
"""

import os
import shutil
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from jev_fabric import Fabric, FabricError  # noqa: E402

REQUEST = {
    "state": "synthetic",
    "questions": {"ok": {"type": "noul", "instructions": "Is two plus two four?"}},
}


class FabricTest(unittest.TestCase):
    def setUp(self):
        # Job storage refuses symlinked paths, such as macOS's /var -> /private/var.
        parent = os.environ.get("JEV_FABRIC_TEST_TMP") or os.path.realpath(tempfile.gettempdir())
        self.home = tempfile.mkdtemp(prefix="jev-fabric-py-", dir=parent)
        self.env = {"PATH": os.environ["PATH"], "JEV_FABRIC_HOME": self.home}

    def tearDown(self):
        shutil.rmtree(self.home, ignore_errors=True)

    def open(self, **options):
        return Fabric(env=self.env, **options)

    def test_ready_reports_session_budgets(self):
        with self.open(timeout_ms=60000, max_evaluations=4, max_tokens=900) as fabric:
            self.assertEqual(fabric.ready["protocol"], 1)
            self.assertEqual(fabric.ready["timeoutMs"], 60000)
            self.assertEqual(fabric.ready["maxEvaluations"], 4)
            self.assertEqual(fabric.ready["maxTokens"], 900)
        with self.open(max_tokens=10) as fabric:
            self.assertEqual(fabric.ready["maxEvaluations"], 1)

    def test_exec_receipts_and_errors(self):
        with self.open() as fabric:
            self.assertEqual(fabric.exec(["/bin/echo", "hi"])["stdout"], "hi\n")
            self.assertEqual(fabric.exec(["/bin/cat"], stdin="é\n")["stdout"], "é\n")
            failed = fabric.exec(["/bin/sh", "-c", "exit 3"])
            self.assertEqual((failed["state"], failed["exitCode"]), ("failed", 3))
            with self.assertRaises(FabricError) as caught:
                fabric.exec([])
            self.assertEqual(caught.exception.code, 2)
            self.assertEqual(caught.exception.op, "exec")
            self.assertEqual(fabric.exec(["/bin/echo", "after"])["stdout"], "after\n")
        self.assertEqual(fabric.close(), 0)

    def test_jobs(self):
        with self.open() as fabric:
            job = fabric.start(["/bin/sh", "-c", "sleep 0.2; echo ready; sleep 0.2"])
            records = fabric.watch(job, "ready", timeout_ms=5000)
            lines = [line["text"] for r in records if r["type"] == "monitor.batch" for line in r["lines"]]
            self.assertEqual(lines, ["ready"])
            self.assertEqual(fabric.wait(job, timeout_ms=5000)["state"], "exited")
            self.assertEqual(fabric.status(job)["stdout"], "ready\n")
            self.assertTrue(all("sequence" in e for e in fabric.events(job)))
            self.assertEqual(fabric.stop(job)["state"], "exited")

    def test_validate_and_jev_budget(self):
        with self.open(max_evaluations=0) as fabric:
            self.assertEqual(fabric.validate(REQUEST), REQUEST)
            with self.assertRaises(FabricError) as caught:
                fabric.validate({"state": "x", "questions": {}})
            self.assertEqual(caught.exception.code, 22)
            with self.assertRaises(FabricError) as caught:
                fabric.jev(REQUEST)
            self.assertEqual(caught.exception.message, "Jev budget exhausted")

    def test_threads_share_one_session(self):
        results = []
        with self.open() as fabric:
            def run(n):
                results.append(fabric.exec(["/bin/echo", str(n)])["stdout"])
            threads = [threading.Thread(target=run, args=(n,)) for n in range(4)]
            for t in threads:
                t.start()
            for t in threads:
                t.join()
        self.assertEqual(sorted(results), ["0\n", "1\n", "2\n", "3\n"])

    def test_startup_failure_raises(self):
        with self.assertRaises(FabricError) as caught:
            Fabric(env=self.env, timeout_ms=0)
        self.assertEqual(caught.exception.code, 2)
        with self.assertRaises(FileNotFoundError):
            Fabric(env=self.env, binary=os.path.join(self.home, "missing"))

    def test_session_end_is_reported(self):
        # Less than the two-second receipt grace remains, so no request can run.
        fabric = self.open(timeout_ms=2100)
        time.sleep(0.2)
        with self.assertRaises(FabricError) as caught:
            fabric.exec(["/bin/echo", "late"])
        self.assertEqual(caught.exception.code, 124)
        with self.assertRaises(FabricError) as caught:
            fabric.exec(["/bin/echo", "ended"])
        self.assertEqual(caught.exception.code, 124)
        self.assertIn("serve deadline expired", caught.exception.message)
        self.assertEqual(fabric.close(), 124)


if __name__ == "__main__":
    unittest.main()
