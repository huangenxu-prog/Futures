"""Offline credential and session recovery tests; no broker connection."""
import unittest
from unittest.mock import patch
import trade_gateway as g

class RecoveryTests(unittest.TestCase):
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
