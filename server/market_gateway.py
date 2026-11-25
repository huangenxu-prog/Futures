"""Read-only TqSdk K-line HTTP gateway. Bind to loopback; expose only behind authenticated HTTPS reverse proxy."""
import fcntl
import hmac
import json
import math
import os
import re
import tempfile
import threading
import time
from collections import deque, OrderedDict
from functools import wraps
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

from tqsdk import TqApi, TqAuth

ROOT = os.path.dirname(os.path.abspath(__file__))
AUTH_PATH = os.environ.get("TQ_AUTH_FILE", "/root/tq_test/auth.json")
# Rollout: unset keeps legacy clients working; configured key protects every
# market /v1 endpoint, independently of the trading access key.
MARKET_ACCESS = os.environ.get("QIHUI_MARKET_ACCESS_KEY", "")


def market_authorized(headers):
    if not MARKET_ACCESS:
        return True
    supplied = headers.get("X-Qihui-Market-Access", "")
    return hmac.compare_digest(supplied.encode("utf-8"), MARKET_ACCESS.encode("utf-8"))
PERIODS = {60, 180, 300, 600, 900, 1800, 3600, 7200, 86400, 604800}
SYMBOLS = {
    "SHFE.rb", "SHFE.ag", "SHFE.au", "SHFE.cu",
    "CZCE.SR", "CZCE.RM", "CZCE.MA", "CZCE.CF", "CZCE.TA", "CZCE.SA",
    "DCE.m", "DCE.p", "DCE.jm", "DCE.c", "DCE.y", "GFEX.lc", "INE.sc",
}
EXCHANGES = {"CFFEX", "SHFE", "DCE", "CZCE", "INE", "GFEX"}
CATALOG_LOCK = threading.Lock()
CATALOG_CACHE = []
CATALOG_UNTIL = 0.0
CATALOG_RETRY_AFTER = 0.0
DYNAMIC_QUOTE_LOCK = threading.Lock()
QUOTE_BATCH_CACHE = {}
QUOTE_BATCH_UNTIL = {}

# Serialize TqSdk requests: the SDK manages its own event loop and is not thread-safe.
LOCK = threading.Lock()


# Short-lived SDK sessions share one admission gate. Persistent quote and
# chart workers stay independent. Reentrant for catalog validation.
SHORT_QUERY_GATE = threading.RLock()
SHORT_QUERY_CACHE = OrderedDict()
SHORT_QUERY_TTL = 6.0
SHORT_QUERY_MAX_KEYS = 64


def short_query(function):
    @wraps(function)
    def wrapped(*args, **kwargs):
        if not SHORT_QUERY_GATE.acquire(timeout=3):
            raise RuntimeError("market_query_busy")
        try:
            return function(*args, **kwargs)
        finally:
            SHORT_QUERY_GATE.release()
    return wrapped


def cached_short_query(function):
    @wraps(function)
    @short_query
    def wrapped(symbol):
        key = (function.__name__, symbol)
        now = time.monotonic()
        cached = SHORT_QUERY_CACHE.get(key)
        if cached is not None and now < cached[0]:
            SHORT_QUERY_CACHE.move_to_end(key)
            return cached[1]
        result = function(symbol)
        if result:
            SHORT_QUERY_CACHE[key] = (time.monotonic() + SHORT_QUERY_TTL, result)
            SHORT_QUERY_CACHE.move_to_end(key)
            while len(SHORT_QUERY_CACHE) > SHORT_QUERY_MAX_KEYS:
                SHORT_QUERY_CACHE.popitem(last=False)
        return result
    return wrapped


contract_cache = {}
contract_cache_until = 0.0


def contract_product(code):
    match = re.fullmatch(r"([A-Z]+\.[A-Za-z]+)[0-9]{3,4}", code)
    return match.group(1) if match else None


