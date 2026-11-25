
import unittest
from types import SimpleNamespace as Obj
from trade_gateway import snapshot, number

class SnapshotTests(unittest.TestCase):
    def test_account_and_positions(self):
        account = Obj(balance=100000, available=90000, margin=10000, float_profit=100, close_profit=0)
        result = snapshot(account, {"DCE.m2701": Obj(pos_long=2, pos_short=0, float_profit=100),
                                    "DCE.m2705": Obj(pos_long=0, pos_short=0)})
        self.assertEqual(result["account"]["balance"], 100000)
        self.assertEqual(result["positions"], [{"symbol":"DCE.m2701","long":2,"short":0,"float_profit":100}])
    def test_invalid_data(self):
        self.assertIsNone(snapshot(Obj(balance=float("nan"), available=0), {}))
        self.assertIsNone(number(float("inf")))
        self.assertIsNone(number(None))

if __name__ == "__main__":
    unittest.main()
