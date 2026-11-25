"""Apply the tested resource-control delta to the installed systemd gateway.

Never replace unrelated local changes. Stage both patches before changing
either installed file; retain backups and roll back on failed local health.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
from urllib.request import urlopen

ROOT = Path("/root/tq_test/server")
MARKET = "qihui-gateway.service"
TRADE = "qihui-trade.service"
TIMER = "qihui-main-history-prefetch.timer"
PREFETCH = "qihui-main-history-prefetch.service"
FILES = {
    "market_gateway.py": (
        "c7df76a389b8b8e58ce9e344a3b0cbc681866c73",
        "73644b621ca5bd8c3e1b998656e7b9b7870f5150",
        "01eeb731652975a336c79f0602a8f698237ca201"),
    "prefetch_main_history.py": (
        "5e97f36ff0afb395dfd1afa529c3667d24f917ab",
        "2b68a2a1d6f01bde3eae12ea2b836f036e8a8f0a",
        "92fbfdfd69f56d685b25e2e7633154a269463c4e"),
}


def systemctl(*args):
    return subprocess.run(["systemctl", *args], check=True, timeout=120,
                          stdout=subprocess.PIPE, text=True).stdout.strip()


def state(unit):
    return systemctl("show", unit, "-p", "ActiveState", "--value")


PATCHES = {"market_gateway.py":"--- a/market_gateway.py\n+++ b/market_gateway.py\n@@ -7,7 +7,8 @@\n import tempfile\n import threading\n import time\n-from collections import deque\n+from collections import deque, OrderedDict\n+from functools import wraps\n from pathlib import Path\n from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer\n from urllib.parse import parse_qs, urlsplit\n@@ -34,6 +35,46 @@\n LOCK = threading.Lock()\n \n \n+# Short-lived SDK sessions share one admission gate. Persistent quote and\n+# chart workers stay independent. Reentrant for catalog validation.\n+SHORT_QUERY_GATE = threading.RLock()\n+SHORT_QUERY_CACHE = OrderedDict()\n+SHORT_QUERY_TTL = 6.0\n+SHORT_QUERY_MAX_KEYS = 64\n+\n+\n+def short_query(function):\n+    @wraps(function)\n+    def wrapped(*args, **kwargs):\n+        if not SHORT_QUERY_GATE.acquire(timeout=3):\n+            raise RuntimeError(\"market_query_busy\")\n+        try:\n+            return function(*args, **kwargs)\n+        finally:\n+            SHORT_QUERY_GATE.release()\n+    return wrapped\n+\n+\n+def cached_short_query(function):\n+    @wraps(function)\n+    @short_query\n+    def wrapped(symbol):\n+        key = (function.__name__, symbol)\n+        now = time.monotonic()\n+        cached = SHORT_QUERY_CACHE.get(key)\n+        if cached is not None and now < cached[0]:\n+            SHORT_QUERY_CACHE.move_to_end(key)\n+            return cached[1]\n+        result = function(symbol)\n+        if result:\n+            SHORT_QUERY_CACHE[key] = (time.monotonic() + SHORT_QUERY_TTL, result)\n+            SHORT_QUERY_CACHE.move_to_end(key)\n+            while len(SHORT_QUERY_CACHE) > SHORT_QUERY_MAX_KEYS:\n+                SHORT_QUERY_CACHE.popitem(last=False)\n+        return result\n+    return wrapped\n+\n+\n contract_cache = {}\n contract_cache_until = 0.0\n \n@@ -43,6 +84,7 @@\n     return match.group(1) if match else None\n \n \n+@short_query\n def product_catalog():\n     \"\"\"Discover listed futures from TqSdk's authoritative contract directory.\"\"\"\n     global CATALOG_CACHE, CATALOG_UNTIL\n@@ -128,6 +170,7 @@\n     return symbol in SYMBOLS or supported_product(contract_product(symbol))\n \n \n+@short_query\n def selected_quotes(products):\n     \"\"\"A bounded pull of main futures contracts, never subscribes the whole catalog.\"\"\"\n     requested = sorted(set(products))\n@@ -170,6 +213,14 @@\n                 result[product] = dict(fields, code=code,\n                                        month=f\"{int(year) % 100:02d}{int(month):02d}\")\n             if result:\n+                for expired in list(QUOTE_BATCH_UNTIL):\n+                    if QUOTE_BATCH_UNTIL[expired] <= time.monotonic():\n+                        QUOTE_BATCH_UNTIL.pop(expired, None)\n+                        QUOTE_BATCH_CACHE.pop(expired, None)\n+                if key not in QUOTE_BATCH_CACHE and len(QUOTE_BATCH_CACHE) >= 64:\n+                    oldest = min(QUOTE_BATCH_UNTIL, key=QUOTE_BATCH_UNTIL.get)\n+                    QUOTE_BATCH_UNTIL.pop(oldest, None)\n+                    QUOTE_BATCH_CACHE.pop(oldest, None)\n                 QUOTE_BATCH_CACHE[key] = result\n                 QUOTE_BATCH_UNTIL[key] = time.monotonic() + 8\n             return result\n@@ -195,6 +246,7 @@\n     return values\n \n \n+@short_query\n def main_contracts():\n     global contract_cache, contract_cache_until\n     if time.monotonic() < contract_cache_until:\n@@ -222,6 +274,7 @@\n         api.close()\n \n \n+@cached_short_query\n def option_chain(underlying):\n     with open(AUTH_PATH, encoding=\"utf-8\") as handle:\n         credentials = json.load(handle)\n@@ -247,6 +300,7 @@\n         api.close()\n \n \n+@cached_short_query\n def listed_contracts(product):\n     \"\"\"Query genuine unexpired delivery months, with quotes if available.\"\"\"\n     if not supported_product(product):\n@@ -285,6 +339,7 @@\n         api.close()\n \n \n+@short_query\n def load_bars(symbol, period, count):\n     with open(AUTH_PATH, encoding=\"utf-8\") as handle:\n         credentials = json.load(handle)\n@@ -1109,12 +1164,15 @@\n \n     def reply(self, status, payload):\n         data = json.dumps(payload, ensure_ascii=False, allow_nan=False).encode(\"utf-8\")\n-        self.send_response(status)\n-        self.send_header(\"Content-Type\", \"application/json; charset=utf-8\")\n-        self.send_header(\"Cache-Control\", \"no-store\")\n-        self.send_header(\"Content-Length\", str(len(data)))\n-        self.end_headers()\n-        self.wfile.write(data)\n+        try:\n+            self.send_response(status)\n+            self.send_header(\"Content-Type\", \"application/json; charset=utf-8\")\n+            self.send_header(\"Cache-Control\", \"no-store\")\n+            self.send_header(\"Content-Length\", str(len(data)))\n+            self.end_headers()\n+            self.wfile.write(data)\n+        except (BrokenPipeError, ConnectionResetError):\n+            self.close_connection = True\n \n     def do_GET(self):\n         url = urlsplit(self.path)\n@@ -1185,8 +1243,7 @@\n             return\n         if url.path == \"/v1/main-contracts\":\n             try:\n-                with LOCK:\n-                    contracts = LIVE_QUOTES.current() or main_contracts()\n+                contracts = LIVE_QUOTES.current() or main_contracts()\n                 self.reply(200, contracts)\n             except Exception:\n                 self.reply(503, {\"error\": \"market_data_unavailable\"})\n@@ -1197,8 +1254,7 @@\n                 self.reply(400, {\"error\": \"invalid_product\"})\n                 return\n             try:\n-                with LOCK:\n-                    contracts = listed_contracts(product)\n+                contracts = listed_contracts(product)\n                 self.reply(200, contracts)\n             except Exception as exc:\n                 print(\"挂牌合约查询失败:\", type(exc).__name__, str(exc)[:140], flush=True)\n@@ -1210,8 +1266,7 @@\n                 self.reply(400, {\"error\": \"invalid_underlying\"})\n                 return\n             try:\n-                with LOCK:\n-                    chain = option_chain(code)\n+                chain = option_chain(code)\n                 self.reply(200, chain)\n             except Exception:\n                 self.reply(503, {\"error\": \"options_unavailable\"})\n","prefetch_main_history.py":"--- a/prefetch_main_history.py\n+++ b/prefetch_main_history.py\n@@ -40,6 +40,18 @@\n MAX_SERIES_PER_RUN = 24\n MAX_RUNTIME_SECONDS = 7 * 60\n MIN_FREE_BYTES = 160 * 1024 * 1024\n+MIN_AVAILABLE_MEMORY_KIB = 300 * 1024\n+\n+\n+def memory_allows_prefetch():\n+    try:\n+        for line in Path(\"/proc/meminfo\").read_text().splitlines():\n+            if line.startswith(\"MemAvailable:\"):\n+                return int(line.split()[1]) >= MIN_AVAILABLE_MEMORY_KIB\n+    except (OSError, ValueError, IndexError):\n+        pass\n+    # Fail closed for optional background warming.\n+    return False\n VALID_CODE = re.compile(r\"(CFFEX|SHFE|DCE|CZCE|INE|GFEX)\\.[A-Za-z]+[0-9]{3,4}\\Z\")\n \n \n@@ -128,6 +140,9 @@\n \n \n def run(limit):\n+    if not memory_allows_prefetch():\n+        print(\"可用内存不足300MiB或无法检测，跳过本轮预热。\", flush=True)\n+        return\n     start = time.monotonic()\n     os.umask(0o077)\n     store = KlineFileCache(directory=KLINE_CACHE_DIR)\n@@ -162,6 +177,9 @@\n             print(\"所有主力合约的六个周期缓存均处于本轮有效期内。\", flush=True)\n             return\n         for i, key in enumerate(jobs):\n+            if not memory_allows_prefetch():\n+                print(\"可用内存不足300MiB，结束本轮预热。\", flush=True)\n+                break\n             if time.monotonic() - start >= MAX_RUNTIME_SECONDS:\n                 print(\"达到单轮运行时间预算，剩余任务留给下次。\", flush=True)\n                 break\n"}


def health():
    with urlopen("http://127.0.0.1:8765/health", timeout=3) as response:
        return response.status == 200 and json.load(response).get("ok") is True


def wait_health():
    for _ in range(30):
        try:
            if health() and state(MARKET) == "active":
                return
        except (OSError, ValueError):
            pass
        time.sleep(1)
    raise RuntimeError("Market health check failed")


def replace_from(source, target):
    fd, name = tempfile.mkstemp(prefix=".resource-", dir=target.parent)
    os.close(fd)
    try:
        shutil.copy2(source, name)
        os.replace(name, target)
    finally:
        Path(name).unlink(missing_ok=True)


def stage(directory, name, hashes):
    local_hash, old_blob, new_blob = hashes
    target = ROOT / name
    raw = target.read_bytes()
    if hashlib.sha1(raw).hexdigest() != local_hash:
        raise RuntimeError("Installed file changed since inspection: " + name)
    delta = directory / (name + ".diff")
    candidate = directory / name
    delta.write_text(PATCHES[name], encoding="utf-8")
    subprocess.run(["patch", "--batch", "--forward", "--fuzz=0",
                    "--no-backup-if-mismatch", "--reject-file", str(directory / (name + ".rej")), "-o", str(candidate),
                    str(target), str(delta)], check=True, timeout=30)
    compile(candidate.read_bytes(), str(target), "exec")
    shutil.copystat(target, candidate)
    print("STAGED", name, flush=True)
    return candidate


def main():
    if os.geteuid() != 0:
        raise RuntimeError("root required")
    if state(MARKET) != "active" or state(TRADE) != "active" or not health():
        raise RuntimeError("Existing services not healthy; no changes")
    trade_pid = systemctl("show", TRADE, "-p", "MainPID", "--value")
    with tempfile.TemporaryDirectory(prefix=".resource-stage-", dir=ROOT) as tmp:
        directory = Path(tmp)
        candidates = {name: stage(directory, name, hashes) for name, hashes in FILES.items()}
        timer_active = state(TIMER) == "active"
        if timer_active:
            systemctl("stop", TIMER)
        backups = {}
        changed = []
        try:
            if state(PREFETCH) not in ("inactive", "failed"):
                raise RuntimeError("Prefetch is running; retry after it finishes. No files changed.")
            for name, hashes in FILES.items():
                if hashlib.sha1((ROOT / name).read_bytes()).hexdigest() != hashes[0]:
                    raise RuntimeError("Installed file changed during staging: " + name)
            stamp = str(time.time_ns())
            for name in FILES:
                target = ROOT / name
                backup = target.with_name(name + ".resource.bak." + stamp)
                shutil.copy2(target, backup)
                backups[name] = backup
                print("BACKUP", backup, flush=True)
            try:
                for name, candidate in candidates.items():
                    replace_from(candidate, ROOT / name)
                    changed.append(name)
                systemctl("restart", MARKET)
                wait_health()
            except BaseException:
                for name in reversed(changed):
                    replace_from(backups[name], ROOT / name)
                if "market_gateway.py" in changed:
                    systemctl("restart", MARKET)
                    wait_health()
                print("RESOURCE_PATCH_ROLLED_BACK", flush=True)
                raise
        finally:
            if timer_active:
                systemctl("start", TIMER)
        trade_now = systemctl("show", TRADE, "-p", "MainPID", "--value")
        print("TRADE_PID", trade_pid, trade_now, flush=True)
        print("RESOURCE_PATCH_OK: market health=200; trade not restarted by updater", flush=True)


if __name__ == "__main__":
    main()
