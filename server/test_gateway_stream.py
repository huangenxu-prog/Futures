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
    def test_quote_poll_age_is_distinct_from_quote_change_age(self):
        hub = gateway.LiveQuoteHub()
        hub.record_poll(False)
        status = hub.status()
        self.assertEqual(status["connection_state"], "polling")
        self.assertIsNotNone(status["last_poll_age_seconds"])
        self.assertIsNone(status["last_sdk_event_age_seconds"])
        self.assertIsNone(status["last_change_age_seconds"])
        hub.record_poll(True)
        self.assertIsNotNone(hub.status()["last_sdk_event_age_seconds"])

    def test_query_worker_start_failure_releases_admission(self):
        worker = gateway.QueryWorker()
        with patch.object(gateway.threading.Thread, "start", side_effect=RuntimeError("start failed")):
            with self.assertRaises(RuntimeError):
                worker.submit(lambda: None)
        self.assertTrue(worker.slots.acquire(blocking=False))
        self.assertTrue(worker.slots.acquire(blocking=False))
        self.assertFalse(worker.slots.acquire(blocking=False))

    def test_query_worker_reuses_sdk_on_single_owner_and_recycles(self):
        import threading
        from unittest.mock import mock_open, Mock
        owner_ids = []
        instances = []
        worker = gateway.QueryWorker(idle_seconds=60, max_calls=2)
        def factory(**kwargs):
            api = Mock()
            instances.append(api)
            owner_ids.append(threading.get_ident())
            return api
        def query():
            api = worker.acquire_api()
            owner_ids.append(threading.get_ident())
            worker.release_api(api)
            return len(instances)
        with patch("builtins.open", mock_open(read_data='{"username":"test","password":"test"}')), patch.object(
                gateway, "TqApi", side_effect=factory), patch.object(gateway, "TqAuth"):
            self.assertEqual(worker.submit(query), 1)
            self.assertEqual(worker.submit(query), 1)
            instances[0].close.assert_called_once()
            self.assertEqual(worker.submit(query), 2)
            worker.submit(query)
            instances[1].close.assert_called_once()
        self.assertEqual(len(set(owner_ids)), 1)
        self.assertNotEqual(owner_ids[0], threading.get_ident())

    def test_query_worker_nested_call_does_not_deadlock(self):
        worker = gateway.QueryWorker()
        self.assertEqual(worker.submit(lambda: worker.submit(lambda: 7)), 7)

    def test_market_access_optional_and_protects_all_v1_routes(self):
        from types import SimpleNamespace
        key = "x" * 64
        with patch.object(gateway, "MARKET_ACCESS", key):
            for path in ("/v1/stream/quotes", "/v1/options", "/v1/history", "/v1/cache/warm"):
                output = []
                handler = SimpleNamespace(path=path, headers={},
                    reply=lambda status, payload: output.append((status, payload)))
                gateway.Handler.do_GET(handler)
                self.assertEqual(output, [(403, {"error": "market_access_denied"})])
            self.assertTrue(gateway.market_authorized({"X-Qihui-Market-Access": key}))
            self.assertFalse(gateway.market_authorized({"X-Qihui-Market-Access": "wrong"}))
        with patch.object(gateway, "MARKET_ACCESS", ""):
            self.assertTrue(gateway.market_authorized({}))

    def test_two_short_depths_signal_temporary_history_pause(self):
        import tempfile
        rows = [{"time": t, "open": 1., "high": 2., "low": 0.,
                 "close": 1.5, "volume": 5} for t in range(100, 150)]
        with tempfile.TemporaryDirectory() as directory:
            hub = gateway.SharedKlineHub(store=gateway.KlineFileCache(directory))
            with patch.object(gateway, "KLINE_HUB", hub), patch.object(
                    gateway, "HISTORY_SHORT_PROBES", gateway.OrderedDict()), patch.object(
                    gateway, "load_bars", return_value=rows):
                first, second = {}, {}
                gateway.historical_page("CZCE.SR701", 900, 100, 300, 1100, page_info=first)
                gateway.historical_page("CZCE.SR701", 900, 100, 300, 2000, page_info=second)
                self.assertNotIn("retry_after_seconds", first)
                self.assertEqual(second["retry_after_seconds"], 300)

    def test_common_quote_does_not_acquire_short_query_gate(self):
        live = {"CZCE.SR": {"last": 5000}}
        with patch.object(gateway.LIVE_QUOTES, "current", return_value=live), patch.object(
                gateway, "SHORT_QUERY_GATE", SimpleNamespace(acquire=lambda **kw: False)):
            self.assertEqual(gateway.selected_quotes(["CZCE.SR"]), live)

    def test_catalog_cache_survives_busy_gate(self):
        sample = [{"id": "SHFE.zn"}]
        with patch.object(gateway, "CATALOG_CACHE", sample), patch.object(
                gateway, "CATALOG_UNTIL", gateway.time.monotonic() + 60), patch.object(
                gateway, "_refresh_catalog") as refresh:
            self.assertTrue(gateway.supported_product("SHFE.zn"))
            refresh.assert_not_called()

    def test_bounded_server_rejects_excess_connections(self):
        from unittest.mock import Mock
        server = object.__new__(gateway.BoundedMarketServer)
        server.request_slots = SimpleNamespace(acquire=lambda **kw: False)
        server.shutdown_request = Mock()
        sock = Mock()
        server.process_request(sock, ("127.0.0.1", 1))
        self.assertIn(b"503", sock.sendall.call_args.args[0])
        server.shutdown_request.assert_called_once_with(sock)

    def test_live_disk_queue_coalesces_and_is_bounded(self):
        hub = gateway.SharedKlineHub(store=object())
        hub.disk_writer = SimpleNamespace(is_alive=lambda: True)
        key = ("CZCE.SR701", 900)
        hub._queue_live_write(key, [{"time": 1}])
        hub._queue_live_write(key, [{"time": 2}])
        self.assertEqual(hub.pending_disk_writes[key], [{"time": 2}])
        for i in range(30):
            hub._queue_live_write(("DCE.m2701", i), [{"time": i}])
        self.assertLessEqual(len(hub.pending_disk_writes), gateway.KLINE_MAX_SERIES)

    def test_short_history_repeated_depth_uses_disk_during_cooldown(self):
        rows = [{"time": t, "open": 1., "high": 2., "low": 0.,
                 "close": 1.5, "volume": 5} for t in range(100, 150)]
        import tempfile
        with tempfile.TemporaryDirectory() as dirname:
            store = gateway.KlineFileCache(dirname)
            hub = gateway.SharedKlineHub(store=store)
            with patch.object(gateway, "KLINE_HUB", hub), patch.object(
                    gateway, "HISTORY_SHORT_PROBES", gateway.OrderedDict()), patch.object(
                    gateway, "load_bars", return_value=rows) as sdk:
                args = ("CZCE.SR701", 900, 100, 300, 1100)
                self.assertEqual(gateway.historical_page(*args), [])
                self.assertEqual(gateway.historical_page(*args), [])
                self.assertEqual(sdk.call_count, 1)
                gateway.historical_page("CZCE.SR701", 900, 100, 300, 2000)
                self.assertEqual(sdk.call_count, 2)

    def test_quote_health_reports_age_without_assuming_market_open(self):
        hub = gateway.LiveQuoteHub()
        self.assertIsNone(hub.status()["last_change_age_seconds"])
        hub.publish({"CZCE.SR": {"last": 5000}})
        self.assertEqual(hub.status()["products"], 1)
        self.assertGreaterEqual(hub.status()["last_change_age_seconds"], 0)

    def test_http_preview_does_not_evict_live_subscription(self):
        hub = gateway.SharedKlineHub(max_series=1)
        with patch.object(hub, "start"):
            active = hub.reserve("CZCE.SR701", 900, listener=True)
            preview = ("DCE.m2701", 900)
            hub.publish(preview, [{"time": 100}], history=True)
            self.assertEqual(hub.snapshot(*preview, 1, timeout=0), [{"time": 100}])
        self.assertEqual(set(hub.entries), {active})
        self.assertEqual(hub.generation, 0)

    def test_busy_catalog_validation_returns_json(self):
        output = []
        handler = SimpleNamespace(path="/v1/contracts?product=SHFE.zn",
                                  reply=lambda status, payload: output.append((status, payload)))
        with patch.object(gateway, "supported_product", side_effect=RuntimeError("market_query_busy")):
            gateway.Handler.do_GET(handler)
        self.assertEqual(output, [(503, {"error": "market_query_busy"})])

    def test_short_query_cache_reuses_result_and_expires(self):
        with patch.object(gateway, "SHORT_QUERY_CACHE", gateway.OrderedDict()):
            calls = []
            @gateway.cached_short_query
            def query(symbol):
                calls.append(symbol)
                return [{"code": symbol}]
            with patch.object(gateway.time, "monotonic", return_value=10):
                self.assertEqual(query("a"), query("a"))
            self.assertEqual(calls, ["a"])
            with patch.object(gateway.time, "monotonic", return_value=17):
                query("a")
            self.assertEqual(calls, ["a", "a"])

    def test_short_query_cache_bounded(self):
        with patch.object(gateway, "SHORT_QUERY_CACHE", gateway.OrderedDict()):
            @gateway.cached_short_query
            def query(symbol):
                return [symbol]
            for i in range(70):
                query(str(i))
            self.assertEqual(len(gateway.SHORT_QUERY_CACHE), 64)

    def test_reply_ignores_disconnected_client(self):
        handler = object.__new__(gateway.Handler)
        with patch.object(handler, "send_response", side_effect=BrokenPipeError()):
            handler.reply(200, {"ok": True})
        self.assertTrue(handler.close_connection)

    def test_open_interest_is_genuine_optional_data(self):
        import tempfile
        from add_kline_interest import patched
        rows = [
            SimpleNamespace(datetime=1000000000, open=10, high=12, low=9,
                            close=11, volume=3, open_oi=100, close_oi=102),
            SimpleNamespace(datetime=2000000000, open=11, high=12, low=10,
                            close=11, volume=4, open_oi=float("nan"), close_oi=0),
            SimpleNamespace(datetime=3000000000, open=11, high=12, low=10,
                            close=11, volume=5),
        ]
        serial = SimpleNamespace(itertuples=lambda index=False: iter(rows))
        bars = gateway.bars_from_serial(serial)
        self.assertEqual(bars[0]["openInterest"], 100)
        self.assertEqual(bars[0]["closeInterest"], 102)
        self.assertNotIn("openInterest", bars[1])
        self.assertEqual(bars[1]["closeInterest"], 0)
        self.assertNotIn("closeInterest", bars[2])
        with tempfile.TemporaryDirectory() as dirname:
            store = gateway.KlineFileCache(dirname)
            key = ("CZCE.SR701", 900)
            store.write(key, bars)
            self.assertEqual(store.read(key)[0], bars)
        before = bars[:2]
        after = [before[0], dict(before[1], closeInterest=5)]
        self.assertEqual(gateway.next_kline_stream_event("CZCE.SR701", before, after, 2)["bar"], after[-1])
        source = Path(gateway.__file__).read_text(encoding="utf-8")
        self.assertEqual(patched(source), source)

    def test_live_history_depth_covers_longest_used_ma(self):
        # On the live connection only 2 real bars are subscribed. A separate
        # One-off worker warms 1200 real bars; disk retains fetched older pages.
        self.assertEqual(gateway.KLINE_DATA_LENGTH, 2)
        self.assertEqual(gateway.KLINE_HISTORY_LENGTH, 1200)
        self.assertEqual(gateway.KLINE_DISK_HISTORY_LENGTH, 8964)
        self.assertGreaterEqual(gateway.KLINE_HISTORY_LENGTH, 120)
        self.assertEqual(gateway.SharedKlineHub().status()["data_length"], 2)

    def test_continuous_chart_resolution_for_new_products(self):
        self.assertEqual(gateway.quote_symbol("SHFE.zn"), "KQ.m@SHFE.zn")
        self.assertEqual(gateway.quote_symbol("CFFEX.IF"), "KQ.m@CFFEX.IF")
        self.assertEqual(gateway.quote_symbol("DCE.m2701"), "DCE.m2701")

    def test_existing_live_quotes_never_open_another_tqsdk_session(self):
        sample = {
            "CZCE.SR": {"code": "CZCE.SR701", "last": 5066},
            "DCE.m": {"code": "DCE.m2701", "last": 3022},
        }
        with patch.object(gateway.LIVE_QUOTES, "current", return_value=sample):
            with patch.object(gateway, "TqApi") as new_connection:
                result = gateway.selected_quotes(["DCE.m", "CZCE.SR"])
        self.assertEqual(result, sample)
        new_connection.assert_not_called()

    def test_live_timing_matches_only_current_version(self):
        hub = gateway.SharedKlineHub()
        key = ("CZCE.SR701", 900)
        hub.publish(key, [{"time": 100, "close": 1}], received_at=1000.0)
        self.assertEqual(hub.timing_for(key, 1), 1000.0)
        self.assertIsNone(hub.timing_for(key, 0))
        # History at the same timestamp preserves the latest live bar.
        # A newer historical candle actually advances the published version.
        hub.publish(key, [{"time": 200, "close": 2}], history=True)
        self.assertIsNone(hub.timing_for(key, 2))
        self.assertIsNone(hub.timing_for(key, 1))

    def test_snapshot_includes_actual_top_of_book_sizes(self):
        quote = SimpleNamespace(datetime="2026-11-24 14:36:34.000000",
                                bid_price1=5113, ask_price1=5114,
                                bid_volume1=83, ask_volume1=126)
        values = gateway.snapshot(quote)
        self.assertEqual(values["bid"], 5113)
        self.assertEqual(values["ask"], 5114)
        self.assertEqual(values["bidVolume"], 83)
        self.assertEqual(values["askVolume"], 126)
        quote.bid_volume1 = 0
        quote.ask_volume1 = float("nan")
        values = gateway.snapshot(quote)
        self.assertEqual(values["bidVolume"], 0)
        self.assertNotIn("askVolume", values)
        self.assertNotIn("bidVolume", gateway.snapshot(SimpleNamespace(datetime="2026-11-24 14:36:34")))

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

    def test_disk_retains_older_pages_when_live_tail_updates(self):
        import tempfile
        with tempfile.TemporaryDirectory() as dirname:
            store = gateway.KlineFileCache(dirname)
            key = ("CZCE.SR701", 900)
            def bar(i, price=None):
                c = float(i if price is None else price)
                return {"time": i, "open": c, "high": c,
                        "low": c, "close": c, "volume": 1}
            first = [bar(i) for i in range(1, 1701)]
            store.write(key, first)
            self.assertEqual(len(store.read(key)[0]), 1700)
            store.write(key, [bar(1700, 9000), bar(1701, 9001)])
            restored, _ = store.read(key)
            self.assertEqual(len(restored), 1701)
            self.assertEqual(restored[0]["time"], 1)
            self.assertEqual(restored[-2]["close"], 9000)
            # Cold older history may overlap a fresh live final candle.
            store.write(key, [bar(i) for i in range(1, 1750)], older=True)
            restored, _ = store.read(key)
            self.assertEqual(restored[-50]["close"], 9000)
            self.assertEqual(restored[-1]["time"], 1749)

    def test_history_page_uses_disk_without_connecting_to_tqsdk(self):
        import tempfile
        with tempfile.TemporaryDirectory() as dirname:
            store = gateway.KlineFileCache(dirname)
            key = ("CZCE.SR701", 900)
            def bar(t):
                return {"time": t, "open": 1., "high": 2., "low": 0.,
                        "close": 1.5, "volume": 5}
            store.write(key, [bar(t) for t in range(1, 1301)])
            hub = gateway.SharedKlineHub(store=store)
            with patch.object(gateway, "KLINE_HUB", hub):
                with patch.object(gateway, "load_bars") as sdk:
                    found = gateway.historical_page("CZCE.SR701", 900,
                                                    before=1151, count=300,
                                                    depth=1100)
            self.assertEqual(len(found), 300)
            self.assertEqual(found[0]["time"], 851)
            self.assertEqual(found[-1]["time"], 1150)
            sdk.assert_not_called()

    def test_history_page_downloads_once_and_stores_for_restart(self):
        import tempfile
        with tempfile.TemporaryDirectory() as dirname:
            store = gateway.KlineFileCache(dirname)
            key = ("CZCE.SR701", 900)
            def bar(t):
                return {"time": t, "open": 1., "high": 2., "low": 0.,
                        "close": 1.5, "volume": 5}
            store.write(key, [bar(t) for t in range(1001, 1201)])
            hub = gateway.SharedKlineHub(store=store)
            with patch.object(gateway, "KLINE_HUB", hub):
                with patch.object(gateway, "load_bars",
                                  return_value=[bar(t) for t in range(1, 1201)]) as sdk:
                    first = gateway.historical_page("CZCE.SR701", 900,
                                                    before=1101, count=300,
                                                    depth=1100)
                    second = gateway.historical_page("CZCE.SR701", 900,
                                                     before=1101, count=300,
                                                     depth=1100)
            self.assertEqual(first, second)
            self.assertEqual(len(first), 300)
            self.assertEqual(first[0]["time"], 801)
            self.assertEqual(sdk.call_count, 1)
            self.assertEqual(len(gateway.KlineFileCache(dirname).read(key)[0]), 1200)

    def test_history_reply_survives_disk_write_error(self):
        class BrokenStore:
            def read(self, key):
                return [], 0.0
            def write(self, key, bars, *, older=False):
                raise OSError("read-only filesystem")
        rows = [{"time": t, "close": 1} for t in range(101, 501)]
        hub = gateway.SharedKlineHub(store=BrokenStore())
        with patch.object(gateway, "KLINE_HUB", hub):
            with patch.object(gateway, "load_bars", return_value=rows):
                found = gateway.historical_page(
                    "CZCE.SR701", 900, before=150, count=5, depth=500)
        self.assertEqual([row["time"] for row in found],
                         [145, 146, 147, 148, 149])

    def test_rehydrated_disk_uses_bounded_ram(self):
        import tempfile
        with tempfile.TemporaryDirectory() as dirname:
            store = gateway.KlineFileCache(dirname)
            key = ("CZCE.SR701", 900)
            store.write(key, [{"time": t, "open": 1., "high": 2., "low": 0.,
                              "close": 1.5, "volume": 1} for t in range(1, 2001)])
            hub = gateway.SharedKlineHub(store=store)
            with hub.condition:
                hub._restore_locked(key)
                self.assertEqual(len(hub.cache[key][0]), 1200)

    def test_multi_writer_persistence_preserves_older_bars(self):
        import tempfile
        with tempfile.TemporaryDirectory() as dirname:
            key = ("SHFE.ao2701", 900)
            a = gateway.KlineFileCache(dirname)
            b = gateway.KlineFileCache(dirname)
            def row(t, close):
                return {"time": t, "open": close, "high": close,
                        "low": close, "close": close, "volume": 1}
            a.write(key, [row(t, float(t)) for t in range(1, 20)])
            b.write(key, [row(t, float(t) + 10) for t in range(20, 30)])
            a.write(key, [row(30, 1000.)])
            result, _ = b.read(key)
            self.assertEqual(len(result), 30)
            self.assertEqual(result[0]["time"], 1)
            self.assertEqual(result[-1]["close"], 1000.)
            lockfile = a.path(key).with_suffix(".lock")
            self.assertTrue(lockfile.is_file())

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
