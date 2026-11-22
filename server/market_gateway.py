"""Read-only TqSdk K-line HTTP gateway. Bind to loopback; expose only behind authenticated HTTPS reverse proxy."""
import json
import math
import os
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
                 if q.underlying_symbol and q.underlying_symbol.startswith(product)]
        if not pairs:
            raise ValueError("missing contract identifiers")
        quotes = api.get_quote_list([code for _, code in pairs])
        result = {}
        for (product, code), quote in zip(pairs, quotes):
            year, month = quote.delivery_year, quote.delivery_month
            if 2000 <= year <= 2099 and 1 <= month <= 12:
                result[product] = {"code": code, "month": f"{int(year) % 100:02d}{int(month):02d}"}
        contract_cache = result
        contract_cache_until = time.monotonic() + (300 if len(result) == len(products) else 30)
        return result
    finally:
        api.close()


def load_bars(symbol, period, count):
    with open(AUTH_PATH, encoding="utf-8") as handle:
        credentials = json.load(handle)
    api = None
    try:
        api = TqApi(auth=TqAuth(credentials["username"], credentials["password"]))
        serial = api.get_kline_serial("KQ.m@" + symbol, period, data_length=count)
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


class Handler(BaseHTTPRequestHandler):
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
            self.reply(200, {"ok": True})
            return
        if url.path == "/v1/main-contracts":
            try:
                with LOCK:
                    contracts = main_contracts()
                self.reply(200, contracts)
            except Exception:
                self.reply(503, {"error": "market_data_unavailable"})
            return
        if url.path != "/v1/klines":
            self.reply(404, {"error": "not_found"})
            return
        try:
            params = parse_qs(url.query)
            symbol = params["symbol"][0]
            period = int(params["period"][0])
            count = int(params.get("count", ["100"])[0])
            if symbol not in SYMBOLS or period not in PERIODS or not 5 <= count <= 500:
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
    ThreadingHTTPServer((host, port), Handler).serve_forever()
