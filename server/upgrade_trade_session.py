"""Upgrade only an installed, read-only Qihui simulation service to order-capable TqKq."""
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from urllib.request import Request, urlopen
from urllib.error import HTTPError

COMMIT = "1814c149ea4e412cc4f74139e2dbf9785016ccba"
BLOB = "ce0452501f00970d0246bee203fd57562791e71f"
TARGET = Path("/root/tq_test/server/trade_gateway.py")
ENV = Path("/etc/qihui-trade.env")
SERVICE = "qihui-trade.service"
BASE = "https://8.153.96.190"

def blob(raw):
    return hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest()

def code(url, key=None):
    req = Request(url, headers={"X-Qihui-Access": key} if key else {})
    try:
        with urlopen(req, timeout=5) as r:
            return r.status
    except HTTPError as exc:
        return exc.code

def download():
    sources = [
        ("api", "https://api.github.com/repos/huangenxu-prog/Futures/contents/server/trade_gateway.py?ref=" + COMMIT),
        ("cdn", "https://cdn.jsdelivr.net/gh/huangenxu-prog/Futures@" + COMMIT + "/server/trade_gateway.py"),
    ]
    for kind, url in sources:
        try:
            with urlopen(Request(url, headers={"User-Agent": "Qihui-Updater"}), timeout=20) as response:
                raw = response.read(100000)
            if kind == "api":
                raw = base64.b64decode(json.loads(raw)["content"])
            if blob(raw) != BLOB:
                raise ValueError("hash mismatch")
            compile(raw, str(TARGET), "exec")
            return raw
        except Exception as exc:
            print("Download failed:", kind, type(exc).__name__, flush=True)
    raise RuntimeError("No verified source available")

def replace(raw):
    fd, name = tempfile.mkstemp(dir=TARGET.parent)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(raw)
        os.chmod(name, 0o644)
        os.replace(name, TARGET)
    finally:
        Path(name).unlink(missing_ok=True)

def verify(key):
    for _ in range(12):
        try:
            status = [code(BASE + "/health"), code(BASE + "/v1/trade/snapshot"),
                      code(BASE + "/v1/trade/snapshot", key)]
            print("market/unauthenticated/authorized:", *status, flush=True)
            if status == [200, 403, 401]:
                return
        except OSError:
            pass
        time.sleep(1)
    raise RuntimeError("Service health check failed")

def main():
    if os.geteuid() != 0:
        raise RuntimeError("root required")
    old = TARGET.read_bytes()
    if blob(old) == BLOB:
        print("Already upgraded; no restart")
        return
    if blob(old) not in ("7d114adafc48c9c6268f214628105dd0395b84b8",):
        raise RuntimeError("Unexpected existing gateway version; no changes made")
    key = ENV.read_text().strip().split("=", 1)[1]
    subprocess.run(["systemctl", "is-active", "--quiet", SERVICE], check=True)
    if code(BASE + "/health") != 200:
        raise RuntimeError("Market service not healthy")
    raw = download()
    backup = TARGET.with_name(TARGET.name + ".bak." + str(time.time_ns()))
    backup.write_bytes(old)
    try:
        replace(raw)
        subprocess.run(["systemctl", "restart", SERVICE], check=True)
        verify(key)
        print("TRADE_UPGRADE_OK: simulation only; sign in again")
    except BaseException:
        replace(old)
        subprocess.run(["systemctl", "restart", SERVICE], check=True)
        verify(key)
        print("TRADE_UPGRADE_ROLLED_BACK")
        raise

if __name__ == "__main__":
    main()
