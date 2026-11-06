#!/bin/zsh
# Neurio W2 soak test -- polls the Site meter over time to confirm the RS-485
# link is solid (no intermittent CRC errors) and the CTs track load.
# Watches VAM6351AB1657 only. Ctrl-C to stop; a summary prints on exit.
#
# Usage:  ./neurio_soak.sh [interval_sec] [duration_min]
#   interval default 2s, duration default 15 min (0 = run until Ctrl-C)

GW=192.168.10.231
EMAIL="installer@yahoo.com"
PW="XJDYUSKMDK"
SERIAL="VAM6351AB1657"

INTERVAL=${1:-2}
DUR_MIN=${2:-15}

COOKIE=$(mktemp)
LOG="neurio_soak_$(date +%Y%m%d_%H%M%S).log"

# login
curl -sk -c "$COOKIE" -X POST https://$GW/api/login/Basic -H "Content-Type: application/json" \
  -d "{\"username\":\"installer\",\"email\":\"$EMAIL\",\"password\":\"$PW\",\"force_sm_off\":false}" >/dev/null

ver=$(curl -sk --max-time 5 https://$GW/api/status | python3 -c 'import sys,json;print(json.load(sys.stdin).get("version","?"))' 2>/dev/null)
if [ -z "$ver" ]; then echo "Gateway NOT reachable at $GW"; rm -f "$COOKIE"; exit 1; fi

echo "Neurio soak test -> $SERIAL on $GW (fw $ver)"
echo "interval ${INTERVAL}s, duration ${DUR_MIN} min (0 = until Ctrl-C)"
echo "logging to $LOG"
echo "-----------------------------------------------------------"

# counters live in temp files so the Python summary can read them
STATE=$(mktemp)
echo "0 0 0 0 0" > "$STATE"   # polls good crc empty maxW

end=0
if [ "$DUR_MIN" -gt 0 ]; then end=$(( $(date +%s) + DUR_MIN*60 )); fi

summary(){
  read polls good crc empty maxW < "$STATE"
  echo "\n-----------------------------------------------------------"
  echo "SOAK SUMMARY"
  echo "  polls total     : $polls"
  echo "  good reads      : $good"
  echo "  CRC errors      : $crc"
  echo "  empty/stripped  : $empty"
  echo "  peak site watts : $maxW"
  if [ "$crc" -eq 0 ] && [ "$good" -gt 0 ]; then
    echo "  RESULT: link SOLID -- no CRC errors over $polls polls."
  elif [ "$crc" -gt 0 ]; then
    echo "  RESULT: ** $crc CRC error(s) ** -- link marginal. Reseat HI/LO, land shield, increase separation."
  else
    echo "  RESULT: no good reads -- check meter config / power."
  fi
  echo "  full log: $LOG"
  rm -f "$COOKIE" "$STATE"
  exit 0
}
trap summary INT TERM

while true; do
  now=$(date +%s)
  if [ "$DUR_MIN" -gt 0 ] && [ "$now" -ge "$end" ]; then summary; fi

  body=$(curl -sk -b "$COOKIE" --max-time 8 "https://$GW/api/meters/readings" 2>/dev/null)
  line=$(echo "$body" | SERIAL="$SERIAL" python3 -c '
import sys, json, os, time
serial = os.environ["SERIAL"]
stamp = time.strftime("%H:%M:%S")
try:
    m = json.load(sys.stdin)[serial]
except Exception:
    print("EMPTY|%s (no meter in response)" % stamp); sys.exit()
err = m.get("error","")
d = m.get("data",{})
cts = [c for c in d.get("cts",[]) if c.get("ct") in (1,2)]
if err and "crc" in err.lower():
    print("CRC|%s  crc error" % stamp); sys.exit()
if not cts or all(c.get("i_A",0)==0 and c.get("v_V",0)==0 for c in cts):
    print("EMPTY|%s (stripped poll)" % stamp); sys.exit()
tot = sum(c.get("p_W",0) for c in cts)
parts = "  ".join("CT%d %6.1fV %8.1fW %6.2fA" % (c["ct"],c["v_V"],c["p_W"],c["i_A"]) for c in cts)
print("GOOD|%s  %s  | site %7.1f W  %.2f Hz|%.1f" % (stamp, parts, tot, d.get("f_Hz",0), tot))
')

  tag=${line%%|*}
  rest=${line#*|}
  # strip trailing |<watts> payload for GOOD lines
  disp=${rest%|*}
  watts=${rest##*|}

  read polls good crc empty maxW < "$STATE"
  polls=$((polls+1))
  case "$tag" in
    GOOD)
      good=$((good+1))
      # integer-compare peak watts
      w=${watts%.*}; [ -z "$w" ] && w=0
      [ "$w" -gt "$maxW" ] 2>/dev/null && maxW=$w
      echo "$disp" | tee -a "$LOG" ;;
    CRC)
      crc=$((crc+1))
      echo ">>> $disp" | tee -a "$LOG" ;;
    EMPTY)
      empty=$((empty+1))
      echo "    $disp" | tee -a "$LOG" ;;
  esac
  echo "$polls $good $crc $empty $maxW" > "$STATE"

  sleep "$INTERVAL"
done