def product_catalog():
    global CATALOG_RETRY_AFTER
    now = time.monotonic()
    if CATALOG_CACHE and now < CATALOG_UNTIL:
        return list(CATALOG_CACHE)
    if now < CATALOG_RETRY_AFTER:
        if CATALOG_CACHE:
            return list(CATALOG_CACHE)
        raise RuntimeError("market_data_unavailable")
    try:
        return _refresh_catalog()
    except Exception as exc:
        if str(exc) == "market_query_busy":
            raise
        CATALOG_RETRY_AFTER = time.monotonic() + 30
        if CATALOG_CACHE:
            return list(CATALOG_CACHE)
        raise RuntimeError("market_data_unavailable") from exc


@short_query
def _refresh_catalog():
    """Discover listed futures from TqSdk's authoritative contract directory."""
    global CATALOG_CACHE, CATALOG_UNTIL, CATALOG_RETRY_AFTER
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
            CATALOG_RETRY_AFTER = 0.0
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
    return _selected_quotes_cold(tuple(requested))


@short_query
def _selected_quotes_cold(requested):
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
            deadline = time.time() + 2
            while time.time() < deadline and not all(getattr(q, "datetime", "") for q in quotes):
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
                for expired in list(QUOTE_BATCH_UNTIL):
                    if QUOTE_BATCH_UNTIL[expired] <= time.monotonic():
                        QUOTE_BATCH_UNTIL.pop(expired, None)
                        QUOTE_BATCH_CACHE.pop(expired, None)
                if key not in QUOTE_BATCH_CACHE and len(QUOTE_BATCH_CACHE) >= 64:
                    oldest = min(QUOTE_BATCH_UNTIL, key=QUOTE_BATCH_UNTIL.get)
                    QUOTE_BATCH_UNTIL.pop(oldest, None)
                    QUOTE_BATCH_CACHE.pop(oldest, None)
                QUOTE_BATCH_CACHE[key] = result
                QUOTE_BATCH_UNTIL[key] = time.monotonic() + 8
            return result
        finally:
            api.close()


def snapshot(quote):
    if not quote.datetime:
        return {}
    fields = {
        "last": "last_price", "settlement": "pre_settlement", "opening": "open", "bid": "bid_price1",
        "ask": "ask_price1", "volume": "volume", "interest": "open_interest",
        "previousInterest": "pre_open_interest",
        "highest": "highest", "lowest": "lowest",
        "bidVolume": "bid_volume1", "askVolume": "ask_volume1",
    }
    values = {"time": quote.datetime}
    for key, field in fields.items():
        value = getattr(quote, field, None)
        if value is not None and math.isfinite(value):
            values[key] = float(value)
    return values


@short_query
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


@cached_short_query
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
                    row = dict(snapshot(quote), code=code, strike=quote.strike_price,
                               side=quote.option_class)
                    for field, key in (("price_tick", "priceTick"),
                                       ("volume_multiple", "volumeMultiple")):
                        value = getattr(quote, field, None)
                        if isinstance(value, (int, float)) and math.isfinite(value) and value > 0:
                            row[key] = float(value)
                    result.append(row)
        return sorted(result, key=lambda row: (row["strike"], row["side"], row["code"]))
    finally:
        api.close()


@cached_short_query
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


