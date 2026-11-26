"""Safely deploy a pinned Qihui gateway revision on the new Alibaba systemd VPS.

Only modifies /root/tq_test/server/market_gateway.py and qihui-gateway.service.
It never reads or prints the TqSdk account credential file.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
from urllib.request import Request, urlopen

ROOT = Path("/root/tq_test")
TARGET = ROOT / "server/market_gateway.py"
COMMIT = "16665d05cea7d7088a451e745457630b3035a7e7"
BLOB = "7e25743bd1e29a135b53ca85f0fac0bf5f253a9c"
SERVICE = "qihui-gateway.service"
BASE = "http://127.0.0.1:8765"


def verify(content):
    sha = hashlib.sha1(b"blob " + str(len(content)).encode() + b"\0" + content).hexdigest()
    if sha != BLOB:
        raise ValueError("Git源码SHA不匹配，拒绝部署: " + sha)
    compile(content, str(TARGET), "exec")


def download():
    url = ("https://api.github.com/repos/huangenxu-prog/Futures/"
           "contents/server/market_gateway.py?ref=" + COMMIT)
    for source in ("api", "jsdelivr"):
        try:
            if source == "api":
                req = Request(url, headers={
                    "Accept": "application/vnd.github+json",
                    "User-Agent": "Qihui-Aliyun-Updater"})
                with urlopen(req, timeout=25) as response:
                    meta = json.load(response)
                raw = base64.b64decode(meta["content"])
            else:
                cdn = ("https://cdn.jsdelivr.net/gh/huangenxu-prog/"
                       "Futures@" + COMMIT + "/server/market_gateway.py")
                with urlopen(cdn, timeout=25) as response:
                    raw = response.read()
            verify(raw)
            print("下载成功，来源:", source, "SHA校验通过", flush=True)
            return raw
        except Exception as exc:
            print("下载尝试失败:", source, type(exc).__name__, flush=True)
    raise RuntimeError("没有可用的可信下载源；旧网关保持不变")


def health():
    with urlopen(BASE + "/health", timeout=5) as response:
        doc = json.load(response)
    return doc


def board_ready(result):
    feed = result.get("quote_feed", {})
    expected = feed.get("expected_products", 0)
    priced = feed.get("priced_products", 0)
    return (expected >= 70 and priced >= expected * 0.90
            and feed.get("connection_state") == "polling"
            and feed.get("last_poll_age_seconds") is not None
            and feed["last_poll_age_seconds"] < 5
            and feed.get("sdk_creations", 0) == 1)


def exact_ready():
    with urlopen(BASE + "/v1/quote?symbol=DCE.p2701", timeout=5) as response:
        row = json.load(response)
    return row.get("code") == "DCE.p2701" and row.get("priceTick", 0) > 0 and row.get("volumeMultiple", 0) > 0


def report_funds():
    try:
        with urlopen(BASE + "/v1/quote?symbol=DCE.p2701", timeout=5) as response:
            row = json.load(response)
        print("FUNDS_CHECK", json.dumps({k: row.get(k) for k in
              ("code", "last", "settlement", "interest", "previousInterest",
               "estimatedFunds", "estimatedFundFlow")}, ensure_ascii=False), flush=True)
        if row.get("estimatedFunds") is None:
            print("保证金参考数据缺失，App资金字段显示 --", flush=True)
    except Exception as exc:
        print("资金字段检查未完成:", type(exc).__name__, flush=True)


def report_options():
    from urllib.parse import urlencode
    def get(path, params, timeout=45):
        with urlopen(BASE + path + "?" + urlencode(params), timeout=timeout) as response:
            return json.load(response)
    try:
        underlying = "DCE.p2701"
        rows = get("/v1/options", {"symbol": underlying})
        puts = [r for r in rows if r.get("side") == "PUT" and r.get("last") is not None]
        if not puts:
            raise RuntimeError("no listed put quotes")
        chosen = min(puts, key=lambda r: abs(r["strike"] - 8200))
        symbol = chosen["code"]
        quote = get("/v1/option-quote", {"symbol": symbol, "underlying": underlying})
        print("OPTION_QUOTE_CHECK", json.dumps({k: quote.get(k) for k in
              ("code", "last", "bid", "ask", "expireEpoch", "previousInterest")}), flush=True)
        print("OPTION_EXPIRY_CHECK", "OK" if quote.get("expireEpoch", 0) > time.time() else "MISSING_OR_EXPIRED", flush=True)
        bars = get("/v1/klines", {"symbol": symbol, "period": 1800, "count": 200}, 60)
        count = len(bars.get("bars", []))
        print("OPTION_KLINE_CHECK", json.dumps({"symbol": symbol, "count": count}), flush=True)
        print("OPTION_FEATURES_OK" if count and quote.get("expireEpoch", 0) > time.time() else "OPTION_FEATURES_INCOMPLETE", flush=True)
    except Exception as exc:
        print("OPTION_FEATURES_INCOMPLETE", type(exc).__name__, str(exc)[:160], flush=True)


def run():
    if os.geteuid() != 0 or not TARGET.is_file():
        raise RuntimeError("必须在已部署期汇的阿里云 root 用户下执行")
    subprocess.run(["systemctl", "is-active", "--quiet", SERVICE], check=True)
    if TARGET.is_symlink() or not health().get("ok"):
        raise RuntimeError("Existing gateway not healthy or unexpected target")
    original = TARGET.read_bytes()
    new = download()
    if original == new:
        if board_ready(health()) and exact_ready():
            print("MARKET_OPTIONS_UPGRADE_OK: already running", flush=True)
            report_funds()
            report_options()
            return
        raise RuntimeError("Target file matches but running version is not verified")
    backup = TARGET.with_name("market_gateway.py.bak." + str(time.time_ns()))
    shutil.copy2(TARGET, backup)
    print("已备份旧网关，准备重启", flush=True)

    with tempfile.NamedTemporaryFile(
        dir=TARGET.parent, prefix=".qihui-new-", delete=False
    ) as handle:
        staged = Path(handle.name)
        handle.write(new)
    try:
        os.chmod(staged, 0o644)
        os.replace(staged, TARGET)
        subprocess.run(["systemctl", "restart", SERVICE], check=True)
        for _ in range(90):
            try:
                result = health()
                cache = result.get("kline_cache", {})
                if (result.get("ok")
                        and cache.get("history_length") == 1200
                        and cache.get("data_length") == 2
                        and cache.get("disk_enabled")
                        and board_ready(result)
                        and exact_ready()
                        and result.get("process_memory_kib", {}).get("VmRSS", 0) > 0):
                    print("期汇新网关启动成功：实时2根、历史预取1200根、"
                          "磁盘可累计8964根；现有缓存保留", flush=True)
                    print("如历史首次不足1200根，将在后台补齐。", flush=True)
                    print("MARKET_OPTIONS_UPGRADE_OK", json.dumps(result, ensure_ascii=False), flush=True)
                    report_funds()
                    report_options()
                    return
            except Exception:
                pass
            time.sleep(1)
        raise RuntimeError("新网关未通过健康检查")
    except Exception:
        print("升级未通过检查，恢复旧代码...", flush=True)
        shutil.copy2(backup, TARGET)
        subprocess.run(["systemctl", "restart", SERVICE], check=True)
        print("已恢复原网关", flush=True)
        raise
    finally:
        staged.unlink(missing_ok=True)


if __name__ == "__main__":
    run()
