"""Offline credential and session recovery tests; no broker connection."""
import unittest
from unittest.mock import patch
import trade_gateway as g

class RecoveryTests(unittest.TestCase):
    def test_uncertain_order_is_not_replayed_or_reported_success(self):
        from unittest.mock import Mock
        with patch.object(g.threading.Thread, "start"):
            s = g.Session("test", "password")
        api = Mock()
        api.insert_order.side_effect = RuntimeError("unknown outcome")
        payload = ("a"*32, "CZCE.SR701", "BUY", "OPEN", 1, 5000.)
        with self.assertRaises(RuntimeError):
            s.submit_order(api, {}, payload)
        self.assertEqual(s.submit_order(api, {}, payload), 503)
        self.assertEqual(s.submit_order(api, {"a"*32: object()}, payload), 200)
        self.assertEqual(s.submit_order(api, {}, payload[:-1] + (5001.,)), 409)
        api.insert_order.assert_called_once()

    def test_successful_order_duplicate_does_not_resubmit(self):
        from unittest.mock import Mock
        with patch.object(g.threading.Thread, "start"):
            s = g.Session("test", "password")
        api = Mock()
        payload = ("b"*32, "CZCE.SR701", "BUY", "OPEN", 1, 5000.)
        self.assertEqual(s.submit_order(api, {}, payload), 200)
        self.assertEqual(s.submit_order(api, {}, payload), 200)
        api.insert_order.assert_called_once()

    def test_snapshot_age_is_measured_not_assumed_sdk_status(self):
        with patch.object(g.threading.Thread, "start"):
            s = g.Session("test", "password")
        s.data = {"account": {}}
        s.snapshot_monotonic = g.time.monotonic() - 6
        self.assertGreaterEqual(s.read()["snapshot_age_ms"], 6000)

    def test_order_validation_rejects_coercion(self):
        body = {"id": "c"*32, "symbol": "CZCE.SR701", "direction": "BUY",
                "offset": "OPEN", "quantity": 2, "price": 5000.0}
        self.assertEqual(g.validate_order(body)[4:], (2, 5000.0))
        for quantity in (11, 100, 200, 1000):
            self.assertEqual(g.validate_order(dict(body, quantity=quantity))[4], quantity)
        for value in (2.5, 2.0, True, "2", 0, -1):
            with self.subTest(quantity=value):
                with self.assertRaises(ValueError):
                    g.validate_order(dict(body, quantity=value))
        for value in (True, "5000", float("nan"), float("inf"), 0, -1):
            with self.subTest(price=value):
                with self.assertRaises(ValueError):
                    g.validate_order(dict(body, price=value))

    def test_large_close_respects_frozen_positions(self):
        from types import SimpleNamespace
        from unittest.mock import Mock
        with patch.object(g.threading.Thread, "start"):
            s = g.Session("test", "password")
        api = Mock()
        symbol = "CZCE.SR701"
        positions = {symbol: SimpleNamespace(pos_long=200, volume_long_frozen=30)}
        payload = ("a"*32, symbol, "SELL", "CLOSE", 171, 5000.)
        self.assertEqual(s.submit_order(api, {}, payload, positions), 422)
        api.insert_order.assert_not_called()
        self.assertEqual(s.submit_order(api, {}, payload[:4] + (170, 5000.), positions), 200)
        self.assertEqual(api.insert_order.call_args.kwargs["volume"], 170)

    def test_close_today_and_history_are_checked_separately(self):
        from types import SimpleNamespace
        symbol = "SHFE.ag2701"
        positions = {symbol: SimpleNamespace(pos_long=200, volume_long_frozen=30,
                    pos_long_today=100, volume_long_frozen_today=20,
                    pos_long_his=100, volume_long_frozen_his=10)}
        self.assertEqual(g.close_capacity(positions, symbol, "SELL", "CLOSETODAY"), 80)
        self.assertEqual(g.close_capacity(positions, symbol, "SELL", "CLOSE"), 90)
        self.assertIsNone(g.close_capacity(positions, symbol, "BUY", "CLOSE"))
        self.assertIsNone(g.close_capacity({}, symbol, "SELL", "CLOSE"))

    def test_persistent_intent_blocks_replay_after_restart(self):
        import os
        import tempfile
        from unittest.mock import Mock
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "intents.sqlite3")
            with patch.object(g.threading.Thread, "start"):
                first = g.Session("test", "password")
                second = g.Session("test", "password")
                other = g.Session("other", "password")
            payload = ("d"*32, "CZCE.SR701", "BUY", "OPEN", 1, 5000.)
            api = Mock()
            api.insert_order.side_effect = RuntimeError("unknown outcome")
            with patch.object(g, "ORDER_LEDGER", g.OrderIntentLedger(path)):
                with self.assertRaises(RuntimeError):
                    first.submit_order(api, {}, payload)
            api.insert_order.side_effect = None
            with patch.object(g, "ORDER_LEDGER", g.OrderIntentLedger(path)):
                self.assertEqual(second.submit_order(api, {}, payload), 503)
                self.assertEqual(second.submit_order(api, {}, payload[:-1] + (5001.,)), 409)
                api.insert_order.assert_called_once()
                self.assertEqual(other.submit_order(api, {}, payload), 200)
                self.assertEqual(api.insert_order.call_count, 2)
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)

    def test_restart_reconciles_only_matching_confirmed_order(self):
        import os
        import tempfile
        from types import SimpleNamespace
        from unittest.mock import Mock
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "intents.sqlite3")
            with patch.object(g.threading.Thread, "start"):
                first = g.Session("test", "password")
                second = g.Session("test", "password")
            payload = ("e"*32, "CZCE.SR701", "BUY", "OPEN", 1, 5000.)
            api = Mock()
            with patch.object(g, "ORDER_LEDGER", g.OrderIntentLedger(path)):
                self.assertEqual(first.submit_order(api, {}, payload), 200)
            order = SimpleNamespace(exchange_id="CZCE", instrument_id="SR701",
                direction="BUY", offset="OPEN", limit_price=5000., volume_orign=1,
                volume_left=1, status="ALIVE", last_msg="", is_error=False,
                exchange_order_id="", insert_date_time=0)
            orders = {payload[0]: order}
            with patch.object(g, "ORDER_LEDGER", g.OrderIntentLedger(path)):
                self.assertEqual(second.submit_order(api, orders, payload), 503)
                order.exchange_order_id = "confirmed"
                self.assertEqual(second.submit_order(api, orders, payload), 200)
                order.limit_price = 5001.
                self.assertEqual(second.submit_order(api, orders, payload), 409)
                api.insert_order.assert_called_once()

    def test_live_readonly_cannot_submit_order(self):
        from unittest.mock import Mock
        with patch.object(g, "TRADE_MODE", "live_readonly"), patch.object(g.threading.Thread, "start"):
            s = g.Session("test", "password")
        api = Mock()
        payload = ("f"*32, "CZCE.SR701", "BUY", "OPEN", 1, 5000.)
        self.assertEqual(s.submit_order(api, {}, payload), 403)
        api.insert_order.assert_not_called()
        self.assertFalse(s.seen)

    def test_account_adapter_requires_explicit_live_configuration(self):
        import sys
        from types import SimpleNamespace
        from unittest.mock import Mock
        sdk = SimpleNamespace(TqKq=Mock(), TqAccount=Mock())
        with patch.dict(sys.modules, {"tqsdk": sdk}), patch.dict(g.os.environ, {}, clear=True):
            self.assertIs(g.make_account("simulation"), sdk.TqKq.return_value)
            with self.assertRaises(RuntimeError):
                g.make_account("live_readonly")
            sdk.TqAccount.assert_not_called()
            with self.assertRaises(ValueError):
                g.make_account("unknown")
            with patch.dict(g.os.environ, {"QIHUI_LIVE_BROKER": "test-broker",
                                            "QIHUI_LIVE_ACCOUNT": "test-account",
                                            "QIHUI_LIVE_PASSWORD": "test-password"}):
                self.assertIs(g.make_account("live_readonly"), sdk.TqAccount.return_value)
            sdk.TqAccount.assert_called_once_with("test-broker", "test-account", "test-password")

    def test_maintenance_drains_idle_session(self):
        from unittest.mock import Mock
        from types import SimpleNamespace
        worker = Mock()
        worker.is_alive.return_value = False
        session = SimpleNamespace(inflight=0, stop=g.threading.Event(), worker=worker)
        with patch.object(g, "SESSION", session), patch.object(g, "MAINTENANCE", g.threading.Event()):
            self.assertTrue(g.drain_session(timeout=1))
            self.assertTrue(g.MAINTENANCE.is_set())
            self.assertTrue(session.stop.is_set())
            worker.join.assert_called_once()

    def test_maintenance_does_not_stop_inflight_session(self):
        from unittest.mock import Mock
        from types import SimpleNamespace
        worker = Mock()
        session = SimpleNamespace(inflight=1, stop=g.threading.Event(), worker=worker)
        with patch.object(g, "SESSION", session), patch.object(g, "MAINTENANCE", g.threading.Event()):
            self.assertFalse(g.drain_session(timeout=0))
            self.assertTrue(g.MAINTENANCE.is_set())
            self.assertFalse(session.stop.is_set())
            worker.join.assert_not_called()

    def test_auto_login_is_opt_in(self):
        with patch.dict(g.os.environ, {}, clear=True):
            self.assertIsNone(g.startup_credentials())
            self.assertFalse(g.start_configured_session())
        with patch.dict(g.os.environ, {"QIHUI_TRADE_AUTO_LOGIN": "1"}, clear=True):
            with self.assertRaises(RuntimeError):
                g.startup_credentials()

    def test_configured_startup_session(self):
        from unittest.mock import Mock
        with patch.dict(g.os.environ, {"QIHUI_TRADE_AUTO_LOGIN": "1",
                                        "QIHUI_TQ_USERNAME": "test",
                                        "QIHUI_TQ_PASSWORD": "test-password"}, clear=True):
            with patch.object(g, "SESSION", None), patch.object(g, "MAINTENANCE", g.threading.Event()), patch.object(g, "Session") as factory:
                factory.return_value.worker.is_alive.return_value = True
                self.assertTrue(g.start_configured_session())
                self.assertFalse(g.start_configured_session())
                factory.assert_called_once_with("test", "test-password", keepalive=True)

    def test_recovery_supervisor_backoff_and_pause(self):
        with patch.object(g, "SESSION", None), patch.object(g, "MAINTENANCE", g.threading.Event()), patch.object(g, "AUTO_RECOVERY_PAUSED", g.threading.Event()), patch.object(g, "start_configured_session", return_value=True) as start:
            supervisor = g.RecoverySupervisor(minimum=30, maximum=300)
            self.assertTrue(supervisor.tick(0))
            self.assertFalse(supervisor.tick(29))
            self.assertTrue(supervisor.tick(30))
            self.assertFalse(supervisor.tick(89))
            g.AUTO_RECOVERY_PAUSED.set()
            self.assertFalse(supervisor.tick(90))
            g.AUTO_RECOVERY_PAUSED.clear()
            self.assertTrue(supervisor.tick(90))
            g.MAINTENANCE.set()
            self.assertFalse(supervisor.tick(1000))
            self.assertEqual(start.call_count, 3)

    def test_sdk_first_does_not_restart_running_worker(self):
        from types import SimpleNamespace
        from unittest.mock import Mock
        worker = Mock()
        worker.is_alive.return_value = True
        session = SimpleNamespace(worker=worker)
        self.assertFalse(g.scheduled_restart_allowed(True, True, session))
        self.assertTrue(g.scheduled_restart_allowed(True, False, session))
        self.assertFalse(g.scheduled_restart_allowed(False, True, None))
        worker.is_alive.return_value = False
        self.assertTrue(g.scheduled_restart_allowed(True, True, session))

    def test_scheduled_restart_slots_and_deduplication(self):
        import os
        import tempfile
        from datetime import datetime, timezone
        self.assertEqual(g.scheduled_restart_slot(datetime(2026, 11, 26, 0, 30, tzinfo=timezone.utc)), "2026-11-26 08:30")
        self.assertEqual(g.scheduled_restart_slot(datetime(2026, 11, 26, 4, 0, tzinfo=timezone.utc)), "2026-11-26 12:00")
        self.assertEqual(g.scheduled_restart_slot(datetime(2026, 11, 26, 12, 30, tzinfo=timezone.utc)), "2026-11-26 20:30")
        self.assertIsNone(g.scheduled_restart_slot(datetime(2026, 11, 26, 12, 31, tzinfo=timezone.utc)))
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "restart.sqlite3")
            self.assertTrue(g.claim_restart_slot(path, "2026-11-26 08:30"))
            self.assertFalse(g.claim_restart_slot(path, "2026-11-26 08:30"))
            self.assertTrue(g.claim_restart_slot(path, "2026-11-26 12:00"))

    def test_password_verifier(self):
        with patch.object(g.threading.Thread, "start"):
            s = g.Session("test", "password")
        self.assertTrue(s.matches("test", "password"))
        self.assertFalse(s.matches("test", "wrong"))
        self.assertFalse(s.matches("other", "password"))
        self.assertEqual(s.inflight, 0)
        self.assertNotEqual(s.verifier, b"password")
    def test_salt(self):
        with patch.object(g.threading.Thread, "start"):
            a = g.Session("test", "password")
            b = g.Session("test", "password")
        self.assertNotEqual(a.verifier, b.verifier)

if __name__ == "__main__":
    unittest.main()
