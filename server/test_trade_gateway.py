
import unittest
from types import SimpleNamespace as Obj
from trade_gateway import snapshot, number, validate_order

class SnapshotTests(unittest.TestCase):
    def test_audit_uses_private_file_and_structured_metadata(self):
        import json
        import tempfile
        import os
        import trade_gateway as gateway
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "audit.jsonl")
            with patch.object(gateway.AUDIT, "handlers", []):
                gateway.configure_audit(path)
                try:
                    gateway.audit("order_attempt", id="a"*32, symbol="CZCE.SR701")
                    row = json.loads(open(path, encoding="utf-8").read())
                    self.assertEqual(row["event"], "order_attempt")
                    self.assertEqual(row["id"], "a"*32)
                    self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
                finally:
                    for handler in gateway.AUDIT.handlers:
                        handler.close()

    def test_account_and_positions(self):
        account = Obj(balance=100000, available=90000, margin=10000, float_profit=100, close_profit=0)
        result = snapshot(account, {"DCE.m2701": Obj(pos_long=2, pos_short=0, float_profit=100),
                                    "DCE.m2705": Obj(pos_long=0, pos_short=0)})
        self.assertEqual(result["account"]["balance"], 100000)
        self.assertEqual(len(result["positions"]), 1)
        self.assertEqual(result["positions"][0]["symbol"], "DCE.m2701")
        self.assertEqual(result["positions"][0]["long"], 2)
        self.assertIsNone(result["positions"][0]["open_price_long"])
    def test_invalid_data(self):
        self.assertIsNone(snapshot(Obj(balance=float("nan"), available=0), {}))
        self.assertIsNone(number(float("inf")))
        self.assertIsNone(number(None))

    def test_validate_order(self):
        order = dict(id="a"*32, symbol="CZCE.SR701", direction="BUY", offset="OPEN", quantity="1", price="5120")
        self.assertEqual(validate_order(order)[1], "CZCE.SR701")
        for patch in (dict(quantity="11"), dict(price="nan"), dict(symbol="KQ.m@CZCE.SR"), dict(offset="CLOSETODAY")):
            with self.assertRaises(ValueError):
                validate_order(dict(order, **patch))

if __name__ == "__main__":
    unittest.main()
