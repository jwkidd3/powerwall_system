#!/bin/zsh
# Probe the known Backup Gateway 2 local REST endpoints on the prod gateway.
# Logs in, hits each endpoint, labels + pretty-prints, and saves a timestamped snapshot.
# /api/devices/vitals is the firmware canary: JSON back = commissionable firmware; empty/403 = locked.

GW=192.168.10.231
EMAIL="installer@yahoo.com"
PW="XJDYUSKMDK"

COOKIE=$(mktemp)
OUT="gw_api_probe_$(date +%Y%m%d_%H%M%S).txt"

# reachable?
ver=$(curl -sk --max-time 5 https://$GW/api/status | python3 -c 'import sys,json; print(json.load(sys.stdin).get("version","?"))' 2>/dev/null)
if [ -z "$ver" ]; then echo "Gateway NOT reachable at $GW (powered? on network?)"; exit 1; fi
echo "Gateway $GW reachable — firmware: $ver" | tee "$OUT"

# login
curl -sk -c "$COOKIE" -X POST https://$GW/api/login/Basic -H "Content-Type: application/json" \
  -d "{\"username\":\"installer\",\"email\":\"$EMAIL\",\"password\":\"$PW\",\"force_sm_off\":false}" >/dev/null

ENDPOINTS=(
  /api/status
  /api/sitemaster
  /api/system_status/soe
  /api/system_status/grid_status
  /api/system_status
  /api/meters/aggregates
  /api/meters/status
  /api/operation
  /api/powerwalls
  /api/site_info
  /api/site_info/site_name
  /api/customer/registration
  /api/networks
  /api/networks/conn_tests
  /api/system/networks
  /api/system/update/status
  /api/devices/vitals
  /api/troubleshooting/problems
  /api/solars
  /api/generators
)

for ep in $ENDPOINTS; do
  echo "\n========== $ep ==========" | tee -a "$OUT"
  body=$(curl -sk -b "$COOKIE" --max-time 8 "https://$GW$ep" 2>/dev/null)
  if [ -z "$body" ]; then
    echo "(empty response)" | tee -a "$OUT"
  else
    echo "$body" | python3 -m json.tool 2>/dev/null | tee -a "$OUT" || echo "$body" | tee -a "$OUT"
  fi
done

# ---- Focused meter check for Neurio CT verification -------------------------
# site sign convention: positive = IMPORT (from grid), negative = EXPORT.
# With no battery discharging, site should NEVER be negative -- if it is, the
# metering is wrong. Use this readout for the known-load tests.
echo "\n########## METER VERIFICATION (site) ##########" | tee -a "$OUT"
curl -sk -b "$COOKIE" --max-time 8 "https://$GW/api/meters/aggregates" 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("  meters/aggregates: no/invalid JSON (meter configured in the wizard yet?)")
    sys.exit()
if not isinstance(d, dict):
    print("  unexpected response:", d); sys.exit()

def show(name, m):
    if not isinstance(m, dict):
        return
    p  = m.get("instant_power")
    pa = m.get("real_power_a")
    pb = m.get("real_power_b")
    v  = m.get("instant_average_voltage")
    ia = m.get("i_a_current")
    ib = m.get("i_b_current")
    n  = m.get("num_meters_aggregated")
    print("  [%s]" % name)
    if p is not None:
        flow = "IMPORT (from grid)" if p > 0.5 else ("EXPORT (to grid!)" if p < -0.5 else "balanced ~0")
        print("    instant_power : %9.1f W   -> %s" % (p, flow))
    if pa is not None or pb is not None:
        print("    per-leg real  : A=%s W  B=%s W" % (
            ("%.1f" % pa) if pa is not None else "?",
            ("%.1f" % pb) if pb is not None else "?"))
    if v is not None:
        print("    avg voltage   : %.1f V" % v)
    if ia is not None or ib is not None:
        print("    per-leg amps  : A=%s  B=%s" % (
            ("%.2f" % ia) if ia is not None else "?",
            ("%.2f" % ib) if ib is not None else "?"))
    if n is not None:
        print("    CTs aggregated: %s" % n)

for key in ("site", "load", "battery", "solar"):
    if key in d:
        show(key, d[key])

site = d.get("site") if isinstance(d.get("site"), dict) else None
if site and site.get("instant_power") is not None and site["instant_power"] < -0.5:
    print("\n  ** WARNING: site is NEGATIVE with no generation = METERING ERROR **")
print("\n  Known-load test cheat sheet:")
print("    add a resistive load (heater/kettle):")
print("      site goes UP and stays POSITIVE -> correct")
print("      site goes DOWN / NEGATIVE        -> a CT is REVERSED (flip it)")
print("      site rises ~HALF expected watts  -> a leg/CT is missing")
print("    240V resistive load: A and B legs should be ~equal and both POSITIVE")
' | tee -a "$OUT"

rm -f "$COOKIE"
echo "\nSaved to $OUT"
