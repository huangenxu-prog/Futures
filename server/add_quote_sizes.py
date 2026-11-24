"""Add level-one quote sizes to the deployed gateway without replacing its K-line logic."""
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
OLD = '        "previousInterest": "pre_open_interest",'
ADDITION = '        "bidVolume": "bid_volume1", "askVolume": "ask_volume1",'


def patched(source):
    tree = ast.parse(source)
    fn = next((n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "snapshot"), None)
    if fn is None:
        raise ValueError("snapshot function not found; no changes made")
    lines = source.splitlines(keepends=True)
    segment = "".join(lines[fn.lineno - 1:fn.end_lineno])
    if ADDITION.strip() in segment:
        return source
    if segment.count(OLD) != 1 or "bid_volume1" in segment or "ask_volume1" in segment:
        raise ValueError("snapshot differs from expected source; no changes made")
    result = "".join(lines[:fn.lineno - 1]) + segment.replace(OLD, OLD + "\n" + ADDITION, 1) + "".join(lines[fn.end_lineno:])
    compile(result, str(TARGET), "exec")
    return result


def replace_source(content):
    with tempfile.NamedTemporaryFile(dir=TARGET.parent, prefix=".quote-size-", delete=False) as f:
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
        print("挂单量字段已存在，无需重启", flush=True)
        return
    backup = TARGET.with_name(TARGET.name + ".bak.book-size." + str(int(time.time())))
    shutil.copy2(TARGET, backup)
    print("仅修改 snapshot 的两个报价字段；已备份:", backup, flush=True)
    replace_source(updated)
    try:
        subprocess.run(["systemctl", "restart", SERVICE], check=True, timeout=30)
        for _ in range(20):
            try:
                if healthy():
                    print("挂单量字段已部署，网关健康检查通过；K线逻辑未更改", flush=True)
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
