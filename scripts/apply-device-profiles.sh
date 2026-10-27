#!/usr/bin/env bash
# Merge device-profiles/ (SmartCrop's supported sensors) into the local
# lorawan-devices clone and re-run the ChirpStack import.
#   bash scripts/apply-device-profiles.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -d lorawan-devices/vendors ]; then
  rm -rf lorawan-devices
  git clone --depth 1 https://github.com/chirpstack/chirpstack-device-profiles ./lorawan-devices
fi

for vendor_dir in device-profiles/vendors/*/; do
  vendor=$(basename "$vendor_dir")
  dest="lorawan-devices/vendors/$vendor"
  mkdir -p "$dest/devices" "$dest/codecs" "$dest/profiles"
  cp -f "$vendor_dir"/devices/*.toml "$dest/devices/" 2>/dev/null || true
  cp -f "$vendor_dir"/codecs/*       "$dest/codecs/"  2>/dev/null || true
  cp -f "$vendor_dir"/profiles/*     "$dest/profiles/" 2>/dev/null || true
  [ -f "$vendor_dir/vendor.toml" ] && cp -f "$vendor_dir/vendor.toml" "$dest/vendor.toml"

  # append each device file to the vendor's devices = [...] list if missing
  for dev in "$vendor_dir"/devices/*.toml; do
    [ -e "$dev" ] || continue
    f=$(basename "$dev")
    if ! grep -q "\"$f\"" "$dest/vendor.toml"; then
      python3 - "$dest/vendor.toml" "$f" << 'PY'
import re, sys
p, f = sys.argv[1], sys.argv[2]
s = open(p).read()
s = re.sub(r'(devices\s*=\s*\[)', r'\1\n    "%s",' % f, s, count=1)
open(p, "w").write(s)
PY
      echo "added $f to $vendor/vendor.toml"
    fi
  done
done

echo "importing..."
docker compose run --rm chirpstack -c /etc/chirpstack import-device-profiles -d /opt/lorawan-devices 2>&1 | grep -iE "error|panic|d20" || true
echo "done — check Network Server → Device Profiles → Dragino"
