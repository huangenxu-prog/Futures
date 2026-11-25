"""Install the read-only Qihui trade gateway alongside the existing Nginx market route."""
import hashlib
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import tempfile
import time
from urllib.request import Request, urlopen
from urllib.error import HTTPError

ROOT = Path("/root/tq_test")
PY = ROOT / ".venv/bin/python"
TARGET = ROOT / "server/trade_gateway.py"
UNIT = Path("/etc/systemd/system/qihui-trade.service")
ENV = Path("/etc/qihui-trade.env")
WORK = Path("/var/lib/qihui-trade")
CONF = Path("/etc/nginx/sites-enabled/qihui-ip").resolve(strict=True)
SERVICE = "qihui-trade.service"
BASE = "https://8.153.96.190"
COMMIT = "1c2bd0cf77dd76183d62abf069929daff1883275"
BLOB = "3043a1bf998ecc8b202cec3d6ae77ba25ec86d1d"

def run(*args):
    subprocess.run(args, check=True)

def code(url, key=None):
    req = Request(url, headers={"X-Qihui-Access": key} if key else {})
    try:
        with urlopen(req, timeout=8) as res:
            return res.status
    except HTTPError as exc:
        return exc.code

def write_new(path, data, mode=0o600):
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode), "wb") as f:
        f.write(data)

def replace_config(data, mode):
    fd, name = tempfile.mkstemp(prefix=".qihui-trade-", dir=CONF.parent)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.chmod(name, mode)
        st = CONF.stat()
        os.chown(name, st.st_uid, st.st_gid)
        os.replace(name, CONF)
    finally:
        Path(name).unlink(missing_ok=True)

