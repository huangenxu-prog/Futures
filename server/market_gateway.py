"""Read-only TqSdk K-line HTTP gateway. Bind to loopback; expose only behind authenticated HTTPS reverse proxy."""
import json
import math
import os
import re
import tempfile
import threading
import time
from collections import deque
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

from tqsdk import TqApi, TqAuth

ROOT = os.path.dirname(os.path.abspath(__file__))
AUTH_PATH = os.environ.get("TQ_AUTH_FILE", "/root/tq_test/auth.json")
PERIODS = {60, 300, 900, 1800, 3600, 86400}
SYMBOLS = {
    "SHFE.rb", "SHFE.ag", "SHFE.au", "SHFE.cu",
    "CZCE.SR", "CZCE.RM", "CZCE.MA", "CZCE.CF", "CZCE.TA", "CZCE.SA",
    "DCE.m", "DCE.p", "DCE.jm", "DCE.c", "DCE.y", "GFEX.lc", "INE.sc",
}
EXCHANGES = {"CFFEX", "SHFE", "DCE", "CZCE", "INE", "GFEX"}
CATALOG_LOCK = threading.Lock()
CATALOG_CACHE = []
CATALOG_UNTIL = 0.0
DYNAMIC_QUOTE_LOCK = threading.Lock()
QUOTE_BATCH_CACHE = {}
QUOTE_BATCH_UNTIL = {}

# Serialize TqSdk requests: the SDK manages its own event loop and is not thread-safe.
LOCK = threading.Lock()


contract_cache = {}
contract_cache_until = 0.0


def contract_product(code):
    match = re.fullmatch(r"([A-Z]+\.[A-Za-z]+)[0-9]{3,4}", code)
    return match.group(1) if match else None


def product_catalog():
    """Discover listed futures from TqSdk's authoritative contract directory."""
    global CATALOG_CACHE, CATALOG_UNTIL
    with CATALOG_LOCK:
        if CATALOG_CACHE and time.monotonic() < CATALOG_UNTIL:
            return list(CATALOG_CACHE)
        with open(AUTH_PATH, encoding="utf-8") as handle:
            credentials = json.load(handle)
        api = TqApi(auth=TqAuth(credentials["username"], credentials["password"]))
        try:
            symbols = api.query_quotes(ins_class="FUTURE",
                                       exchange_id=sorted(EXCHANGES), expired=False)
            samples = {}
            for symbol in sorted(set(symbols)):
                product = contract_product(symbol)
                if product and product.split(".")[0] in EXCHANGES:
                    samples.setdefault(product, symbol)
            if not samples:
                raise ValueError("TqSdk returned an empty listed futures catalog")
            names = {}
            sample_codes = list(samples.values())
            # Contract metadata is preferred over a live quote subscription
            # when the SDK exposes the symbol-information query.
            if hasattr(api, "query_symbol_info"):
                try:
                    for offset in range(0, len(sample_codes), 48):
                        frame = api.query_symbol_info(sample_codes[offset:offset + 48])
                        for item in frame.itertuples(index=False):
                            code = str(getattr(item, "instrument_id", ""))
                            exchange = str(getattr(item, "exchange_id", ""))
                            if "." not in code and exchange in EXCHANGES:
                                code = exchange + "." + code
                            product = contract_product(code)
                            raw = getattr(item, "instrument_name", "")
                            if product in samples and isinstance(raw, str) and raw.strip():
                                name = re.sub(r"[0-9]{3,4}$", "", raw).strip()
                                if name:
                                    names[product] = name
                except Exception:
                    # Metadata is optional; ordinary quote names remain a
                    # fallback rather than making the entire catalog fail.
                    pass
            for offset in range(0, len(sample_codes), 48):
                chunk = sample_codes[offset:offset + 48]
                if all(contract_product(code) in names for code in chunk):
                    continue
                quotes = api.get_quote_list(chunk)
                for code, quote in zip(chunk, quotes):
                    raw = getattr(quote, "instrument_name", "")
                    if isinstance(raw, str) and raw.strip():
                        # Quote names generally end with the delivery month.
                        name = re.sub(r"[0-9]{3,4}$", "", raw).strip()
                        if name and name != raw:
                            names[contract_product(code)] = name
            result = [
                {"id": product, "name": names.get(product, product.split(".")[1]),
                 "exchange": product.split(".")[0]}
                for product in sorted(samples)
            ]
            CATALOG_CACHE = result
            CATALOG_UNTIL = time.monotonic() + 6 * 3600
            return list(result)
        finally:
            api.close()


def supported_product(product):
    if product in SYMBOLS:
        return True
    if not re.fullmatch(r"(CFFEX|SHFE|DCE|CZCE|INE|GFEX)\.[A-Za-z]+", product or ""):
        return False
    return any(item["id"] == product for item in product_catalog())


def quote_symbol(symbol):
    """Continuous chart for a product, exact chart for a delivery month."""
    if re.fullmatch(r"(CFFEX|SHFE|DCE|CZCE|INE|GFEX)\.[A-Za-z]+", symbol or ""):
        return "KQ.m@" + symbol
    return symbol


def supported_symbol(symbol):
    return symbol in SYMBOLS or supported_product(contract_product(symbol))


