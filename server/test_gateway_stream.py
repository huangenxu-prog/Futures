"""Offline regression tests for the read-only streaming gateway."""
import importlib.util
import io
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch
from types import SimpleNamespace

# The CI worker only needs to validate the transport; it does not log in to TqSdk.
fake = types.ModuleType("tqsdk")
fake.TqApi = object
fake.TqAuth = object
sys.modules["tqsdk"] = fake

spec = importlib.util.spec_from_file_location("market_gateway", Path(__file__).with_name("market_gateway.py"))
gateway = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gateway)


class GatewayStreamingTests(unittest.TestCase):
    def test_quote_publish_is_change_driven(self):
        hub = gateway.LiveQuoteHub()
        first = {"CZCE.SR": {"code": "CZCE.SR701", "month": "2701", "last": 5024.0}}
        hub.publish(first)
        self.assertEqual(hub.version, 1)
        hub.publish(dict(first))
        self.assertEqual(hub.version, 1)
        changed = {"CZCE.SR": {**first["CZCE.SR"], "last": 5025.0}}
        hub.publish(changed)
        self.assertEqual(hub.version, 2)

    def test_sse_event_framing_utf8(self):
        out = io.BytesIO()
        handler = SimpleNamespace(wfile=out)
        gateway.Handler.push_event(handler, {"hello": "白糖", "last": 5024})
        data = out.getvalue()
        self.assertTrue(data.startswith(b"data: "))
        self.assertTrue(data.endswith(b"\n\n"))
        self.assertIn("白糖".encode("utf-8"), data)

    def test_code_validation(self):
        self.assertEqual(gateway.contract_product("CZCE.SR701"), "CZCE.SR")
        self.assertEqual(gateway.contract_product("SHFE.rb2701"), "SHFE.rb")
        self.assertIsNone(gateway.contract_product("KQ.m@SHFE.rb"))

    def test_history_page_contains_only_older_bars(self):
        results = []
        handler = SimpleNamespace(
            path="/v1/history?symbol=CZCE.SR701&period=900&before=145&count=5&depth=600",
            reply=lambda status, payload: results.append((status, payload))
        )
        with patch.object(gateway, "load_bars", return_value=[{"time": t} for t in range(100, 200)]):
            gateway.Handler.do_GET(handler)
        self.assertEqual(results[0][0], 200)
        self.assertEqual([bar["time"] for bar in results[0][1]["bars"]], [140, 141, 142, 143, 144])

    def test_history_page_rejects_unbounded_depth(self):
        results = []
        handler = SimpleNamespace(
            path="/v1/history?symbol=CZCE.SR701&period=900&before=145&count=5&depth=10000",
            reply=lambda status, payload: results.append((status, payload))
        )
        gateway.Handler.do_GET(handler)
        self.assertEqual(results[0][0], 400)

    def test_contract_month_endpoint_rejects_unknown_product(self):
        output = []
        handler = SimpleNamespace(path="/v1/contracts?product=FAKE.xyz",
                                  reply=lambda status, payload: output.append((status, payload)))
        gateway.Handler.do_GET(handler)
        self.assertEqual(output[0][0], 400)

    def test_contract_month_endpoint_returns_real_codes(self):
        output = []
        handler = SimpleNamespace(path="/v1/contracts?product=CZCE.SR",
                                  reply=lambda status, payload: output.append((status, payload)))
        expected = [{"code": "CZCE.SR701", "month": "2701", "last": 5029.0}]
        with patch.object(gateway, "listed_contracts", return_value=expected) as mock:
            gateway.Handler.do_GET(handler)
        mock.assert_called_once_with("CZCE.SR")
        self.assertEqual(output, [(200, expected)])

    def test_contract_discovery_filters_wrong_product(self):
        quote = SimpleNamespace(
            datetime="2026-11-23 14:59:59", delivery_year=2027, delivery_month=1,
            last_price=5029., pre_settlement=5010., bid_price1=5028., ask_price1=5030.,
            volume=5000, open_interest=12000, pre_open_interest=11900,
            price_tick=1., volume_multiple=10
        )
        class FakeAPI:
            def query_quotes(self, **kwargs):
                self.filters = kwargs
                return ["CZCE.SR701", "DCE.m2701"]
            def get_quote_list(self, codes):
                self.codes = codes
                return [quote]
            def close(self):
                pass
        api = FakeAPI()
        with patch("builtins.open", return_value=io.StringIO('{"username":"u","password":"p"}')):
            with patch.object(gateway, "TqApi", return_value=api):
                with patch.object(gateway, "TqAuth", return_value="auth"):
                    rows = gateway.listed_contracts("CZCE.SR")
        self.assertEqual(api.codes, ["CZCE.SR701"])
        self.assertEqual(api.filters["expired"], False)
        self.assertEqual(rows[0]["month"], "2701")
        self.assertEqual(rows[0]["priceTick"], 1)
        self.assertEqual(rows[0]["last"], 5029.)

    def test_numeric_snapshot_never_sends_nan(self):
        q = SimpleNamespace(datetime="2026-11-23 10:01:00",
                            last_price=5024.0, pre_settlement=5047.0,
                            bid_price1=float("nan"), ask_price1=5025.0,
                            volume=100, open_interest=2000, pre_open_interest=1990)
        result = gateway.snapshot(q)
        self.assertEqual(result["last"], 5024)
        self.assertNotIn("bid", result)
        self.assertEqual(result["interest"], 2000)


if __name__ == "__main__":
    unittest.main()