@short_query
def load_bars(symbol, period, count):
    with open(AUTH_PATH, encoding="utf-8") as handle:
        credentials = json.load(handle)
    api = None
    try:
        api = TqApi(auth=TqAuth(credentials["username"], credentials["password"]))
        serial = api.get_kline_serial(quote_symbol(symbol), period, data_length=count)
        deadline = time.time() + 20
        bars = []
        while time.time() < deadline:
            api.wait_update(deadline=time.time() + 1)
            bars = bars_from_serial(serial)
            # Do not cache a partially initialized historical frame.
            # A cold request can be slower once, but every later page is
            # returned from the VPS disk cache.
            if len(bars) >= max(1, count - 2):
                break
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

    def status(self):
        with self.condition:
            return {"products": len(self.contracts),
                    "last_change_age_seconds": round(time.monotonic() - self.last_received, 1)
                    if self.last_received else None}

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
        bar = {
            "time": int(row.datetime) // 1_000_000_000,
            "open": float(row.open),
            "high": float(row.high),
            "low": float(row.low),
            "close": float(row.close),
            "volume": int(row.volume) if math.isfinite(float(row.volume)) else 0,
        }
        for key, field in (("openInterest", "open_oi"), ("closeInterest", "close_oi")):
            value = getattr(row, field, None)
            if value is not None and math.isfinite(float(value)) and value >= 0:
                bar[key] = int(value)
        bars.append(bar)
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

    def __init__(self, directory=KLINE_CACHE_DIR, max_files=1800):
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
                row = {name: bar[name] for name in
                       ("time", "open", "high", "low", "close", "volume")}
                for field in ("openInterest", "closeInterest"):
                    value = bar.get(field)
                    if isinstance(value, (int, float)) and math.isfinite(value) and value >= 0:
                        row[field] = int(value)
                valid.append(row)
            return merge_kline_bars([], valid, limit=KLINE_DISK_HISTORY_LENGTH), float(payload.get("saved_at", 0))
        except (OSError, ValueError, TypeError, AttributeError, json.JSONDecodeError):
            return [], 0.0

    def write(self, key, bars, *, older=False):
        if not bars:
            return
        # A separate systemd historical prefetch job also writes these files.
        # A per-series OS lock prevents lost updates across two processes.
        try:
            target = self.path(key)
            self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            lock_path = target.with_suffix(".lock")
            with lock_path.open("a+b") as lock_file:
                os.fchmod(lock_file.fileno(), 0o600)
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
                try:
                    self._write_locked(key, bars, older=older)
                finally:
                    fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
        except (OSError, ValueError) as exc:
            print("K线缓存跨进程写入失败:", type(exc).__name__,
                  str(exc)[:100], flush=True)

    def _write_locked(self, key, bars, *, older=False):
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
    """24 live subscriptions, bounded RAM, persistent K-line disk cache.

    The live and interactive history workers use separate TqApi instances.
    A scheduled systemd job prefetches all active main contracts through a
    third low-priority process and shares only the locked disk files.
    """

    def __init__(self, max_series=KLINE_MAX_SERIES, store=None):
        self.condition = threading.Condition()
        self.max_series = max_series
        self.store = store
        self.entries = {}           # active live subscription entries
        self.cache = {}             # key -> (deduplicated bars, version)
        self.cached_used = {}       # key -> monotonic LRU clock
        self.live_tail = {}         # last 2 authoritative live bars
        self.live_timing = {}       # key -> (version, TqSdk observation epoch)
        self.last_saved = {}
        self.file_write_lock = threading.Lock()
        self.pending_disk_writes = OrderedDict()
        self.disk_writer = None
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
            if (not bars or time.time() - refreshed > KLINE_HISTORY_REFRESH_SECONDS):
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

    def publish(self, key, bars, *, history=False, received_at=None):
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
                if not history and received_at is not None:
                    self.live_timing[key] = (version + 1, received_at)
                else:
                    self.live_timing.pop(key, None)
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
                    self.live_timing.pop(oldest, None)
        if to_save is not None:
            if history:
                self._persist_latest(key, to_save)
            else:
                self._queue_live_write(key, to_save)

    def _persist_latest(self, key, fallback):
        with self.file_write_lock:
            with self.condition:
                newest = self.cache.get(key, (fallback, 0))[0]
            self.store.write(key, newest)

    def _queue_live_write(self, key, bars):
        with self.condition:
            self.pending_disk_writes[key] = bars
            self.pending_disk_writes.move_to_end(key)
            while len(self.pending_disk_writes) > KLINE_MAX_SERIES:
                dropped, _ = self.pending_disk_writes.popitem(last=False)
                self.last_saved.pop(dropped, None)
            if self.disk_writer is None or not self.disk_writer.is_alive():
                self.disk_writer = threading.Thread(target=self._run_disk_writer,
                                                    name="kline-disk", daemon=True)
                self.disk_writer.start()
            self.condition.notify_all()

    def _run_disk_writer(self):
        while True:
            with self.condition:
                while not self.pending_disk_writes:
                    self.condition.wait()
            try:
                # Lock order matches history pagination. Do not hold the hub
                # condition during disk I/O. Coalesce by key before writing.
                with self.file_write_lock:
                    with self.condition:
                        if not self.pending_disk_writes:
                            continue
                        key, fallback = self.pending_disk_writes.popitem(last=False)
                        newest = self.cache.get(key, ([], 0))[0]
                    # Evicted keys are already recoverable from disk/history;
                    # don't persist an obsolete queued frame over newer data.
                    if newest:
                        self.store.write(key, newest)
            except Exception as exc:
                print("K线异步写盘失败:", type(exc).__name__, flush=True)

    def timing_for(self, key, version):
        with self.condition:
            record = self.live_timing.get(key)
            return record[1] if record and record[0] == version else None

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
        # HTTP previews never consume a live subscription slot.
        key = (quote_symbol(symbol), period)
        with self.condition:
            self._restore_locked(key)
            bars = self.cache.get(key, ([], 0))[0]
            if (not bars or time.time() - self.last_history.get(key, 0)
                    > KLINE_HISTORY_REFRESH_SECONDS):
                self._schedule_locked(key, urgent=True)
        self.start()
        bars, _ = self.read(key, timeout=timeout)
        return bars[-count:]

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
                            started = time.monotonic()
                            installed[key] = api.get_kline_serial(
                                key[0], key[1], data_length=KLINE_DATA_LENGTH)
                            elapsed = (time.monotonic() - started) * 1000
                            if elapsed >= 300:
                                print(f"QIHUI_LATENCY subscribe symbol={key[0]} period={key[1]} ms={elapsed:.1f}", flush=True)
                            break
                    updated = api.wait_update(deadline=time.time() + 0.3)
                    received_at = time.time()
                    for key in targets:
                        serial = installed.get(key)
                        if serial is None:
                            continue
                        if updated and api.is_changing(serial):
                            started = time.monotonic()
                            self.publish(key, bars_from_serial(serial), received_at=received_at)
                            elapsed = (time.monotonic() - started) * 1000
                            if elapsed >= 100:
                                print(f"QIHUI_LATENCY publish symbol={key[0]} period={key[1]} ms={elapsed:.1f}", flush=True)
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
HISTORY_SHORT_PROBES = OrderedDict()
HISTORY_SHORT_PROBE_TTL = 300
HISTORY_SHORT_PROBE_MAX = 128


