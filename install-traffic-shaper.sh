#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# TRAFFIC SHAPER INSTALLER
# Deploys the adaptive monthly-bandwidth-budget rate limiter.
# Run as root on the target VPS, from inside this directory
# (or after scp -r'ing this whole folder to the VPS).
# See README.md for details.
# ─────────────────────────────────────────────

[[ $EUID -ne 0 ]] && { echo "Run as root: sudo $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for bin in vnstat tc jq python3; do
  command -v "$bin" &>/dev/null || { echo "Missing dependency: $bin" >&2; exit 1; }
done

install -m 755 "$SCRIPT_DIR/traffic-shaper.sh" /usr/local/bin/traffic-shaper.sh
install -m 644 "$SCRIPT_DIR/traffic-shaper.service" /etc/systemd/system/traffic-shaper.service
install -m 644 "$SCRIPT_DIR/traffic-shaper.timer" /etc/systemd/system/traffic-shaper.timer

systemctl daemon-reload
systemctl enable --now traffic-shaper.timer

echo "Running traffic-shaper.sh once now so shaping is live immediately..."
/usr/local/bin/traffic-shaper.sh

echo
echo "Installed. Check status with:"
echo "  systemctl status traffic-shaper.timer"
echo "  journalctl -u traffic-shaper -n 20"
echo "  tc qdisc show dev \${IFACE:-ens3}"
