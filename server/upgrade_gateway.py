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
VERSION = "ae2dfcc49d1d06ed079410cca36869bc2644c439"
GIT_BLOB_SHA = "d91b39b03a2c125b1ca116319b8301e2fbb775fd"


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


def first_stream_event(base, path):
    with urlopen(base + path, timeout=35) as response:
        if not response.headers.get("Content-Type", "").startswith("text/event-stream"):
            raise ValueError("实时推送接口不是 SSE")
        for _ in range(120):
            line = response.readline()
            if not line:
                break
            if line.startswith(b"data: "):
                return json.loads(line[6:])
    raise RuntimeError("实时推送未返回行情")


def upgrade():
    proc = existing()
    env = dict(os.fsdecode(item).split("=", 1) for item in (proc / "environ").read_bytes().split(b"\0") if item)
    base = "http://127.0.0.1:" + env.get("QIHUI_PORT", "8765")
    if not get(base, "/health").get("ok"):
        raise RuntimeError("原网关健康检查失败")
    with urlopen(f"https://raw.githubusercontent.com/huangenxu-prog/Futures/{VERSION}/server/market_gateway.py", timeout=30) as response:
        source = response.read()
    blob_hash = hashlib.sha1(b"blob " + str(len(source)).encode() + b"\0" + source).hexdigest()
    if blob_hash != GIT_BLOB_SHA:
        raise ValueError("新版脚本 Git 内容校验失败")
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
            kline_path = "/v1/klines?" + urlencode(dict(symbol=code, period=900, count=5))
            # First request may need TqSdk backfill. The second must reuse
            # the persistent subscription and not recreate a market API.
            bars = get(base, kline_path)
            if bars.get("symbol") != code or not bars.get("bars"):
                raise ValueError("白糖具体合约K线验证失败")
            started = time.monotonic()
            repeated = get(base, kline_path)
            cached_seconds = time.monotonic() - started
            if repeated.get("symbol") != code or not repeated.get("bars"):
                raise ValueError("K线缓存复用校验失败")
            cache_status = get(base, "/health").get("kline_cache", {})
            if cache_status.get("ready", 0) < 1:
                raise ValueError("K线后台缓存尚未就绪")
            if cache_status.get("tracked", 0) < 1:
                raise ValueError("没有激活实时K线订阅")
            if (cache_status.get("data_length") != 2
                    or cache_status.get("history_length") != 200
                    or not cache_status.get("disk_enabled")):
                raise ValueError("2根实时K线/200根历史文件缓存未启用")
            if cached_seconds > 2.0:
                raise ValueError(f"K线缓存响应过慢：{cached_seconds:.2f}秒")
            print(f"白糖K线缓存复用耗时: {cached_seconds:.3f}秒，"
                  f"实时订阅 {cache_status['data_length']} 根，"
                  f"历史回补 {cache_status['history_length']} 根，"
                  f"后台待补 {cache_status.get('pending_history', 0)} 组", flush=True)
            # An initial live 2-bar frame is not enough for MA120. Wait for
            # genuine 200-bar TqSdk history to arrive and persist on disk.
            deadline = time.monotonic() + 40
            while time.monotonic() < deadline:
                hydrated = get(base, kline_path.replace("count=5", "count=200"))
                if len(hydrated.get("bars", [])) >= 120:
                    break
                time.sleep(0.75)
            else:
                raise ValueError("历史回补没有生成至少120根真实K线")
            folder = Path(env.get("QIHUI_KLINE_CACHE_DIR", "/root/tq_test/cache/klines"))
            cached_file = folder / (code.replace("@", "_") + "_900.json")
            if not cached_file.is_file():
                raise ValueError("历史K线没有写入VPS本地文件")
            saved = json.loads(cached_file.read_text(encoding="utf-8"))
            if (saved.get("symbol") != code or saved.get("period") != 900
                    or len(saved.get("bars", [])) < 120):
                raise ValueError("VPS历史文件内容不完整")
            print("VPS历史缓存验证通过，白糖15分钟", len(saved["bars"]), "根", flush=True)
            catalog = get(base, "/v1/catalog")
            if not isinstance(catalog, list) or len(catalog) <= 17 or not any(
                    item.get("exchange") == "CFFEX" for item in catalog):
                raise ValueError("动态全市场合约目录不完整")
            latest = get(base, "/v1/product-quotes?product=CZCE.SR")
            if not isinstance(latest, dict):
                raise ValueError("按需主力报价接口不可用")
            monthly = get(base, "/v1/contracts?" + urlencode(dict(product="CZCE.SR")))
            if not isinstance(monthly, list) or not any(item.get("code") == code for item in monthly):
                raise ValueError("白糖挂牌月份查询失败")
            quote_update = first_stream_event(base, "/v1/stream/quotes")
            if quote_update.get("CZCE.SR", {}).get("code") != code:
                raise ValueError("实时行情推送缺少白糖主力")
            candle_update = first_stream_event(base, "/v1/stream/klines?" + urlencode(dict(symbol=code, period=900, count=5)))
            if candle_update.get("symbol") != code or not candle_update.get("bars"):
                raise ValueError("K线实时推送未返回初始K线")
            oldest = min(item["time"] for item in candle_update["bars"])
            older = get(base, "/v1/history?" + urlencode(dict(
                symbol=code, period=900, before=oldest, count=5, depth=600
            )))
            if older.get("symbol") != code or not isinstance(older.get("bars"), list):
                raise ValueError("K线历史分页接口不可用")
            print("实时推送检查通过；全市场目录", len(catalog), "个品种；按需报价和挂牌月份检查通过", flush=True)
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
