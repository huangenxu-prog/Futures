"""Read-only OHLC comparison of TqSdk and local gateway; never prints credentials.

Run on the Futures VPS, for example:
  cd /root/tq_test && .venv/bin/python server/diagnose_kline.py CZCE.SR701 900
"""
import json
import math
import os
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import urlopen

from tqsdk import TqApi, TqAuth

PERIODS = {60, 300, 900, 1800, 3600, 86400}
CST = timezone(timedelta(hours=8))


def rows(serial):
    result = []
    for row in serial.itertuples(index=False):
        try:
            item = {
                "time": int(row.datetime) // 1_000_000_000,
                "open": float(row.open), "high": float(row.high),
                "low": float(row.low), "close": float(row.close),
                "volume": int(row.volume) if math.isfinite(float(row.volume)) else 0,
            }
            if item["time"] > 0 and all(math.isfinite(item[k])
                    for k in ("open", "high", "low", "close")):
                result.append(item)
        except (TypeError, ValueError, OverflowError):
            continue
    return result


def show(symbol, period, source, data):
    print(f"\n{source}  {symbol}  {period}秒", flush=True)
    for bar in data[-12:]:
        label = datetime.fromtimestamp(bar["time"], tz=CST).strftime("%m-%d %H:%M")
        direction = "阳" if bar["close"] > bar["open"] else (
            "阴" if bar["close"] < bar["open"] else "平")
        print(f"  {label}  O={bar['open']:.2f} H={bar['high']:.2f} "
              f"L={bar['low']:.2f} C={bar['close']:.2f} {direction}  V={bar['volume']}")


def differences(left, right, left_name, right_name):
    by_time = {bar["time"]: bar for bar in left}
    mismatches = []
    for current in right[-12:]:
        previous = by_time.get(current["time"])
        if previous is None:
            continue
        fields = [field for field in ("open", "high", "low", "close", "volume")
                  if previous[field] != current[field]]
        if fields:
            stamp = datetime.fromtimestamp(current["time"], tz=CST).strftime("%m-%d %H:%M")
            mismatches.append((stamp, fields))
    print(f"{left_name} vs {right_name}: "
          + (str(mismatches) if mismatches else "相同时间戳的OHLCV无差异"))


def main():
    symbol = sys.argv[1] if len(sys.argv) > 1 else "CZCE.SR701"
    period = int(sys.argv[2]) if len(sys.argv) > 2 else 900
    if not symbol.replace(".", "").isalnum() or period not in PERIODS:
        raise ValueError("invalid symbol / period")
    auth_path = os.environ.get("TQ_AUTH_FILE", "/root/tq_test/auth.json")
    with open(auth_path, encoding="utf-8") as stream:
        auth = json.load(stream)
    api = None
    try:
        api = TqApi(auth=TqAuth(auth["username"], auth["password"]))
        history = api.get_kline_serial(symbol, period, data_length=200)
        latest = api.get_kline_serial(symbol, period, data_length=2)
        deadline = time.monotonic() + 25
        full = []
        two = []
        while time.monotonic() < deadline:
            api.wait_update(deadline=time.time() + 0.7)
            full, two = rows(history), rows(latest)
            if len(full) >= 12 and len(two) == 2:
                break
        show(symbol, period, "天勤原始200根，最后12根", full)
        show(symbol, period, "天勤原始2根", two)
        if full and two:
            differences(full, two, "天勤200", "天勤2")
    finally:
        if api is not None:
            api.close()

    endpoint = ("http://127.0.0.1:"
                + os.environ.get("QIHUI_PORT", "8765")
                + "/v1/klines?" + urlencode({
                    "symbol": symbol, "period": period, "count": 200
                }))
    with urlopen(endpoint, timeout=20) as response:
        cached = json.load(response)["bars"]
    show(symbol, period, "VPS接口缓存", cached)
    if full:
        differences(full, cached, "天勤原始200", "VPS接口缓存")

    cache_file = Path(os.environ.get("QIHUI_KLINE_CACHE_DIR",
                   "/root/tq_test/cache/klines")) / (
                       symbol.replace("@", "_") + "_" + str(period) + ".json")
    if cache_file.is_file():
        with cache_file.open(encoding="utf-8") as handle:
            persisted = json.load(handle)["bars"]
        show(symbol, period, "VPS磁盘缓存", persisted)
        if full:
            differences(full, persisted, "天勤原始200", "VPS磁盘缓存")
    else:
        print("VPS磁盘缓存尚未创建。")


if __name__ == "__main__":
    main()
