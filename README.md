# vps_rate_limiter

Bandwidth limiter that keeps a VPS under a monthly traffic budget (combined
in+out): each day's quota is sized from what's actually left of that budget
and how many days remain in the month, and rate follows a downward parabola
as usage climbs toward a threshold percentage of that day's quota, reaching
a low floor rate right at the threshold and staying there for the rest of
the day.

## Why this exists

Some VPS providers bill or cut you off after a fixed amount of monthly
traffic (e.g. 1024 GiB). If you run a VPN or proxy on the box, a burst of
client usage on any given day can blow through a fair daily share of that
budget. This tool paces the monthly cap with an envelope-budgeting model:
every 5 minutes it computes today's quota as 95% of `(BUDGET_GIB - usage
through yesterday) / days remaining in the calendar month, today included`,
then checks today's usage against that quota, computing a rate that curves
smoothly downward from `MAX_MBIT` at 0% used to `EMERGENCY_MBIT` at
`EMERGENCY_THRESHOLD_PCT`% used (default 85%) — both directions, so it also
covers inbound traffic (e.g. downloads relayed through a VPN/proxy count as
*inbound* to the VPS first). The 5% held back is a standing safety margin
against the overshoot risk described below.

Because the quota is derived from what's actually left, a light day leaves
more room for the days that follow it and a heavy day tightens them — usage
naturally paces itself out to the end of the month instead of following a
fixed per-day split.

`EMERGENCY_MBIT` is deliberately not zero, so you can always SSH in and fix
things even after the day's quota is exhausted. Because the rate curve has
zero slope at 0% used but keeps accelerating downward as usage climbs (a
parabola's slope is `-2kX` — see **Known limitation** below), there's still
some residual overshoot risk near the threshold, just far less than a flat
step function would have.

## How it works

1. **Topology (set up once, kept idempotent so it's safe to re-check every
   run):**
   - Egress on the real interface (`IFACE`, e.g. `ens3`) is shaped directly
     with a `tc tbf` (token bucket filter) qdisc — the simplest qdisc that
     does a flat rate limit, since there's only one traffic class here (no
     priorities needed).
   - Ingress can't be shaped directly in Linux (`tc` only supports
     *policing*, i.e. dropping packets, on ingress — not smooth shaping).
     The standard workaround is used: an `ifb0` virtual interface is
     created, all ingress traffic on `IFACE` is mirrored/redirected to it
     via `tc filter ... action mirred egress redirect dev ifb0`, and a
     `tbf` qdisc shapes `ifb0` instead.

2. **Every 5 minutes** (systemd timer, matching vnstat's own poll
   interval — checking more often wouldn't see new data anyway):
   - Read today's `rx+tx` byte total for `IFACE` from `vnstat --json d`,
     and this month's `rx+tx` total from `vnstat --json m` (vnstat is
     already tracking both; no separate counters needed; the daily/monthly
     boundaries follow the system's local calendar — see `MonthRotate` in
     `/etc/vnstat.conf`).
   - Compute `used_through_yesterday = used_this_month - used_today` and
     `remaining_gib = BUDGET_GIB - used_through_yesterday / GiB`.
   - Compute `remaining_days = days_in_current_calendar_month -
     day_of_month + 1` (today counts as one of the remaining days, so this
     is never zero).
   - Compute `daily_quota = 0.95 * max(remaining_gib, 0) / remaining_days`
     and `pct_used = used_today / daily_quota * 100` (if `daily_quota` is
     zero or negative — this month's budget is already spent — `pct_used`
     is forced to a large sentinel instead, so the next step clamps
     straight to `EMERGENCY_MBIT` rather than reading as "no usage yet"
     and running at `MAX_MBIT`).
   - Compute `k = (MAX_MBIT - EMERGENCY_MBIT) / EMERGENCY_THRESHOLD_PCT^2`,
     then `rate = max(MAX_MBIT - k * pct_used^2, EMERGENCY_MBIT)` — a
     downward parabola pinned to `rate(0%) = MAX_MBIT` and
     `rate(EMERGENCY_THRESHOLD_PCT%) = EMERGENCY_MBIT`, clamped flat at the
     floor beyond that point.
   - Apply the resulting rate to both the `IFACE` egress qdisc and the
     `ifb0` ingress qdisc via `tc qdisc replace` (upsert — safe to run
     repeatedly, no duplicate rules ever get created).

Each new day's quota is recomputed from whatever budget and days actually
remain — a lighter-than-average day leaves a bigger quota for the days
after it, a heavier one leaves less, so usage self-paces toward the end of
the month rather than resetting to a fixed split every midnight.

## Global variables

All are read as environment variables by `traffic-shaper.sh`, with the
defaults below baked in via `VAR="${VAR:-default}"` lines at the top of the
script. To change them permanently, edit those lines in
`/usr/local/bin/traffic-shaper.sh` on the VPS after install (systemd timers
don't carry env vars from your shell, so exporting them before running
`install-traffic-shaper.sh` only affects that one immediate first run —
edit the deployed script for a lasting change).

| Variable | Default | Meaning |
|---|---|---|
| `IFACE` | `ens3` | The public network interface to shape. Must be the interface that all VPN/proxy traffic actually egresses/ingresses through (check with `ip -4 addr show`). |
| `BUDGET_GIB` | `1024` | The provider's stated monthly traffic cap, in GiB (binary gigabytes, matches vnstat's units). Each day's quota is 95% of what's left of this budget (minus usage through yesterday) divided by the actual number of days left in the calendar month. |
| `MIN_MBIT` | `5` | Floor rate in Mbps used only by the manual force-floor override (below) — not used by the day-to-day threshold check. |
| `MAX_MBIT` | `500` | Rate in Mbps at 0% of today's quota used — the parabola's peak, effectively "unshaped" if your real link is slower than this. |
| `OVERRIDE_FILE` | `/etc/traffic-shaper-force-floor` | Path checked for the force-floor override, see below. |
| `EMERGENCY_THRESHOLD_PCT` | `85` | The percentage of today's (dynamically computed) quota at which the parabola reaches `EMERGENCY_MBIT` exactly; the rate stays clamped at the floor for any usage beyond this point. |
| `EMERGENCY_MBIT` | `3` | Rate in Mbps at and beyond `EMERGENCY_THRESHOLD_PCT` — the parabola's floor. |

## Force floor now

The adaptive rate is only as good as vnstat's byte count for today. If your
provider's dashboard disagrees with vnstat — e.g. vnstat's counter for
`IFACE` was reset partway through the day (check
`vnstat --json d -i IFACE | jq '.interfaces[0].created'`) — the computed
rate can be wildly wrong. For that case there's a manual override that pins
the rate to `MIN_MBIT` for the rest of today and then gets out of the way
automatically:

```bash
# force MIN_MBIT (5 Mbps) for the rest of today
VPN_VPS=<vps-ip> ./force-floor-on.sh

