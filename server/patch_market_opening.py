"""Add the trading-day opening quote to the deployed gateway without replacing other code."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
from urllib.request import urlopen

TARGET = Path("/root/tq_test/server/market_gateway.py")
SERVICE = "qihui-gateway"
OLD = '"last": "last_price", "settlement": "pre_settlement", "bid": "bid_price1",'
NEW = '"last": "last_price", "settlement": "pre_settlement", "opening": "open", "bid": "bid_price1",'

def health():
    with urlopen("https://8.153.96.190/health", timeout=5) as response:
        return response.status == 200

def wait_health():
    for _ in range(30):
        try:
            if health():
                return
        except OSError:
            pass
        time.sleep(1)
    raise RuntimeError("Market health check failed")

def replace(data):
    fd, name = tempfile.mkstemp(dir=TARGET.parent)
    try:
        with os.fdopen(fd, "wb") as out:
            out.write(data)
        shutil.copystat(TARGET, name)
        os.replace(name, TARGET)
    finally:
        Path(name).unlink(missing_ok=True)

def main():
    if os.geteuid() != 0:
        raise RuntimeError("root required")
    subprocess.run(["systemctl", "is-active", "--quiet", SERVICE], check=True)
    if not health():
        raise RuntimeError("Existing market service not healthy")
    raw = TARGET.read_bytes()
    if raw.count(NEW.encode()) == 1 and OLD.encode() not in raw:
        print("MARKET_OPEN_ALREADY_PRESENT")
        return
    if raw.count(OLD.encode()) != 1 or b'"opening":' in raw:
        raise RuntimeError("Unexpected market gateway source; no changes made")
    updated = raw.replace(OLD.encode(), NEW.encode(), 1)
    compile(updated, str(TARGET), "exec")
    backup = TARGET.with_name(TARGET.name + ".opening.bak." + str(time.time_ns()))
    shutil.copy2(TARGET, backup)
    try:
        replace(updated)
        subprocess.run(["systemctl", "restart", SERVICE], check=True)
        wait_health()
        print("MARKET_OPEN_PATCH_OK: market health=200; trade service untouched")
    except BaseException:
        replace(raw)
        subprocess.run(["systemctl", "restart", SERVICE], check=True)
        wait_health()
        print("MARKET_OPEN_PATCH_ROLLED_BACK")
        raise

if __name__ == "__main__":
    main()
