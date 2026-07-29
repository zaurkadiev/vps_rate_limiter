#!/usr/bin/env bash
# Adaptive tc rate limiter driven by monthly vnstat usage.
# See README.md for how this works and what each variable means.
set -euo pipefail

IFACE="${IFACE:-ens3}"
BUDGET_GIB="${BUDGET_GIB:-1024}"
MARGIN_PCT="${MARGIN_PCT:-5}"
MIN_MBIT="${MIN_MBIT:-5}"
MAX_MBIT="${MAX_MBIT:-1000}"
OVERRIDE_FILE="${OVERRIDE_FILE:-/etc/traffic-shaper-force-floor}"

# ── One-time topology setup (idempotent: safe to re-run every 5 min) ──
ip link show ifb0 &>/dev/null || { modprobe ifb numifbs=1; ip link add ifb0 type ifb; }
ip link set ifb0 up

tc qdisc show dev "$IFACE" | grep -q "ingress" || \
  tc qdisc add dev "$IFACE" handle ffff: ingress

tc filter show dev "$IFACE" parent ffff: | grep -q "ifb0" || \
  tc filter add dev "$IFACE" parent ffff: protocol all u32 match u32 0 0 \
    action mirred egress redirect dev ifb0

# ── This month's usage (bytes) from vnstat, for the rate calc and the log line ──
used=$(vnstat --json m -i "$IFACE" | jq -r '.interfaces[0].traffic.month[-1] | .rx+.tx')

if [[ -f "$OVERRIDE_FILE" && "$(cat "$OVERRIDE_FILE")" == "$(date +%Y-%m)" ]]; then
  # Forced floor for the rest of this calendar month (auto-expires when the
  # file's YYYY-MM stops matching, i.e. at the next month rollover).
  rate_mbit="$MIN_MBIT"
  burst_kbit=$(( MIN_MBIT * 50 ))
else
  # ── Target rate = remaining budget / remaining time in calendar month ──
  read -r rate_mbit burst_kbit <<<"$(python3 - "$used" "$BUDGET_GIB" "$MARGIN_PCT" "$MIN_MBIT" "$MAX_MBIT" <<'PYEOF'
import sys, datetime

used = int(sys.argv[1])
budget_gib = float(sys.argv[2])
margin_pct = float(sys.argv[3])
min_mbit = float(sys.argv[4])
max_mbit = float(sys.argv[5])

budget = budget_gib * (1 - margin_pct / 100) * 1024**3

now = datetime.datetime.now()
if now.month == 12:
    next_month = now.replace(year=now.year + 1, month=1, day=1, hour=0, minute=0, second=0, microsecond=0)
else:
    next_month = now.replace(month=now.month + 1, day=1, hour=0, minute=0, second=0, microsecond=0)
remaining_seconds = max((next_month - now).total_seconds(), 1)
remaining_bytes = max(budget - used, 0)

target_mbit = (remaining_bytes * 8 / remaining_seconds) / 1_000_000
rate_mbit = min(max(target_mbit, min_mbit), max_mbit)
burst_kbit = max(32, int(rate_mbit * 50))  # ~50ms worth of data at the target rate

print(f"{rate_mbit:.2f} {burst_kbit}")
PYEOF
)"
fi

# ── Apply (idempotent upsert) ──
tc qdisc replace dev "$IFACE" root tbf rate "${rate_mbit}mbit" burst "${burst_kbit}kbit" latency 50ms
tc qdisc replace dev ifb0 root tbf rate "${rate_mbit}mbit" burst "${burst_kbit}kbit" latency 50ms

used_mib=$((used / 1048576))
echo "traffic-shaper: used=${used_mib}MiB budget=${BUDGET_GIB}GiB margin=${MARGIN_PCT}% rate=${rate_mbit}mbit"
