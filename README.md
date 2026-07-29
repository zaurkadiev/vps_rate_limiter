# vps_rate_limiter

Adaptive bandwidth shaper that keeps a VPS under a monthly traffic cap
(combined in+out) by throttling the NIC harder as usage approaches budget —
while never throttling below a floor that keeps SSH usable.

## Why this exists

Some VPS providers bill or cut you off after a fixed amount of monthly
traffic (e.g. 1024 GiB). If you run a VPN or proxy on the box, a burst of
client usage early in the month can blow through that budget before the
month ends. This tool continuously recomputes "how fast can I go right now
without exceeding the budget by month-end" and applies that as a hard rate
limit on the network interface — both directions, so it also covers
inbound traffic (e.g. downloads relayed through a VPN/proxy count as
*inbound* to the VPS first).

It intentionally never throttles below `MIN_MBIT` (default 5 Mbps), so you
can always SSH in and fix things even if the month's budget is already
exhausted. That means it's possible to slightly exceed the stated budget in
a worst case (heavy usage right up to month-end) — this is a deliberate
trade-off, not a bug. The `MARGIN_PCT` setting (below) is the mitigation.

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
   - Read this calendar month's `rx+tx` byte total for `IFACE` from
     `vnstat --json m` (vnstat is already tracking this; no separate
     counter needed).
   - Compute `remaining_budget = BUDGET_GIB * (1 - MARGIN_PCT/100) - used`.
   - Compute `remaining_seconds` = time left until the 1st of next month,
     from the system clock (system timezone must match how you think about
     "the month" — see `MonthRotate` in `/etc/vnstat.conf`, default is
     calendar-month-in-local-time, which is what this script assumes).
   - `target_rate = remaining_budget * 8 / remaining_seconds` (bits/sec).
   - Clamp `target_rate` to `[MIN_MBIT, MAX_MBIT]` and apply it to both the
     `IFACE` egress qdisc and the `ifb0` ingress qdisc via
     `tc qdisc replace` (upsert — safe to run repeatedly, no duplicate
     rules ever get created).

This makes the shaper self-correcting: if usage is running ahead of an even
pace, the rate drops; if usage is running behind pace (e.g. quiet week), the
rate rises back up (up to `MAX_MBIT`). It re-evaluates from scratch every
run, so no state file is needed beyond what vnstat already persists.

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
| `BUDGET_GIB` | `1024` | The provider's stated monthly traffic cap, in GiB (binary gigabytes, matches vnstat's units). |
| `MARGIN_PCT` | `5` | Safety margin subtracted from `BUDGET_GIB` before computing the target rate, to leave headroom for the "floor rate at month-end" overage risk described above. `5` means the shaper actually paces itself to 95% of `BUDGET_GIB`. |
| `MIN_MBIT` | `5` | Floor rate in Mbps. Never shapes below this, regardless of how far over budget usage is — this is what guarantees SSH keeps working. |
| `MAX_MBIT` | `1000` | Ceiling rate in Mbps. Effectively "unshaped" if your real link is slower than this; raise it if the VPS has faster real bandwidth and you want the shaper to allow bursting to full speed when budget is plentiful. |
| `OVERRIDE_FILE` | `/etc/traffic-shaper-force-floor` | Path checked for the force-floor override, see below. |

## Force floor now

The adaptive rate is only as good as vnstat's byte count for the current
month. If your provider's dashboard disagrees with vnstat — e.g. vnstat's
counter for `IFACE` was reset partway through the month (check
`vnstat --json m -i IFACE | jq '.interfaces[0].created'`; if that date is
mid-month, vnstat has no visibility into traffic before it) — the computed
rate can be wildly wrong. For that case there's a manual override that pins
the rate to `MIN_MBIT` for the rest of the current calendar month and then
gets out of the way automatically:

```bash
# force MIN_MBIT (5 Mbps) for the rest of this calendar month
VPN_VPS=<vps-ip> ./force-floor-on.sh

# clear it early, before month-end, if you want adaptive mode back sooner
ssh root@<vps-ip> rm -f /etc/traffic-shaper-force-floor
ssh root@<vps-ip> /usr/local/bin/traffic-shaper.sh
```

`force-floor-on.sh` reads the target host from `$VPN_VPS` and does exactly
those two SSH steps: write today's `YYYY-MM` to the override file, then run
the shaper once immediately so the rate drops without waiting for the next
timer tick.

The file's content is the month it applies to (`YYYY-MM`). Each run
compares that content against the current month — once the calendar rolls
over, the content no longer matches, the override is ignored, and adaptive
mode resumes with the fresh month's budget. Nothing needs to be cleaned up
manually for the normal case; the file can be left in place indefinitely,
it only ever forces the floor for the month it names.

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

## Check status / logs

```bash
systemctl status traffic-shaper.timer
journalctl -u traffic-shaper -n 20 --no-pager
tc qdisc show dev ens3      # egress shaping
tc qdisc show dev ifb0      # ingress shaping
vnstat -i ens3 -m           # current month's usage
```

Each run logs one line like:

```
traffic-shaper: used=196MiB budget=1024GiB margin=5% rate=1000.00mbit
```

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

Because the rate never drops below `MIN_MBIT`, a burst of usage very close
to month-end can still push total traffic slightly past `BUDGET_GIB`. This
is intentional — the alternative (a hard cutoff) would lock you out over
SSH too. `MARGIN_PCT` is the safety valve: raise it if you want more
headroom against this edge case, at the cost of more aggressive throttling
earlier in the month.
