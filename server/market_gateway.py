"""Read-only TqSdk K-line HTTP gateway. Bind to loopback; expose only behind authenticated HTTPS reverse proxy."""
import json
import math
import os
import re
import threading
import time
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



# Shared, bounded live K-line cache. All TqApi methods for this hub run on one
# dedicated worker thread; HTTP threads only read copied, immutable snapshots.
# A cold symbol still needs an initial TqSdk subscription. Subsequent HTTP
# requests and SSE viewers share that subscription and receive cached data.
KLINE_MAX_SERIES = 24
KLINE_DATA_LENGTH = 200
# Warm sibling timeframes only after the requested chart has real bars.
# Prewarming is opportunistic: it never evicts a subscribed/active chart.
KLINE_PREWARM_PERIODS = (60, 300, 900, 1800, 3600, 86400)
KLINE_PREWARM_SPACING = 0.8


class KlineCapacityError(Exception):
    pass


class SharedKlineHub:
    def __init__(self, max_series=KLINE_MAX_SERIES):
        self.condition = threading.Condition()
        self.max_series = max_series
        self.entries = {}  # (sdk_symbol, period): {used, listeners, waiters}
        self.cache = {}    # key: (list of bars, version)
        self.generation = 0
        self.thread = None
        self.connected = False
        self.error = None

    def _prefetch_siblings_locked(self, key):
        # Called only with condition locked, after a foreground series
        # has yielded valid bars. The active chart is always first.
        symbol, selected_period = key
        for period in KLINE_PREWARM_PERIODS:
            sibling = (symbol, period)
            if sibling == key or sibling in self.entries:
                continue
            if len(self.entries) >= self.max_series:
                break
            self.entries[sibling] = {
                "used": time.monotonic(), "listeners": 0, "waiters": 0,
                "prefetch": True, "warmup_started": False
            }
        self.condition.notify_all()

    def start(self):
        with self.condition:
            if self.thread is None or not self.thread.is_alive():
                self.thread = threading.Thread(target=self.run, name="kline-feed", daemon=True)
                self.thread.start()

    def reserve(self, symbol, period, *, listener=False, waiter=False):
        key = (quote_symbol(symbol), period)
        with self.condition:
            if key not in self.entries:
                if len(self.entries) >= self.max_series:
                    # Do not evict a stream that is being watched or a pending
                    # HTTP request. Recycling the SDK drops stale subscriptions.
                    candidates = [((not entry.get("prefetch", False), entry["used"]), old)
                                  for old, entry in self.entries.items()
                                  if not entry["listeners"] and not entry["waiters"]]
                    if not candidates:
                        raise KlineCapacityError("kline_subscription_limit")
                    old_key = min(candidates)[1]
                    del self.entries[old_key]
                    self.cache.pop(old_key, None)
                    self.generation += 1
                self.entries[key] = {
                    "used": time.monotonic(), "listeners": 0, "waiters": 0,
                    "prefetch": False, "warmup_started": False
                }
            entry = self.entries[key]
            entry["used"] = time.monotonic()
            if listener or waiter:
                # An explicitly requested period supersedes its speculative
                # prefetch and must be installed before other cold siblings.
                entry["prefetch"] = False
            if listener:
                entry["listeners"] += 1
            if waiter:
                entry["waiters"] += 1
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

    def publish(self, key, bars):
        if not bars:
            return
        with self.condition:
            if key not in self.entries:
                return
            previous, version = self.cache.get(key, (None, 0))
            if bars != previous:
                self.cache[key] = (list(bars), version + 1)
                entry = self.entries[key]
                if (not entry.get("prefetch", False)
                        and not entry.get("warmup_started", False)):
                    entry["warmup_started"] = True
                    self._prefetch_siblings_locked(key)
                self.condition.notify_all()

    def read(self, key, after_version=-1, timeout=10):
        deadline = time.monotonic() + timeout
        with self.condition:
            while True:
                bars, version = self.cache.get(key, ([], 0))
                if bars and version != after_version:
                    if key in self.entries:
                        self.entries[key]["used"] = time.monotonic()
                    return list(bars), version
                remaining = deadline - time.monotonic()
                if remaining <= 0 or key not in self.entries:
                    return list(bars), version
                self.condition.wait(timeout=remaining)

    def snapshot(self, symbol, period, count, timeout=11):
        key = self.reserve(symbol, period, waiter=True)
        try:
            bars, _ = self.read(key, timeout=timeout)
            return bars[-count:]
        finally:
            self.release(key, waiter=True)

    def status(self):
        with self.condition:
            return {"connected": self.connected, "tracked": len(self.entries),
                    "ready": len(self.cache), "data_length": KLINE_DATA_LENGTH,
                    "prefetch_pending": sum(1 for key, entry in self.entries.items()
                                            if entry.get("prefetch") and key not in self.cache)}

    def run(self):
        while True:
            api = None
            try:
                with open(AUTH_PATH, encoding="utf-8") as handle:
                    credentials = json.load(handle)
                api = TqApi(auth=TqAuth(credentials["username"], credentials["password"]))
                installed = {}
                last_prefetch_at = 0.0
                with self.condition:
                    generation = self.generation
                    self.connected = True
                    self.error = None
                    self.condition.notify_all()
                while True:
                    with self.condition:
                        if generation != self.generation:
                            # The bounded subscription set was evicted. Restart
                            # the SDK session so unsubscribed serials are freed.
                            break
                        targets = sorted(
                            self.entries,
                            key=lambda key: (
                                self.entries[key]["prefetch"],
                                -self.entries[key]["used"]
                            )
                        )
                        urgent = any(
                            key not in installed and not self.entries[key]["prefetch"]
                            for key in targets
                        )
                    for key in targets:
                        if key in installed:
                            continue
                        with self.condition:
                            if key not in self.entries:
                                continue
                            speculative = self.entries[key]["prefetch"]
                        if speculative:
                            # Never delay a requested chart behind optional
                            # subscriptions. Space speculative work out so
                            # existing live charts can process updates.
                            if (urgent or
                                    time.monotonic() - last_prefetch_at < KLINE_PREWARM_SPACING):
                                continue
                            last_prefetch_at = time.monotonic()
                        # One subscription per event-loop pass; all non-thread
                        # safe TqSdk operations remain on this worker.
                        installed[key] = api.get_kline_serial(
                            key[0], key[1], data_length=KLINE_DATA_LENGTH)
                        break
                    updated = api.wait_update(deadline=time.time() + 0.3)
                    for key in targets:
                        serial = installed.get(key)
                        if serial is None:
                            continue
                        with self.condition:
                            has_snapshot = key in self.cache
                        if not has_snapshot or (updated and api.is_changing(serial)):
                            bars = bars_from_serial(serial)
                            if bars:
                                self.publish(key, bars)
            except Exception as exc:
                with self.condition:
                    self.error = type(exc).__name__ + ": " + str(exc)[:140]
                    self.connected = False
                    self.condition.notify_all()
                print("K线共享连接异常，准备重连:", self.error, flush=True)
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


KLINE_HUB = SharedKlineHub()


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
            previous = bars[-1]
            last_full = time.monotonic()
            while True:
                bars, next_version = KLINE_HUB.read(key, after_version=version, timeout=12)
                now = time.monotonic()
                if bars and next_version != version:
                    latest = bars[-1]
                    if now - last_full >= 60:
                        self.push_event({"symbol": symbol, "bars": bars[-count:]})
                        last_full = now
                    elif latest != previous:
                        self.push_event({"symbol": symbol, "bar": latest})
                    previous = latest
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
                with LOCK:
                    candles = load_bars(symbol, period, depth)
                older = [bar for bar in candles if bar["time"] < before]
                self.reply(200, {"symbol": symbol, "period": period, "bars": older[-count:]})
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
