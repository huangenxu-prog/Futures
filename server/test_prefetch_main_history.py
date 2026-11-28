"""Offline tests: full domestic main-contract history prefetch planner."""
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.modules.setdefault("tqsdk", types.ModuleType("tqsdk"))
sys.modules["tqsdk"].TqApi = object
sys.modules["tqsdk"].TqAuth = object

server = Path(__file__).parent
sys.path.insert(0, str(server))
spec = importlib.util.spec_from_file_location("prefetch_main_history",
                                               server / "prefetch_main_history.py")
prefetch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prefetch)

class MemoryStore:
    def __init__(self):
        self.bars = {}
    def read(self, key):
        return self.bars.get(key, ([], 0))

class MainPrefetchTests(unittest.TestCase):
    def test_metadata_connection_closed_before_disk_scan(self):
        from unittest.mock import Mock
        api = Mock()
        api.query_cont_quotes.return_value = ["CZCE.SR701"]
        def scan(*args):
            api.close.assert_called_once()
            return [], {"series_total": 6, "series_cached": 6,
                        "series_fresh": 6, "series_missing": 0}
        with patch.object(prefetch, "memory_allows_prefetch", return_value=True), patch.object(
                prefetch.Path, "read_text", return_value='{"username":"test","password":"test"}'), patch.object(
                prefetch, "TqApi", return_value=api), patch.object(prefetch, "TqAuth"), patch.object(
                prefetch, "select_history_jobs", side_effect=scan), patch.object(
                prefetch, "write_status"), patch.object(prefetch.os, "umask"):
            prefetch.run(1)
        api.close.assert_called_once()

    def test_memory_guard(self):
        with patch.object(Path, "read_text", return_value="MemAvailable: 307199 kB"):
            self.assertFalse(prefetch.memory_allows_prefetch())
        with patch.object(Path, "read_text", return_value="MemAvailable: 307200 kB"):
            self.assertTrue(prefetch.memory_allows_prefetch())
        with patch.object(Path, "read_text", side_effect=OSError):
            self.assertFalse(prefetch.memory_allows_prefetch())

    def test_only_real_domestic_main_underlying_codes(self):
        sample = ["CZCE.SR701", "SHFE.ao2701", "DCE.m2701",
                  "INE.sc2701", "GFEX.lc2701", "CFFEX.IF2612",
                  "KQD.m@NYMEX.NG", "SHFE.ao", "SHFE.ao2702",
                  "../etc/shadow", "SHFE.ao2701"]
        result = prefetch.current_main_contracts(sample)
        self.assertEqual(len(result), 6)
        self.assertEqual(result["SHFE.ao"], "SHFE.ao2701")
        self.assertNotIn("KQD.m@NYMEX.NG", result)

    def test_all_seven_periods_included_not_just_watchlist(self):
        now = 100000.
        main = {"SHFE.ao": "SHFE.ao2701", "DCE.m": "DCE.m2701"}
        jobs, coverage = prefetch.select_history_jobs(main, MemoryStore(), now, limit=24)
        self.assertEqual(coverage["series_total"], 14)
        self.assertEqual(coverage["series_missing"], 14)
        self.assertEqual(len(jobs), 14)
        self.assertEqual(set(period for _,period in jobs), set(prefetch.KLINE_PERIOD_ORDER))
        self.assertEqual(jobs[0], ("DCE.m2701", 900))
        self.assertEqual(jobs[1], ("SHFE.ao2701", 900))

    def test_recent_snapshots_not_redownloaded(self):
        now = 1500000
        store = MemoryStore()
        symbol = "SHFE.ao2701"
        store.bars[(symbol, 900)] = ([{"time": 100}], now - 120)
        store.bars[(symbol, 7200)] = ([{"time": 100}], now - 120)
        jobs, coverage = prefetch.select_history_jobs(
            {"SHFE.ao": symbol}, store, now)
        self.assertEqual(len(jobs), 5)
        self.assertEqual(coverage["series_cached"], 2)
        self.assertEqual(coverage["series_fresh"], 2)

    def test_older_snapshots_are_selected_after_missing_periods(self):
        now = 1500000
        store = MemoryStore()
        store.bars[("SHFE.ao2701", 900)] = ([{"time": 100}], now - 90000)
        jobs, coverage = prefetch.select_history_jobs(
            {"SHFE.ao": "SHFE.ao2701"}, store, now)
        self.assertEqual(jobs[0], ("SHFE.ao2701", 300))
        self.assertEqual(jobs[-1], ("SHFE.ao2701", 900))

    def test_persistent_status_never_includes_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(prefetch, "STATUS_FILE", Path(directory) / "status.json"):
                prefetch.write_status(dict(products=2, series_total=12, state="idle"))
                text = prefetch.STATUS_FILE.read_text()
                self.assertIn('"products": 2', text)
                self.assertNotIn("password", text)
                self.assertEqual(prefetch.STATUS_FILE.stat().st_mode & 0o777, 0o600)

if __name__ == "__main__":
    unittest.main()
