#!/bin/zsh
# pw_control_test.sh -- verify whether the LOCAL gateway accepts control writes
# (operation mode + backup reserve). Safe: reposts the CURRENT values (no-op),
# nothing changes. The HTTP code tells you if HA can control the Powerwall locally.

GW=192.168.10.231
EMAIL="installer@yahoo.com"
PW="XJDYUSKMDK"

C=$(mktemp)
curl -sk -c "$C" -X POST https://$GW/api/login/Basic -H "Content-Type: application/json" \
  -d "{\"username\":\"installer\",\"email\":\"$EMAIL\",\"password\":\"$PW\",\"force_sm_off\":false}" >/dev/null

cur=$(curl -sk -b "$C" https://$GW/api/operation)
echo "current: $cur"

mode=$(echo "$cur" | python3 -c 'import sys,json;print(json.load(sys.stdin)["real_mode"])' 2>/dev/null)
res=$(echo "$cur"  | python3 -c 'import sys,json;print(json.load(sys.stdin)["backup_reserve_percent"])' 2>/dev/null)

if [ -z "$mode" ]; then
  echo "could not read current settings -- login/endpoint problem"; rm -f "$C"; exit 1
fi

echo "posting SAME values back (no-op): mode=$mode reserve=$res"
code=$(curl -sk -b "$C" -o /tmp/pwop.json -X POST https://$GW/api/operation \
  -H "Content-Type: application/json" \
  -d "{\"real_mode\":\"$mode\",\"backup_reserve_percent\":$res}" \
  -w "%{http_code}")
echo "response: $(head -c 300 /tmp/pwop.json)"
echo "HTTP=$code"
echo "-----------------------------------------------------------"
resp=$(cat /tmp/pwop.json 2>/dev/null)
case "$code" in
  200) echo "ACCEPTED -> gateway takes local writes. HA CAN control mode + reserve locally." ;;
  401|403) echo "AUTH REJECTED -> writes blocked for this login. Likely cloud-gated." ;;
  404|405) echo "NO ENDPOINT -> firmware removed local control. Isolated = no control path." ;;
  500)
    if echo "$resp" | grep -qi "synchronizer\|sitemanager"; then
      echo "ENDPOINT OK, SYSTEM NOT READY -> control path exists and takes your login,"
      echo "but no battery/synchronizer is online yet (pre-commissioning)."
      echo "Re-run after Phase 2 is up: HTTP=200 then confirms HA local control."
    else
      echo "Server error (500) -- paste the response line above for a read."
    fi ;;
  *) echo "Unexpected ($code) -- paste the response line above for a read." ;;
esac
rm -f "$C" /tmp/pwop.json
