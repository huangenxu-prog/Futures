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
# Serialize TqSdk requests: the SDK manages its own event loop and is not thread-safe.
LOCK = threading.Lock()


contract_cache = {}
contract_cache_until = 0.0


def contract_product(code):
    match = re.fullmatch(r"([A-Z]+\.[A-Za-z]+)[0-9]{3,4}", code)
    return match.group(1) if match else None


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


def load_bars(symbol, period, count):
    with open(AUTH_PATH, encoding="utf-8") as handle:
        credentials = json.load(handle)
    api = None
    try:
        api = TqApi(auth=TqAuth(credentials["username"], credentials["password"]))
        serial = api.get_kline_serial("KQ.m@" + symbol if symbol in SYMBOLS else symbol, period, data_length=count)
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
BAR_STREAM_SLOTS = threading.BoundedSemaphore(3)


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
        api = None
        try:
            with open(AUTH_PATH, encoding="utf-8") as handle:
                credentials = json.load(handle)
            api = TqApi(auth=TqAuth(credentials["username"], credentials["password"]))
            serial = api.get_kline_serial("KQ.m@" + symbol if symbol in SYMBOLS else symbol,
                                        period, data_length=count)
            self.begin_stream()
            previous = None
            last_full = 0.0
            last_sent = 0.0
            pending = False
            last_heartbeat = time.monotonic()
            while True:
                updated = api.wait_update(deadline=time.time() + 0.3)
                now = time.monotonic()
                # Stream a full frame initially and periodically, then lightweight current-bar changes.
                pending = pending or (updated and api.is_changing(serial))
                if (previous is None or pending or now - last_full >= 60) and now - last_sent >= 0.2:
                    bars = bars_from_serial(serial)
                    if bars:
                        latest = bars[-1]
                        if previous is None or now - last_full >= 60:
                            self.push_event({"symbol": symbol, "bars": bars})
                            last_full = now
                        elif latest != previous:
                            self.push_event({"symbol": symbol, "bar": latest})
                        else:
                            pending = False
                            continue
                        previous = latest
                        pending = False
                        last_sent = now
                        last_heartbeat = now
                if now - last_heartbeat >= 12:
                    self.wfile.write(b": heartbeat\n\n")
                    self.wfile.flush()
                    last_heartbeat = now
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        except Exception as exc:
            print("K线实时流异常:", type(exc).__name__, str(exc)[:180], flush=True)
        finally:
            if api is not None:
                try:
                    api.close()
                except Exception:
                    pass
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
            self.reply(200, {"ok": True, "quote_stream": True, "bar_stream": True})
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
                if (symbol not in SYMBOLS and contract_product(symbol) not in SYMBOLS) or period not in PERIODS or not 5 <= count <= 500:
                    raise ValueError("invalid stream")
            except (KeyError, ValueError, IndexError):
                self.reply(400, {"error": "invalid_stream_parameters"})
                return
            self.stream_bars(symbol, period, count)
            return
        if url.path == "/v1/main-contracts":
            try:
                with LOCK:
                    contracts = LIVE_QUOTES.current() or main_contracts()
                self.reply(200, contracts)
            except Exception:
                self.reply(503, {"error": "market_data_unavailable"})
            return
        if url.path == "/v1/options":
            code = parse_qs(url.query).get("symbol", [""])[0]
            if contract_product(code) not in SYMBOLS:
                self.reply(400, {"error": "invalid_underlying"})
                return
            try:
                with LOCK:
                    chain = option_chain(code)
                self.reply(200, chain)
            except Exception:
                self.reply(503, {"error": "options_unavailable"})
            return
        if url.path != "/v1/klines":
            self.reply(404, {"error": "not_found"})
            return
        try:
            params = parse_qs(url.query)
            symbol = params["symbol"][0]
            period = int(params["period"][0])
            count = int(params.get("count", ["100"])[0])
            if (symbol not in SYMBOLS and contract_product(symbol) not in SYMBOLS) or period not in PERIODS or not 5 <= count <= 500:
                raise ValueError("invalid symbol, period or count")
        except (KeyError, ValueError, IndexError) as exc:
            self.reply(400, {"error": str(exc)})
            return
        try:
            with LOCK:
                bars = load_bars(symbol, period, count)
            self.reply(200 if bars else 503, {
                "symbol": symbol, "period": period, "bars": bars,
                "error": None if bars else "no_data",
            })
        except Exception:
            self.reply(503, {"error": "market_data_unavailable"})

    def log_message(self, format, *args):
        print("%s %s" % (self.address_string(), format % args), flush=True)


if __name__ == "__main__":
    host = os.environ.get("QIHUI_BIND", "127.0.0.1")
    port = int(os.environ.get("QIHUI_PORT", "8765"))
    print("Qihui read-only gateway listening on %s:%s" % (host, port), flush=True)
    LIVE_QUOTES.start()
    ThreadingHTTPServer((host, port), Handler).serve_forever()