def historical_page(symbol, period, before, count, depth, *, page_info=None):
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
    if not HISTORY_QUERY_LOCK.acquire(timeout=3):
        raise RuntimeError("history_query_busy")
    try:
        stored = available()
        older = older_rows(stored)
        if len(older) >= count or len(stored) >= depth:
            return older[-count:]
        probe_key = (key, depth)
        previous_probe = HISTORY_SHORT_PROBES.get(probe_key)
        if (previous_probe is not None and time.monotonic() < previous_probe[0]
                and stored and stored[0]["time"] <= previous_probe[1]):
            return older[-count:]
        fetched = load_bars(symbol, period, depth)
        if fetched and len(fetched) < depth - 2:
            # A short SDK response is not proof of listing-date exhaustion.
            # Two different depths with the same earliest timestamp justify
            # pausing this interactive search, not declaring permanent EOF.
            if page_info is not None and fetched[0]["time"] >= before:
                now = time.monotonic()
                if any(other_key == key and other_depth < depth
                       and expiry > now and earliest == fetched[0]["time"]
                       for (other_key, other_depth), (expiry, earliest)
                       in HISTORY_SHORT_PROBES.items()):
                    page_info["retry_after_seconds"] = 300
            HISTORY_SHORT_PROBES[probe_key] = (time.monotonic() + HISTORY_SHORT_PROBE_TTL,
                                              fetched[0]["time"])
            HISTORY_SHORT_PROBES.move_to_end(probe_key)
            while len(HISTORY_SHORT_PROBES) > HISTORY_SHORT_PROBE_MAX:
                HISTORY_SHORT_PROBES.popitem(last=False)
        if not fetched:
            return older[-count:]
        if KLINE_HUB.store is None:
            return older_rows(merge_kline_bars(
                fetched, stored, limit=KLINE_DISK_HISTORY_LENGTH))[-count:]
        with KLINE_HUB.file_write_lock:
            try:
                KLINE_HUB.store.write(key, fetched, older=True)
            except OSError as exc:
                print("历史缓存持久化失败:", type(exc).__name__, flush=True)
            persisted = available()
        # Storage may be unavailable (read-only volume, exhausted disk).
        # A valid upstream response must still reach the phone: persistence
        # is a performance optimization, never a correctness prerequisite.
        merged = merge_kline_bars(
            fetched, persisted or stored, limit=KLINE_DISK_HISTORY_LENGTH)
        return older_rows(merged)[-count:]
    finally:
        HISTORY_QUERY_LOCK.release()


