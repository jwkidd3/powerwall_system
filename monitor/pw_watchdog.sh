#!/usr/bin/env bash
# pw_watchdog.sh — link + proxy freshness watchdog for the air-gapped BGW2 monitor.
#
# Every INTERVAL seconds it records, for the Pi's gateway-AP link and the
# pypowerwall proxy:
#   - wlan0 RSSI + bitrate (the Wi-Fi link to TEG-1E1)
#   - ping to the gateway AP (reachability)
#   - proxy HTTP reachability (does the proxy answer at all)
#   - proxy DATA FRESHNESS (how old is last_communication_time in the aggregates)
# and SELF-HEALS: bounces wlan0 if the link/ping is down, restarts the proxy
# container if the link is fine but the data has gone stale. Every line lands in
# a CSV so you get before/after numbers and the exact cause next time the
# landing page "stops reflecting accurate data for a while."
#
# Run in the foreground to watch, or install the systemd unit (see bottom).

set -u

# ---- config (edit to match your box) ---------------------------------------
WLAN="${WLAN:-wlan0}"               # Pi interface joined to the gateway AP
NM_CONN="${NM_CONN:-teg}"           # NetworkManager connection name for TEG-1E1
GW_IP="${GW_IP:-192.168.91.1}"      # gateway AP address (TEDAPI endpoint)
PROXY="${PROXY:-http://localhost:8675}"   # pypowerwall proxy base URL
CONTAINER="${CONTAINER:-pypowerwall}"     # docker container name (docker ps to confirm)
INTERVAL="${INTERVAL:-30}"          # seconds between checks
STALE_SEC="${STALE_SEC:-120}"       # data older than this = stale -> restart proxy
HEAL_COOLDOWN="${HEAL_COOLDOWN:-300}"     # min seconds between heals of the same type
LOG="${LOG:-/var/log/pw_watchdog.csv}"
STATE_DIR="${STATE_DIR:-/run/pw_watchdog}"
# ----------------------------------------------------------------------------

mkdir -p "$(dirname "$LOG")" "$STATE_DIR" 2>/dev/null || true
if [[ ! -f "$LOG" ]]; then
  echo "ts,rssi_dbm,tx_mbit,link,ping_ms,proxy_http,data_age_s,action" >> "$LOG"
fi

log_line() { echo "$1" | tee -a "$LOG"; }

# cooldown helper: returns 0 (ok to heal) if last heal of this type was long ago
may_heal() {
  local kind="$1" f="$STATE_DIR/last_$1" now last
  now=$(date +%s)
  last=$(cat "$f" 2>/dev/null || echo 0)
  if (( now - last >= HEAL_COOLDOWN )); then
    echo "$now" > "$f"
    return 0
  fi
  return 1
}

bounce_wifi() {
  if command -v nmcli >/dev/null 2>&1; then
    nmcli connection down "$NM_CONN" >/dev/null 2>&1
    sleep 2
    nmcli connection up   "$NM_CONN" >/dev/null 2>&1
  else
    ip link set "$WLAN" down 2>/dev/null; sleep 2; ip link set "$WLAN" up 2>/dev/null
  fi
}

restart_proxy() {
  docker restart "$CONTAINER" >/dev/null 2>&1
}

# parse the oldest last_communication_time across meters -> age in seconds
# (uses system python3; no jq dependency). prints age or "nan".
data_age() {
  local body="$1"
  python3 - "$body" <<'PY' 2>/dev/null || echo "nan"
import sys, json, time
from datetime import datetime, timezone
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("nan"); sys.exit()
ages = []
now = time.time()
for v in d.values():
    if isinstance(v, dict):
        t = v.get("last_communication_time")
        if t:
            try:
                dt = datetime.fromisoformat(t.replace("Z", "+00:00"))
                if dt.tzinfo is None:
                    dt = dt.replace(tzinfo=timezone.utc)
                ages.append(now - dt.timestamp())
            except Exception:
                pass
print(int(max(ages)) if ages else "nan")
PY
}

echo "pw_watchdog: interval=${INTERVAL}s stale>${STALE_SEC}s log=$LOG  (Ctrl-C to stop)"

while true; do
  ts=$(date -Is)
  action="-"

  # --- Wi-Fi link ---
  linkout=$(iw dev "$WLAN" link 2>/dev/null)
  if echo "$linkout" | grep -q "Not connected"; then
    link="down"; rssi="nan"; tx="nan"
  else
    link="up"
    rssi=$(echo "$linkout" | awk '/signal:/{print $2}')
    tx=$(echo   "$linkout" | awk '/tx bitrate:/{print $3}')
    [[ -z "$rssi" ]] && rssi="nan"
    [[ -z "$tx"   ]] && tx="nan"
  fi

  # --- gateway reachability ---
  pingms=$(ping -c1 -W2 "$GW_IP" 2>/dev/null | awk -F'time=' '/time=/{print $2+0; exit}')
  [[ -z "$pingms" ]] && pingms="nan"

  # --- proxy HTTP + freshness ---
  body=$(curl -fsS --max-time 5 "$PROXY/api/meters/aggregates" 2>/dev/null)
  if [[ -n "$body" ]]; then
    proxy_http="ok"
    age=$(data_age "$body")
  else
    proxy_http="fail"; age="nan"
  fi

  # --- decide + heal ---
  if [[ "$link" == "down" || "$pingms" == "nan" ]]; then
    if may_heal wifi; then action="bounce_wifi"; bounce_wifi; fi
  elif [[ "$proxy_http" == "fail" ]] || { [[ "$age" != "nan" ]] && (( ${age%.*} > STALE_SEC )); }; then
    # link is fine but data is stale or proxy not answering -> proxy problem
    if may_heal proxy; then action="restart_proxy"; restart_proxy; fi
  fi

  log_line "$ts,$rssi,$tx,$link,$pingms,$proxy_http,$age,$action"
  sleep "$INTERVAL"
done