# clear it early, before midnight, if you want adaptive mode back sooner
ssh root@<vps-ip> rm -f /etc/traffic-shaper-force-floor
ssh root@<vps-ip> /usr/local/bin/traffic-shaper.sh
```

`force-floor-on.sh` reads the target host from `$VPN_VPS` and does exactly
those two SSH steps: write today's `YYYY-MM-DD` to the override file, then
run the shaper once immediately so the rate drops without waiting for the
next timer tick.

The file's content is the day it applies to (`YYYY-MM-DD`). Each run
compares that content against the current day — once the calendar rolls
over to the next day, the content no longer matches, the override is
ignored, and adaptive mode resumes with the fresh day's quota. Nothing needs
to be cleaned up manually for the normal case; the file can be left in place
indefinitely, it only ever forces the floor for the day it names.

## Install

On a fresh VPS (as root), from your machine:

```bash
scp -r vps_rate_limiter/ root@<vps-ip>:~/
ssh root@<vps-ip> './vps_rate_limiter/install-traffic-shaper.sh'
```

This installs `traffic-shaper.sh` to `/usr/local/bin/`, the systemd unit +
timer to `/etc/systemd/system/`, enables and starts the timer, and runs the
script once immediately so shaping is active without waiting 5 minutes.

Requires `vnstat`, `tc` (iproute2), `jq`, and `python3` to already be
installed and `vnstat` to already be tracking `IFACE` (it does this
automatically for any interface it sees traffic on — check with
`vnstat --iflist`).

## Manually updating the deployed script

After editing `traffic-shaper.sh` locally (e.g. changing one of the
defaults above), push it to the VPS without re-running the full installer:

```bash
# 1. Copy the new version to the VPS under a temp name, so a half-uploaded
#    or broken file never gets installed.
scp traffic-shaper.sh "root@$VPN_VPS:/usr/local/bin/traffic-shaper.sh.new"

