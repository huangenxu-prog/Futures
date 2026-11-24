#!/usr/bin/env bash
set -Eeuo pipefail
bash -n server/setup_ip_https_ubuntu2404.sh
grep -q 'IP=8.153.96.190' server/setup_ip_https_ubuntu2404.sh
grep -q 'certbot>=5.4,<6' server/setup_ip_https_ubuntu2404.sh
grep -q -- '--preferred-profile shortlived' server/setup_ip_https_ubuntu2404.sh
grep -q -- '--webroot' server/setup_ip_https_ubuntu2404.sh
grep -q 'QIHUI_BIND' server/bootstrap_ubuntu2404.sh
grep -q 'proxy_pass http://127.0.0.1:8765' server/setup_ip_https_ubuntu2404.sh
grep -q 'qihui-cert-renew.timer' server/setup_ip_https_ubuntu2404.sh
grep -q 'nginx -t' server/setup_ip_https_ubuntu2404.sh
echo "IP HTTPS installer syntax and defaults: OK"
