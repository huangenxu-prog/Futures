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

    def test_wait_config(self):
        for raw, expected in (("3",3),("0.25",.25),("not-a-number",3),("inf",3),("-5",3)):
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
                with urllib.request.urlopen(url+"stream/klines"+q, timeout=4) as r:
                    def event():
                        return json.loads(next(line for line in r if line.startswith(b"data:"))[5:])
                    first = event()
                    self.assertEqual((first["bars"], first["syncing"]), (http["bars"], True))
                    self.hub.publish(self.key, rows(11, 21, 31), history=True)
                    final = event()
                    self.assertEqual((final["bars"], final["syncing"]), (first["bars"], False))
            finally:
                server.shutdown()
                server.server_close()
                thread.join(2)

    def test_probe_rejects_auth_and_unavailable(self):
        for status in (401, 403, 503):
            error = urllib.error.HTTPError("http://localhost", status, "test", {}, None)
            with self.subTest(status=status), patch.object(urllib.request, "urlopen", side_effect=error):
                with self.assertRaises((urllib.error.HTTPError, RuntimeError)):
                    deploy.probe_chart()

    def test_probe_rejects_mismatched_tail(self):
        def response(req, **kw):
            url = req if isinstance(req,str) else req.full_url
            stream = "stream/klines" in url
            ts = range(2,202) if stream else range(1,201)
            data = json.dumps({"bars":rows(*ts), "syncing":False}).encode()
            return io.BytesIO(b"data: "+data+b"\n\n" if stream else data)
        with patch.object(urllib.request, "urlopen", side_effect=response):
            with self.assertRaises(RuntimeError):
                deploy.probe_chart()
