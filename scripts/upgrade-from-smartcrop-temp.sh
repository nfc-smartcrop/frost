#!/usr/bin/env bash
# One-time upgrade on tools: smartcrop-temp (v1) -> smartcrop-frost (v2).
# Keeps all ChirpStack data (tenant, profile, devices) by copying the Docker
# volumes to the new project name, then migrates the frost DB schema.
#
# Run from inside the NEW smartcrop-frost folder, next to the OLD smartcrop-temp folder:
#   sudo bash scripts/upgrade-from-smartcrop-temp.sh ../smartcrop-temp
set -euo pipefail

OLD_DIR="${1:?usage: $0 <path-to-smartcrop-temp>}"
OLD=smartcrop-temp
NEW=smartcrop-frost

echo "== 1/5 stopping old stack ($OLD_DIR)"
( cd "$OLD_DIR" && docker compose down )

echo "== 2/5 copying volumes $OLD_* -> $NEW_*"
for v in postgresqldata redisdata grafanadata; do
  docker volume inspect "${NEW}_${v}" >/dev/null 2>&1 || docker volume create "${NEW}_${v}" >/dev/null
  docker run --rm -v "${OLD}_${v}:/from:ro" -v "${NEW}_${v}:/to" alpine sh -c 'cd /from && cp -a . /to'
  echo "   copied ${v}"
done

echo "== 3/5 copying .env and device repo"
[ -f .env ] || cp "$OLD_DIR/.env" .env
[ -d lorawan-devices ] || cp -r "$OLD_DIR/lorawan-devices" . 2>/dev/null || true

echo "== 4/5 starting new stack"
docker compose up -d --build
echo "   waiting for postgres..."
for i in $(seq 1 30); do
  docker compose exec -T postgres pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 2
done

echo "== 5/5 migrating frost DB schema v1 -> v2"
docker compose exec -T postgres psql -U frost -d frost < migrations/001_v1_to_v2_subscriptions.sql

docker compose restart ingest
echo
echo "Done. ChirpStack UI: http://tools:8100  (same tenant, devices, profile as before)"
echo "Old volumes ${OLD}_* are untouched; remove them later with: docker volume rm ${OLD}_postgresqldata ${OLD}_redisdata ${OLD}_grafanadata"