def selected_quotes(products):
    """A bounded pull of main futures contracts, never subscribes the whole catalog."""
    requested = sorted(set(products))
    if not requested or len(requested) > 48 or any(not supported_product(p) for p in requested):
        raise ValueError("invalid products")
    # The long-lived quote feed already holds current prices for the common
    # products. Reply directly instead of creating and closing a new TqApi
    # for requests wholly covered by that feed.
    live = LIVE_QUOTES.current()
    if requested and all(product in live for product in requested):
        return {product: live[product] for product in requested}
    key = tuple(requested)
    with DYNAMIC_QUOTE_LOCK:
        if time.monotonic() < QUOTE_BATCH_UNTIL.get(key, 0):
            return QUOTE_BATCH_CACHE.get(key, {})
        with open(AUTH_PATH, encoding="utf-8") as handle:
            credentials = json.load(handle)
        api = TqApi(auth=TqAuth(credentials["username"], credentials["password"]))
        try:
            continuous = api.get_quote_list(["KQ.m@" + p for p in requested])
            deadline = time.time() + 4
            while time.time() < deadline and not all(
                    getattr(q, "underlying_symbol", "") for q in continuous):
                api.wait_update(deadline=time.time() + 0.5)
            pairs = [(p, q.underlying_symbol) for p, q in zip(requested, continuous)
                     if contract_product(getattr(q, "underlying_symbol", "")) == p]
            if not pairs:
                return {}
            quotes = api.get_quote_list([code for _, code in pairs])
            while time.time() < deadline and not any(getattr(q, "datetime", "") for q in quotes):
                api.wait_update(deadline=time.time() + 0.5)
            result = {}
            for (product, code), quote in zip(pairs, quotes):
                year, month = getattr(quote, "delivery_year", 0), getattr(quote, "delivery_month", 0)
                if not (2000 <= year <= 2099 and 1 <= month <= 12):
                    continue
                fields = snapshot(quote)
                if not fields:
                    continue
                result[product] = dict(fields, code=code,
                                       month=f"{int(year) % 100:02d}{int(month):02d}")
            if result:
                QUOTE_BATCH_CACHE[key] = result
                QUOTE_BATCH_UNTIL[key] = time.monotonic() + 8
            return result
        finally:
            api.close()


def snapshot(quote):
    if not quote.datetime:
        return {}
    fields = {
        "last": "last_price", "settlement": "pre_settlement", "bid": "bid_price1",
        "ask": "ask_price1", "volume": "volume", "interest": "open_interest",
        "previousInterest": "pre_open_interest",
    }
    values = {"time": quote.datetime}
    for key, field in fields.items():
        value = getattr(quote, field, None)
        if value is not None and math.isfinite(value):
            values[key] = float(value)
    return values


def main_contracts():
    global contract_cache, contract_cache_until
    if time.monotonic() < contract_cache_until:
        return contract_cache
    with open(AUTH_PATH, encoding="utf-8") as handle:
        credentials = json.load(handle)
    api = TqApi(auth=TqAuth(credentials["username"], credentials["password"]))
    try:
        products = sorted(SYMBOLS)
        continuous = api.get_quote_list(["KQ.m@" + product for product in products])
        pairs = [(product, q.underlying_symbol) for product, q in zip(products, continuous)
                 if q.underlying_symbol and contract_product(q.underlying_symbol) == product]
        if not pairs:
            raise ValueError("missing contract identifiers")
        quotes = api.get_quote_list([code for _, code in pairs])
        result = {}
        for (product, code), quote in zip(pairs, quotes):
            year, month = quote.delivery_year, quote.delivery_month
            if 2000 <= year <= 2099 and 1 <= month <= 12:
                result[product] = {**snapshot(quote), "code": code, "month": f"{int(year) % 100:02d}{int(month):02d}"}
        contract_cache = result
        contract_cache_until = time.monotonic() + 10
        return result
    finally:
        api.close()


def option_chain(underlying):
    with open(AUTH_PATH, encoding="utf-8") as handle:
        credentials = json.load(handle)
    api = TqApi(auth=TqAuth(credentials["username"], credentials["password"]))
    try:
        codes = list(api.query_options(underlying, expired=False))
        result = []
        for start in range(0, len(codes), 64):
            batch = codes[start:start + 64]
            for code, quote in zip(batch, api.get_quote_list(batch)):
                if (quote.underlying_symbol == underlying and math.isfinite(quote.strike_price)
                        and quote.option_class in ("CALL", "PUT")):
                    result.append(dict(snapshot(quote), code=code, strike=quote.strike_price,
                                       side=quote.option_class))
        return sorted(result, key=lambda row: (row["strike"], row["side"], row["code"]))
    finally:
        api.close()


def listed_contracts(product):
    """Query genuine unexpired delivery months, with quotes if available."""
    if not supported_product(product):
        raise ValueError("unknown product")
    exchange, product_id = product.split(".", 1)
    with open(AUTH_PATH, encoding="utf-8") as handle:
        credentials = json.load(handle)
    api = TqApi(auth=TqAuth(credentials["username"], credentials["password"]))
    try:
        available = api.query_quotes(ins_class="FUTURE", exchange_id=exchange,
                                     product_id=product_id, expired=False)
        codes = sorted(code for code in available if contract_product(code) == product)[:48]
        if not codes:
            return []
        quotes = api.get_quote_list(codes)
        # Quote metadata can arrive before the live snapshot. Give it a short
        # window, but don't block the request waiting for off-session ticks.
        deadline = time.time() + 2
        while time.time() < deadline and not any(q.datetime for q in quotes):
            api.wait_update(deadline=time.time() + 0.3)
        contracts = []
        for code, quote in zip(codes, quotes):
            year = getattr(quote, "delivery_year", 0)
            month = getattr(quote, "delivery_month", 0)
            if not (2000 <= year <= 2099 and 1 <= month <= 12):
                continue
            row = dict(snapshot(quote), code=code, month=f"{int(year) % 100:02d}{int(month):02d}")
            for field, key in (("price_tick", "priceTick"),
                               ("volume_multiple", "volumeMultiple")):
                value = getattr(quote, field, None)
                if isinstance(value, (int, float)) and math.isfinite(value) and value > 0:
                    row[key] = float(value)
            contracts.append(row)
        return sorted(contracts, key=lambda row: (row["month"], row["code"]))
    finally:
        api.close()


