"""Cold K-line benchmarks: NYMEX natural gas and a genuinely uncached Qihui contract.

Run on the existing Alibaba VPS:
  cd /root/tq_test && .venv/bin/python -u server/benchmark_cold_kline.py

No credentials are printed. No cache files are deleted. This script never
changes the gateway service or the app's supported contract list.
"""
import json
import os
import time
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import urlopen

BASE = "http://127.0.0.1:8765"
ROOT = Path("/root/tq_test")
CACHEDIR = Path(os.environ.get("QIHUI_KLINE_CACHE_DIR", str(ROOT / "cache/klines")))
PERIOD = 900
NATGAS = "KQD.m@NYMEX.NG"


def request(path, timeout=18):
    started = time.monotonic()
    with urlopen(BASE + path, timeout=timeout) as response:
        status = response.status
        data = json.load(response)
    return status, data, time.monotonic() - started


def benchmark_natural_gas():
    print("\n=== 天然气：直接测 TqSdk 外盘冷加载（不是期汇网关） ===", flush=True)
    print("品种:", NATGAS, "周期:15分钟；外盘主连通常延时15分钟", flush=True)
    from tqsdk import TqApi, TqAuth
    from pathlib import Path
    auth = json.loads((ROOT / "auth.json").read_text(encoding="utf-8"))
    started = time.monotonic()
    api = None
    try:
        api = TqApi(auth=TqAuth(auth["username"], auth["password"]))
        serial = api.get_kline_serial(NATGAS, PERIOD, data_length=500)
        deadline = time.monotonic() + 30
        count = 0
        first = None
        while time.monotonic() < deadline:
            api.wait_update(deadline=time.time() + 1)
            try:
                valid = serial.dropna(subset=["open", "high", "low", "close"])
                count = len(valid)
            except (TypeError, ValueError, AttributeError):
                count = 0
            if count and first is None:
                first = time.monotonic() - started
            if count >= 480:
                break
        print("初次有数据耗时:", f"{first:.3f}秒" if first is not None else "无数据",
              "返回完整有效根数:", count,
              "累计用时:", f"{time.monotonic()-started:.3f}秒", flush=True)
        if not count:
            print("未获得天然气K线；请检查外盘行情权限、交易所数据可用性或SDK日志。", flush=True)
    except Exception as e:
        print("天然气测试不可用:", type(e).__name__, str(e)[:220], flush=True)
    finally:
        if api is not None:
            api.close()


def benchmark_real_gateway_cold():
    print("\n=== 期汇网关：自动选取真正未缓存的国内主力合约 ===", flush=True)
    try:
        _, quotes, elapsed = request("/v1/main-contracts", timeout=18)
        print("获取主力合约表耗时:", f"{elapsed:.3f}秒", flush=True)
        candidates = []
        for product, row in quotes.items():
            code = row.get("code", "") if isinstance(row, dict) else ""
            if (not code or product == "CZCE.SR"
                    or not code.replace(".", "").isalnum()):
                continue
            cachefile = CACHEDIR / (code.replace("@", "_") + "_900.json")
            if not cachefile.exists():
                candidates.append(code)
        if not candidates:
            print("主力合约全部已有磁盘缓存；不再冒充冷启动测试。", flush=True)
            return
        symbol = sorted(candidates)[0]
        cachefile = CACHEDIR / (symbol.replace("@", "_") + "_900.json")
        print("选择未缓存合约:", symbol, "首次请求前文件存在:", cachefile.exists(), flush=True)
        endpoint = "/v1/klines?" + urlencode({"symbol": symbol, "period": PERIOD, "count": 500})
        for name in ("首次请求", "重复请求"):
            try:
                status, data, seconds = request(endpoint, timeout=25)
                bars = data.get("bars", [])
                print(name, "HTTP", status, "耗时:", f"{seconds:.3f}秒",
                      "返回根数:", len(bars), "磁盘文件存在:", cachefile.exists(), flush=True)
            except Exception as e:
                print(name, "失败:", type(e).__name__, str(e)[:200], flush=True)
                break
    except Exception as e:
        print("网关冷加载测试失败:", type(e).__name__, str(e)[:220], flush=True)


if __name__ == "__main__":
    benchmark_natural_gas()
    benchmark_real_gateway_cold()
