#!/usr/bin/env bash
set -Eeuo pipefail
bash -n server/update_gateway_systemd.sh
grep -q 'systemctl restart qihui-gateway.service' server/update_gateway_systemd.sh
grep -q 'trap restore ERR' server/update_gateway_systemd.sh
grep -q '1a224e5fe7406d22624ed047b043cba1f148ff63' server/update_gateway_systemd.sh
grep -q 'api.github.com/repos/huangenxu-prog/Futures/contents' server/update_gateway_systemd.sh
echo "Safe systemd gateway updater: syntax OK"
