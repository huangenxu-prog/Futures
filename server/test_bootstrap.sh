#!/usr/bin/env bash
set -Eeuo pipefail
bash -n server/bootstrap_ubuntu2404.sh
grep -q 'QIHUI_BIND=127.0.0.1' server/bootstrap_ubuntu2404.sh
grep -q 'tqsdk==3.10.4' server/bootstrap_ubuntu2404.sh
grep -q 'chmod 0600' server/bootstrap_ubuntu2404.sh
grep -q 'cdn.jsdelivr.net/gh/huangenxu-prog/Futures@' server/bootstrap_ubuntu2404.sh
grep -q 'api.github.com/repos/huangenxu-prog/Futures/contents/' server/bootstrap_ubuntu2404.sh
grep -q 'if digest != sys.argv\[2\]' server/bootstrap_ubuntu2404.sh
echo "Ubuntu bootstrap syntax and defaults: OK"
