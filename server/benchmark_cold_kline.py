"""Benchmark alumina (SHFE.ao) without deleting or faking any VPS cache.

Measures Qihui's gateway on the real quoted alumina contract if possible,
then a separate TqSdk session. A missing disk file is not proof that the
gateway has no in-memory data; print that uncertainty explicitly.

Run: cd /root/tq_test && .venv/bin/python -u server/benchmark_cold_kline.py
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
PRODUCT = "SHFE.ao"
CONTINUOUS = "KQ.m@SHFE.ao"


def request(path, timeout=30):
    started = time.monotonic()
    with urlopen(BASE + path, timeout=timeout) as response:
        status = response.status
        data = json.load(response)
    return status, data, time.monotonic() - started


def choose_symbol():
    """Use the actual alumina main delivery month; never invent a contract."""
    try:
        status, data, elapsed = request(
            "/v1/product-quotes?product=SHFE.ao", timeout=35)
        item = data.get(PRODUCT, {}) if isinstance(data, dict) else {}
        code = item.get("code", "")
        if status == 200 and code.startswith("SHFE.ao") and code[len(PRODUCT):].isdigit():
            print("获取氧化铝主力月份耗时:", f"{elapsed:.3f}秒",
                  "合约:", code, flush=True)
            return code
        print("主力月份尚不可用；改用上期所氧化铝主连 SHFE.ao", flush=True)
    except Exception as exc:
        print("主力月份解析不可用:", type(exc).__name__,
              str(exc)[:130], "改用主连", flush=True)
    return PRODUCT


def cache_path(symbol):
    key = CONTINUOUS if symbol == PRODUCT else symbol
    return CACHEDIR / (key.replace("@", "_") + f"_{PERIOD}.json")


def cache_count(path):
    try:
        return len(json.loads(path.read_text(encoding="utf-8"))["bars"])
    except (FileNotFoundError, OSError, ValueError, KeyError, TypeError):
        return 0


def benchmark_gateway(symbol):
    print("\n=== 氧化铝：期汇网关首次/重复请求 ===", flush=True)
    path = cache_path(symbol)
    prior = cache_count(path)
    print("品种:", symbol, "周期:15分钟",
          "请求前磁盘缓存:", prior, "根", flush=True)
    print("说明：磁盘为0根也不能排除内存已有预热数据。", flush=True)
    endpoint = "/v1/klines?" + urlencode(
        {"symbol": symbol, "period": PERIOD, "count": 500})
    for name in ("首次请求", "重复请求"):
        try:
            status, data, elapsed = request(endpoint, timeout=30)
            bars = data.get("bars", []) if isinstance(data, dict) else []
            print(name, "HTTP", status,
                  "耗时:", f"{elapsed:.3f}秒",
                  "返回:", len(bars), "根",
                  "磁盘已有:", cache_count(path), "根", flush=True)
            if status != 200:
                print("网关错误:", data.get("error", "unknown"), flush=True)
                break
        except Exception as exc:
            print(name, "失败:", type(exc).__name__,
                  str(exc)[:180], flush=True)
            break


def benchmark_sdk(symbol):
    print("\n=== 氧化铝：独立TqSdk会话取500根 ===", flush=True)
    print("这项是独立SDK会话耗时，不等同于网络层完全冷启动。", flush=True)
    from tqsdk import TqApi, TqAuth

    auth = json.loads((ROOT / "auth.json").read_text(encoding="utf-8"))
    market_symbol = CONTINUOUS if symbol == PRODUCT else symbol
    started = time.monotonic()
    api = None
    try:
        api = TqApi(auth=TqAuth(auth["username"], auth["password"]))
        serial = api.get_kline_serial(market_symbol, PERIOD, data_length=500)
        deadline = time.monotonic() + 30
        first = None
        count = 0
        while time.monotonic() < deadline:
            api.wait_update(deadline=time.time() + 1)
            frame = serial.dropna(subset=["open", "high", "low", "close"])
            count = len(frame)
            if count and first is None:
                first = time.monotonic() - started
            if count >= 498:
                break
        print("TqSdk品种:", market_symbol,
              "首次有数据:", f"{first:.3f}秒" if first is not None else "无数据",
              "有效K线:", count, "根",
              "耗时:", f"{time.monotonic()-started:.3f}秒",
              flush=True)
    except Exception as exc:
        print("TqSdk测试失败:", type(exc).__name__, str(exc)[:220], flush=True)
    finally:
        if api is not None:
            api.close()


if __name__ == "__main__":
    selected = choose_symbol()
    benchmark_gateway(selected)
    benchmark_sdk(selected)
