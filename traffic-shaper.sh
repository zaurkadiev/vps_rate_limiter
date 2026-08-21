#!/usr/bin/env bash
# tc rate limiter driven by a self-adjusting daily quota: 95% of the
# month's remaining budget spread over the month's remaining days (an
# envelope-budgeting pacer — a light day leaves more for the days after
# it, a heavy day leaves less). Rate follows a downward parabola
# (Y = MAX_MBIT - k*X^2, X = % of today's quota used) that reaches
# EMERGENCY_MBIT exactly at EMERGENCY_THRESHOLD_PCT and stays there for
# the rest of the day.
# See README.md for how this works and what each variable means.
set -euo pipefail

IFACE="${IFACE:-ens3}"
BUDGET_GIB="${BUDGET_GIB:-1024}"
MIN_MBIT="${MIN_MBIT:-5}"
MAX_MBIT="${MAX_MBIT:-500}"
OVERRIDE_FILE="${OVERRIDE_FILE:-/etc/traffic-shaper-force-floor}"
EMERGENCY_THRESHOLD_PCT="${EMERGENCY_THRESHOLD_PCT:-85}"
EMERGENCY_MBIT="${EMERGENCY_MBIT:-3}"

# ── One-time topology setup (idempotent: safe to re-run every 5 min) ──
ip link show ifb0 &>/dev/null || { modprobe ifb numifbs=1; ip link add ifb0 type ifb; }
ip link set ifb0 up

tc qdisc show dev "$IFACE" | grep -q "ingress" || \
  tc qdisc add dev "$IFACE" handle ffff: ingress

tc filter show dev "$IFACE" parent ffff: | grep -q "ifb0" || \
  tc filter add dev "$IFACE" parent ffff: protocol all u32 match u32 0 0 \
    action mirred egress redirect dev ifb0

# ── Usage (bytes) from vnstat: today's, for the rate calc and the log ──
# ── line, and this month's, to derive today's quota below.            ──
used=$(vnstat --json d -i "$IFACE" | jq -r '.interfaces[0].traffic.day[-1] | .rx+.tx')
used_month=$(vnstat --json m -i "$IFACE" | jq -r '.interfaces[0].traffic.month[-1] | .rx+.tx')

# ── Quota: 95% of (BUDGET_GIB - usage through yesterday) / days left    ──
# ── in the calendar month (today counts as a remaining day). Parabola: ──
# ── Y = MAX_MBIT - k*X^2, X = % of that quota used today, k chosen so  ──
# ── Y(EMERGENCY_THRESHOLD_PCT)=EMERGENCY_MBIT.                         ──
read -r rate_mbit burst_kbit daily_quota_gib <<<"$(python3 - "$used" "$used_month" "$BUDGET_GIB" "$MAX_MBIT" "$EMERGENCY_THRESHOLD_PCT" "$EMERGENCY_MBIT" <<'PYEOF'
import calendar
import datetime
import sys

used = int(sys.argv[1])
used_month = int(sys.argv[2])
budget_gib = float(sys.argv[3])
max_mbit = float(sys.argv[4])
emergency_threshold_pct = float(sys.argv[5])
emergency_mbit = float(sys.argv[6])

today = datetime.date.today()
days_in_month = calendar.monthrange(today.year, today.month)[1]
remaining_days = days_in_month - today.day + 1

used_through_yesterday = used_month - used
remaining_gib = budget_gib - used_through_yesterday / 1024**3

daily_quota_gib = 0.95 * max(remaining_gib, 0) / remaining_days
daily_quota = daily_quota_gib * 1024**3

# Non-positive quota means the monthly budget is already spent: force
# the emergency floor via a huge pct_used rather than defaulting to 0,
# which would read as "no usage yet" and give full MAX_MBIT speed.
pct_used = (used / daily_quota * 100) if daily_quota > 0 else 1e9

k = (max_mbit - emergency_mbit) / (emergency_threshold_pct ** 2)
rate_mbit = max(max_mbit - k * pct_used ** 2, emergency_mbit)

burst_kbit = max(32, int(rate_mbit * 50))  # ~50ms worth of data at the target rate

print(f"{rate_mbit:.2f} {burst_kbit} {daily_quota_gib:.2f}")
PYEOF
)"

if [[ -f "$OVERRIDE_FILE" && "$(cat "$OVERRIDE_FILE")" == "$(date +%Y-%m-%d)" ]]; then
  # Forced floor for the rest of today (auto-expires when the file's
  # YYYY-MM-DD stops matching, i.e. at midnight). Overrides the computed
  # rate above; daily_quota_gib is still logged below for visibility.
  rate_mbit="$MIN_MBIT"
  burst_kbit=$(( MIN_MBIT * 50 ))
fi

# ── Apply (idempotent upsert) ──
tc qdisc replace dev "$IFACE" root tbf rate "${rate_mbit}mbit" burst "${burst_kbit}kbit" latency 50ms
tc qdisc replace dev ifb0 root tbf rate "${rate_mbit}mbit" burst "${burst_kbit}kbit" latency 50ms

used_mib=$((used / 1048576))
echo "traffic-shaper: used_today=${used_mib}MiB daily_quota=${daily_quota_gib}GiB rate=${rate_mbit}mbit"
