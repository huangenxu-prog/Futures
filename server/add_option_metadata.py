"""Add genuine option tick size and contract multiplier to the existing gateway."""
import ast
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
from urllib.request import urlopen

TARGET = Path("/root/tq_test/server/market_gateway.py")
SERVICE = "qihui-gateway.service"
REPLACEMENTS = [("                    result.append(dict(snapshot(quote), code=code, strike=quote.strike_price,\n                                       side=quote.option_class))", "                    row = dict(snapshot(quote), code=code, strike=quote.strike_price,\n                               side=quote.option_class)\n                    for field, key in ((\"price_tick\", \"priceTick\"),\n                                       (\"volume_multiple\", \"volumeMultiple\")):\n                        value = getattr(quote, field, None)\n                        if isinstance(value, (int, float)) and math.isfinite(value) and value > 0:\n                            row[key] = float(value)\n                    result.append(row)")]



def patched(source):
    ast.parse(source)
    for old, new in REPLACEMENTS:
        if source.count(new) == 1:
            continue
        if source.count(old) != 1:
            raise ValueError("网关源码与预期不一致；停止修改")
        source = source.replace(old, new, 1)
    compile(source, str(TARGET), "exec")
    return source


def replace_source(content):
    with tempfile.NamedTemporaryFile(dir=TARGET.parent, prefix=".option-metadata-", delete=False) as f:
        path = Path(f.name)
        f.write(content.encode("utf-8"))
    try:
        shutil.copymode(TARGET, path)
        os.replace(path, TARGET)
    finally:
        path.unlink(missing_ok=True)


def healthy():
    with urlopen("http://127.0.0.1:8765/health", timeout=5) as response:
        return json.load(response).get("ok") is True


def run():
    subprocess.run(["systemctl", "is-active", "--quiet", SERVICE], check=True)
    if not healthy():
        raise RuntimeError("现有网关健康检查失败，停止操作")
    original = TARGET.read_text(encoding="utf-8")
    updated = patched(original)
    if original == updated:
        print("期权交易参数已存在，无需重启", flush=True)
        return
    backup = TARGET.with_name(TARGET.name + ".bak.option-metadata." + str(int(time.time())))
    shutil.copy2(TARGET, backup)
    print("仅增加期权最小价位及乘数字段；已备份:", backup, flush=True)
    replace_source(updated)
    try:
        subprocess.run(["systemctl", "restart", SERVICE], check=True, timeout=30)
        for _ in range(20):
            try:
                if healthy():
                    print("期权字段已部署，网关健康检查通过；订阅和缓存策略未更改", flush=True)
                    return
            except Exception:
                pass
            time.sleep(1)
        raise RuntimeError("健康检查失败")
    except Exception:
        shutil.copy2(backup, TARGET)
        subprocess.run(["systemctl", "restart", SERVICE], check=True)
        print("部署失败，已恢复原网关文件", flush=True)
        raise


if __name__ == "__main__":
    run()
