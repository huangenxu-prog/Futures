"""Install pinned full-market main-contract history prefetch on Alibaba ECS.

Downloads and SHA-verifies the gateway and prefetch modules; checks gateway
health, installs a low-priority systemd timer, rolls back on failure.
Does not alter iOS, Nginx, or public ports, or disclose TqSdk credentials.
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
SERVER = ROOT / "server"
PIN = "0a89df952326602a89f4f426f4b083a923fba1a4"
BLOBS = {"market_gateway.py":"43422995aa429a942bb74524245e91e011c4ad44","prefetch_main_history.py":"2b68a2a1d6f01bde3eae12ea2b836f036e8a8f0a"}
GATEWAY_SERVICE = "qihui-gateway.service"
WARM_SERVICE = "qihui-main-history-prefetch.service"
WARM_TIMER = "qihui-main-history-prefetch.timer"
UNITS = Path("/etc/systemd/system")

SERVICE_BODY = """[Unit]
Description=Qihui background prefetch for all domestic main-contract K-lines
Wants=network-online.target
After=network-online.target qihui-gateway.service

[Service]
Type=oneshot
User=root
WorkingDirectory=/root/tq_test
Environment=PYTHONUNBUFFERED=1
Environment=TQ_AUTH_FILE=/root/tq_test/auth.json
Environment=QIHUI_KLINE_CACHE_DIR=/root/tq_test/cache/klines
ExecStart=/root/tq_test/.venv/bin/python -u /root/tq_test/server/prefetch_main_history.py --limit 24
TimeoutStartSec=8min
Nice=10
IOSchedulingClass=idle
CPUWeight=10
IOWeight=10
NoNewPrivileges=true
PrivateTmp=true
"""

TIMER_BODY = """[Unit]
Description=Qihui refresh all main-futures historical caches periodically

[Timer]
OnBootSec=2min
OnUnitInactiveSec=10min
AccuracySec=30sec
RandomizedDelaySec=20sec
Unit=qihui-main-history-prefetch.service

[Install]
WantedBy=timers.target
"""


def run_cmd(*cmd):
    subprocess.run(cmd, check=True)


def get_source(filename, expected):
    candidates = [
        "https://api.github.com/repos/huangenxu-prog/Futures/"
        "contents/server/" + filename + "?ref=" + PIN,
        "https://cdn.jsdelivr.net/gh/huangenxu-prog/Futures@" +
        PIN + "/server/" + filename,
    ]
    for index, link in enumerate(candidates):
        try:
            req = Request(link, headers={
                "User-Agent": "Qihui-Aliyun-History-Installer",
                "Accept": "application/vnd.github+json"})
            with urlopen(req, timeout=35) as response:
                raw = response.read()
            if index == 0:
                meta = json.loads(raw)
                if meta.get("encoding") != "base64":
                    raise ValueError("GitHub文件编码不是base64")
                raw = base64.b64decode(meta["content"])
            digest = hashlib.sha1(
                b"blob " + str(len(raw)).encode() + b"\0" + raw
            ).hexdigest()
            if digest != expected:
                raise ValueError("Git Blob摘要校验失败")
            compile(raw, str(SERVER / filename), "exec")
            print("校验通过:", filename, len(raw), "bytes", flush=True)
            return raw
        except Exception as exc:
            print("下载尝试失败:", filename, index + 1,
                  type(exc).__name__, flush=True)
    raise RuntimeError("无法下载或验证必要源码：" + filename)


def healthy():
    with urlopen("http://127.0.0.1:8765/health", timeout=5) as response:
        result = json.load(response)
    cache = result.get("kline_cache", {})
    return bool(result.get("ok") and cache.get("history_length") == 1200
                and cache.get("disk_enabled") and cache.get("data_length") == 2)


def safe_install(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        dir=path.parent, prefix=".qihui-install-", delete=False
    ) as handle:
        temp = Path(handle.name)
        handle.write(content)
    try:
        os.chmod(temp, 0o644)
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def deploy():
    if os.geteuid() != 0:
        raise RuntimeError("只允许阿里云 root 安装")
    gateway = SERVER / "market_gateway.py"
    prefetch = SERVER / "prefetch_main_history.py"
    if not gateway.is_file() or not (ROOT / ".venv/bin/python").exists():
        raise RuntimeError("期汇网关尚未安装")
    run_cmd("systemctl", "is-active", "--quiet", GATEWAY_SERVICE)
    if not healthy():
        raise RuntimeError("原网关健康检查失败，拒绝升级")
    data = {
        name: get_source(name, digest) for name, digest in BLOBS.items()
    }
    old_gateway = gateway.read_bytes()
    old_prefetch = prefetch.read_bytes() if prefetch.is_file() else None
    gateway_changed = old_gateway != data["market_gateway.py"]
    originals = {}
    for name in (WARM_SERVICE, WARM_TIMER):
        path = UNITS / name
        originals[name] = path.read_bytes() if path.is_file() else None
    try:
        if gateway_changed:
            backup = gateway.with_name(
                "market_gateway.py.bak." + str(int(time.time())))
            shutil.copy2(gateway, backup)
            print("旧网关备份:", backup, flush=True)
        safe_install(gateway, data["market_gateway.py"])
        safe_install(prefetch, data["prefetch_main_history.py"])
        if gateway_changed:
            run_cmd("systemctl", "restart", GATEWAY_SERVICE)
            for attempt in range(45):
                try:
                    if healthy():
                        break
                except Exception:
                    pass
                time.sleep(1)
            else:
                raise RuntimeError("新网关健康检查超时")
        safe_install(UNITS / WARM_SERVICE, SERVICE_BODY.encode())
        safe_install(UNITS / WARM_TIMER, TIMER_BODY.encode())
        run_cmd("systemctl", "daemon-reload")
        run_cmd("systemctl", "enable", "--now", WARM_TIMER)
        run_cmd("systemctl", "start", "--no-block", WARM_SERVICE)
        print("全市场历史缓存任务已安装并启动", flush=True)
        print("每次最多24组；本轮完成后约10分钟自动执行下一轮", flush=True)
        print("查看: systemctl list-timers qihui-main-history-prefetch.timer", flush=True)
        print("日志: journalctl -u qihui-main-history-prefetch.service -n 30 --no-pager",
              flush=True)
        print("统计: /root/tq_test/.venv/bin/python "
              "/root/tq_test/server/prefetch_main_history.py --status",
              flush=True)
    except Exception:
        print("安装失败：恢复原有文件和网关...", flush=True)
        subprocess.run(["systemctl", "disable", "--now", WARM_TIMER],
                       check=False, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
        safe_install(gateway, old_gateway)
        if old_prefetch is not None:
            safe_install(prefetch, old_prefetch)
        else:
            prefetch.unlink(missing_ok=True)
        for name, body in originals.items():
            path = UNITS / name
            if body is None:
                path.unlink(missing_ok=True)
            else:
                safe_install(path, body)
        run_cmd("systemctl", "daemon-reload")
        if gateway_changed:
            run_cmd("systemctl", "restart", GATEWAY_SERVICE)
        print("已恢复原文件，请确认网关健康状态。", flush=True)
        raise


if __name__ == "__main__":
    deploy()
