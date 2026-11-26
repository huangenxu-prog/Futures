
"""Single-owner TqKq simulation only. No real accounts."""
import hmac
import hashlib
import json
import math
import logging
from logging.handlers import RotatingFileHandler
import queue
import re
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

AUDIT = logging.getLogger("qihui.trade.audit")
AUDIT.propagate = False
AUDIT.addHandler(logging.NullHandler())


def configure_audit(path):
    # The installer already provides a private, mode-0700 working directory.
    fd = os.open(path, os.O_APPEND | os.O_CREAT | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        os.fchmod(fd, 0o600)
    finally:
        os.close(fd)
    handler = RotatingFileHandler(path, maxBytes=2_000_000, backupCount=3, encoding="utf-8")
    handler.setFormatter(logging.Formatter("%(message)s"))
    AUDIT.handlers[:] = [handler]
    AUDIT.setLevel(logging.INFO)


def audit(event, **fields):
    # Only explicitly selected metadata; never raw request/exception messages.
    try:
        if "id" in fields and not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", fields["id"]):
            fields["id"] = hashlib.sha256(fields["id"].encode("utf-8")).hexdigest()
        AUDIT.info(json.dumps(dict(event=event, time_ns=time.time_ns(), **fields),
                              ensure_ascii=False, allow_nan=False))
    except Exception:
        pass


def equal(a, b):
    return hmac.compare_digest(a.encode("utf-8"), b.encode("utf-8"))

def number(v):
    try:
        v = float(v)
        return v if math.isfinite(v) else None
    except (TypeError, ValueError, OverflowError):
        return None

def order_state(status, quantity, remaining, message, is_error, exchange_order_id):
    if status == "ALIVE":
        return "PARTIAL" if 0 < remaining < quantity else "ALIVE"
    if status != "FINISHED":
        return "UNKNOWN"
    if quantity > 0 and remaining == 0:
        return "FILLED"
    if is_error is True:
        return "REJECTED"
    # Do not confuse cancellation rejection with successful cancellation.
    if any(x in message for x in ("撤单失败", "撤单拒绝", "撤单错误", "无法撤单", "不能撤单")):
        return "FINISHED"
    if any(x in message for x in ("已撤", "撤单成功", "撤单完成", "撤单已完成", "撤销成功", "已撤销", "部成部撤", "全部撤单")):
        return "PARTIAL_CANCELED" if 0 < remaining < quantity else "CANCELED"
    # A finished, incompletely filled order with an exchange order ID was accepted.
    # Keep ambiguous terminal results distinct when the SDK supplies no evidence.
    if is_error is False and exchange_order_id and remaining > 0:
        return "PARTIAL_CANCELED" if remaining < quantity else "CANCELED"
    return "FINISHED"

def order_row(oid, o):
    message = str(o.last_msg or "")
    is_error = getattr(o, "is_error", None)
    exchange_order_id = str(getattr(o, "exchange_order_id", "") or "")
    return {"id": oid, "symbol": str(o.exchange_id) + "." + str(o.instrument_id),
            "direction": str(o.direction), "offset": str(o.offset),
            "price": number(o.limit_price), "quantity": int(o.volume_orign),
            "remaining": int(o.volume_left), "status": str(o.status),
            "message": message[:200], "time_ns": int(getattr(o, "insert_date_time", 0) or 0),
            "exchange_order_id": exchange_order_id,
            "is_error": is_error if isinstance(is_error, bool) else None,
            "display_state": order_state(str(o.status), int(o.volume_orign), int(o.volume_left), message, is_error, exchange_order_id)}

def fill_row(tid, t):
    return {"id": tid, "order_id": str(t.order_id),
            "symbol": str(t.exchange_id) + "." + str(t.instrument_id),
            "direction": str(t.direction), "offset": str(t.offset),
            "price": number(t.price), "quantity": int(t.volume),
            "time_ns": int(t.trade_date_time)}

def validate_order(body):
    oid = body["id"]
    symbol = body["symbol"]
    direction, offset = body["direction"], body["offset"]
    quantity = body["quantity"]
    raw_price = body["price"]
    # Reject fractional quantities and JSON booleans instead of coercing them.
    if type(quantity) is not int or type(raw_price) not in (int, float):
        raise ValueError("invalid price or volume type")
    price = float(raw_price)
    if not isinstance(oid, str) or not re.fullmatch(r"[a-f0-9]{32}", oid):
        raise ValueError("invalid id")
    if not isinstance(symbol, str) or not re.fullmatch(r"(SHFE|INE|DCE|CZCE|GFEX|CFFEX)\.[A-Za-z]+[0-9]{3,4}([CP][0-9]+(?:\.[0-9]+)?|-[CP]-[0-9]+(?:\.[0-9]+)?)?", symbol):
        raise ValueError("invalid symbol")
    if direction not in ("BUY", "SELL") or offset not in ("OPEN", "CLOSE", "CLOSETODAY"):
        raise ValueError("invalid direction or offset")
    if offset == "CLOSETODAY" and symbol.split(".")[0] not in ("SHFE", "INE"):
        raise ValueError("invalid close today")
    if not 1 <= quantity <= 10 or not math.isfinite(price) or not 0 < price <= 1e8:
        raise ValueError("invalid price or volume")
    return oid, symbol, direction, offset, quantity, price

def snapshot(account, positions, orders=None, fills=None):
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
                         "float_profit": number(getattr(pos, "float_profit", None)),
                         "open_price_long": number(getattr(pos, "open_price_long", None)),
                         "open_price_short": number(getattr(pos, "open_price_short", None)),
                         "float_profit_long": number(getattr(pos, "float_profit_long", None)),
                         "float_profit_short": number(getattr(pos, "float_profit_short", None)),
                         "frozen_long": number(getattr(pos, "volume_long_frozen", None)),
                         "frozen_short": number(getattr(pos, "volume_short_frozen", None))})
    return {"account": data, "positions": sorted(rows, key=lambda x: x["symbol"]),
            "orders": sorted([order_row(k, v) for k, v in (orders or {}).items() if v.instrument_id and v.volume_orign > 0], key=lambda x: (x["time_ns"], x["id"]), reverse=True),
            "fills": [fill_row(k, v) for k, v in (fills or {}).items() if v.instrument_id and v.volume > 0],
            "simulation_orders": True}

