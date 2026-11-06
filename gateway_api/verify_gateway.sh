#!/bin/zsh
# ============================================================================
# DONOR / OLDER-FIRMWARE ONLY (annotated 2026-11-05).
# Uses the routed-LAN /api/ REST surface, which Tesla removed on FW 26.x. It does
# NOT work against the live 26.34.1 gateway (TEDAPI-via-AP 192.168.91.1 only).
# Keep it for bringing up / probing the eBay DONOR gateway on older firmware;
# update GW= to the donor's IP and the installer password before use.
# ============================================================================
# Verify the Tesla Backup Gateway 2 has no path to Tesla / the internet.
# Logs in, confirms reachability, prints connection status + per-interface flags.

GW=192.168.10.231
EMAIL="installer@yahoo.com"
PW="XJDYUSKMDK"

ver=$(curl -sk --max-time 5 https://$GW/api/status | python3 -c 'import sys,json; print(json.load(sys.stdin).get("version","?"))' 2>/dev/null)
if [ -z "$ver" ]; then echo "Gateway NOT reachable at $GW (powered? on network?)"; exit 1; fi
echo "Gateway reachable — firmware: $ver"

curl -sk -c /tmp/tcookie -X POST https://$GW/api/login/Basic -H "Content-Type: application/json" \
  -d "{\"username\":\"installer\",\"email\":\"$EMAIL\",\"password\":\"$PW\",\"force_sm_off\":false}" >/dev/null

echo "========== TESLA CONNECTION STATUS =========="
curl -sk -b /tmp/tcookie https://$GW/api/sitemaster 2>/dev/null | python3 -c '
import sys,json
d=json.load(sys.stdin)
if isinstance(d,dict) and "connected_to_tesla" in d:
    print("Connected to Tesla NOW : %s" % d.get("connected_to_tesla"))
    print("Sitemaster status      : %s" % d.get("status"))
else:
    print("sitemaster error/auth:", d)'
echo
echo "Per-interface (last check):"
curl -sk -b /tmp/tcookie https://$GW/api/networks 2>/dev/null | python3 -c '
import sys,json
d=json.load(sys.stdin)
if not isinstance(d,list):
    print("  networks error/auth:", d); sys.exit()
print("  %-34s%-8s%-12s%s" % ("INTERFACE","ACTIVE","LAST TESLA","LAST NET"))
for n in d:
    print("  %-34s%-8s%-12s%s" % (n.get("network_name"), n.get("active"), n.get("lastTeslaConnected"), n.get("lastInternetConnected")))'
echo "============================================="
