#!/usr/bin/env bash
# Fresh Ubuntu 24.04 setup for Qihui read-only gateway. No credentials included.
set -Eeuo pipefail
umask 077
if [[ "$(id -u)" -ne 0 ]]; then
  echo "请用 root 运行此脚本。" >&2
  exit 1
fi
# shellcheck disable=SC1091
source /etc/os-release
if [[ "$ID" != "ubuntu" || "$VERSION_ID" != "24.04" ]]; then
  echo "只支持 Ubuntu 24.04；检测到 $PRETTY_NAME。" >&2
  exit 1
fi
ROOT=/root/tq_test
APP="$ROOT/server/market_gateway.py"
MARKET_COMMIT="eb2ffb7249ec5d81c925ef959f3db83cda834efc"
MARKET_BLOB="99d16601b87dc3bff50a9d38875c2fa17ddabae2"
SERVICE=/etc/systemd/system/qihui-gateway.service

echo "[1/5] 安装系统依赖..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends python3 python3-venv python3-pip ca-certificates curl

echo "[2/5] 创建 Python 虚拟环境..."
install -d -m 0700 "$ROOT" "$ROOT/server" "$ROOT/cache/klines"
if [[ ! -f "$ROOT/.venv/bin/python" ]]; then
  python3 -m venv "$ROOT/.venv"
fi
"$ROOT/.venv/bin/python" -m pip install --disable-pip-version-check -q --upgrade pip
"$ROOT/.venv/bin/python" -m pip install --disable-pip-version-check "tqsdk==3.10.4"

echo "[3/5] 下载网关并校验 Git 文件摘要..."
TEMP="$(mktemp)"
trap 'rm -f "$TEMP"' EXIT
# GitHub Raw can reset TLS handshakes on some Alibaba Cloud routes.
# Try public CDN first and GitHub Contents API second; the Git blob SHA
# check below guarantees byte-for-byte identity whichever source succeeds.
SOURCE_PATH="server/market_gateway.py"
CDN_URL="https://cdn.jsdelivr.net/gh/huangenxu-prog/Futures@$MARKET_COMMIT/$SOURCE_PATH"
API_URL="https://api.github.com/repos/huangenxu-prog/Futures/contents/$SOURCE_PATH?ref=$MARKET_COMMIT"
RAW_URL="https://raw.githubusercontent.com/huangenxu-prog/Futures/$MARKET_COMMIT/$SOURCE_PATH"
META="$(mktemp)"
trap 'rm -f "$TEMP" "$META"' EXIT
if curl -4 -fLsS --connect-timeout 8 --max-time 40 "$CDN_URL" -o "$TEMP"; then
  echo "网关源码下载成功（jsDelivr）"
elif curl -4 -fLsS --connect-timeout 8 --max-time 40 \
  -H 'Accept: application/vnd.github+json' "$API_URL" -o "$META"; then
  python3 - "$META" "$TEMP" <<'PY'
import base64
import json
import sys
from pathlib import Path
meta = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if meta.get("encoding") != "base64" or not meta.get("content"):
    raise SystemExit("GitHub API 未返回完整源码。")
Path(sys.argv[2]).write_bytes(base64.b64decode(meta["content"], validate=False))
PY
  echo "网关源码下载成功（GitHub API）"
elif curl -4 -fLsS --connect-timeout 8 --max-time 40 "$RAW_URL" -o "$TEMP"; then
  echo "网关源码下载成功（GitHub Raw）"
else
  echo "源码下载失败：jsDelivr、GitHub API 和 GitHub Raw 均无法访问。" >&2
  exit 1
fi
python3 - "$TEMP" "$MARKET_BLOB" <<'PY'
import hashlib, sys
from pathlib import Path
data = Path(sys.argv[1]).read_bytes()
digest = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
if digest != sys.argv[2]:
    raise SystemExit("网关源码摘要校验失败。")
print("Git 文件摘要校验通过：" + digest)
PY
if [[ -f "$APP" ]]; then
  cp -p "$APP" "$APP.bak.$(date +%s)"
fi
install -m 0644 "$TEMP" "$APP"
"$ROOT/.venv/bin/python" -m py_compile "$APP"
"$ROOT/.venv/bin/python" -c "import tqsdk; print('TqSdk 导入成功')"

echo "[4/5] 注册开机自启服务（仅绑定本机）..."
cat > "$SERVICE" <<'UNIT'
[Unit]
Description=Qihui Futures Read-Only Market Gateway
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/tq_test
Environment=PYTHONUNBUFFERED=1
Environment=QIHUI_BIND=127.0.0.1
Environment=QIHUI_PORT=8765
Environment=TQ_AUTH_FILE=/root/tq_test/auth.json
Environment=QIHUI_KLINE_CACHE_DIR=/root/tq_test/cache/klines
ExecStart=/root/tq_test/.venv/bin/python -u /root/tq_test/server/market_gateway.py
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
LimitNOFILE=16384

[Install]
WantedBy=multi-user.target
UNIT
chmod 0644 "$SERVICE"
systemctl daemon-reload
systemctl enable qihui-gateway.service >/dev/null

echo "[5/5] 检查天勤凭证..."
if [[ -s "$ROOT/auth.json" ]]; then
  chmod 0600 "$ROOT/auth.json"
  "$ROOT/.venv/bin/python" - "$ROOT/auth.json" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if not isinstance(data.get("username"), str) or not isinstance(data.get("password"), str):
    raise SystemExit("auth.json 必须包含 username 和 password")
PY
  systemctl restart qihui-gateway.service
  echo "网关已启动。执行：curl -fsS http://127.0.0.1:8765/health"
else
  systemctl stop qihui-gateway.service 2>/dev/null || true
  echo "基础部署完成，但尚未配置天勤账户，未启动网关。"
  echo "请将账号密码安全存放到 $ROOT/auth.json，格式为 username/password 两个 JSON 字段。"
  echo "配置后运行：systemctl start qihui-gateway && curl -fsS http://127.0.0.1:8765/health"
fi
echo "服务名：qihui-gateway.service"
echo "目录：$ROOT"
