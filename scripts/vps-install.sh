#!/usr/bin/env bash
# SmartCrop Frost — first-time install on the SmartCrop VPS.
# Run as root from the smartcrop-frost folder:  bash scripts/vps-install.sh
set -euo pipefail

echo "== 1/6 .env"
[ -f .env ] || { cp .env.example .env; echo "   created .env — edit it (Twilio, smtp2go, WEBHOOK_SECRET) and re-run"; exit 1; }

echo "== 2/6 start stack"
docker compose up -d --build
for i in $(seq 1 30); do docker compose exec -T postgres pg_isready -U postgres >/dev/null 2>&1 && break; sleep 2; done

echo "== 3/6 device profile repo"
if [ ! -d lorawan-devices ]; then
  git clone --depth 1 https://github.com/chirpstack/chirpstack-device-profiles ./lorawan-devices
  docker compose run --rm chirpstack -c /etc/chirpstack import-device-profiles -d /opt/lorawan-devices > /dev/null
fi

echo "== 4/6 nginx sites"
for f in nginx/*.conf; do
  n=$(basename "$f")
  cp "$f" "/etc/nginx/sites-available/$n"
  ln -sf "/etc/nginx/sites-available/$n" "/etc/nginx/sites-enabled/$n"
done
nginx -t && systemctl reload nginx

echo "== 5/6 firewall (ufw): Basic Station rides on 443; UDP 1700 only if you add a source IP"
if command -v ufw >/dev/null; then
  ufw status | grep -q "Status: active" && echo "   ufw active; add gateway source IPs with: ufw allow from <ip> to any port 1700 proto udp"
fi

echo "== 6/6 TLS"
echo "   DNS: frost.smartcrop.com and lns.smartcrop.com -> this server (lns MUST be DNS-only, not Cloudflare-proxied)"
echo "   then: certbot --nginx -d frost.smartcrop.com -d lns.smartcrop.com"
echo
echo "ChirpStack UI: https://frost.smartcrop.com  (admin / admin — change it)"
echo "Gateways:      wss://lns.smartcrop.com  (Basic Station, TLS server auth)"
