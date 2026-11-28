"""Independent regressions for the final market-gateway patch."""
import io
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from unittest.mock import patch

import deploy_first_frame as deploy
from test_first_frame import gateway as g, rows


class FinalFrameTests(unittest.TestCase):
    key = ("DCE.a2701", 1800)

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.store = g.KlineFileCache(directory.name)
        self.hub = g.SharedKlineHub(store=self.store)
        self.hub.start = lambda: None

    def test_live_confirmed_complete_history_does_not_wait_for_periodic_refresh(self):
        self.hub.reserve(*self.key)
        self.hub.connected = True
        self.hub.publish(self.key, rows(11, 21), history=True)
        self.hub.last_history[self.key] -= 601
        self.hub.publish(self.key, rows(21, 31), received_at=time.time())
        with patch.object(self.hub.condition, "wait", side_effect=AssertionError("unnecessary wait")):
            self.assertEqual(self.hub.snapshot(*self.key, 20), rows(11, 21, 31))

    def test_full_source_candidate_includes_constants_and_module_functions(self):
        baseline = "LIMIT = 1\n"
        updated = "LIMIT = 2\n\ndef helper():\n    return LIMIT\n"
        import hashlib
        with patch.object(deploy, "PRODUCTION_SHA256", hashlib.sha256(baseline.encode()).hexdigest()):
            self.assertEqual(deploy.candidate(baseline, updated, baseline), updated)
            self.assertEqual(deploy.candidate(baseline, updated, updated), updated)
            with self.assertRaises(RuntimeError):
                deploy.candidate(baseline, updated, baseline+"# drift")

    def test_empty_cache_respects_first_frame_deadline(self):
        with patch.dict(os.environ, QIHUI_FIRST_FRAME_WAIT_SECONDS="0"):
            with patch.object(self.hub.condition, "wait", side_effect=AssertionError):
                self.assertEqual(self.hub.read(self.key, timeout=11, with_sync=True), ([], 0, True))

    def test_witness_requires_current_exact_sdk_quote_and_connection(self):
        quote = {"code": self.key[0], "time": "2026-11-27 22:59:59", "volume": 120, "last": 123}
        board = g.LiveQuoteHub()
        board.exact_quotes[self.key[0]] = quote
        with patch.object(g, "LIVE_QUOTES", board):
            self.assertIsNone(g.quote_witness(self.key))
            board.record_poll(True)
            first = g.quote_witness(self.key)
            self.assertIsNotNone(first)
            board.sdk_creations += 1
            self.assertNotEqual(g.quote_witness(self.key), first)
            board.last_poll -= 4
            self.assertIsNone(g.quote_witness(self.key))

    def test_queue_stamp_on_first_enqueue_only(self):
        with self.hub.condition:
            self.hub._schedule_locked(self.key)
            first = self.hub.history_enqueued[self.key]
            self.hub._schedule_locked(self.key, urgent=True)
        self.assertEqual(first, self.hub.history_enqueued[self.key])
        self.assertLess(abs(time.monotonic()-first), 1)

    def test_exchange_session_append_and_shifted_window(self):
        for count in (2, 20):
            self.assertEqual(g.next_kline_stream_event("a", rows(11, 21), rows(11, 21, 9999), count),
                             {"symbol": "a", "bar": rows(9999)[0]})
        corrected = rows(11, 21, 9999)
        corrected[1]["volume"] += 1
        self.assertIn("bars", g.next_kline_stream_event("a", rows(11, 21), corrected, 2))
        self.assertIn("bars", g.next_kline_stream_event("a", rows(11, 21), rows(11, 21, 31, 41), 2))
        self.assertIn("bars", g.next_kline_stream_event("a", rows(11), rows(11, 21), 20, force_full=True))

    def test_legacy_missing_interior_is_never_certified_by_live_overlap(self):
        self.store.write(self.key, rows(11, 31))
        self.hub.publish(self.key, rows(31, 41), received_at=time.time())
        self.assertEqual(self.hub.read(self.key, timeout=0)[0], rows(11, 31))
        self.assertEqual(self.store.read(self.key, frame=True)[1], 0)
        self.hub.publish(self.key, rows(11, 21, 31, 41), history=True)
        self.assertGreater(self.store.read(self.key, frame=True)[1], 0)
        p = self.store.path(self.key)
        obj = json.loads(p.read_text())
        obj["bars"].pop(1)
        p.write_text(json.dumps(obj))
        self.assertEqual(self.store.read(self.key, frame=True)[1], 0)

    def test_stale_certified_frame_uses_unchanged_verified_quote_without_live_tail(self):
        token = (1, "2026-11-27 22:59:59.500", 100, 4231)
        with patch.object(g, "quote_witness", return_value=token):
            self.hub.publish(self.key, rows(10, 20), history=True, witness=token)
            self.hub.last_history[self.key] -= 7200
            with patch.object(self.hub.condition, "wait", side_effect=AssertionError):
                self.assertEqual(self.hub.snapshot(*self.key, 10, with_sync=True), (rows(10, 20), False))
            self.assertIn(self.key, self.hub.pending_history)
        with patch.object(g, "quote_witness", return_value=None):
            self.assertTrue(self.hub.read(self.key, timeout=0, with_sync=True)[2])

    def test_legacy_ahead_does_not_block_verified_history_forever(self):
        self.store.write(self.key, rows(10, 999))
        self.assertTrue(self.hub.publish(self.key, rows(10, 20, 30), history=True))
        self.assertEqual(self.hub.read(self.key, timeout=0, with_sync=True),
                         (rows(10, 20, 30), 2, False))
        self.assertFalse(self.hub.publish(self.key, rows(10, 20), history=True))

    def test_old_three_field_marker_requires_real_history_once(self):
        self.hub.publish(self.key, rows(10, 20, 30), history=True)
        path = self.store.path(self.key)
        payload = json.loads(path.read_text())
        del payload["history_digest"]
        path.write_text(json.dumps(payload))
        old_bytes = path.read_bytes()
        restored = g.SharedKlineHub(store=self.store)
        restored.start = lambda: None
        self.assertEqual(restored.snapshot(*self.key, 20, timeout=0, with_sync=True),
                         (rows(10, 20, 30), True))
        self.assertEqual(path.read_bytes(), old_bytes)
        restored.publish(self.key, rows(10, 20, 30), history=True)
        self.assertGreater(self.store.read(self.key, frame=True)[1], 0)
        restarted = g.SharedKlineHub(store=self.store)
        restarted.start = lambda: None
        self.assertEqual(restarted.snapshot(*self.key, 20, timeout=0, with_sync=True),
                         (rows(10, 20, 30), False))
        self.assertFalse(restarted.pending_history)

    def test_wait_config(self):
        for raw, expected in (("3",3),("0.25",.25),("not-a-number",3),("inf",3),("-5",3),("100",3)):
            with patch.dict(os.environ, QIHUI_FIRST_FRAME_WAIT_SECONDS=raw):
                self.assertEqual(g.first_frame_wait_seconds(), expected)

    def test_http_sse_degraded_then_same_bars_recover(self):
        self.store.write(self.key, rows(11, 21, 31))
        server = ThreadingHTTPServer(("127.0.0.1", 0), g.Handler)
        url = f"http://127.0.0.1:{server.server_port}/v1/"
        q = "?symbol=DCE.a2701&period=1800&count=200"
        with patch.object(g, "KLINE_HUB", self.hub), patch.object(g, "supported_symbol", return_value=True), \
             patch.object(g, "MARKET_ACCESS", ""), patch.dict(os.environ, QIHUI_FIRST_FRAME_WAIT_SECONDS="0"):
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                with urllib.request.urlopen(url+"klines"+q, timeout=4) as r:
                    http = json.load(r)
                self.assertTrue(http["syncing"])
                self.assertIsNone(http["history_age_s"])
                with urllib.request.urlopen(url+"stream/klines"+q, timeout=4) as r:
                    def event():
                        return json.loads(next(line for line in r if line.startswith(b"data:"))[5:])
                    first = event()
                    self.assertEqual((first["bars"], first["syncing"]), (http["bars"], True))
                    self.hub.publish(self.key, rows(11, 21, 31), history=True)
                    final = event()
                    self.assertEqual(final["bar"], first["bars"][-1])
                    self.assertNotIn("bars", final)
                    self.assertFalse(final["syncing"])
                    self.assertIsNone(first["history_age_s"])
                    self.assertGreaterEqual(final["history_age_s"], 0)
            finally:
                server.shutdown()
                server.server_close()
                thread.join(2)

    def test_probe_rejects_auth_and_unavailable(self):
        for status in (401, 403, 503):
            error = urllib.error.HTTPError("http://localhost", status, "test", {}, None)
            with self.subTest(status=status), patch.object(deploy, "reference_tails", return_value={}), patch.object(urllib.request, "urlopen", side_effect=error):
                with self.assertRaises((urllib.error.HTTPError, RuntimeError)):
                    deploy.probe_chart()

    def test_probe_rejects_mismatched_tail(self):
        def response(req, **kw):
            url = req if isinstance(req,str) else req.full_url
            stream = "stream/klines" in url
            ts = range(2,202) if stream else range(1,201)
            data = json.dumps({"bars":rows(*ts), "syncing":False}).encode()
            return io.BytesIO(b"data: "+data+b"\n\n" if stream else data)
        expected = {("DCE.a2701", 1800): 200, ("DCE.a2701", 3600): 200, ("DCE.c2701", 300): 200}
        with patch.object(deploy, "reference_tails", return_value=expected), patch.object(urllib.request, "urlopen", side_effect=response):
            with self.assertRaises(RuntimeError):
                deploy.probe_chart()


    def test_identical_http_and_sse_wrong_exchange_tail_fails(self):
        expected = {("DCE.a2701", 1800): 201, ("DCE.a2701", 3600): 201, ("DCE.c2701", 300): 201}
        def response(req, **kw):
            data = json.dumps({"bars": rows(*range(1, 201)), "syncing": False}).encode()
            return io.BytesIO(b"data: "+data+b"\n\n" if "stream/klines" in req.full_url else data)
        with patch.object(deploy, "reference_tails", return_value=expected), patch.object(urllib.request, "urlopen", side_effect=response):
            with self.assertRaisesRegex(RuntimeError, "Independent exchange tail mismatch"):
                deploy.probe_chart()

    def test_pure_multiple_append_preserves_existing_protocol(self):
        before = rows(11, 21, 31)
        incoming = rows(11, 21, 31, 41, 51)
        self.assertEqual(g.kline_stream_events("a", before, incoming, 3),
                         [{"symbol": "a", "bar": row} for row in incoming[-2:]])
        incoming[2]["close"] = 2
        self.assertIn("bars", g.kline_stream_events("a", before, incoming, 3)[0])

    def test_http_sse_timeout_then_append_without_full_replace(self):
        self.store.write(self.key, rows(11, 21, 31))
        server = ThreadingHTTPServer(("127.0.0.1", 0), g.Handler)
        url = f"http://127.0.0.1:{server.server_port}/v1/stream/klines?symbol=DCE.a2701&period=1800&count=200"
        with patch.object(g, "KLINE_HUB", self.hub), patch.object(g, "supported_symbol", return_value=True), \
             patch.object(g, "MARKET_ACCESS", ""), patch.dict(os.environ, QIHUI_FIRST_FRAME_WAIT_SECONDS="0"):
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                with urllib.request.urlopen(url, timeout=4) as response:
                    def event():
                        return json.loads(next(line for line in response if line.startswith(b"data:"))[5:])
                    first = event()
                    self.assertTrue(first["syncing"])
                    self.hub.publish(self.key, rows(11, 21, 31, 41, 51), history=True)
                    one, two = event(), event()
                    self.assertEqual([one["bar"]["time"], two["bar"]["time"]], [41, 51])
                    self.assertTrue(one["syncing"])
                    self.assertFalse(two["syncing"])
                    self.assertNotIn("bars", one)
                    self.assertNotIn("bars", two)
            finally:
                server.shutdown()
                server.server_close()
                thread.join(2)