def main():
    if os.geteuid() != 0 or not PY.is_file():
        raise RuntimeError("Run as root on the existing Qihui VPS")
    for path in (TARGET, UNIT, ENV, WORK):
        if path.exists() or path.is_symlink():
            raise RuntimeError("Existing trade installation; stop instead of overwriting: " + str(path))
    run("systemctl", "is-active", "--quiet", "qihui-gateway")
    run("systemctl", "is-active", "--quiet", "nginx")
    run("nginx", "-t")
    if code(BASE + "/health") != 200:
        raise RuntimeError("Existing HTTPS market health check failed")
    old = CONF.read_bytes()
    source = old.decode()
    # Match the existing multiline root proxy, not the HTTP ACME server's inline location.
    pattern = r"(?m)^([ \t]*)location[ \t]+/[ \t]*\{[ \t]*\n(?=[ \t]*limit_except GET \{ deny all; \}[ \t]*\n[ \t]*limit_req zone=qihui_requests burst=24 nodelay;[ \t]*\n[ \t]*limit_conn qihui_connections 16;[ \t]*\n[ \t]*proxy_pass http://127\.0\.0\.1:8765;)"
    matches = list(re.finditer(pattern, source))
    if len(matches) != 1 or "/v1/trade/" in source:
        raise RuntimeError("Unexpected Nginx configuration; no changes made")
    match = matches[0]
    indent = match.group(1)
    location = "\n".join(indent + line for line in [
        "location ^~ /v1/trade/ {",
        "    limit_except GET POST { deny all; }",
        "    limit_req zone=qihui_requests burst=24 nodelay;",
        "    limit_conn qihui_connections 16;",
        "    proxy_pass http://127.0.0.1:8766;",
        "    proxy_set_header X-Qihui-Access $http_x_qihui_access;",
        "    proxy_set_header Authorization $http_authorization;",
        "    proxy_read_timeout 75s;",
        "    proxy_connect_timeout 3s;",
        "    client_max_body_size 8k;",
        "    access_log off;",
        "    error_log /dev/null crit;",
        "}", ""
    ]) + "\n"
    updated = (source[:match.start()] + location + source[match.start():]).encode()
    import base64
    import json
    sources = [
        ("api", "https://api.github.com/repos/huangenxu-prog/Futures/contents/server/trade_gateway.py?ref=" + COMMIT),
        ("cdn", "https://cdn.jsdelivr.net/gh/huangenxu-prog/Futures@" + COMMIT + "/server/trade_gateway.py"),
        ("raw", "https://raw.githubusercontent.com/huangenxu-prog/Futures/" + COMMIT + "/server/trade_gateway.py"),
    ]
    for kind, url in sources:
        try:
            req = Request(url, headers={"User-Agent": "Qihui-Trade-Installer", "Accept": "application/vnd.github+json"})
            with urlopen(req, timeout=15) as res:
                raw = res.read(100000)
            if kind == "api":
                raw = base64.b64decode(json.loads(raw)["content"])
            if hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest() != BLOB:
                raise RuntimeError("Trade gateway source hash mismatch")
            print("Verified trade gateway source:", kind, flush=True)
            break
        except Exception as exc:
            print("Download failed:", kind, type(exc).__name__, flush=True)
    else:
        raise RuntimeError("No verified trade gateway download available; no changes made")
    compile(raw, str(TARGET), "exec")
    run(str(PY), "-c", "from tqsdk import TqApi, TqAuth, TqKq")
    key = secrets.token_hex(32)
    mode = CONF.stat().st_mode & 0o777
    backup = Path("/root/qihui-nginx-before-trade-" + str(time.time_ns()) + ".conf")
    write_new(backup, old)
    created = []
    config_changed = False
    try:
        WORK.mkdir(mode=0o700)
        created.append(WORK)
        write_new(TARGET, raw, 0o644)
        created.append(TARGET)
        write_new(ENV, ("QIHUI_TRADE_ACCESS_KEY=" + key + "\n").encode())
        created.append(ENV)
        unit = """[Unit]
Description=Qihui read-only cloud simulation gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/var/lib/qihui-trade
EnvironmentFile=/etc/qihui-trade.env
ExecStart=/root/tq_test/.venv/bin/python /root/tq_test/server/trade_gateway.py
Restart=on-failure
RestartSec=3
UMask=0077
LimitCORE=0
NoNewPrivileges=true
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
"""
        write_new(UNIT, unit.encode(), 0o644)
        created.append(UNIT)
        run("systemctl", "daemon-reload")
        run("systemctl", "start", SERVICE)
        for _ in range(20):
            try:
                if code("http://127.0.0.1:8766/v1/trade/snapshot") == 403 and code("http://127.0.0.1:8766/v1/trade/snapshot", key) == 401:
                    break
            except OSError:
                pass
            time.sleep(1)
        else:
            raise RuntimeError("Local trade service authorization check failed")
        config_changed = True
        replace_config(updated, mode)
        run("nginx", "-t")
        run("systemctl", "reload", "nginx")
        # systemctl reload returns before the new Nginx workers accept connections.
        # Check all routes separately, never print the secret or response bodies.
        for attempt in range(1, 13):
            time.sleep(1)
            statuses = []
            for url, access in ((BASE + "/health", None),
                                (BASE + "/v1/trade/snapshot", None),
                                (BASE + "/v1/trade/snapshot", key)):
                try:
                    statuses.append(code(url, access))
                except OSError as exc:
                    statuses.append(type(exc).__name__)
            print("HTTPS attempt", attempt, "market/unauthenticated/authorized:", *statuses, flush=True)
            if statuses == [200, 403, 401]:
                break
        else:
            raise RuntimeError("HTTPS authorization or market health check failed: " + str(statuses))
        run("systemctl", "enable", SERVICE)
        print("TRADE_DEPLOY_OK: market health=200; unauthenticated=403; authorized without session=401")
        print("Access key stored privately in /etc/qihui-trade.env; not printed.")
    except BaseException:
        if config_changed:
            try:
                replace_config(old, mode)
                run("nginx", "-t")
                run("systemctl", "reload", "nginx")
            except Exception:
                print("NGINX ROLLBACK FAILED. Restore from:", backup, flush=True)
        if UNIT in created:
            subprocess.run(["systemctl", "disable", "--now", SERVICE], check=False)
        for path in reversed(created):
            if path == WORK:
                shutil.rmtree(path, ignore_errors=True)
            else:
                path.unlink(missing_ok=True)
        subprocess.run(["systemctl", "daemon-reload"], check=False)
        raise

if __name__ == "__main__":
    main()