def load_bars(symbol, period, count):
    with open(AUTH_PATH, encoding="utf-8") as handle:
        credentials = json.load(handle)
    api = None
    try:
        api = TqApi(auth=TqAuth(credentials["username"], credentials["password"]))
        serial = api.get_kline_serial(quote_symbol(symbol), period, data_length=count)
        deadline = time.time() + 15
        while time.time() < deadline:
            api.wait_update(deadline=time.time() + 1)
            if len(serial.dropna(subset=["open", "high", "low", "close"])) >= 1:
                break
        bars = []
        for row in serial.itertuples(index=False):
            fields = (row.open, row.high, row.low, row.close)
            if not all(math.isfinite(float(value)) for value in fields):
                continue
            bars.append({
                "time": int(row.datetime) // 1_000_000_000,
                "open": float(row.open),
                "high": float(row.high),
                "low": float(row.low),
                "close": float(row.close),
                "volume": int(row.volume) if math.isfinite(float(row.volume)) else 0,
            })
        return bars
    finally:
        if api is not None:
            api.close()


# A single persistent TqSdk connection fans live quotes out to all phone clients.
# HTTP request threads never call methods on this connection.
class LiveQuoteHub:
    def __init__(self):
        self.condition = threading.Condition()
        self.contracts = {}
        self.version = 0
        self.last_received = 0.0
        self.thread = None

    def start(self):
        with self.condition:
            if self.thread is not None and self.thread.is_alive():
                return
            self.thread = threading.Thread(target=self.run, name="quote-feed", daemon=True)
            self.thread.start()

    def current(self):
        with self.condition:
            return dict(self.contracts)

    def publish(self, contracts):
        with self.condition:
            if self.contracts == contracts:
                return
            self.contracts = contracts
            self.version += 1
            self.last_received = time.monotonic()
            self.condition.notify_all()

    def run(self):
        products = sorted(SYMBOLS)
        while True:
            api = None
            try:
                with open(AUTH_PATH, encoding="utf-8") as handle:
                    credentials = json.load(handle)
                api = TqApi(auth=TqAuth(credentials["username"], credentials["password"]))
                continuous = api.get_quote_list(["KQ.m@" + product for product in products])
                live_quotes = {}
                last_sent = 0.0
                last_published = {}
                while True:
                    # wait_update is TqSdk's event-driven feed; no periodic HTTP quote polling.
                    api.wait_update(deadline=time.time() + 0.2)
                    pairs = [(product, q.underlying_symbol)
                             for product, q in zip(products, continuous)
                             if q.underlying_symbol and contract_product(q.underlying_symbol) == product]
                    new_codes = list(dict.fromkeys(code for _, code in pairs if code not in live_quotes))
                    if new_codes:
                        for code, quote in zip(new_codes, api.get_quote_list(new_codes)):
                            live_quotes[code] = quote
                    current = {}
                    for product, code in pairs:
                        quote = live_quotes.get(code)
                        if quote is None:
                            continue
                        year, month = quote.delivery_year, quote.delivery_month
                        if 2000 <= year <= 2099 and 1 <= month <= 12:
                            details = snapshot(quote)
                            if details.get("time"):
                                current[product] = dict(details, code=code,
                                                        month=f"{int(year) % 100:02d}{int(month):02d}")
                    now = time.monotonic()
                    if current and current != last_published and now - last_sent >= 0.15:
                        self.publish(current)
                        last_published = current
                        last_sent = now
            except Exception as exc:
                print("行情推送连接断开，准备重连:", type(exc).__name__, str(exc)[:180], flush=True)
                time.sleep(3)
            finally:
                if api is not None:
                    try:
                        api.close()
                    except Exception:
                        pass


LIVE_QUOTES = LiveQuoteHub()
QUOTE_STREAM_SLOTS = threading.BoundedSemaphore(8)
BAR_STREAM_SLOTS = threading.BoundedSemaphore(8)


def bars_from_serial(serial):
    bars = []
    for row in serial.itertuples(index=False):
        fields = (row.open, row.high, row.low, row.close)
        if not all(math.isfinite(float(value)) for value in fields):
            continue
        bars.append({
            "time": int(row.datetime) // 1_000_000_000,
            "open": float(row.open),
            "high": float(row.high),
            "low": float(row.low),
            "close": float(row.close),
            "volume": int(row.volume) if math.isfinite(float(row.volume)) else 0,
        })
    return bars



# Recent-history snapshots are persisted as ordinary JSON files. Real-time
# subscriptions are *separate* and request only the last two genuine TqSdk
# bars. Never synthesize missing bars, even over exchange session breaks.
KLINE_MAX_SERIES = 24
KLINE_DATA_LENGTH = 2
KLINE_HISTORY_LENGTH = 1200  # prefetch recent history once per symbol/period
KLINE_DISK_HISTORY_LENGTH = 8964  # preserve older pages on VPS across visits
KLINE_MAX_MEMORY_SERIES = 96   # bounded RAM; old pages stay on disk
KLINE_HISTORY_REFRESH_SECONDS = 600
# The favorites' stored history need not be re-downloaded every 10 minutes.
# Opening a chart always requests an up-to-date reconciliation separately.
KLINE_WARM_HISTORY_FRESH_SECONDS = 3600
KLINE_SAVE_INTERVAL = 30
KLINE_CACHE_DIR = os.environ.get("QIHUI_KLINE_CACHE_DIR", "/root/tq_test/cache/klines")
KLINE_PERIOD_ORDER = (900, 300, 1800, 3600, 60, 86400)


