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


def normalized_restore(node):
    # Phase one may drop/zero just the cached history clock.
    import copy
    node = copy.deepcopy(node)
    for parent in ast.walk(node):
        if hasattr(parent, "body") and isinstance(parent.body, list):
            parent.body[:] = [stmt for stmt in parent.body if not (
                isinstance(stmt, ast.Assign) and len(stmt.targets) == 1
                and ast.unparse(stmt.targets[0]) == "self.last_history[key]")]
    return ast.dump(node)


def phase_one_only(name, base, current, backup):
    if not backup or ast.dump(base.args) != ast.dump(current.args):
        return False
    if name == "_restore_locked":
        return normalized_restore(base) == normalized_restore(current)
    # A recognized phase-one replacement may only read/wait/schedule. Unfamiliar
    # server optimizations or changed interfaces need a source-specific review.
    if name not in {"read", "snapshot"} or ast.dump(base) != ast.dump(backup):
        return False
    known = {n.attr for n in ast.walk(base) if isinstance(n, ast.Attribute)}
    known.update("read pending_history history_running history_completed history_retry_after last_history condition notify_all monotonic wait get cache cached_used".split())
    for n in ast.walk(current):
        if isinstance(n, ast.Attribute) and n.attr not in known:
            return False
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id not in {
            "min", "max", "float", "list", "bool", "len", "quote_symbol"}:
            return False
    return True


def candidate(base, new, live, backup, work):
    old_methods, new_methods, live_methods = map(methods, (base, new, live))
    backup_methods = methods(backup) if backup else {}
    lines = live.splitlines(True)
    edits = []
    for key, old in old_methods.items():
        new_fn = new_methods[key]
        before, after = segment(base, old), segment(new, new_fn)
        if before == after:
            continue
        actual = live_methods[key]
        current = segment(live, actual)
        if current != before and current != after:
            for filename, value in (("live", current), ("base", before), ("new", after)):
                (work / filename).write_text(value)
            merged = subprocess.run(["git", "merge-file", "-p", "live", "base", "new"],
                                    cwd=work, capture_output=True, text=True)
            if merged.returncode == 0:
                after = merged.stdout
            elif not (key[0] == "SharedKlineHub" and phase_one_only(
                    key[1], old, actual, backup_methods.get(key))):
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
        prior = TARGET.with_suffix(".py.bak-first-sync")
        base = fetch(BASE, "market_gateway.py").decode()
        updated = fetch(rev, "market_gateway.py").decode()
        result = candidate(base, updated, original.decode(), prior.read_text() if prior.exists() else "", work)
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