class BoundedMarketServer(ThreadingHTTPServer):
    """Reserve a fixed process-wide budget, including SSE connections."""
    def __init__(self, *args, **kwargs):
        self.request_slots = threading.BoundedSemaphore(32)
        super().__init__(*args, **kwargs)

    def process_request(self, request, client_address):
        if not self.request_slots.acquire(blocking=False):
            try:
                request.settimeout(0.2)
                request.sendall(b"HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\nRetry-After: 3\r\n\r\n")
            except OSError:
                pass
            finally:
                self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.request_slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.request_slots.release()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    timeout = 30

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
            last_trace = float('-inf')
            while True:
                bars, next_version = KLINE_HUB.read(key, after_version=version, timeout=12)
                now = time.monotonic()
                if bars and next_version != version:
                    event = next_kline_stream_event(
                        symbol, previous_frame, bars, count,
                        force_full=(now - last_full >= 60))
                    if event is not None:
                        received_at = KLINE_HUB.timing_for(key, next_version) if now - last_trace >= 2 else None
                        if received_at is not None:
                            sent_at = time.time()
                            event["diag"] = {"version": next_version, "received_at": received_at,
                                             "sent_at": sent_at}
                            started = time.monotonic()
                            self.push_event(event)
                            print(f"QIHUI_LATENCY sse symbol={symbol} period={period} version={next_version} "
                                  f"server_ms={(sent_at - received_at) * 1000:.1f} "
                                  f"flush_ms={(time.monotonic() - started) * 1000:.1f}", flush=True)
                            last_trace = now
                        else:
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
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True

    def do_GET(self):
        try:
            Handler.handle_get(self)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True
        except RuntimeError as exc:
            self.reply(503, {"error": "market_query_busy" if str(exc) == "market_query_busy"
                             else "market_data_unavailable"})

    def handle_get(self):
        url = urlsplit(self.path)
        if url.path.startswith("/v1/") and not market_authorized(getattr(self, "headers", {})):
            self.reply(403, {"error": "market_access_denied"})
            return
        if url.path == "/health":
            self.reply(200, {"ok": True, "quote_stream": True, "bar_stream": True,
                             "kline_cache": KLINE_HUB.status(),
                             "quote_feed": LIVE_QUOTES.status()})
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
                page_info = {}
                older = historical_page(symbol, period, before, count, depth, page_info=page_info)
                self.reply(200, {"symbol": symbol, "period": period, "bars": older, **page_info})
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
    if MARKET_ACCESS and (len(MARKET_ACCESS) < 32 or not MARKET_ACCESS.isascii()):
        raise SystemExit("QIHUI_MARKET_ACCESS_KEY must be at least 32 ASCII characters")
    host = os.environ.get("QIHUI_BIND", "127.0.0.1")
    port = int(os.environ.get("QIHUI_PORT", "8765"))
    print("Qihui read-only gateway listening on %s:%s" % (host, port), flush=True)
    LIVE_QUOTES.start()
    KLINE_HUB.start()
    BoundedMarketServer((host, port), Handler).serve_forever()