def merge_kline_bars(older, newer, limit=KLINE_HISTORY_LENGTH):
    # The identity of a K-line is its exchange-provided start timestamp.
    # This handles overnight sessions and non-trading hours without guessing.
    indexed = {}
    for bar in list(older) + list(newer):
        timestamp = bar.get("time") if isinstance(bar, dict) else None
        if isinstance(timestamp, int) and timestamp > 0:
            indexed[timestamp] = bar
    return [indexed[key] for key in sorted(indexed)[-limit:]]


def next_kline_stream_event(symbol, previous, incoming, count, force_full=False):
    """Return a full correction whenever an earlier candle changed.

    A last-bar-only SSE event is safe only if every preceding displayed
    candle has identical OHLCV. Otherwise the TradingChart must be told to
    replace the corrected series, not just update the current price.
    """
    current = incoming[-count:]
    if not current:
        return None
    before = previous[-count:]
    if force_full or len(current) != len(before) or current[:-1] != before[:-1]:
        return {"symbol": symbol, "bars": current}
    if current[-1] != before[-1]:
        return {"symbol": symbol, "bar": current[-1]}
    return None


class KlineFileCache:
    """Atomic, bounded, non-database cache. Never stores account credentials."""

    def __init__(self, directory=KLINE_CACHE_DIR, max_files=720):
        self.directory = Path(directory)
        self.max_files = max_files
        self.writes = 0

    def path(self, key):
        symbol, period = key
        if not re.fullmatch(r"[A-Za-z0-9@._-]{1,64}", symbol) or period not in PERIODS:
            raise ValueError("invalid cache key")
        return self.directory / (symbol.replace("@", "_") + "_" + str(period) + ".json")

    def read(self, key):
        try:
            path = self.path(key)
            if path.stat().st_size > 2_000_000:
                return [], 0.0
            with path.open("r", encoding="utf-8") as handle:
                payload = json.load(handle)
            if (payload.get("symbol") != key[0]
                    or payload.get("period") != key[1]):
                return [], 0.0
            valid = []
            for bar in payload.get("bars", []):
                if (not isinstance(bar, dict)
                        or not isinstance(bar.get("time"), int)
                        or bar["time"] <= 0):
                    continue
                if not all(isinstance(bar.get(field), (float, int))
                           and math.isfinite(bar[field])
                           for field in ("open", "high", "low", "close", "volume")):
                    continue
                valid.append({name: bar[name] for name in
                              ("time", "open", "high", "low", "close", "volume")})
            return merge_kline_bars([], valid, limit=KLINE_DISK_HISTORY_LENGTH), float(payload.get("saved_at", 0))
        except (OSError, ValueError, TypeError, AttributeError, json.JSONDecodeError):
            return [], 0.0

    def write(self, key, bars, *, older=False):
        if not bars:
            return
        target = self.path(key)
        temporary = None
        try:
            self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            # Disk is a persistent historical store, not a 200-bar ring.
            # Updating the current bar must not delete already-downloaded
            # older pages; pagination backfills must not overwrite recent
            # candles with a stale historical snapshot.
            persisted, _ = self.read(key)
            combined = (merge_kline_bars(bars, persisted,
                                         limit=KLINE_DISK_HISTORY_LENGTH)
                        if older else merge_kline_bars(
                            persisted, bars, limit=KLINE_DISK_HISTORY_LENGTH))
            content = json.dumps({
                "symbol": key[0], "period": key[1], "saved_at": time.time(),
                "bars": combined
            }, allow_nan=False, separators=(",", ":")).encode("utf-8")
            with tempfile.NamedTemporaryFile(dir=self.directory, prefix=".tmp-",
                                             delete=False) as handle:
                temporary = Path(handle.name)
                os.fchmod(handle.fileno(), 0o600)
                handle.write(content)
            os.replace(temporary, target)
            temporary = None
            self.writes += 1
            if self.writes % 48 == 0:
                snapshots = sorted(self.directory.glob("*.json"),
                                   key=lambda file: file.stat().st_mtime)
                for old in snapshots[:-self.max_files]:
                    old.unlink(missing_ok=True)
        except (OSError, ValueError, TypeError) as exc:
            print("K线缓存写入失败:", type(exc).__name__, str(exc)[:100], flush=True)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)


class KlineCapacityError(Exception):
    pass


