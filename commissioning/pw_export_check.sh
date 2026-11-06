#!/bin/zsh
# ============================================================================
# DONOR / OLDER-FIRMWARE ONLY (annotated 2026-11-05).
# Uses the old routed-LAN /api/ REST surface, which Tesla removed on FW 26.x.
# It will NOT work against the live 26.34.1 gateway (TEDAPI-via-AP 192.168.91.1
# is the only local path now). Keep it for commissioning the eBay DONOR gateway
# while it's still on older firmware. Before use: update GW= to the donor's IP
# and PW= to the donor's installer password (below are old Gateway-A values).
# ============================================================================
# pw_export_check.sh -- confirm the gateway's grid import/export limits.
# Export limit = min_site_meter_power_kW: 0 = non-export, negative = export allowed.
# (These are set in the Commissioning Wizard; this script only reads/confirms them.)

GW=192.168.10.231
EMAIL="installer@yahoo.com"
PW="EBHNLAEBUH"

C=$(mktemp)
curl -sk -c "$C" -X POST https://$GW/api/login/Basic -H "Content-Type: application/json" \
  -d "{\"username\":\"installer\",\"email\":\"$EMAIL\",\"password\":\"$PW\",\"force_sm_off\":false}" >/dev/null

SI=$(curl -sk -b "$C" https://$GW/api/site_info)
SI="$SI" python3 <<'PY'
import os, json, sys
try:
    d = json.loads(os.environ.get("SI",""))
except Exception:
    print("could not read site_info (login/endpoint problem)"); sys.exit(1)
imp = d.get("max_site_meter_power_kW")
exp = d.get("min_site_meter_power_kW")
if exp is None:
    print("site_info returned no power-limit fields -- not logged in, or pre-commission")
    sys.exit(1)
print("Import limit : %s kW" % imp)
print("Export limit : %s kW  (min_site_meter_power_kW)" % exp)
if exp == 0:
    print("NON-EXPORT   : PASS (export pinned to 0 kW)")
elif exp is not None and exp < 0:
    print("NON-EXPORT   : NOT PINNED -- export uncapped (%s). No-solar system can't export in" % exp)
    print("               practice, but it is not explicitly set to 0 for the Oncor record.")
rm = d.get("grid_code", {}).get("grid_code")
if rm: print("Grid code    : %s" % rm)
PY
rm -f "$C"
