
"""Single-owner, read-only TqKq gateway. No real accounts or order endpoints."""
import hmac
import json
import math
import os
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PREFIX = "/v1/trade/"
IDLE = 1200
LOCK = threading.Lock()
SESSION = None
LAST_LOGIN = 0.0
ACCESS = os.environ.get("QIHUI_TRADE_ACCESS_KEY", "")

def equal(a, b):
    return hmac.compare_digest(a.encode("utf-8"), b.encode("utf-8"))

def number(v):
    try:
        v = float(v)
        return v if math.isfinite(v) else None
    except (TypeError, ValueError, OverflowError):
        return None

def snapshot(account, positions):
    fields = ("balance", "available", "margin", "float_profit", "close_profit")
    data = {field: number(getattr(account, field, None)) for field in fields}
    if data["balance"] is None or data["available"] is None:
        return None
    rows = []
    for symbol, pos in positions.items():
        long = int(number(getattr(pos, "pos_long", 0)) or 0)
        short = int(number(getattr(pos, "pos_short", 0)) or 0)
        if long or short:
            rows.append({"symbol": symbol, "long": long, "short": short,
                         "float_profit": number(getattr(pos, "float_profit", None))})
    return {"account": data, "positions": sorted(rows, key=lambda x: x["symbol"])}

class Session:
    def __init__(self, username, password):
        self.token = secrets.token_urlsafe(32)
        self.stop = threading.Event()
        self.ready = threading.Event()
        self.data_lock = threading.Lock()
        self.data = None
        self.last_access = time.monotonic()
        self.worker = threading.Thread(target=self.run, args=(username, password), daemon=True)
        self.worker.start()

    def run(self, username, password):
        api = None
        try:
            from tqsdk import TqApi, TqAuth, TqKq
            api = TqApi(TqKq(), auth=TqAuth(username, password))
            password = None
            account = api.get_account()
            positions = api.get_position()
            while not self.stop.is_set() and time.monotonic() - self.last_access < IDLE:
                api.wait_update(deadline=time.time() + 1)
                data = snapshot(account, positions)
                with self.data_lock:
                    self.data = data
                if data is not None:
                    self.ready.set()
        except Exception:
            # Never return or log SDK errors containing account credentials.
            pass
        finally:
            self.stop.set()
            with self.data_lock:
                self.data = None
            self.ready.set()
            if api is not None:
                try:
                    api.close()
                except Exception:
                    pass

    def read(self):
        with self.data_lock:
            return self.data

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def setup(self):
        super().setup()
        self.connection.settimeout(10)

    def reply(self, code, data=None):
        payload = json.dumps(data or {}, allow_nan=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def authorized(self):
        return bool(ACCESS) and equal(self.headers.get("X-Qihui-Access", ""), ACCESS)

    def do_GET(self):
        self.handle_request("GET")

    def do_POST(self):
        self.handle_request("POST")

    def handle_request(self, method):
        global SESSION, LAST_LOGIN
        if not self.authorized():
            return self.reply(403)
        if self.path == PREFIX + "login" and method == "POST":
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 8192:
                    return self.reply(400)
                body = json.loads(self.rfile.read(length))
                username, password = body["username"], body["password"]
                if not all(isinstance(x, str) and 0 < len(x) <= 512 for x in (username, password)):
                    return self.reply(400)
            except (ValueError, TypeError, KeyError, OSError):
                return self.reply(400)
            with LOCK:
                now = time.monotonic()
                if SESSION is not None and SESSION.worker.is_alive():
                    return self.reply(409)
                if now - LAST_LOGIN < 5:
                    return self.reply(429)
                LAST_LOGIN = now
                SESSION = s = Session(username, password)
            del body, username, password
            if not s.ready.wait(60) or s.stop.is_set() or s.read() is None:
                s.stop.set()
                return self.reply(503)
            return self.reply(200, {"token": s.token, "snapshot": s.read()})
        if self.path not in (PREFIX + "snapshot", PREFIX + "logout"):
            return self.reply(404)
        with LOCK:
            s = SESSION
            if s is None or s.stop.is_set() or not equal(self.headers.get("Authorization", ""), "Bearer " + s.token):
                return self.reply(401)
            if self.path == PREFIX + "logout" and method == "POST":
                s.stop.set()
                return self.reply(200)
            if self.path != PREFIX + "snapshot" or method != "GET":
                return self.reply(405)
            s.last_access = time.monotonic()
            data = s.read()
        return self.reply(200, {"snapshot": data}) if data is not None else self.reply(503)

def main():
    if len(ACCESS) < 32:
        raise SystemExit("Set a private QIHUI_TRADE_ACCESS_KEY of at least 32 characters")
    ThreadingHTTPServer(("127.0.0.1", 8766), Handler).serve_forever()

if __name__ == "__main__":
    main()
