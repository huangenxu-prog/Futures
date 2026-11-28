"""Deploy only the reviewed market-gateway delta; invoke with an immutable repo revision."""
import ast
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
import urllib.error
import urllib.request

BASE = "5857a6b9a66740cc930f20135b701514b67f1ca6"
TARGET = Path("/root/tq_test/server/market_gateway.py")
PYTHON = "/root/tq_test/.venv/bin/python"
SERVICE = "qihui-gateway.service"
TRADE = "qihui-trade.service"


def fetch(ref, name):
    url = f"https://raw.githubusercontent.com/huangenxu-prog/Futures/{ref}/server/{name}"
    with urllib.request.urlopen(url, timeout=30) as reply:
        return reply.read()


def methods(source):
    return {(cls.name, fn.name): fn for cls in ast.parse(source).body if isinstance(cls, ast.ClassDef)
            for fn in cls.body if isinstance(fn, ast.FunctionDef)}


def segment(source, node):
    return "".join(source.splitlines(True)[node.lineno-1:node.end_lineno])


# Exact method bodies reviewed from the November 28 production diff.
# Only methods touched by this release are considered for replacement.
REVIEWED_HUB = {
    "__init__": "abd190a623a4da4959d984bf4a08e57ebf5220a1bf4dd643eb6921bdf9a12d9d",
    "_restore_locked": "16f20a3d79f232f78c052a834b2dfbda75d21578eae41a75fee59d4f4920dcf2",
    "_trim_cache_locked": "4d008931f0be2d0d503fc505b9da553dffc4a6bf0457c70c08c1f8a21e15a6c2",
    "read": "0e6d50f1f8c451a4a263ec3a42751781c0f209de69479fb5d412b2d090233e6c",
    "reserve": "cb373002050dfdde9188f16ae6ab75339af2952a9c9b7f7f7b91ae2a459fd9c2",
    "run_history": "c03cca31dadc894ac8eabf3abb9f0f7e55a7adb3876b426648fdd81b035309be",
    "snapshot": "fea45c851b57e0d09d1d36fa418d28c6d2ef9249d04948cff17559c7d9bfa726",
    "warm_symbols": "f29cb4c688de87f793d2720b41d339927c6a7a3973f0d9e0a10dbbbd606da60f",
}


def candidate(base, new, live):
    old_methods, new_methods, live_methods = map(methods, (base, new, live))
    lines = live.splitlines(True)
    edits = []
    for key, old in old_methods.items():
        before = segment(base, old)
        after = segment(new, new_methods[key])
        if before == after:
            continue
        actual = live_methods[key]
        current = segment(live, actual)
        digest = hashlib.sha256(current.encode()).hexdigest()
        reviewed = key[0] == "SharedKlineHub" and REVIEWED_HUB.get(key[1]) == digest
        if key == ("SharedKlineHub", "warm_symbols"):
            # Retain the site's warm hint for a recently synced short history.
            site_after = after.replace("if len(bars) > KLINE_DATA_LENGTH and", "if bars and")
            if reviewed or current == site_after:
                after = site_after
        if current == after:
            continue
        if current != before and not reviewed:
            raise RuntimeError(f"Unreviewed live difference in {key}; source unchanged")
        edits.append((actual.lineno-1, actual.end_lineno, after))
    for start, end, replacement in sorted(edits, reverse=True):
        lines[start:end] = [replacement]
    result = "".join(lines)
    if live == base and result != new:
        raise RuntimeError("Deployment delta is incomplete")
    return result


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


def probe_chart():
    # Read-only probes share the gateway's normal history queue and live slots.
    for symbol, period in (("DCE.a2701", 1800), ("DCE.a2701", 3600), ("DCE.c2701", 300)):
        tails = []
        for route in ("klines", "stream/klines"):
            url = f"http://127.0.0.1:8765/v1/{route}?symbol={symbol}&period={period}&count=200"
            try:
                started = time.monotonic()
                with urllib.request.urlopen(url, timeout=14) as response:
                    if route == "klines":
                        frame = json.load(response)
                    else:
                        line = next(line for line in response if line.startswith(b"data:"))
                        frame = json.loads(line[5:])
                times = [bar["time"] for bar in frame["bars"]]
                if not times or times != sorted(set(times)):
                    raise RuntimeError(f"Invalid chart frame: {symbol}, {period}, {route}")
                tails.append(times[-1])
                print("FRAME", symbol, period, route, "bars", len(times), "tail", times[-1],
                      "ms", round((time.monotonic()-started)*1000), flush=True)
            except urllib.error.HTTPError as exc:
                if exc.code in (401, 403):
                    print("Authenticated chart probe unavailable; market health verified")
                    return
                if exc.code != 503:
                    raise
                print("FRAME not ready", symbol, period, route, exc.code)
        if len(set(tails)) > 1:
            print("Different observation times; inspect QIHUI_FIRST_FRAME logs", symbol, period)


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
        staged.write_text(result)
        subprocess.run([PYTHON, "-m", "py_compile", str(staged)], check=True)
        subprocess.run([PYTHON, "-c", "from tqsdk import TqApi; assert callable(TqApi.is_serial_ready)"], check=True)
        test = work / "test_first_frame.py"
        test.write_bytes(fetch(rev, test.name))
        subprocess.run([PYTHON, str(test)], check=True,
                       env={**os.environ, "QIHUI_TEST_GATEWAY": str(staged),
                            "PYTHONPATH": str(TARGET.parent)})
        if staged.read_bytes() == original:
            print("Already installed", metrics(health()))
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
            if final["pid"] != after["pid"] or identity(TRADE) != trade:
                raise RuntimeError("Market PID unstable or trade service identity changed")
        except BaseException:
            shutil.copy2(backup, staged)
            os.replace(staged, TARGET)
            ctl("restart", SERVICE)
            print("ROLLED BACK", metrics(wait_healthy()), flush=True)
            raise
        print("DEPLOYED", rev, "AFTER", final, "TRADE", trade, flush=True)
        print(f"ROLLBACK: sudo cp -p {backup} {TARGET} && sudo systemctl restart {SERVICE} && curl -fsS http://127.0.0.1:8765/health")


if __name__ == "__main__":
    with open("/run/lock/qihui-first-frame.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        deploy(sys.argv[1])
