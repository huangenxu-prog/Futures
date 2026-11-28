"""Persist recent history for every *current domestic main contract* on Aliyun.

Designed for a low-priority systemd timer, independent of the public gateway.
Discovers real underlying contracts with TqSdk query_cont_quotes() on each
invocation: no fixed 17-product list, synthetic symbols or account writes.

A run selects at most 24 of the oldest/missing (contract, period) snapshots.
With an every-10-minute timer, cold seeding progresses over several hours,
without allocating hundreds of concurrent K-line subscriptions.

Command: .venv/bin/python -u server/prefetch_main_history.py
Status:  .venv/bin/python server/prefetch_main_history.py --status
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
import time

from tqsdk import TqApi, TqAuth
from market_gateway import (
    AUTH_PATH, EXCHANGES, KLINE_CACHE_DIR, KLINE_HISTORY_LENGTH,
    KLINE_PERIOD_ORDER, KlineFileCache, bars_from_serial, contract_product,
)

ROOT = Path("/root/tq_test")
STATUS_FILE = ROOT / "cache" / "main-prefetch-status.json"
PERIOD_ORDER = {value: i for i, value in enumerate(KLINE_PERIOD_ORDER)}
# As historical series become recent, leave them alone and prioritize missing
# products. Live charts have their own real-time K-line stream.
FRESH_SECONDS = {
    900: 6 * 3600, 300: 6 * 3600,
    1800: 12 * 3600, 3600: 12 * 3600, 7200: 12 * 3600,
    60: 12 * 3600, 86400: 24 * 3600,
}
MAX_SERIES_PER_RUN = 24
MAX_RUNTIME_SECONDS = 7 * 60
MIN_FREE_BYTES = 160 * 1024 * 1024
MIN_AVAILABLE_MEMORY_KIB = 300 * 1024


def memory_allows_prefetch():
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            if line.startswith("MemAvailable:"):
                return int(line.split()[1]) >= MIN_AVAILABLE_MEMORY_KIB
    except (OSError, ValueError, IndexError):
        pass
    # Fail closed for optional background warming.
    return False
VALID_CODE = re.compile(r"(CFFEX|SHFE|DCE|CZCE|INE|GFEX)\.[A-Za-z]+[0-9]{3,4}\Z")


def current_main_contracts(codes):
    """Use real main underlying symbols returned by the exchange SDK."""
    result = {}
    for code in codes:
        if not isinstance(code, str) or VALID_CODE.fullmatch(code) is None:
            continue
        product = contract_product(code)
        if product and product.split(".")[0] in EXCHANGES:
            result.setdefault(product, code)
    return dict(sorted(result.items()))


def select_history_jobs(main_codes, store, now, limit=MAX_SERIES_PER_RUN):
    """Missing first; then refresh old series. Never fabricate an OHLC bar."""
    jobs = []
    coverage = {"series_total": 0, "series_cached": 0,
                "series_fresh": 0, "series_missing": 0}
    for product, code in main_codes.items():
        for period in KLINE_PERIOD_ORDER:
            coverage["series_total"] += 1
            key = (code, period)
            candles, saved = store.read(key)
            if candles:
                coverage["series_cached"] += 1
            else:
                coverage["series_missing"] += 1
            age = max(0, now - saved) if saved else float("inf")
            if candles and age < FRESH_SECONDS[period]:
                coverage["series_fresh"] += 1
                continue
            # Full history is not expected for recently listed contracts.
            # If a cache contains genuine bars, don't repeatedly retry to
            # reach 1200 before the freshness period has elapsed.
            missing = not bool(candles)
            jobs.append(((0 if missing else 1,
                          PERIOD_ORDER[period],
                          saved if saved else 0,
                          product), key))
    jobs.sort(key=lambda item: item[0])
    return [item[1] for item in jobs[:max(0, limit)]], coverage


def write_status(payload):
    STATUS_FILE.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    safe = dict(payload, updated_at=datetime.now(timezone.utc).isoformat())
    handle_path = None
    try:
        with tempfile.NamedTemporaryFile(
            dir=STATUS_FILE.parent, prefix=".main-prefetch-",
            mode="w", encoding="utf-8", delete=False
        ) as handle:
            handle_path = Path(handle.name)
            json.dump(safe, handle, ensure_ascii=False)
            handle.flush()
            os.fchmod(handle.fileno(), 0o600)
        os.replace(handle_path, STATUS_FILE)
        handle_path = None
    finally:
        if handle_path is not None:
            handle_path.unlink(missing_ok=True)


def show_status():
    if STATUS_FILE.exists():
        print(STATUS_FILE.read_text(encoding="utf-8"))
    else:
        print("暂无全市场预热记录；首次执行系统定时任务后生成。")


def fetch_history(api, key, wanted=KLINE_HISTORY_LENGTH):
    serial = api.get_kline_serial(key[0], key[1], data_length=wanted)
    timeout = time.monotonic() + 17
    found = []
    while time.monotonic() < timeout:
        api.wait_update(deadline=time.time() + 1)
        found = bars_from_serial(serial)
        if len(found) >= min(wanted - 2, 1000):
            break
        # Short or recently listed products may genuinely have fewer candles.
        if found and time.monotonic() > timeout - 3:
            break
    return found


def run(limit):
    if not memory_allows_prefetch():
        print("可用内存不足300MiB或无法检测，跳过本轮预热。", flush=True)
        return
    start = time.monotonic()
    os.umask(0o077)
    store = KlineFileCache(directory=KLINE_CACHE_DIR)
    auth = json.loads(Path(AUTH_PATH).read_text(encoding="utf-8"))
    if not isinstance(auth.get("username"), str) or not isinstance(auth.get("password"), str):
        raise ValueError("TqSdk授权文件格式不正确")
    api = None
    codes = {}
    done = 0
    failures = 0
    try:
        # One metadata session; no 17-symbol shortlist. query_cont_quotes
        # gives actual main delivery-month codes for all active products.
        api = TqApi(auth=TqAuth(auth["username"], auth["password"]))
        codes = current_main_contracts(api.query_cont_quotes())
        if not codes:
            raise RuntimeError("天勤未返回有效的国内主力合约；不写入虚构数据")
        print("发现国内主力品种:", len(codes),
              "历史周期:", len(KLINE_PERIOD_ORDER), flush=True)
        # Close the metadata connection before scanning historical files.
        api.close()
        api = None
        jobs, coverage = select_history_jobs(codes, store, time.time(), limit)
        write_status(dict(coverage, products=len(codes),
                          attempted=0, succeeded=0, failed=0,
                          pending=max(0, coverage["series_total"] - coverage["series_fresh"]),
                          state="running"))
        print("本轮计划:", len(jobs),
              "组；磁盘已缓存:", coverage["series_cached"],
              "组；尚无缓存:", coverage["series_missing"], "组", flush=True)
        if not jobs:
            write_status(dict(coverage, products=len(codes),
                              attempted=0, succeeded=0, failed=0,
                              pending=0, state="idle", elapsed_seconds=0))
            print("所有主力合约的各周期缓存均处于本轮有效期内。", flush=True)
            return
        for i, key in enumerate(jobs):
            if not memory_allows_prefetch():
                print("可用内存不足300MiB，结束本轮预热。", flush=True)
                break
            if time.monotonic() - start >= MAX_RUNTIME_SECONDS:
                print("达到单轮运行时间预算，剩余任务留给下次。", flush=True)
                break
            if shutil.disk_usage(store.directory if store.directory.exists() else ROOT).free < MIN_FREE_BYTES:
                print("磁盘剩余空间不足160MB，停止预热，保护网关。", flush=True)
                break
            # TqSdk subscriptions are not unsubscribed by get_kline_serial.
            # Close every 6 series to bound SDK RAM and server-side resources.
            if i > 0 and i % 6 == 0 and api is not None:
                api.close()
                api = None
            try:
                if api is None:
                    api = TqApi(auth=TqAuth(auth["username"], auth["password"]))
                bars = fetch_history(api, key)
                if not bars:
                    failures += 1
                    print("无数据:", key, flush=True)
                    continue
                store.write(key, bars)
                # Verify persistence, not just a successful SDK response.
                saved, _ = store.read(key)
                if not saved:
                    failures += 1
                    print("写入后未能读取:", key, flush=True)
                    continue
                done += 1
                print("完成:", key[0], key[1],
                      "有效:", len(bars), "磁盘:", len(saved), flush=True)
            except Exception as exc:
                failures += 1
                print("预热失败:", key, type(exc).__name__, flush=True)
                if api is not None:
                    try:
                        api.close()
                    except Exception:
                        pass
                    api = None
            finally:
                time.sleep(0.2)  # best-effort gentle pacing
        # Release SDK memory before parsing cache files again.
        if api is not None:
            api.close()
            api = None
        # Recompute actual disk coverage after successful writes.
        _, coverage = select_history_jobs(codes, store, time.time(), limit=0)
        write_status(dict(coverage, products=len(codes),
                          attempted=done + failures, succeeded=done,
                          failed=failures,
                          pending=max(0, coverage["series_total"] - coverage["series_fresh"]),
                          state="idle",
                          elapsed_seconds=round(time.monotonic() - start, 2)))
        print("本轮结束：成功", done, "失败", failures,
              "当前覆盖", coverage["series_cached"], "/", coverage["series_total"],
              "最近已更新", coverage["series_fresh"], flush=True)
    finally:
        if api is not None:
            api.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--status", action="store_true")
    parser.add_argument("--limit", type=int, default=MAX_SERIES_PER_RUN)
    args = parser.parse_args()
    if args.status:
        show_status()
    else:
        if not 1 <= args.limit <= MAX_SERIES_PER_RUN:
            parser.error("--limit must be between 1 and 24")
        run(args.limit)