class SharedKlineHub:
    """24 live subscriptions; 256 RAM history series; bounded disk snapshots.

    The TqApi for live bars is owned by the live worker. The separate history
    worker performs bounded 200-bar backfills in small SDK batches. HTTP
    threads never touch either TqApi. A warmup never reserves a live slot.
    """

    def __init__(self, max_series=KLINE_MAX_SERIES, store=None):
        self.condition = threading.Condition()
        self.max_series = max_series
        self.store = store
        self.entries = {}           # active live subscription entries
        self.cache = {}             # key -> (deduplicated bars, version)
        self.cached_used = {}       # key -> monotonic LRU clock
        self.live_tail = {}         # last 2 authoritative live bars
        self.last_saved = {}
        self.file_write_lock = threading.Lock()
        self.last_history = {}
        self.pending_history = set()
        self.urgent_history = deque()
        self.background_history = deque()
        self.history_running = set()
        self.warm_until = {}
        self.history_retry_after = {}
        self.generation = 0
        self.thread = None
        self.history_thread = None
        self.connected = False
        self.error = None

    def _restore_locked(self, key):
        if key in self.cache or self.store is None:
            return
        bars, saved_at = self.store.read(key)
        if bars:
            self.cache[key] = (bars[-KLINE_HISTORY_LENGTH:], 1)
            self.cached_used[key] = time.monotonic()
            # A disk file is instantly displayable but must be reconciled
            # before being treated as a current exchange snapshot.
            self.last_history[key] = max(0, saved_at)

    def _schedule_locked(self, key, urgent=False):
        if time.monotonic() < self.history_retry_after.get(key, 0):
            return
        if key in self.history_running:
            return
        if key in self.pending_history:
            if urgent and key not in self.urgent_history:
                self.urgent_history.append(key)  # one priority upgrade only
            return
        # The foreground chart must not lose backfill priority to a backlog
        # of public warm hints. Discard one speculative task when necessary.
        if len(self.pending_history) >= 144:
            if urgent and self.background_history:
                dropped = self.background_history.pop()
                self.pending_history.discard(dropped)
            else:
                return
        self.pending_history.add(key)
        (self.urgent_history if urgent else self.background_history).append(key)
        self.condition.notify_all()

    def start(self):
        with self.condition:
            if self.thread is None or not self.thread.is_alive():
                self.thread = threading.Thread(target=self.run, name="kline-live",
                                               daemon=True)
                self.thread.start()
            if self.history_thread is None or not self.history_thread.is_alive():
                self.history_thread = threading.Thread(
                    target=self.run_history, name="kline-history", daemon=True)
                self.history_thread.start()

    def reserve(self, symbol, period, *, listener=False, waiter=False):
        key = (quote_symbol(symbol), period)
        with self.condition:
            self._restore_locked(key)
            if key not in self.entries:
                if len(self.entries) >= self.max_series:
                    inactive = [(row["used"], old) for old, row in self.entries.items()
                                if not row["listeners"] and not row["waiters"]]
                    if not inactive:
                        raise KlineCapacityError("kline_subscription_limit")
                    victim = min(inactive)[1]
                    del self.entries[victim]
                    self.generation += 1  # TqSdk cannot unsubscribe old serials
                self.entries[key] = {
                    "used": time.monotonic(), "listeners": 0, "waiters": 0,
                }
            entry = self.entries[key]
            entry["used"] = time.monotonic()
            if listener:
                entry["listeners"] += 1
            if waiter:
                entry["waiters"] += 1
            bars = self.cache.get(key, ([], 0))[0]
            refreshed = self.last_history.get(key, 0)
            if (len(bars) < KLINE_HISTORY_LENGTH - 2
                    or time.time() - refreshed > KLINE_HISTORY_REFRESH_SECONDS):
                self._schedule_locked(key, urgent=True)
            self.condition.notify_all()
        self.start()
        return key

    def release(self, key, *, listener=False, waiter=False):
        with self.condition:
            entry = self.entries.get(key)
            if entry:
                if listener:
                    entry["listeners"] = max(0, entry["listeners"] - 1)
                if waiter:
                    entry["waiters"] = max(0, entry["waiters"] - 1)
                entry["used"] = time.monotonic()
            self.condition.notify_all()

    def publish(self, key, bars, *, history=False):
        if not bars:
            return
        to_save = None
        with self.condition:
            self._restore_locked(key)
            previous, version = self.cache.get(key, ([], 0))
            if history:
                # A completed candle is authoritative after backfill. The
                # live two-bar subscription may have captured the *previous*
                # candle before it was finalized; do not overwrite that
                # completed candle with a stale live-tail copy.
                combined = merge_kline_bars(previous, bars)
                newest_history_time = max(bar["time"] for bar in bars)
                live_tail = self.live_tail.get(key, [])
                newest_live = max(live_tail, key=lambda bar: bar["time"],
                                  default=None)
                # Preserve only the current/live-most-recent candle.
                # The preceding candle may have finalized since a 2-bar
                # subscription captured it, even when the history snapshot
                # itself has not received the new candle yet.
                if newest_live is not None and newest_live["time"] >= newest_history_time:
                    combined = merge_kline_bars(combined, [newest_live])
                self.last_history[key] = time.time()
            else:
                # Exchange calendar gaps are not automatically filled. A
                # discontinuity merely schedules a genuine TqSdk backfill.
                if previous and max(bar["time"] for bar in bars) > (
                        previous[-1]["time"] + 3 * key[1]):
                    self._schedule_locked(key, urgent=True)
                self.live_tail[key] = list(bars)[-2:]
                combined = merge_kline_bars(previous, bars)
            if combined != previous:
                self.cache[key] = (combined, version + 1)
                self.cached_used[key] = time.monotonic()
                self.condition.notify_all()
            now = time.monotonic()
            if self.store is not None and (history
                  or combined != previous and now - self.last_saved.get(key, 0) > KLINE_SAVE_INTERVAL):
                self.last_saved[key] = now
                to_save = combined
            if len(self.cache) > KLINE_MAX_MEMORY_SERIES:
                evictable = [(self.cached_used.get(old, 0), old)
                             for old in self.cache if old not in self.entries
                             and old not in self.pending_history
                             and old not in self.history_running]
                if evictable:
                    oldest = min(evictable)[1]
                    del self.cache[oldest]
                    self.cached_used.pop(oldest, None)
                    self.live_tail.pop(oldest, None)
        if to_save is not None:
            # Serialize writes and take the newest version after acquiring the
            # lock: a simultaneous live tick must never overwrite an already
            # completed 200-bar history snapshot with an older 2-bar file.
            with self.file_write_lock:
                with self.condition:
                    newest = self.cache.get(key, (to_save, 0))[0]
                self.store.write(key, newest)

    def read(self, key, after_version=-1, timeout=10):
        deadline = time.monotonic() + timeout
        with self.condition:
            self._restore_locked(key)
            while True:
                bars, version = self.cache.get(key, ([], 0))
                if bars and version != after_version:
                    self.cached_used[key] = time.monotonic()
                    return list(bars), version
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return list(bars), version
                self.condition.wait(timeout=remaining)

    def snapshot(self, symbol, period, count, timeout=11):
        key = self.reserve(symbol, period, waiter=True)
        try:
            bars, _ = self.read(key, timeout=timeout)
            return bars[-count:]
        finally:
            self.release(key, waiter=True)

    def warm_symbols(self, symbols):
        accepted = 0
        with self.condition:
            now = time.monotonic()
            for symbol in list(dict.fromkeys(symbols)):
                if now < self.warm_until.get(symbol, 0):
                    continue
                self.warm_until[symbol] = now + 300
                accepted += 1
                for period in KLINE_PERIOD_ORDER:
                    key = (quote_symbol(symbol), period)
                    self._restore_locked(key)
                    # Skip recent, complete snapshots. Old snapshots remain
                    # immediately readable while fresh bars are fetched.
                    bars = self.cache.get(key, ([], 0))[0]
                    if (len(bars) >= KLINE_HISTORY_LENGTH - 2
                            and time.time() - self.last_history.get(key, 0)
                            < KLINE_WARM_HISTORY_FRESH_SECONDS):
                        continue
                    self._schedule_locked(key)
        if accepted:
            self.start()
        return accepted

    def status(self):
        with self.condition:
            return {"connected": self.connected, "tracked": len(self.entries),
                    "ready": len(self.cache), "data_length": KLINE_DATA_LENGTH,
                    "history_length": KLINE_HISTORY_LENGTH,
                    "pending_history": len(self.pending_history),
                    "disk_enabled": self.store is not None}

    def run_history(self):
        # Keep one TqApi for a small batch to avoid login per contract, but
        # close it periodically so finished serials release SDK resources.
        api = None
        batches = 0
        while True:
            with self.condition:
                while not self.urgent_history and not self.background_history:
                    self.condition.wait(timeout=5)
                    if api is not None:
                        break
                key = None
                while self.urgent_history or self.background_history:
                    candidate = (self.urgent_history.popleft()
                                 if self.urgent_history else self.background_history.popleft())
                    if candidate in self.pending_history:
                        self.pending_history.remove(candidate)
                        self.history_running.add(candidate)
                        key = candidate
                        break
            if key is None:
                if api is not None:
                    try:
                        api.close()
                    except Exception:
                        pass
                    api = None
                    batches = 0
                continue
            try:
                if api is None:
                    with open(AUTH_PATH, encoding="utf-8") as handle:
                        credentials = json.load(handle)
                    api = TqApi(auth=TqAuth(credentials["username"], credentials["password"]))
                serial = api.get_kline_serial(key[0], key[1], data_length=KLINE_HISTORY_LENGTH)
                deadline = time.time() + 15
                bars = []
                while time.time() < deadline:
                    api.wait_update(deadline=time.time() + 1)
                    bars = bars_from_serial(serial)
                    if len(bars) >= min(1000, KLINE_HISTORY_LENGTH):
                        break
                    # Newly listed contracts can have fewer than 120 bars.
                    # Let the SDK continue filling history before returning
                    # a partial frame, but don't block the worker indefinitely.
                    if bars and time.time() > deadline - 3:
                        break
                if bars:
                    self.publish(key, bars, history=True)
                    with self.condition:
                        self.history_retry_after.pop(key, None)
                else:
                    with self.condition:
                        self.history_retry_after[key] = time.monotonic() + 60
                batches += 1
            except Exception as exc:
                with self.condition:
                    self.history_retry_after[key] = time.monotonic() + 60
                print("历史K线补齐失败:", key, type(exc).__name__,
                      str(exc)[:120], flush=True)
                if api is not None:
                    try:
                        api.close()
                    except Exception:
                        pass
                api = None
                batches = 0
            finally:
                with self.condition:
                    self.history_running.discard(key)
                    self.condition.notify_all()
            if batches >= 8:
                try:
                    api.close()
                except Exception:
                    pass
                api = None
                batches = 0

    def run(self):
        while True:
            api = None
            try:
                with open(AUTH_PATH, encoding="utf-8") as handle:
                    credentials = json.load(handle)
                api = TqApi(auth=TqAuth(credentials["username"], credentials["password"]))
                installed = {}
                with self.condition:
                    generation = self.generation
                    self.connected = True
                    self.error = None
                    self.condition.notify_all()
                while True:
                    with self.condition:
                        if generation != self.generation:
                            break
                        targets = sorted(self.entries, key=lambda key: -self.entries[key]["used"])
                    for key in targets:
                        if key not in installed:
                            installed[key] = api.get_kline_serial(
                                key[0], key[1], data_length=KLINE_DATA_LENGTH)
                            break
                    updated = api.wait_update(deadline=time.time() + 0.3)
                    for key in targets:
                        serial = installed.get(key)
                        if serial is None:
                            continue
                        if updated and api.is_changing(serial):
                            self.publish(key, bars_from_serial(serial))
                        with self.condition:
                            last = self.last_history.get(key, 0)
                            if time.time() - last > KLINE_HISTORY_REFRESH_SECONDS:
                                self._schedule_locked(key, urgent=True)
            except Exception as exc:
                with self.condition:
                    self.error = type(exc).__name__ + ": " + str(exc)[:140]
                    self.connected = False
                    self.condition.notify_all()
                print("K线实时连接异常，准备重连:", self.error, flush=True)
                time.sleep(3)
            finally:
                with self.condition:
                    self.connected = False
                    self.condition.notify_all()
                if api is not None:
                    try:
                        api.close()
                    except Exception:
                        pass


