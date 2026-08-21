#!/usr/bin/env bash
# Forces the traffic-shaper to MIN_MBIT (5 Mbps) for the rest of today.
# Auto-expires at midnight — see README.md.
set -euo pipefail

VPS="${VPN_VPS:?Set VPN_VPS to the VPS host/IP}"

ssh "root@$VPS" 'date +%Y-%m-%d > /etc/traffic-shaper-force-floor && /usr/local/bin/traffic-shaper.sh'