class Session:
    def __init__(self, username, password):
        self.token = secrets.token_urlsafe(32)
        self.username = username
        self.salt = secrets.token_bytes(16)
        self.verifier = self.password_digest(password)
        self.inflight = 0
        self.stop = threading.Event()
        self.ready = threading.Event()
        self.data_lock = threading.Lock()
        self.data = None
        self.commands = queue.Queue(maxsize=16)
        self.seen = {}
        self.submitted = set()
        self.snapshot_monotonic = None
        self.last_access = time.monotonic()
        self.worker = threading.Thread(target=self.run, args=(username, password), daemon=True)
        self.worker.start()

    def password_digest(self, password):
        return hashlib.scrypt(password.encode('utf-8'), salt=self.salt, n=16384, r=8, p=1)

    def matches(self, username, password):
        return equal(self.username, username) and hmac.compare_digest(self.verifier, self.password_digest(password))

    def run(self, username, password):
        api = None
        try:
            from tqsdk import TqApi, TqAuth, TqKq
            api = TqApi(TqKq(), auth=TqAuth(username, password))
            password = None
            account = api.get_account()
            positions = api.get_position()
            orders = api.get_order()
            fills = api.get_trade()
            while not self.stop.is_set() and time.monotonic() - self.last_access < IDLE:
                try:
                    action, payload, done, result = self.commands.get_nowait()
                except queue.Empty:
                    pass
                else:
                    try:
                        if action == "order":
                            oid, symbol, direction, offset, qty, price = payload
                            audit("order_attempt", id=oid, symbol=symbol, direction=direction,
                                  offset=offset, quantity=qty, price=price)
                            if (self.snapshot_monotonic is None
                                    or time.monotonic() - self.snapshot_monotonic > 5):
                                result["status"] = 503
                            else:
                                result["status"] = self.submit_order(api, orders, payload)
                        else:
                            audit("cancel_attempt", id=payload)
                            order = orders.get(payload)
                            if order is None or order.status != "ALIVE":
                                result["status"] = 409
                            else:
                                api.cancel_order(order)
                                result["status"] = 200
                    except Exception as exc:
                        result["status"] = 503
                        audit("command_exception", action=action, error_type=type(exc).__name__)
                    finally:
                        audit("command_result", action=action, id=payload[0] if action == "order" else payload,
                              status=result.get("status", 503))
                        with LOCK:
                            self.inflight -= 1
                        done.set()
                api.wait_update(deadline=time.time() + 0.5)
                data = snapshot(account, positions, orders, fills)
                with self.data_lock:
                    self.data = data
                    self.snapshot_monotonic = time.monotonic() if data is not None else None
                if data is not None:
                    self.ready.set()
        except Exception as exc:
            audit("session_exception", error_type=type(exc).__name__)
        finally:
            audit("session_end")
            self.stop.set()
            with self.data_lock:
                self.data = None
            self.ready.set()
            if api is not None:
                try:
                    api.close()
                except Exception:
                    pass

    def submit_order(self, api, orders, payload):
        # Owner thread only. Record intent before SDK submission; never replay
        # an uncertain request, even if insert_order raised after transmission.
        oid, symbol, direction, offset, qty, price = payload
        if oid in self.seen:
            if self.seen[oid] != payload:
                return 409
            if oid in self.submitted or oid in orders:
                return 200
            return 503
        if oid in orders:
            return 409
        if len(self.seen) >= 1000:
            return 429
        self.seen[oid] = payload
        api.insert_order(symbol=symbol, direction=direction, offset=offset,
                         volume=qty, limit_price=price, order_id=oid)
        self.submitted.add(oid)
        return 200

    def read(self):
        with self.data_lock:
            if self.data is None:
                return None
            result = dict(self.data)
            # Measures worker snapshot age, not upstream exchange connectivity.
            result["snapshot_age_ms"] = (int((time.monotonic() - self.snapshot_monotonic) * 1000)
                                         if self.snapshot_monotonic is not None else None)
            return result

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
                if now - LAST_LOGIN < 5:
                    return self.reply(429)
                LAST_LOGIN = now
                if SESSION is not None and SESSION.worker.is_alive():
                    s = SESSION
                    if s.stop.is_set():
                        return self.reply(409)
                    if not s.matches(username, password):
                        return self.reply(403)
                    if s.inflight:
                        return self.reply(409)
                    # Reuse the authenticated SDK session, never restart it or replay orders.
                    # Rotate only once a usable snapshot exists below.
                    s.last_access = now
                else:
                    SESSION = s = Session(username, password)
            del body, username, password
            if not s.ready.wait(60):
                return self.reply(503)
            with LOCK:
                if s is not SESSION or s.stop.is_set():
                    return self.reply(503)
                data = s.read()
                if data is None:
                    return self.reply(503)
                if s.inflight:
                    return self.reply(409)
                s.token = secrets.token_urlsafe(32)
                s.last_access = time.monotonic()
                token = s.token
            return self.reply(200, {"token": token, "snapshot": data})
        if self.path not in (PREFIX + "snapshot", PREFIX + "logout", PREFIX + "order", PREFIX + "cancel"):
            return self.reply(404)
        with LOCK:
            s = SESSION
            if s is None or s.stop.is_set() or not equal(self.headers.get("Authorization", ""), "Bearer " + s.token):
                return self.reply(401)
            if self.path == PREFIX + "logout" and method == "POST":
                if s.inflight:
                    return self.reply(409)
                s.stop.set()
                return self.reply(200)
            s.last_access = time.monotonic()
            data = s.read()
        if self.path == PREFIX + "snapshot" and method == "GET":
            return self.reply(200, {"snapshot": data}) if data is not None else self.reply(503)
        if method != "POST" or self.path not in (PREFIX + "order", PREFIX + "cancel"):
            return self.reply(405)
        if data is None:
            return self.reply(503)
        age = data.get("snapshot_age_ms")
        action = self.path[len(PREFIX):]
        if action == "order" and (age is None or age > 5000):
            return self.reply(503)
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 8192:
                return self.reply(400)
            body = json.loads(self.rfile.read(length))
            payload = validate_order(body) if action == "order" else body["id"]
            if action == "cancel" and (not isinstance(payload, str) or not 0 < len(payload) <= 128):
                return self.reply(400)
        except (ValueError, TypeError, KeyError, OSError, OverflowError):
            return self.reply(400)
        done, result = threading.Event(), {}
        with LOCK:
            if s is not SESSION or s.stop.is_set() or not equal(self.headers.get("Authorization", ""), "Bearer " + s.token):
                return self.reply(401)
            if s.inflight:
                return self.reply(409)
            try:
                s.inflight += 1
                s.commands.put_nowait((action, payload, done, result))
            except queue.Full:
                s.inflight -= 1
                return self.reply(429)
        if not done.wait(12):
            audit("command_wait_timeout", action=action, id=payload[0] if action == "order" else payload)
            return self.reply(503)
        return self.reply(result.get("status", 503))

def main():
    if len(ACCESS) < 32:
        raise SystemExit("Set a private QIHUI_TRADE_ACCESS_KEY of at least 32 characters")
    configure_audit("trade-audit.jsonl")
    ThreadingHTTPServer(("127.0.0.1", 8766), Handler).serve_forever()

if __name__ == "__main__":
    main()
