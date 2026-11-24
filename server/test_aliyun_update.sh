#!/usr/bin/env bash
set -Eeuo pipefail
python3 -m py_compile server/update_aliyun_gateway.py
grep -q 'qihui-gateway.service' server/update_aliyun_gateway.py
grep -q 'history_length") == 1200' server/update_aliyun_gateway.py
grep -q 'shutil.copy2(backup, TARGET)' server/update_aliyun_gateway.py
grep -q 'api.github.com/repos/huangenxu-prog/Futures' server/update_aliyun_gateway.py
echo "Alibaba systemd upgrade script checks OK"
