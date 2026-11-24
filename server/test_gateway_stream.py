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
    def test_live_history_depth_covers_longest_used_ma(self):
        # On the live connection only 2 real bars are subscribed. A separate
        # one-off history worker acquires 200 bars for MA120 and chart panning.
        self.assertEqual(gateway.KLINE_DATA_LENGTH, 2)
        self.assertEqual(gateway.KLINE_HISTORY_LENGTH, 200)
        self.assertGreaterEqual(gateway.KLINE_HISTORY_LENGTH, 120)
        self.assertEqual(gateway.SharedKlineHub().status()["data_length"], 2)

    def test_continuous_chart_resolution_for_new_products(self):
        self.assertEqual(gateway.quote_symbol("SHFE.zn"), "KQ.m@SHFE.zn")
        self.assertEqual(gateway.quote_symbol("CFFEX.IF"), "KQ.m@CFFEX.IF")
        self.assertEqual(gateway.quote_symbol("DCE.m2701"), "DCE.m2701")

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

    def test_shared_kline_snapshot_reuses_worker_cache(self):
        hub = gateway.SharedKlineHub(max_series=2)
        # The worker's SDK connection must not be needed on cache hits.
        with patch.object(hub, "start"):
            key = hub.reserve("CZCE.MA701", 900)
        rows = [{"time": 100, "open": 3000, "high": 3001,
                 "low": 2999, "close": 3001, "volume": 3},
                {"time": 200, "open": 3001, "high": 3002,
                 "low": 3000, "close": 3002, "volume": 5}]
        hub.publish(key, rows)
        with patch.object(hub, "start") as start, patch.object(gateway, "TqApi") as sdk:
            self.assertEqual(hub.snapshot("CZCE.MA701", 900, 1), rows[-1:])
            self.assertEqual(hub.snapshot("CZCE.MA701", 900, 2), rows)
        self.assertEqual(sdk.call_count, 0)
        self.assertEqual(start.call_count, 2)
        self.assertEqual(hub.entries[key]["waiters"], 0)

    def test_bounded_kline_subscriptions_preserve_active_streams(self):
        hub = gateway.SharedKlineHub(max_series=2)
        with patch.object(hub, "start"):
            a = hub.reserve("CZCE.MA701", 900, listener=True)
            b = hub.reserve("CZCE.SR701", 900)
            hub.publish(a, [{"time": 100}])
            c = hub.reserve("SHFE.rb2701", 900, listener=True)
        self.assertIn(a, hub.entries)
        self.assertNotIn(b, hub.entries)
        self.assertNotIn(b, hub.entries)
        self.assertEqual(hub.generation, 1)
        with patch.object(hub, "start"):
            with self.assertRaises(gateway.KlineCapacityError):
                hub.reserve("DCE.m2701", 900, listener=True)
        hub.release(a, listener=True)
        hub.release(c, listener=True)

    def test_warmup_never_consumes_live_subscription_slots(self):
        hub = gateway.SharedKlineHub(max_series=2)
        with patch.object(hub, "start"):
            accepted = hub.warm_symbols(["CZCE.MA701"])
        self.assertEqual(accepted, 1)
        self.assertEqual(len(hub.entries), 0)
        self.assertEqual(hub.status()["pending_history"], 6)
        self.assertEqual(hub.warm_symbols(["CZCE.MA701"]), 0)

    def test_stream_sends_full_frame_for_corrected_previous_candle(self):
        previous = [
            {"time": 100, "open": 5000, "high": 5010, "low": 4995,
             "close": 5005, "volume": 10},
            {"time": 200, "open": 5005, "high": 5085, "low": 5005,
             "close": 5070, "volume": 20},
            {"time": 300, "open": 5070, "high": 5072, "low": 5069,
             "close": 5071, "volume": 2},
        ]
        revised = [dict(row) for row in previous]
        revised[1] = {**revised[1], "open": 5074, "close": 5068}
        event = gateway.next_kline_stream_event(
            "CZCE.SR701", previous, revised, 3)
        self.assertEqual(event["bars"][1]["close"], 5068)
        self.assertNotIn("bar", event)
        latest_only = [dict(row) for row in previous]
        latest_only[-1] = {**latest_only[-1], "close": 5072}
        event = gateway.next_kline_stream_event(
            "CZCE.SR701", previous, latest_only, 3)
        self.assertEqual(event["bar"]["close"], 5072)
        self.assertNotIn("bars", event)
        self.assertIsNone(gateway.next_kline_stream_event(
            "CZCE.SR701", previous, previous, 3))

    def test_history_backfill_overwrites_stale_completed_live_tail(self):
        hub = gateway.SharedKlineHub(max_series=2)
        key = ("CZCE.SR701", 900)
        hub.publish(key, [
            {"time": 100, "open": 5020, "close": 5028},
            {"time": 200, "open": 5030, "close": 5040}])
        # A 200-bar history response contains the finalized previous candle,
        # while the latest live candle still has a more recent partial close.
        hub.publish(key, [
            {"time": 100, "open": 5030, "close": 5026},
            {"time": 200, "open": 5030, "close": 5035}], history=True)
        bars, _ = hub.read(key, timeout=0)
        self.assertEqual(bars[0]["open"], 5030)
        self.assertEqual(bars[0]["close"], 5026)
        self.assertEqual(bars[-1]["close"], 5040)

    def test_backfill_finalizes_previous_when_history_lags_one_bar(self):
        hub = gateway.SharedKlineHub(max_series=2)
        key = ("CZCE.SR701", 900)
        hub.publish(key, [
            {"time": 100, "open": 5060, "close": 5070},
            {"time": 200, "open": 5070, "close": 5071}])
        # The historical worker has the finalized 09:15 candle, but its
        # page does not yet contain the new 09:30 forming candle.
        hub.publish(key, [
            {"time": 100, "open": 5070, "close": 5068}], history=True)
        actual, _ = hub.read(key, timeout=0)
        self.assertEqual(actual[0]["open"], 5070)
        self.assertEqual(actual[0]["close"], 5068)
        self.assertEqual(actual[1]["close"], 5071)

    def test_dedup_merge_history_and_live_candle(self):
        h = [{"time": 100, "close": 2}, {"time": 200, "close": 3}]
        live = [{"time": 200, "close": 4}, {"time": 300, "close": 5}]
        self.assertEqual(gateway.merge_kline_bars(h, live),
                         [{"time": 100, "close": 2}, {"time": 200, "close": 4},
                          {"time": 300, "close": 5}])

    def test_history_backfill_overrides_disk_not_live(self):
        hub = gateway.SharedKlineHub(max_series=2)
        key = ("CZCE.MA701", 900)
        hub.publish(key, [{"time": 100, "close": 5}])
        hub.publish(key, [{"time": 200, "close": 9}])
        hub.publish(key, [{"time": 100, "close": 3},
                          {"time": 200, "close": 7}], history=True)
        bars, _ = hub.read(key, timeout=0)
        self.assertEqual([b["time"] for b in bars], [100, 200])
        self.assertEqual(bars[-1]["close"], 9)

    def test_persisted_history_loads_immediately_and_reconciles(self):
        class Store:
            def __init__(self):
                self.saved = None
            def read(self, key):
                return self.saved or [], 0.0
            def write(self, key, bars):
                self.saved = list(bars)
        store = Store()
        key = ("CZCE.MA701", 900)
        first = gateway.SharedKlineHub(store=store)
        first.publish(key, [{"time": 100, "close": 3000}], history=True)
        second = gateway.SharedKlineHub(store=store)
        with patch.object(second, "start"):
            self.assertEqual(second.snapshot("CZCE.MA701", 900, 200, timeout=0),
                             [{"time": 100, "close": 3000}])
        self.assertIn(key, second.pending_history)

    def test_atomic_disk_cache_round_trip_and_rejects_corruption(self):
        import tempfile
        with tempfile.TemporaryDirectory() as dirname:
            store = gateway.KlineFileCache(dirname)
            key = ("CZCE.MA701", 900)
            bars = [{"time": 100, "open": 10., "high": 11.,
                     "low": 9., "close": 10.5, "volume": 4}]
            store.write(key, bars)
            loaded, saved_at = store.read(key)
            self.assertEqual(loaded, bars)
            self.assertGreater(saved_at, 0)
            store.path(key).write_text("{broken", encoding="utf-8")
            self.assertEqual(store.read(key)[0], [])
            with self.assertRaises(ValueError):
                store.path(("../secret", 900))

    def test_favorites_warm_endpoint_rejects_arbitrary_codes(self):
        output = []
        handler = SimpleNamespace(
            path="/v1/cache/warm?symbol=CZCE.MA999",
            reply=lambda status, payload: output.append((status, payload)))
        with patch.object(gateway.LIVE_QUOTES, "current", return_value={
            "CZCE.MA": {"code": "CZCE.MA701"}}):
            gateway.Handler.do_GET(handler)
        self.assertEqual(output[0][0], 400)

    def test_kline_endpoint_reads_shared_cache_not_new_sdk(self):
        output = []
        handler = SimpleNamespace(
            path="/v1/klines?symbol=CZCE.MA701&period=900&count=5",
            reply=lambda status, payload: output.append((status, payload)))
        bars = [{"time": i, "open": 1, "high": 1, "low": 1,
                 "close": 1, "volume": 1} for i in range(5)]
        with patch.object(gateway.KLINE_HUB, "snapshot", return_value=bars) as cached:
            with patch.object(gateway, "load_bars") as old_api:
                gateway.Handler.do_GET(handler)
        cached.assert_called_once_with("CZCE.MA701", 900, 5)
        old_api.assert_not_called()
        self.assertEqual(output[0][0], 200)
        self.assertEqual(output[0][1]["bars"], bars)

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

    def test_catalog_endpoint_returns_dynamic_products(self):
        results = []
        handler = SimpleNamespace(
            path="/v1/catalog", reply=lambda status, payload: results.append((status, payload)))
        items = [
            {"id": "DCE.m", "name": "豆粕", "exchange": "DCE"},
            {"id": "CFFEX.IF", "name": "沪深300股指", "exchange": "CFFEX"}
        ]
        with patch.object(gateway, "product_catalog", return_value=items):
            gateway.Handler.do_GET(handler)
        self.assertEqual(results, [(200, items)])

    def test_discovered_product_and_symbol_are_validated(self):
        listed = [{"id": "CFFEX.IF", "name": "股指", "exchange": "CFFEX"}]
        with patch.object(gateway, "product_catalog", return_value=listed):
            self.assertTrue(gateway.supported_product("CFFEX.IF"))
            self.assertTrue(gateway.supported_symbol("CFFEX.IF2612"))
            self.assertFalse(gateway.supported_symbol("CFFEX.IF2612;rm"))
            self.assertFalse(gateway.supported_product("INVALID.x"))

    def test_bounded_requested_quotes_rejects_more_than_48_products(self):
        with self.assertRaises(ValueError):
            gateway.selected_quotes(["DCE.m" + str(i) for i in range(49)])

    def test_dynamic_catalog_uses_only_listed_exchange_products(self):
        class FakeAPI:
            def query_quotes(self, **kwargs):
                self.options = kwargs
                return ["DCE.m2701", "CFFEX.IF2612", "SSE.510050"]
            def get_quote_list(self, symbols):
                return [
                    SimpleNamespace(instrument_name=(
                        "豆粕2701" if symbol.startswith("DCE.") else "沪深300股指2612"))
                    for symbol in symbols
                ]
            def close(self):
                pass
        api = FakeAPI()
        old_cache, old_until = gateway.CATALOG_CACHE, gateway.CATALOG_UNTIL
        gateway.CATALOG_CACHE, gateway.CATALOG_UNTIL = [], 0
        try:
            with patch("builtins.open", return_value=io.StringIO('{"username":"u","password":"p"}')):
                with patch.object(gateway, "TqApi", return_value=api):
                    with patch.object(gateway, "TqAuth", return_value="auth"):
                        result = gateway.product_catalog()
            self.assertEqual([item["id"] for item in result], ["CFFEX.IF", "DCE.m"])
            self.assertEqual(result[1]["name"], "豆粕")
            self.assertEqual(api.options["ins_class"], "FUTURE")
            self.assertFalse(api.options["expired"])
        finally:
            gateway.CATALOG_CACHE, gateway.CATALOG_UNTIL = old_cache, old_until

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
