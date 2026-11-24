"""Add actual K-line open interest to the existing deployed gateway only."""
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
REPLACEMENTS = [
    ("        bars.append({\n            \"time\": int(row.datetime) // 1_000_000_000,\n            \"open\": float(row.open),\n            \"high\": float(row.high),\n            \"low\": float(row.low),\n            \"close\": float(row.close),\n            \"volume\": int(row.volume) if math.isfinite(float(row.volume)) else 0,\n        })", "        bar = {\n            \"time\": int(row.datetime) // 1_000_000_000,\n            \"open\": float(row.open),\n            \"high\": float(row.high),\n            \"low\": float(row.low),\n            \"close\": float(row.close),\n            \"volume\": int(row.volume) if math.isfinite(float(row.volume)) else 0,\n        }\n        for key, field in ((\"openInterest\", \"open_oi\"), (\"closeInterest\", \"close_oi\")):\n            value = getattr(row, field, None)\n            if value is not None and math.isfinite(float(value)) and value >= 0:\n                bar[key] = int(value)\n        bars.append(bar)"),
    ("                valid.append({name: bar[name] for name in\n                              (\"time\", \"open\", \"high\", \"low\", \"close\", \"volume\")})", "                row = {name: bar[name] for name in\n                       (\"time\", \"open\", \"high\", \"low\", \"close\", \"volume\")}\n                for field in (\"openInterest\", \"closeInterest\"):\n                    value = bar.get(field)\n                    if isinstance(value, (int, float)) and math.isfinite(value) and value >= 0:\n                        row[field] = int(value)\n                valid.append(row)"),
]


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
    with tempfile.NamedTemporaryFile(dir=TARGET.parent, prefix=".kline-interest-", delete=False) as f:
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
        print("K线持仓量字段已存在，无需重启", flush=True)
        return
    backup = TARGET.with_name(TARGET.name + ".bak.kline-interest." + str(int(time.time())))
    shutil.copy2(TARGET, backup)
    print("仅增加K线期初/期末持仓字段及缓存读取；已备份:", backup, flush=True)
    replace_source(updated)
    try:
        subprocess.run(["systemctl", "restart", SERVICE], check=True, timeout=30)
        for _ in range(20):
            try:
                if healthy():
                    print("持仓字段已部署，网关健康检查通过；订阅和缓存策略未更改", flush=True)
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
