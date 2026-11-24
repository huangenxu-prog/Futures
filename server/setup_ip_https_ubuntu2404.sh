#!/usr/bin/env bash
# First-time IP HTTPS for the Qihui read-only gateway on Ubuntu 24.04.
# Certbot uses HTTP-01 webroot so renewals never interrupt Nginx or TqSdk.
set -Eeuo pipefail
umask 077

IP=8.153.96.190
CERTBOT=/opt/qihui-certbot/bin/certbot
WEBROOT=/var/www/qihui-acme
SITE=/etc/nginx/sites-available/qihui-ip
LIMITS=/etc/nginx/conf.d/qihui-limits.conf

if [[ "$(id -u)" != "0" ]]; then
  echo "请用 root 运行。" >&2
  exit 1
fi
source /etc/os-release
if [[ "$ID" != "ubuntu" || "$VERSION_ID" != "24.04" ]]; then
  echo "仅针对 Ubuntu 24.04 验证。" >&2
  exit 1
fi
if ! systemctl is-active --quiet qihui-gateway; then
  echo "期汇网关未运行；先检查 qihui-gateway。" >&2
  exit 1
fi
echo "[1/5] 安装 Nginx 和 Certbot 5.4+..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends nginx python3-venv ca-certificates openssl curl
if [[ ! -x "$CERTBOT" ]]; then
  python3 -m venv /opt/qihui-certbot
fi
/opt/qihui-certbot/bin/python -m pip install -q --disable-pip-version-check --upgrade "certbot>=5.4,<6"
"$CERTBOT" --version
install -d -m 0755 "$WEBROOT/.well-known/acme-challenge"

echo "[2/5] 创建 HTTP-01 验证入口..."
cat > "$LIMITS" <<'CONF'
limit_req_zone $binary_remote_addr zone=qihui_requests:10m rate=8r/s;
limit_conn_zone $binary_remote_addr zone=qihui_connections:10m;
CONF
cat > "$SITE" <<CONF
server {
    listen 80;
    server_name $IP;
    location ^~ /.well-known/acme-challenge/ {
        root $WEBROOT;
        default_type text/plain;
        try_files \$uri =404;
    }
    location / { return 404; }
}
CONF
# This new VPS is dedicated to Qihui; disable only Ubuntu's stock default site.
if [[ -L /etc/nginx/sites-enabled/default ]]; then
  rm /etc/nginx/sites-enabled/default
fi
ln -sfn "$SITE" /etc/nginx/sites-enabled/qihui-ip
nginx -t
systemctl enable --now nginx
systemctl reload nginx

echo "[3/5] 申请160小时有效期的IP证书..."
echo "需在阿里云安全组放行TCP 80；以后续期同样需要。"
"$CERTBOT" certonly --webroot --webroot-path "$WEBROOT" \
  --ip-address "$IP" --cert-name "$IP" --preferred-profile shortlived \
  --agree-tos --register-unsafely-without-email --non-interactive --no-eff-email \
  --keep-until-expiring
CHAIN="/etc/letsencrypt/live/$IP/fullchain.pem"
KEY="/etc/letsencrypt/live/$IP/privkey.pem"
if [[ ! -s "$CHAIN" || ! -s "$KEY" ]]; then
  echo "证书未生成，保持网关在本机运行。" >&2
  exit 1
fi
if ! openssl x509 -in "$CHAIN" -noout -ext subjectAltName | grep -Fq "IP Address:$IP"; then
  echo "证书未包含预期IP，拒绝启用HTTPS。" >&2
  exit 1
fi

echo "[4/5] 配置Nginx的443反向代理（支持SSE）..."
cat > "$SITE" <<CONF
server {
    listen 80;
    server_name $IP;
    location ^~ /.well-known/acme-challenge/ {
        root $WEBROOT;
        default_type text/plain;
        try_files \$uri =404;
    }
    location / { return 404; }
}
server {
    listen 443 ssl;
    server_name $IP;
    ssl_certificate $CHAIN;
    ssl_certificate_key $KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 1k;

    location / {
        limit_except GET { deny all; }
        limit_req zone=qihui_requests burst=24 nodelay;
        limit_conn qihui_connections 16;
        proxy_pass http://127.0.0.1:8765;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        add_header Cache-Control "no-store" always;
        add_header X-Content-Type-Options "nosniff" always;
    }
}
CONF
nginx -t
systemctl reload nginx

echo "[5/5] 配置每12小时自动续期检查..."
cat > /etc/systemd/system/qihui-cert-renew.service <<UNIT
[Unit]
Description=Renew Qihui IP TLS certificate
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$CERTBOT renew --quiet --deploy-hook "/usr/bin/systemctl reload nginx"
UNIT
cat > /etc/systemd/system/qihui-cert-renew.timer <<'UNIT'
[Unit]
Description=Check Qihui IP certificate twice daily

[Timer]
OnCalendar=*-*-* 04:15:00
OnCalendar=*-*-* 16:15:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now qihui-cert-renew.timer
echo "--- Certificate ---"
openssl x509 -in "$CHAIN" -noout -dates -ext subjectAltName
echo "--- HTTPS local self-test ---"
curl -4 -fsS --max-time 12 --resolve "$IP:443:127.0.0.1" "https://$IP/health"
echo
echo "HTTPS本地检查通过。公网访问须确保阿里云安全组允许TCP 443。"
echo "自动续期：systemctl list-timers qihui-cert-renew.timer"
