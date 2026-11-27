"""Offline first-frame acceptance tests. Can run against the staged VPS source."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import threading
import tempfile
import time
import types
import unittest
from unittest.mock import patch

source = Path(os.environ.get("QIHUI_TEST_GATEWAY", Path(__file__).with_name("market_gateway.py")))
spec = importlib.util.spec_from_file_location("first_frame_gateway", source)
gateway = importlib.util.module_from_spec(spec)
with patch.dict(sys.modules, tqsdk=types.SimpleNamespace(TqApi=object, TqAuth=object)):
    spec.loader.exec_module(gateway)


def rows(*times):
    return [dict(time=t, open=1, high=2, low=1, close=1, volume=2) for t in times]


class FirstFrameTests(unittest.TestCase):
    key = ("DCE.a2701", 1800)

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.store = gateway.KlineFileCache(directory.name)
        self.hub = gateway.SharedKlineHub(store=self.store)
        self.hub.start = lambda: None

    def test_live_first_cannot_escape_http_sse_or_disk(self):
        self.hub.publish(self.key, rows(51, 61))
        self.assertEqual(self.hub.snapshot(*self.key, 20, timeout=0), [])
        self.assertEqual(self.hub.read(self.key, timeout=0), ([], 0))
        self.assertEqual(self.store.read(self.key)[0], [])
        self.assertEqual(len(self.hub.urgent_history), 1)

    def test_gap_partial_timeout_and_recovery(self):
        self.hub.publish(self.key, rows(1, 11, 21), history=True)
        self.hub.publish(self.key, rows(51, 61))
        self.hub.publish(self.key, rows(61, 71))
        self.assertFalse(self.hub.publish(self.key, rows(1, 11, 21, 31, 41, 51), history=True))
        self.assertEqual(self.store.read(self.key)[0], rows(1, 11, 21))
        t = time.monotonic()
        old = self.hub.snapshot(*self.key, 50, timeout=.03)
        self.assertLess(time.monotonic()-t, .5)
        self.assertEqual(old, rows(1, 11, 21))
        self.assertEqual(self.hub.read(self.key, after_version=1, timeout=0), (old, 1))
        corrected = rows(1, 11, 21, 31, 41, 51, 61)
        corrected[-1]["close"] = 2
        self.assertTrue(self.hub.publish(self.key, corrected, history=True))
        expected = corrected + rows(71)
        self.assertEqual(self.hub.read(self.key, timeout=0), (expected, 2))
        self.assertEqual(self.store.read(self.key)[0], expected)
        self.hub.publish(self.key, rows(61, 71))
        self.assertEqual(self.hub.read(self.key, timeout=0), (expected, 2))

    def test_waiting_http_and_sse_awaken_on_same_history_commit(self):
        self.store.write(self.key, rows(1, 11, 21))
        self.hub.publish(self.key, rows(51, 61))
        results = []
        started = threading.Barrier(3)
        def read(http):
            started.wait()
            if http:
                results.append(self.hub.snapshot(*self.key, 200))
            else:
                results.append(self.hub.read(self.key)[0])
        threads = [threading.Thread(target=read, args=(http,)) for http in (True, False)]
        for thread in threads:
            thread.start()
        started.wait()
        expected = rows(1, 11, 21, 31, 41, 51, 61)
        self.hub.publish(self.key, expected, history=True)
        for thread in threads:
            thread.join(1)
        self.assertEqual(results, [expected, expected])

    def test_newer_history_corrects_even_last_stale_live_bar(self):
        self.hub.publish(self.key, rows(1, 2))
        corrected = rows(1, 2)
        corrected[-1]["close"] = 2
        self.hub.publish(self.key, corrected, history=True, history_started=time.monotonic())
        self.hub.publish(self.key, rows(1, 2))
        self.assertEqual(self.hub.read(self.key, timeout=0)[0], corrected)

    def test_exchange_overlap_across_holiday(self):
        self.hub.publish(self.key, rows(10, 20), history=True)
        self.hub.publish(self.key, rows(20, 900000))
        self.assertEqual(self.hub.snapshot(*self.key, 10, timeout=0), rows(10, 20, 900000))
        self.assertFalse(self.hub.pending_history)

    def test_disjoint_history_restart_and_separate_clock(self):
        self.store.write(self.key, rows(10, 20, 30))
        self.assertEqual(self.store.read(self.key, frame=True)[1], 0)
        self.hub.publish(self.key, rows(101, 111, 121), history=True)
        certified = self.store.read(self.key, frame=True)
        self.store.write(self.key, rows(1), older=True)
        self.assertEqual(self.store.read(self.key, frame=True), certified)
        self.assertGreater(json.loads(self.store.path(self.key).read_text())["saved_at"], certified[1])
        restored = gateway.SharedKlineHub(store=self.store)
        with patch.object(restored, "start"), patch.object(restored.condition, "wait", side_effect=AssertionError):
            self.assertEqual(restored.snapshot(*self.key, 10), rows(101, 111, 121))
        self.assertFalse(restored.pending_history)
        self.assertEqual(self.store.read(self.key)[0], rows(1, 10, 20, 30, 101, 111, 121))
        self.store.write(self.key, rows(201))
        self.assertEqual(self.store.read(self.key, frame=True), (certified[0], 0))


if __name__ == "__main__":
    unittest.main()
