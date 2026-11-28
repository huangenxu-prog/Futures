"""Offline acceptance of the opt-in single-SDK K-line path."""
import unittest
from collections import namedtuple
from unittest.mock import Mock
from test_first_frame import gateway as g, rows


class UnifiedTests(unittest.TestCase):
    key = ("DCE.a2701", 1800)

    def setUp(self):
        self.hub = g.UnifiedKlineHub(max_series=2)
        self.hub.start = lambda: None
        self.hub.reserve(*self.key)
        self.hub.connected = True

    def publish(self, *times):
        return self.hub._publish_sdk(self.key, rows(*times), self.hub.generation)

    def test_cold_window_then_same_window_live_updates(self):
        self.assertEqual(self.hub.read(self.key, timeout=0), ([], 0))
        self.assertTrue(self.publish(11, 21, 31))
        before, version = self.hub.read(self.key, timeout=0)
        self.assertEqual(before, rows(11, 21, 31))
        self.assertTrue(self.publish(11, 21, 31, 41))
        self.assertEqual(self.hub.read(self.key, after_version=version, timeout=0)[0],
                         rows(11, 21, 31, 41))
        self.assertEqual(self.hub.snapshot(*self.key, 3, timeout=0), rows(21, 31, 41))
        self.assertIsNone(self.hub.history_thread)
        self.assertFalse(self.hub.pending_history)

    def test_reconnect_requires_new_ready_serial_even_if_same_bars(self):
        self.publish(11, 21)
        _, version = self.hub.read(self.key, timeout=0)
        with self.hub.condition:
            self.hub._invalidate_locked()
        self.assertEqual(self.hub.read(self.key, timeout=0)[0], [])
        self.assertEqual(self.hub.read(self.key, after_version=version, timeout=0)[0], [])
        self.hub.connected = True
        self.assertTrue(self.publish(11, 21))
        self.assertGreater(self.hub.read(self.key, timeout=0)[1], version)

    def test_stale_generation_and_regressed_tail_rejected(self):
        self.publish(11, 21, 31)
        self.assertFalse(self.hub._publish_sdk(self.key, rows(11, 21, 41), -1))
        self.assertFalse(self.publish(11, 21))
        self.assertEqual(self.hub.read(self.key, timeout=0)[0], [])
        self.assertTrue(self.publish(11, 21, 31))

    def test_sdk_ready_required_and_internal_id_gap_rejected(self):
        Row = namedtuple("Row", "id datetime open high low close volume")
        serial = Mock()
        api = Mock()
        api.is_serial_ready.return_value = False
        self.assertFalse(self.hub._refresh_serial(api, self.key, serial, 0))
        self.assertFalse(serial.itertuples.called)
        api.is_serial_ready.return_value = True
        serial.itertuples.return_value = iter([Row(1, 11*10**9, 1, 2, 1, 1, 2),
                                              Row(3, 31*10**9, 1, 2, 1, 1, 2)])
        self.assertFalse(self.hub._refresh_serial(api, self.key, serial, 0))
        self.assertEqual(self.hub.read(self.key, timeout=0)[0], [])
        data = [Row(1, 11*10**9, 1, 2, 1, 1, 2),
                Row(2, 9999*10**9, 1, 2, 1, 1, 2)]
        serial.itertuples.side_effect = lambda **kw: iter(data)
        self.assertTrue(self.hub._refresh_serial(api, self.key, serial, 0))
        self.assertEqual([r["time"] for r in self.hub.read(self.key, timeout=0)[0]], [11, 9999])

    def test_capacity_does_not_evict_active_reader(self):
        self.hub.reserve(*self.key, listener=True)
        other = self.hub.reserve("DCE.c2701", 300, waiter=True)
        with self.assertRaises(g.KlineCapacityError):
            self.hub.reserve("DCE.m2701", 300)
        self.hub.release(other, waiter=True)
        self.hub.reserve("DCE.m2701", 300)
        self.assertIn(self.key, self.hub.entries)
        self.assertNotIn(other, self.hub.entries)
        self.assertFalse(self.hub.connected)

    def test_same_tail_historical_correction_replaces_window(self):
        self.publish(11, 21, 31)
        corrected = rows(11, 21, 31)
        corrected[1]["close"] = 2
        self.assertTrue(self.hub._publish_sdk(self.key, corrected, 0))
        self.assertEqual(self.hub.read(self.key, timeout=0)[0], corrected)

    def test_default_capacity_is_32_with_two_foreground_slots(self):
        from unittest.mock import patch
        hub = g.UnifiedKlineHub()
        hub.start = lambda: None
        with patch.object(g, "favorite_warm_memory_ok", return_value=True):
            hub.warm_symbols(["DCE.a2701", "DCE.c2701", "DCE.m2701", "CZCE.SR701",
                              "SHFE.rb2701", "SHFE.ag2701", "SHFE.au2701"])
        self.assertEqual(hub.max_series, 32)
        self.assertEqual(len(hub.entries), 30)
        self.assertEqual(hub.status()["max_live_series"], 32)
        hub.reserve("DCE.y2701", 300, listener=True)
        hub.reserve("DCE.p2701", 300, waiter=True)
        self.assertEqual(len(hub.entries), 32)

    def test_cold_batch_installs_all_before_wait_and_never_resubscribes(self):
        hub = g.UnifiedKlineHub()
        hub.start = lambda: None
        keys = [hub.reserve(symbol, period, waiter=True)
                for symbol in ("DCE.a2701", "DCE.c2701", "DCE.m2701", "CZCE.SR701")
                for period in (60, 300, 900, 1800, 3600, 7200, 86400, 604800)]
        api = Mock()
        installed = {}
        hub._install_pending(api, installed, keys, hub.generation)
        self.assertEqual(list(installed), keys)
        self.assertEqual(api.get_kline_serial.call_count, 32)
        api.wait_update.assert_not_called()
        hub._install_pending(api, installed, keys, hub.generation)
        self.assertEqual(api.get_kline_serial.call_count, 32)
        self.assertEqual(hub.sdk_subscriptions, 32)

    def test_stale_generation_does_not_install(self):
        api = Mock()
        self.hub._install_pending(api, {}, [self.key], -1)
        api.get_kline_serial.assert_not_called()

    def test_expanded_capacity_keeps_warm_budget_and_memory_guard(self):
        from unittest.mock import patch
        hub = g.UnifiedKlineHub(max_series=128)
        hub.start = lambda: None
        symbols = ["DCE.a%04d" % n for n in range(2701, 2717)]
        with patch.object(g, "favorite_warm_memory_ok", return_value=True):
            hub.warm_symbols(symbols)
            self.assertEqual(len(hub.entries), 30)
            for symbol in symbols:
                for period in (60, 300, 900, 1800, 3600, 7200, 86400, 604800):
                    hub.reserve(symbol, period)
        self.assertEqual(len(hub.entries), 128)
        self.assertEqual(hub.generation, 0)
        self.assertEqual(hub.status()["max_memory_series"], 256)
        with patch.object(g, "favorite_warm_memory_ok", return_value=False):
            hub.reserve(symbols[0], 60)
            with self.assertRaises(g.KlineCapacityError):
                hub.reserve("DCE.c2701", 300)
        self.assertEqual(hub.generation, 0)

    def test_capacity_environment_validation(self):
        from unittest.mock import patch
        with patch.dict(g.os.environ, {"QIHUI_UNIFIED_MAX_SERIES": "128"}):
            self.assertEqual(g.unified_capacity(), 128)
        with patch.dict(g.os.environ, {"QIHUI_UNIFIED_MAX_SERIES": "129"}):
            with self.assertRaises(ValueError):
                g.unified_capacity()