# 2. Syntax-check it on the VPS before it's moved into place.
ssh "root@$VPN_VPS" bash -n /usr/local/bin/traffic-shaper.sh.new

# 3. Swap it into place: `install` copies the file AND sets its permissions
#    in one atomic step (unlike separate cp + chmod, there's no window
#    where the file exists with the wrong permissions). -m 755 makes it
#    owner rwx / group+other rx, which it must be since systemd executes
#    it directly. This overwrites the live script systemd actually runs
#    (same tool install-traffic-shaper.sh uses for the initial install).
#    Then clean up the temp file.
ssh "root@$VPN_VPS" install -m 755 /usr/local/bin/traffic-shaper.sh.new /usr/local/bin/traffic-shaper.sh
ssh "root@$VPN_VPS" rm -f /usr/local/bin/traffic-shaper.sh.new

# 4. Run it once immediately and check the result, instead of waiting up
#    to 5 minutes for the timer and hoping it worked.
ssh "root@$VPN_VPS" /usr/local/bin/traffic-shaper.sh
ssh "root@$VPN_VPS" tc qdisc show dev ens3
ssh "root@$VPN_VPS" tc qdisc show dev ifb0
```

`force-floor-on.sh` and the systemd unit/timer files rarely change, but if
you do edit them, redeploy the same way: `scp` to a temp path, then
`install -m 644` for `traffic-shaper.service`/`traffic-shaper.timer`
(followed by `systemctl daemon-reload`) or just `scp` directly over
`force-floor-on.sh`, which runs from your machine and isn't installed on
the VPS at all.

## Check status / logs

```bash
systemctl status traffic-shaper.timer
journalctl -u traffic-shaper -n 20 --no-pager
tc qdisc show dev ens3      # egress shaping
tc qdisc show dev ifb0      # ingress shaping
vnstat -i ens3 -d           # today's usage
```

Each run logs one line like:

```
traffic-shaper: used_today=196MiB daily_quota=32.60GiB rate=500.00mbit
```

`daily_quota` is recomputed every run from the remaining budget and
remaining days, so it will drift day to day as the month's actual usage
plays out — it is not a fixed fraction of `BUDGET_GIB` anymore.

## Temporarily disable / re-enable

```bash
# disable
systemctl stop traffic-shaper.timer
tc qdisc del dev ens3 root
tc qdisc del dev ens3 ingress

# re-enable
systemctl start traffic-shaper.timer   # next tick re-creates everything
# or run /usr/local/bin/traffic-shaper.sh once to apply immediately
```

## Using a different interface / provider

Some providers name the public NIC differently (e.g. `eth0`). Just set
`IFACE` — either `IFACE=eth0 ./install-traffic-shaper.sh` before first
install, or edit `IFACE` at the top of the deployed
`/usr/local/bin/traffic-shaper.sh` afterward.

## Known limitation

**A parabola's slope only ever accelerates, so it's still steepest right
near the threshold — this reduces the burst-window overshoot risk
substantially versus a flat step function, but doesn't eliminate it.**
Between 5-minute checks, usage can still climb further than the last-applied
rate assumed, and because the curve is compressed into just
`EMERGENCY_THRESHOLD_PCT`% of the day's usage range (85% by default), the
rate near that point is already dropping fast — but a large sustained burst
that starts well before the threshold and keeps going can still push actual
usage past where the curve expected it to be by the next tick.
`EMERGENCY_MBIT` (never zero) guarantees SSH stays reachable regardless, but
doesn't prevent overshoot on its own.

Mitigations if this matters for your provider's actual enforcement: lower
`MAX_MBIT` (caps the worst-case burst size directly), raise
`EMERGENCY_THRESHOLD_PCT` (spreads the same drop over more of the day,
flattening the curve throughout — see the trade-off noted for the parabola
family: pushing the target *later* makes it gentler, pushing it *earlier*
makes it steeper), or shorten the timer interval in `traffic-shaper.timer`
(smaller `OnUnitActiveSec` means less time between checks, at the cost of a
busier cron). An overage on one day does tighten the days that follow it
(the quota is derived from what's left of the monthly budget), so a single
bad day's overshoot gets absorbed by the rest of the month rather than
compounding indefinitely — but it does mean the days right after a burst
will run with a noticeably smaller quota.
