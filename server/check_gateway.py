"""Check the pinned gateway against the live feed without restarting the service."""
import hashlib
import importlib.util
import math
from pathlib import Path
import tempfile
from urllib.request import urlopen

REVISION = "13291b3f6010fb002e8ba2aabd91035776e6ed36"
DIGEST = "f63906f67eeefb0d568bc5722c6c6e0e9422ca9813b064e33233023091c67452"


def check():
    url = f"https://raw.githubusercontent.com/huangenxu-prog/Futures/{REVISION}/server/market_gateway.py"
    with urlopen(url, timeout=30) as response:
        source = response.read()
    if hashlib.sha256(source).hexdigest() != DIGEST:
        raise ValueError("网关文件校验失败")
    installed = Path("/root/tq_test/server/market_gateway.py")
    print("现有脚本与新版" + ("相同" if installed.read_bytes() == source else "不同"), flush=True)
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "market_gateway.py"
        path.write_bytes(source)
        spec = importlib.util.spec_from_file_location("gateway", path)
        gateway = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gateway)
        print("正在查询白糖主力", flush=True)
        quote = gateway.main_contracts().get("CZCE.SR", {})
        code = quote.get("code", "")
        if gateway.contract_product(code) != "CZCE.SR" or not quote.get("month"):
            raise ValueError("缺少白糖主力代码或交割月份")
        print("白糖" + quote["month"], code, "报价时间", quote.get("time"),
              "最新价", quote.get("last"), "昨结算", quote.get("settlement"), flush=True)
        if not quote.get("time") or not all(math.isfinite(quote.get(k, math.nan)) for k in ("last", "settlement")):
            raise ValueError("报价数据不完整")
        bars = gateway.load_bars(code, 900, 5)
        if not bars:
            raise ValueError("没有返回该合约的15分钟K线")
        print("检查通过", code, "15分钟K线", len(bars), "根", flush=True)


if __name__ == "__main__":
    try:
        check()
    except Exception as error:
        print("检查失败", type(error).__name__, str(error)[:300], flush=True)
        raise SystemExit(1)
