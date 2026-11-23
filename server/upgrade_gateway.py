"""Upgrade the existing standalone Futures gateway from its installation directory."""
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
from urllib.parse import urlencode
from urllib.request import urlopen

ROOT = Path("/root/tq_test")
SCRIPT = ROOT / "server/market_gateway.py"
VERSION = "13291b3f6010fb002e8ba2aabd91035776e6ed36"
DIGEST = "f63906f67eeefb0d568bc5722c6c6e0e9422ca9813b064e33233023091c67452"


def existing():
    matches = []
    for proc in Path("/proc").glob("[0-9]*"):
        try:
            if (proc / "cwd").resolve() != ROOT:
                continue
            args = (proc / "cmdline").read_bytes().split(b"\0")[:-1]
            if len(args) == 3 and args[1] == b"-u" and (ROOT / os.fsdecode(args[2])).resolve() == SCRIPT and (ROOT / os.fsdecode(args[0])).resolve() == (ROOT / ".venv/bin/python").resolve():
                matches.append(proc)
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
    if len(matches) != 1:
        raise RuntimeError(f"找到 {len(matches)} 个匹配的网关进程，请核对启动方式")
    return matches[0]


def start(env):
    with (ROOT / "gateway.log").open("ab") as log:
        return subprocess.Popen([".venv/bin/python", "-u", "server/market_gateway.py"],
                                cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
                                stdout=log, stderr=log, start_new_session=True)


def get(base, path):
    with urlopen(base + path, timeout=45) as response:
        return json.load(response)


def ready(process, base):
    for _ in range(40):
        if process.poll() is not None:
            raise RuntimeError("网关启动失败")
        try:
            if get(base, "/health").get("ok") and process.poll() is None:
                return
        except OSError:
            pass
        time.sleep(0.5)
    raise RuntimeError("网关健康检查超时")


def upgrade():
    proc = existing()
    env = dict(os.fsdecode(item).split("=", 1) for item in (proc / "environ").read_bytes().split(b"\0") if item)
    base = "http://127.0.0.1:" + env.get("QIHUI_PORT", "8765")
    if not get(base, "/health").get("ok"):
        raise RuntimeError("原网关健康检查失败")
    with urlopen(f"https://raw.githubusercontent.com/huangenxu-prog/Futures/{VERSION}/server/market_gateway.py", timeout=30) as response:
        source = response.read()
    if hashlib.sha256(source).hexdigest() != DIGEST:
        raise ValueError("新版脚本校验失败")
    compile(source, str(SCRIPT), "exec")
    backup = SCRIPT.with_name("market_gateway.py.bak." + str(time.time_ns()))
    shutil.copy2(SCRIPT, backup)
    print("备份", backup, flush=True)
    with tempfile.TemporaryDirectory(dir=SCRIPT.parent) as directory:
        staged = Path(directory) / SCRIPT.name
        staged.write_bytes(source)
        shutil.copymode(SCRIPT, staged)
        if existing() != proc:
            raise RuntimeError("原网关进程已变更")
        os.kill(int(proc.name), signal.SIGTERM)
        for _ in range(100):
            try:
                running = bool((proc / "cmdline").read_bytes())
            except FileNotFoundError:
                running = False
            if not running:
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("旧进程仍在退出，请检查进程状态")
        process = None
        try:
            os.replace(staged, SCRIPT)
            process = start(env)
            ready(process, base)
            q = get(base, "/v1/main-contracts")["CZCE.SR"]
            code = q["code"]
            if not q.get("month") or not q.get("time") or not all(math.isfinite(q[k]) for k in ("last", "settlement")):
                raise ValueError("白糖报价不完整")
            bars = get(base, "/v1/klines?" + urlencode(dict(symbol=code, period=900, count=5)))
            if bars.get("symbol") != code or not bars.get("bars"):
                raise ValueError("白糖具体合约K线验证失败")
            print("正式网关检查通过：白糖" + q["month"], code, q["time"], "最新价", q["last"], "15分钟K线", len(bars["bars"]), "根", flush=True)
        except Exception:
            if process and process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
            shutil.copy2(backup, staged)
            os.replace(staged, SCRIPT)
            ready(start(env), base)
            print("已恢复旧脚本，健康检查通过", flush=True)
            raise


if __name__ == "__main__":
    with (ROOT / ".gateway-upgrade.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        upgrade()
