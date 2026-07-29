#!/usr/bin/env bash
# Forces the traffic-shaper to MIN_MBIT (5 Mbps) for the rest of the current
# calendar month. Auto-expires on the 1st of next month — see README.md.
set -euo pipefail

VPS="${VPN_VPS:?Set VPN_VPS to the VPS host/IP}"

ssh "root@$VPS" 'date +%Y-%m > /etc/traffic-shaper-force-floor && /usr/local/bin/traffic-shaper.sh'
