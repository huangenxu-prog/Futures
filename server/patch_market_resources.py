"""Apply the tested resource-control delta to the installed systemd gateway.

Never replace unrelated local changes. Stage both patches before changing
either installed file; retain backups and roll back on failed local health.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
from urllib.request import urlopen

ROOT = Path("/root/tq_test/server")
OLD = "fb7f6143fd7ada01a89267d9f178541307d91dfd"
NEW = "bee117b2bf710cc4b89ea126b007f77034d76d7c"
BASE = "https://raw.githubusercontent.com/huangenxu-prog/Futures/"
MARKET = "qihui-gateway.service"
TRADE = "qihui-trade.service"
TIMER = "qihui-main-history-prefetch.timer"
PREFETCH = "qihui-main-history-prefetch.service"
FILES = {
    "market_gateway.py": (
        "c7df76a389b8b8e58ce9e344a3b0cbc681866c73",
        "73644b621ca5bd8c3e1b998656e7b9b7870f5150",
        "01eeb731652975a336c79f0602a8f698237ca201"),
    "prefetch_main_history.py": (
        "5e97f36ff0afb395dfd1afa529c3667d24f917ab",
        "2b68a2a1d6f01bde3eae12ea2b836f036e8a8f0a",
        "92fbfdfd69f56d685b25e2e7633154a269463c4e"),
}


def systemctl(*args):
    return subprocess.run(["systemctl", *args], check=True, timeout=120,
                          stdout=subprocess.PIPE, text=True).stdout.strip()


def state(unit):
    return systemctl("show", unit, "-p", "ActiveState", "--value")


def download(ref, name, expected):
    with urlopen(BASE + ref + "/server/" + name, timeout=30) as response:
        data = response.read(2_000_000)
    blob = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
    if blob != expected:
        raise RuntimeError("Git blob mismatch: " + name)
    return data


def health():
    with urlopen("http://127.0.0.1:8765/health", timeout=3) as response:
        return response.status == 200 and json.load(response).get("ok") is True


def wait_health():
    for _ in range(30):
        try:
            if health() and state(MARKET) == "active":
                return
        except (OSError, ValueError):
            pass
        time.sleep(1)
    raise RuntimeError("Market health check failed")


def replace_from(source, target):
    fd, name = tempfile.mkstemp(prefix=".resource-", dir=target.parent)
    os.close(fd)
    try:
        shutil.copy2(source, name)
        os.replace(name, target)
    finally:
        Path(name).unlink(missing_ok=True)


def stage(directory, name, hashes):
    local_hash, old_blob, new_blob = hashes
    target = ROOT / name
    raw = target.read_bytes()
    if hashlib.sha1(raw).hexdigest() != local_hash:
        raise RuntimeError("Installed file changed since inspection: " + name)
    old = directory / (name + ".old")
    new = directory / (name + ".new")
    delta = directory / (name + ".diff")
    candidate = directory / name
    old.write_bytes(download(OLD, name, old_blob))
    new.write_bytes(download(NEW, name, new_blob))
    diff = subprocess.run(["diff", "-u", str(old), str(new)], stdout=subprocess.PIPE)
    if diff.returncode != 1 or not diff.stdout:
        raise RuntimeError("Unable to generate delta: " + name)
    delta.write_bytes(diff.stdout)
    subprocess.run(["patch", "--batch", "--forward", "--fuzz=0",
                    "--no-backup-if-mismatch", "-o", str(candidate),
                    str(target), str(delta)], check=True, timeout=30)
    compile(candidate.read_bytes(), str(target), "exec")
    shutil.copystat(target, candidate)
    print("STAGED", name, flush=True)
    return candidate


def main():
    if os.geteuid() != 0:
        raise RuntimeError("root required")
    if state(MARKET) != "active" or state(TRADE) != "active" or not health():
        raise RuntimeError("Existing services not healthy; no changes")
    trade_pid = systemctl("show", TRADE, "-p", "MainPID", "--value")
    with tempfile.TemporaryDirectory(prefix=".resource-stage-", dir=ROOT) as tmp:
        directory = Path(tmp)
        candidates = {name: stage(directory, name, hashes) for name, hashes in FILES.items()}
        timer_active = state(TIMER) == "active"
        if timer_active:
            systemctl("stop", TIMER)
        backups = {}
        changed = []
        try:
            if state(PREFETCH) not in ("inactive", "failed"):
                raise RuntimeError("Prefetch is running; retry after it finishes. No files changed.")
            for name, hashes in FILES.items():
                if hashlib.sha1((ROOT / name).read_bytes()).hexdigest() != hashes[0]:
                    raise RuntimeError("Installed file changed during staging: " + name)
            stamp = str(time.time_ns())
            for name in FILES:
                target = ROOT / name
                backup = target.with_name(name + ".resource.bak." + stamp)
                shutil.copy2(target, backup)
                backups[name] = backup
                print("BACKUP", backup, flush=True)
            try:
                for name, candidate in candidates.items():
                    replace_from(candidate, ROOT / name)
                    changed.append(name)
                systemctl("restart", MARKET)
                wait_health()
            except BaseException:
                for name in reversed(changed):
                    replace_from(backups[name], ROOT / name)
                if "market_gateway.py" in changed:
                    systemctl("restart", MARKET)
                    wait_health()
                print("RESOURCE_PATCH_ROLLED_BACK", flush=True)
                raise
        finally:
            if timer_active:
                systemctl("start", TIMER)
        trade_now = systemctl("show", TRADE, "-p", "MainPID", "--value")
        print("TRADE_PID", trade_pid, trade_now, flush=True)
        print("RESOURCE_PATCH_OK: market health=200; trade not restarted by updater", flush=True)


if __name__ == "__main__":
    main()
