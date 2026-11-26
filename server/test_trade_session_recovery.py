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
        for value in (2.5, 2.0, True, "2", 0, -1, 11):
            with self.subTest(quantity=value):
                with self.assertRaises(ValueError):
                    g.validate_order(dict(body, quantity=value))
        for value in (True, "5000", float("nan"), float("inf"), 0, -1):
            with self.subTest(price=value):
                with self.assertRaises(ValueError):
                    g.validate_order(dict(body, price=value))

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