KLINE_HUB = SharedKlineHub(store=KlineFileCache())


# This lock serializes only cold historical pagination. It never blocks
# quote updates; actual TqApi objects are not shared between threads.
HISTORY_QUERY_LOCK = threading.Lock()


def historical_page(symbol, period, before, count, depth):
    """Serve prior candles from Aliyun disk; fetch only a genuinely missing page.

    Disk can retain up to 8964 genuine TqSdk bars per symbol/period. A 1200-bar
    prewarm covers normal swipes without a new TqSdk login. Requests beyond the
    stored depth fetch once, merge atomically and remain fast on repeat.
    """
    key = (quote_symbol(symbol), period)

    def available():
        if KLINE_HUB.store is not None:
            return KLINE_HUB.store.read(key)[0]
        with KLINE_HUB.condition:
            return list(KLINE_HUB.cache.get(key, ([], 0))[0])

    def older_rows(candles):
        return [bar for bar in candles if bar["time"] < before]

    stored = available()
    older = older_rows(stored)
    if len(older) >= count or len(stored) >= depth:
        return older[-count:]

    # One cold request can download missing history; subsequent requests will
    # be served entirely from disk, including after a gateway restart.
    with HISTORY_QUERY_LOCK:
        stored = available()
        older = older_rows(stored)
        if len(older) >= count or len(stored) >= depth:
            return older[-count:]
        fetched = load_bars(symbol, period, depth)
        if not fetched:
            return older[-count:]
        if KLINE_HUB.store is None:
            return older_rows(merge_kline_bars(
                fetched, stored, limit=KLINE_DISK_HISTORY_LENGTH))[-count:]
        with KLINE_HUB.file_write_lock:
            KLINE_HUB.store.write(key, fetched, older=True)
            persisted = available()
        return older_rows(persisted)[-count:]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def begin_stream(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache, no-transform")
        self.send_header("X-Accel-Buffering", "no")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        self.wfile.write(b": connected\n\n")
        self.wfile.flush()

    def push_event(self, payload):
        data = json.dumps(payload, ensure_ascii=False, allow_nan=False, separators=(",", ":"))
        self.wfile.write(b"data: " + data.encode("utf-8") + b"\n\n")
        self.wfile.flush()

    def stream_quotes(self):
        if not QUOTE_STREAM_SLOTS.acquire(blocking=False):
            self.reply(503, {"error": "too_many_streams"})
            return
        try:
            self.begin_stream()
            last_version = -1
            while True:
                with LIVE_QUOTES.condition:
                    if LIVE_QUOTES.version == last_version:
                        LIVE_QUOTES.condition.wait(timeout=12)
                    version = LIVE_QUOTES.version
                    data = dict(LIVE_QUOTES.contracts)
                if data and version != last_version:
                    self.push_event(data)
                    last_version = version
                else:
                    self.wfile.write(b": heartbeat\n\n")
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            QUOTE_STREAM_SLOTS.release()

    def stream_bars(self, symbol, period, count):
        if not BAR_STREAM_SLOTS.acquire(blocking=False):
            self.reply(503, {"error": "too_many_streams"})
            return
        key = None
        try:
            try:
                key = KLINE_HUB.reserve(symbol, period, listener=True)
            except KlineCapacityError:
                self.reply(503, {"error": "kline_subscription_limit"})
                return
            # A first-time contract takes time to subscribe. Delay HTTP 200
            # until an actual full K-line frame exists so the phone can recover
            # from cold-start / disconnected feeds instead of spinning forever.
            bars, version = KLINE_HUB.read(key, timeout=11)
            if not bars:
                self.reply(503, {"error": "kline_not_ready"})
                return
            self.begin_stream()
            self.push_event({"symbol": symbol, "bars": bars[-count:]})
            previous_frame = bars[-count:]
            last_full = time.monotonic()
            while True:
                bars, next_version = KLINE_HUB.read(key, after_version=version, timeout=12)
                now = time.monotonic()
                if bars and next_version != version:
                    event = next_kline_stream_event(
                        symbol, previous_frame, bars, count,
                        force_full=(now - last_full >= 60))
                    if event is not None:
                        self.push_event(event)
                        if "bars" in event:
                            last_full = now
                    previous_frame = bars[-count:]
                    version = next_version
                else:
                    self.wfile.write(b": heartbeat\n\n")
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            if key is not None:
                KLINE_HUB.release(key, listener=True)
            BAR_STREAM_SLOTS.release()

    def reply(self, status, payload):
        data = json.dumps(payload, ensure_ascii=False, allow_nan=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlsplit(self.path)
        if url.path == "/health":
            self.reply(200, {"ok": True, "quote_stream": True, "bar_stream": True,
                             "kline_cache": KLINE_HUB.status()})
            return
        if url.path == "/v1/stream/quotes":
            self.stream_quotes()
            return
        if url.path == "/v1/stream/klines":
            try:
                params = parse_qs(url.query)
                symbol = params["symbol"][0]
                period = int(params["period"][0])
                count = int(params.get("count", ["500"])[0])
                if (not supported_symbol(symbol)) or period not in PERIODS or not 5 <= count <= 500:
                    raise ValueError("invalid stream")
            except (KeyError, ValueError, IndexError):
                self.reply(400, {"error": "invalid_stream_parameters"})
                return
            self.stream_bars(symbol, period, count)
            return
        if url.path == "/v1/cache/warm":
            # A bounded GET-only cache hint, never an account/favorites write
            # API. The public gateway cannot delete cache files or set server
            # credentials. Repeated hints are throttled per contract.
            symbols = parse_qs(url.query).get("symbol", [])
            if (not 1 <= len(symbols) <= 16
                    or any(not re.fullmatch(r"(CFFEX|SHFE|DCE|CZCE|INE|GFEX)\.[A-Za-z]+[0-9]{3,4}",
                                            symbol) for symbol in symbols)):
                self.reply(400, {"error": "invalid_warm_symbols"})
                return
            # Validate against already resolved, genuine contract identifiers.
            # Arbitrary synthetic delivery months cannot trigger TqSdk traffic.
            current_codes = {item.get("code") for item in LIVE_QUOTES.current().values()}
            with DYNAMIC_QUOTE_LOCK:
                known_codes = {
                    quote.get("code") for snapshot in QUOTE_BATCH_CACHE.values()
                    for quote in snapshot.values()
                }
            if any(symbol not in current_codes and symbol not in known_codes
                   for symbol in symbols):
                self.reply(400, {"error": "unsupported_warm_symbols"})
                return
            accepted = KLINE_HUB.warm_symbols(symbols)
            self.reply(200, {"accepted": accepted,
                             "pending": KLINE_HUB.status()["pending_history"]})
            return
        if url.path == "/v1/catalog":
            try:
                self.reply(200, product_catalog())
            except Exception as exc:
                print("合约目录查询失败:", type(exc).__name__, str(exc)[:120], flush=True)
                self.reply(503, {"error": "catalog_unavailable"})
            return
        if url.path == "/v1/product-quotes":
            params = parse_qs(url.query)
            products = params.get("product", [])
            if not products or len(products) > 48 or any(not supported_product(p) for p in products):
                self.reply(400, {"error": "invalid_products"})
                return
            try:
                self.reply(200, selected_quotes(products))
            except Exception as exc:
                print("按需报价查询失败:", type(exc).__name__, str(exc)[:120], flush=True)
                self.reply(503, {"error": "quotes_unavailable"})
            return
        if url.path == "/v1/main-contracts":
            try:
                with LOCK:
                    contracts = LIVE_QUOTES.current() or main_contracts()
                self.reply(200, contracts)
            except Exception:
                self.reply(503, {"error": "market_data_unavailable"})
            return
        if url.path == "/v1/contracts":
            product = parse_qs(url.query).get("product", [""])[0]
            if not supported_product(product):
                self.reply(400, {"error": "invalid_product"})
                return
            try:
                with LOCK:
                    contracts = listed_contracts(product)
                self.reply(200, contracts)
            except Exception as exc:
                print("挂牌合约查询失败:", type(exc).__name__, str(exc)[:140], flush=True)
                self.reply(503, {"error": "contracts_unavailable"})
            return
        if url.path == "/v1/options":
            code = parse_qs(url.query).get("symbol", [""])[0]
            if not supported_symbol(code):
                self.reply(400, {"error": "invalid_underlying"})
                return
            try:
                with LOCK:
                    chain = option_chain(code)
                self.reply(200, chain)
            except Exception:
                self.reply(503, {"error": "options_unavailable"})
            return
        if url.path == "/v1/history":
            try:
                params = parse_qs(url.query)
                symbol = params["symbol"][0]
                period = int(params["period"][0])
                before = int(params["before"][0])
                count = int(params.get("count", ["300"])[0])
                depth = int(params.get("depth", ["1100"])[0])
                if ((not supported_symbol(symbol))
                        or period not in PERIODS or before <= 0
                        or not 5 <= count <= 300 or not 500 <= depth <= 8964):
                    raise ValueError("invalid history request")
            except (KeyError, ValueError, IndexError):
                self.reply(400, {"error": "invalid_history_parameters"})
                return
            try:
                older = historical_page(symbol, period, before, count, depth)
                self.reply(200, {"symbol": symbol, "period": period, "bars": older})
            except Exception:
                self.reply(503, {"error": "history_unavailable"})
            return
        if url.path != "/v1/klines":
            self.reply(404, {"error": "not_found"})
            return
        try:
            params = parse_qs(url.query)
            symbol = params["symbol"][0]
            period = int(params["period"][0])
            count = int(params.get("count", ["100"])[0])
            if (not supported_symbol(symbol)) or period not in PERIODS or not 5 <= count <= 500:
                raise ValueError("invalid symbol, period or count")
        except (KeyError, ValueError, IndexError) as exc:
            self.reply(400, {"error": str(exc)})
            return
        try:
            bars = KLINE_HUB.snapshot(symbol, period, count)
            self.reply(200 if bars else 503, {
                "symbol": symbol, "period": period, "bars": bars,
                "error": None if bars else "no_data",
            })
        except KlineCapacityError:
            self.reply(503, {"error": "kline_subscription_limit"})
        except Exception as exc:
            print("K线缓存查询失败:", type(exc).__name__, str(exc)[:120], flush=True)
            self.reply(503, {"error": "market_data_unavailable"})

    def log_message(self, format, *args):
        print("%s %s" % (self.address_string(), format % args), flush=True)


if __name__ == "__main__":
    host = os.environ.get("QIHUI_BIND", "127.0.0.1")
    port = int(os.environ.get("QIHUI_PORT", "8765"))
    print("Qihui read-only gateway listening on %s:%s" % (host, port), flush=True)
    LIVE_QUOTES.start()
    KLINE_HUB.start()
    ThreadingHTTPServer((host, port), Handler).serve_forever()
