#!/bin/zsh
# neurio_read.sh -- live read of the Neurio + internal meters + grid/island
# via /api/devices/vitals (fast, non-blocking protobuf; same source as the web UI).
# Needs vitals_decode.py alongside it.
#
# Usage:
#   ./neurio_read.sh                 one read, print, exit
#   ./neurio_read.sh -m [interval]   monitor: refresh every interval s (default 5)
#   ./neurio_read.sh 5               (also works: bare number = monitor interval)

GW=192.168.10.231
EMAIL="installer@yahoo.com"
PW="XJDYUSKMDK"
HERE=${0:A:h}

INTERVAL=""
case "$1" in
  -m|--monitor) INTERVAL=${2:-5} ;;
  ''|*[!0-9]*)  INTERVAL="" ;;      # no arg or non-numeric -> single read
  *)            INTERVAL=$1 ;;      # bare number -> monitor at that interval
esac

login() {
  curl -sk -c "$C" -X POST https://$GW/api/login/Basic -H "Content-Type: application/json" \
    -d "{\"username\":\"installer\",\"email\":\"$EMAIL\",\"password\":\"$PW\",\"force_sm_off\":false}" >/dev/null
}

read_once() {
  BIN=$(mktemp)
  curl -sk -b "$C" --max-time 10 "https://$GW/api/devices/vitals" -o "$BIN"
  if [ ! -s "$BIN" ]; then          # cookie may have expired -- re-login once
    login
    curl -sk -b "$C" --max-time 10 "https://$GW/api/devices/vitals" -o "$BIN"
  fi
  if [ -s "$BIN" ]; then
    python3 "$HERE/vitals_decode.py" < "$BIN"
  else
    echo "no response from /api/devices/vitals"
  fi
  rm -f "$BIN"
}

C=$(mktemp)
login

if [ -z "$INTERVAL" ]; then
  read_once
  rm -f "$C"
else
  printf '\033[?25l'                                  # hide cursor
  trap 'printf "\033[?25h"; clear; rm -f "$C"; exit 0' INT TERM
  clear
  while true; do
    # fetch into a buffer FIRST, then repaint in one shot -- no blank flash
    frame=$(read_once)
    printf '\033[H'                                   # cursor home (no clear)
    {
      printf '== Powerwall site meters ==  %s   (every %ss, Ctrl-C to stop)\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$INTERVAL"
      printf -- '-----------------------------------------------------------------\n'
      printf '%s\n' "$frame"
    } | sed $'s/$/\033[K/'                             # clear each line's old tail
    printf '\033[J'                                    # clear any leftover lines below
    sleep "$INTERVAL"
  done
fi
