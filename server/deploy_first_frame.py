"""Deploy only the reviewed market-gateway delta; invoke with an immutable repo revision."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

BASE = "f18bdfe2faf27c4403036984167d338e7bb48896"
PRODUCTION_SHA256 = "7d60314b3c7d9864e766cdffea4b0274b452160fb80726bdc6598340a4d335ba"
TARGET = Path("/root/tq_test/server/market_gateway.py")
PYTHON = "/root/tq_test/.venv/bin/python"
SERVICE = "qihui-gateway.service"
TRADE = "qihui-trade.service"


def fetch(ref, name):
    url = f"https://raw.githubusercontent.com/huangenxu-prog/Futures/{ref}/server/{name}"
    with urllib.request.urlopen(url, timeout=30) as reply:
        return reply.read()


def candidate(base, new, live):
    if hashlib.sha256(base.encode()).hexdigest() != PRODUCTION_SHA256:
        raise RuntimeError("Reference production source hash mismatch")
    if live != base and live != new:
        raise RuntimeError("Unreviewed production source drift; source unchanged")
    # Whole-file parity also includes constants, module functions and new methods.
    return new


def ctl(*args):
    return subprocess.check_output(["systemctl", *args], text=True).strip()


def identity(unit):
    return ctl("show", unit, "-p", "ActiveState", "-p", "MainPID", "-p", "InvocationID")


def health():
    with urllib.request.urlopen("http://127.0.0.1:8765/health", timeout=2) as r:
        data = json.load(r)
    if data.get("ok") is not True or ctl("is-active", SERVICE) != "active":
        raise RuntimeError("Market gateway unhealthy")
    return data


def wait_healthy():
    for attempt in range(20):
        try:
            return health()
        except Exception:
            if attempt == 19:
                raise
            time.sleep(1)


def metrics(data):
    pid = ctl("show", SERVICE, "-p", "MainPID", "--value")
    connections = None
    if shutil.which("ss"):
        output = subprocess.check_output(["ss", "-Htnp", "state", "established"], text=True)
        connections = sum(f"pid={pid}," in row for row in output.splitlines())
    return dict(pid=pid, established_tcp=connections, memory_kib=data.get("process_memory_kib"))


def reference_tails(requests):
    """Read exact exchange candles independently, using one temporary SDK session."""
    from tqsdk import TqApi, TqAuth
    auth_path = os.environ.get("TQ_AUTH_FILE", "/root/tq_test/auth.json")
    with open(auth_path, encoding="utf-8") as handle:
        credentials = json.load(handle)
    api = TqApi(auth=TqAuth(credentials["username"], credentials["password"]))
    try:
        result = {}
        for symbol, period in requests:
            serial = api.get_kline_serial(symbol, period, data_length=3)
            deadline = time.monotonic() + 15
            while not api.is_serial_ready(serial):
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise RuntimeError(f"Independent history not ready: {symbol} {period}")
                api.wait_update(deadline=time.time() + min(1, remaining))
            times = [int(t) // 1_000_000_000 for t in serial["datetime"] if t > 0]
            if not times:
                raise RuntimeError(f"Independent history empty: {symbol} {period}")
            result[(symbol, period)] = max(times)
        return result
    finally:
        api.close()


def probe_chart():
    paths = ("klines", "stream/klines")
    access = os.environ.get("QIHUI_MARKET_ACCESS_KEY")
    headers = {"X-Qihui-Market-Access": access} if access else {}
    requests = (("DCE.a2701", 1800), ("DCE.a2701", 3600), ("DCE.c2701", 300))
    expected = reference_tails(requests)
    for symbol, period in requests:
        for attempt in (1, 2):
            reference = None
            for route in paths if attempt == 1 else reversed(paths):
                url = f"http://127.0.0.1:8765/v1/{route}?symbol={symbol}&period={period}&count=200"
                request = urllib.request.Request(url, headers=headers)
                started = time.monotonic()
                with urllib.request.urlopen(request, timeout=14) as response:
                    if route == "klines":
                        frame = json.load(response)
                    else:
                        line = next(line for line in response if line.startswith(b"data:"))
                        frame = json.loads(line[5:])
                times = [bar["time"] for bar in frame["bars"]]
                if (len(times) != 200 or times != sorted(set(times))
                        or frame.get("syncing") is not False):
                    raise RuntimeError(f"Incomplete business frame: {symbol} {period} {route}")
                print("FRAME", symbol, period, route, "attempt", attempt, "bars", len(times),
                      "tail", times[-1], "ms", round((time.monotonic()-started)*1000), flush=True)
                if reference is not None and times != reference:
                    raise RuntimeError(f"HTTP/SSE timestamps disagree: {symbol} {period}")
                if times[-1] != expected[(symbol, period)]:
                    raise RuntimeError(f"Independent exchange tail mismatch: {symbol} {period}")
                reference = times
    if reference_tails(requests) != expected:
        raise RuntimeError("Exchange tail advanced during probe; retry in a stable window")


def deploy(rev):
    if not re.fullmatch("[0-9a-f]{40}", rev):
        raise ValueError("Expected a full Git commit SHA")
    with tempfile.TemporaryDirectory(dir=TARGET.parent, prefix=".first-frame-") as tmp:
        work = Path(tmp)
        original = TARGET.read_bytes()
        base = fetch(BASE, "market_gateway.py").decode()
        updated = fetch(rev, "market_gateway.py").decode()
        result = candidate(base, updated, original.decode())
        staged = work / TARGET.name
        shutil.copy2(TARGET, staged)
        staged.write_bytes(result.encode("utf-8"))
        if staged.read_bytes() != updated.encode("utf-8"):
            raise RuntimeError("Staged source does not match immutable repository revision")
        subprocess.run([PYTHON, "-m", "py_compile", str(staged)], check=True)
        subprocess.run([PYTHON, "-c", "from tqsdk import TqApi; assert callable(TqApi.is_serial_ready)"], check=True)
        for name in ("test_first_frame.py", "test_final_first_frame.py", "deploy_first_frame.py"):
            (work / name).write_bytes(fetch(rev, name))
        subprocess.run([PYTHON, "-m", "unittest", "test_first_frame", "test_final_first_frame"],
                       cwd=work, check=True, env={**os.environ, "QIHUI_TEST_GATEWAY": str(staged),
                                                  "PYTHONPATH": str(TARGET.parent)})
        if staged.read_bytes() == original:
            probe_chart()
            print("Already installed; business probes passed", metrics(health()))
            return
        before = metrics(health())
        trade = identity(TRADE)
        if TARGET.read_bytes() != original:
            raise RuntimeError("Live source changed during staging")
        backup = TARGET.with_name(TARGET.name + ".bak-before-frame-" + hashlib.sha256(original).hexdigest()[:16])
        if not backup.exists():
            shutil.copy2(TARGET, backup)
        if backup.read_bytes() != original:
            raise RuntimeError("Backup verification failed")
        print("BACKUP", backup, "BEFORE", before, flush=True)
        try:
            os.replace(staged, TARGET)
            ctl("restart", SERVICE)
            after = metrics(wait_healthy())
            probe_chart()
            time.sleep(2)
            final = metrics(health())
            if TARGET.read_bytes() != updated.encode():
                raise RuntimeError("Running deployment source changed during verification")
            if final["pid"] != after["pid"] or identity(TRADE) != trade:
                raise RuntimeError("Market PID unstable or trade service identity changed")
        except BaseException:
            shutil.copy2(backup, staged)
            os.replace(staged, TARGET)
            ctl("restart", SERVICE)
            print("ROLLED BACK", metrics(wait_healthy()), flush=True)
            raise
        print("DEPLOYED", rev, "sha256", hashlib.sha256(TARGET.read_bytes()).hexdigest(), "AFTER", final, "TRADE", trade, flush=True)
        print(f"ROLLBACK: sudo cp -p {backup} {TARGET} && sudo systemctl restart {SERVICE} && curl -fsS http://127.0.0.1:8765/health")


if __name__ == "__main__":
    with open("/run/lock/qihui-first-frame.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        deploy(sys.argv[1])
