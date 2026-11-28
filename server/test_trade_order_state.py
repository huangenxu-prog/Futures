"""Offline tests for order-state normalization; no live trading."""
import unittest
from types import SimpleNamespace
from trade_gateway import order_row, snapshot, order_state

class OrderTests(unittest.TestCase):
    def test_states(self):
        for status, qty, left, msg, error, exchange_id, expected in [
            ("ALIVE", 1, 1, "", False, "", "ALIVE"),
            ("ALIVE", 3, 1, "", False, "X", "PARTIAL"),
            ("FINISHED", 1, 0, "", False, "X", "FILLED"),
            ("FINISHED", 1, 1, "撤单成功", False, "X", "CANCELED"),
            ("FINISHED", 3, 1, "撤单成功", False, "X", "PARTIAL_CANCELED"),
            ("FINISHED", 1, 1, "资金不足", True, "", "REJECTED"),
            ("FINISHED", 1, 1, "撤单失败", False, "X", "FINISHED"),
            ("FINISHED", 1, 1, "", None, "", "FINISHED"),
            ("FINISHED", 1, 1, "", False, "X", "FINISHED"),
        ]:
            self.assertEqual(order_state(status, qty, left, msg, error, exchange_id), expected)
    def test_structured_terminal_flags_and_ambiguous_results(self):
        self.assertEqual(order_state("ALIVE", 2, 0, "", False, "X", is_dead=True), "FILLED")
        self.assertEqual(order_state("FINISHED", 2, 1, "", False, "X", is_dead=True), "FINISHED")
        self.assertEqual(order_state("FINISHED", 2, 1, "撤单成功", True, "X", is_dead=True), "FINISHED")
        self.assertEqual(order_state("FINISHED", 2, 0, "", False, "X", is_dead=False), "FILLED")
        self.assertEqual(order_state("FINISHED", 2, -1, "", False, "X"), "UNKNOWN")
        self.assertEqual(order_state("FINISHED", 2, 1, "撤单成功", False, "X", is_dead=True), "PARTIAL_CANCELED")

    def test_external_cancel_included_and_sorted(self):
        def order(price, ns):
            return SimpleNamespace(exchange_id="DCE", instrument_id="p2701", direction="SELL",
                offset="OPEN", limit_price=price, volume_orign=1, volume_left=1,
                status="FINISHED", last_msg="撤单成功", insert_date_time=ns,
                is_error=False, exchange_order_id="X")
        account = SimpleNamespace(balance=1, available=1)
        rows = snapshot(account, {}, {"older": order(8266, 100), "external": order(8278, 200)})["orders"]
        self.assertEqual([x["id"] for x in rows], ["external", "older"])
        self.assertEqual(rows[0]["price"], 8278)
        self.assertEqual(rows[0]["display_state"], "CANCELED")

if __name__ == "__main__":
    unittest.main()
