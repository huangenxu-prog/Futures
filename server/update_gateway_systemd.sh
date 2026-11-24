#!/usr/bin/env bash
# Safe fast-path upgrade for the existing systemd-managed Alibaba VPS gateway.
# Never copies passwords; keeps gateway loopback-only and rolls back on failure.
set -Eeuo pipefail
umask 077
ROOT=/root/tq_test
TARGET="$ROOT/server/market_gateway.py"
BACKUP="$ROOT/server/market_gateway.py.before-quote-fastpath"
TEMP_JSON="$(mktemp)"
TEMP_CODE="$(mktemp)"
EXPECTED="1a224e5fe7406d22624ed047b043cba1f148ff63"
COMMIT="cff7897c5190828770c69c964e5303c17024259f"
cleanup() { rm -f "$TEMP_JSON" "$TEMP_CODE"; }
trap cleanup EXIT
if [[ "$(id -u)" != "0" ]] || [[ ! -s "$TARGET" ]] || ! systemctl cat qihui-gateway.service >/dev/null 2>&1; then
  echo "仅适用于已配置 systemd 的期汇阿里云服务器。" >&2
  exit 1
fi
echo "[1/4] 从 GitHub API 获取固定版本的网关源码..."
curl -4 --fail --location --silent --show-error --connect-timeout 10 --max-time 50 \
  "https://api.github.com/repos/huangenxu-prog/Futures/contents/server/market_gateway.py?ref=$COMMIT" \
  -o "$TEMP_JSON"
python3 - "$TEMP_JSON" "$TEMP_CODE" "$EXPECTED" <<'PY'
import base64
import hashlib
import json
import sys
from pathlib import Path
record = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if record.get("encoding") != "base64" or not record.get("content"):
    raise SystemExit("下载内容格式错误，已终止升级")
body = base64.b64decode(record["content"])
sha = hashlib.sha1(b"blob " + str(len(body)).encode() + b"\0" + body).hexdigest()
if sha != sys.argv[3]:
    raise SystemExit("源码摘要不匹配，已终止升级")
Path(sys.argv[2]).write_bytes(body)
print("源码摘要匹配：" + sha)
PY
"$ROOT/.venv/bin/python" -m py_compile "$TEMP_CODE"
echo "[2/4] 备份原网关代码..."
cp -p "$TARGET" "$BACKUP"
restore() {
  echo "升级验证失败，恢复原网关代码..." >&2
  cp -p "$BACKUP" "$TARGET"
  systemctl restart qihui-gateway.service || true
}
trap restore ERR
install -m 0644 "$TEMP_CODE" "$TARGET"
echo "[3/4] 使用 systemd 重启网关..."
systemctl restart qihui-gateway.service
echo "[4/4] 验证运行状态和天勤连接..."
READY=0
for i in $(seq 1 20); do
  if curl -4 -fsS --max-time 2 http://127.0.0.1:8765/health 2>/dev/null \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d["ok"] and d["kline_cache"]["connected"]' >/dev/null 2>&1; then
    READY=1; break
  fi
  sleep 1
done
if [[ "$READY" != "1" ]]; then
  echo "新网关未能在20秒内确认天勤连接。" >&2
  exit 1
fi
trap - ERR
echo "升级成功：天勤连接正常、systemd仍管理期汇行情网关。"
