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
VIDEO_LIMIT_MBIT="${VIDEO_LIMIT_MBIT:-3}"
VIDEO_HOSTS="${VIDEO_HOSTS:-googlevideo.com nflxvideo.net ttvnw.net tiktokcdn.com fbcdn.net}"
BLOCK_QUIC="${BLOCK_QUIC:-1}"
VIDEO_MARK=0x10

# ── One-time topology setup (idempotent: safe to re-run every 5 min) ──
# modprobe with numifbs=1 already creates ifb0 on first load; only add it if not.
ip link show ifb0 &>/dev/null || modprobe ifb numifbs=1
ip link show ifb0 &>/dev/null || ip link add ifb0 type ifb
ip link set ifb0 up

# (grep -q on a here-string, not a pipe: with pipefail, grep exiting early can
# SIGPIPE tc and make a present match look absent.)
grep -q "ingress" <<<"$(tc qdisc show dev "$IFACE")" || \
  tc qdisc add dev "$IFACE" handle ffff: ingress

# connmark restores the video mark onto ingress packets before the redirect,
# so the htb filter on ifb0 can classify them. Old filters (no connmark) are
# replaced.
grep -q connmark <<<"$(tc filter show dev "$IFACE" parent ffff:)" || {
  tc filter del dev "$IFACE" parent ffff: 2>/dev/null || true
  tc filter add dev "$IFACE" parent ffff: protocol all u32 match u32 0 0 \
    action connmark pipe action mirred egress redirect dev ifb0
}

# ── Video detection: mark connections whose TLS ClientHello carries a    ──
# ── VIDEO_HOSTS name in its SNI; the mark is saved on the connection so  ──
# ── later packets (egress here, ingress via act_connmark) inherit it.    ──
# ponytail: SNI over TCP/443 only (QUIC is handled by BLOCK_QUIC below), and
# --save-mark overwrites any other connmark on these flows.
iptables -t mangle -N TS_VIDEO 2>/dev/null || iptables -t mangle -F TS_VIDEO
iptables -t mangle -A TS_VIDEO -j CONNMARK --restore-mark
for h in $VIDEO_HOSTS; do
  iptables -t mangle -A TS_VIDEO -p tcp --dport 443 -m mark --mark 0 \
    -m string --algo bm --string "$h" -j MARK --set-mark "$VIDEO_MARK"
done
iptables -t mangle -A TS_VIDEO -j CONNMARK --save-mark
for chain in OUTPUT FORWARD; do
  iptables -t mangle -C "$chain" -j TS_VIDEO 2>/dev/null || \
    iptables -t mangle -A "$chain" -j TS_VIDEO
done

# ── QUIC (UDP/443) hides the SNI, so reject it and clients fall back to ──
# ── TCP, where the video match above works. BLOCK_QUIC=0 removes this.   ──
if [[ "$BLOCK_QUIC" == 1 ]]; then
  iptables -N TS_QUIC 2>/dev/null || iptables -F TS_QUIC
  iptables -A TS_QUIC -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable
  for chain in FORWARD OUTPUT; do
    iptables -C "$chain" -j TS_QUIC 2>/dev/null || iptables -I "$chain" 1 -j TS_QUIC
  done
else
  for chain in FORWARD OUTPUT; do
    iptables -D "$chain" -j TS_QUIC 2>/dev/null || true
  done
  iptables -F TS_QUIC 2>/dev/null && iptables -X TS_QUIC 2>/dev/null || true
fi

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

# ── Apply (idempotent upsert): htb 1:1 = adaptive total, split into ──
# ── 1:10 video (hard-capped) and 1:20 everything else.              ──
video_mbit=$(awk -v a="$VIDEO_LIMIT_MBIT" -v b="$rate_mbit" 'BEGIN{print (a<b ? a : b)}')

apply_htb() {
  local dev=$1
  grep -q "htb 1:" <<<"$(tc qdisc show dev "$dev")" || \
    tc qdisc replace dev "$dev" root handle 1: htb default 20
  tc class replace dev "$dev" parent 1:  classid 1:1  htb rate "${rate_mbit}mbit" ceil "${rate_mbit}mbit" burst "${burst_kbit}kbit"
  tc class replace dev "$dev" parent 1:1 classid 1:10 htb rate 1mbit ceil "${video_mbit}mbit" burst "${burst_kbit}kbit"
  tc class replace dev "$dev" parent 1:1 classid 1:20 htb rate "${rate_mbit}mbit" ceil "${rate_mbit}mbit" burst "${burst_kbit}kbit"
  tc filter replace dev "$dev" parent 1: protocol all prio 1 handle "$VIDEO_MARK" fw flowid 1:10
}
apply_htb "$IFACE"
apply_htb ifb0

used_mib=$((used / 1048576))
echo "traffic-shaper: used_today=${used_mib}MiB daily_quota=${daily_quota_gib}GiB rate=${rate_mbit}mbit video_cap=${video_mbit}mbit"
