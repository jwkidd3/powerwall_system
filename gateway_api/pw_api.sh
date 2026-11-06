#!/bin/zsh
# pw_api.sh -- complete, VERIFIED reference + runner for the Tesla Backup Gateway 2
# local REST API.  Gateway 1232100-00-H @ 9603 Trailview, firmware 23.36.100 004d11eb
# (pre-TEDAPI local API).  Every endpoint below was classified by live probe on this gateway:
#   200 = GET works   405 = exists but write-only (POST)   202 = action accepted   404 = absent
#
# USAGE
#   ./pw_api.sh                      print this whole API reference
#   ./pw_api.sh <path>               GET one endpoint, pretty-printed
#   ./pw_api.sh vitals               active alarm codes from /api/devices/vitals (protobuf)
#   ./pw_api.sh post <path> '<json>' POST a body  (WRITE / state-changing)
#   ./pw_api.sh all                  dump every READ-ONLY GET endpoint in one pass
#   ./pw_api.sh discover             re-probe GET status per endpoint (safe; excludes action-triggers)
#
# SAFETY: POST writes + the ACTION endpoints change state. "all"/"discover" only hit safe GETs.
#         /api/system/update triggers a firmware update attempt EVEN ON GET -- never touch it.

# ---- gateway + credentials ----
GW=192.168.10.98
EMAIL="installer@yahoo.com"
PASS="ESCPRNPWAS"
USER="installer"
CJAR=$(mktemp)

login() {
  curl -sk -c "$CJAR" -X POST "https://$GW/api/login/Basic" -H "Content-Type: application/json" \
    -d "{\"username\":\"$USER\",\"email\":\"$EMAIL\",\"password\":\"$PASS\",\"force_sm_off\":false}" >/dev/null
}
get() {
  local out; out=$(curl -sk -b "$CJAR" --max-time 10 "https://$GW$1")
  [[ "$out" != \{* && "$out" != \[* ]] && { login; out=$(curl -sk -b "$CJAR" --max-time 10 "https://$GW$1"); }
  echo "$out" | python3 -m json.tool 2>/dev/null || echo "$out"
}
post() {  # $1=path  $2=json body   -- WRITE / STATE-CHANGING
  curl -sk -b "$CJAR" -X POST --max-time 15 -H "Content-Type: application/json" \
    -d "${2:-{}}" "https://$GW$1" | python3 -m json.tool 2>/dev/null \
    || curl -sk -b "$CJAR" -X POST -H "Content-Type: application/json" -d "${2:-{}}" "https://$GW$1"
}
vitals() { curl -sk -b "$CJAR" --max-time 12 "https://$GW/api/devices/vitals" \
    | strings | grep -oE '[A-Za-z]+_[awe][0-9]{2,3}[A-Za-z_]*' | sort | uniq -c ; }

# ========================= VERIFIED GET ENDPOINTS (HTTP 200) =========================
READONLY=(
  # --- gateway / sitemaster state ---
  /api/status                            # gateway version, git_hash, din, uptime, sync_type
  /api/sitemaster                        # status, running, connected_to_tesla, can_reboot
  /api/operation                         # real_mode, backup_reserve_percent, freq-shift
  # --- system status / energy ---
  /api/system_status                     # battery_blocks[], available_blocks, updating, OpSeqState, island
  /api/system_status/soe                 # aggregate state-of-energy %
  /api/system_status/grid_status         # grid connected/islanded, grid_services_active
  /api/system_status/grid_faults         # grid fault event history
  # --- powerwalls ---
  /api/powerwalls                        # per-PW commissioning_diagnostic + update_diagnostic, in_config
  /api/powerwalls/status                 # enumerating, updating, running_phase_detection, grid_qualifying
  # --- meters ---
  /api/meters                            # configured meter list / mapping
  /api/meters/aggregates                 # site/load/battery/solar instant_power + lifetime energy
  /api/meters/site                       # site (Neurio) meter detail + CTs
  /api/meters/solar                      # solar meter detail
  /api/meters/status                     # meter communication status
  /api/meters/readings                   # raw per-meter readings
  /api/synchrometer/ct_voltage_references # CT voltage refs (polarity / phase check)
  # --- config / commissioning ---
  /api/config                            # vin / din
  /api/config/completed                  # commission_count, version, up_time_seconds, teg_type
  /api/installer                         # verified_config, run_sitemaster, company, location, wiring
  /api/customer                          # registration flags
  /api/customer/registration             # registered, timed_out_registration
  /api/site_info                         # grid_code, kWh/kW caps, grid_phase_setting, net_meter_mode
  /api/site_info/site_name               # site name + timezone
  /api/auth/toggle/supported             # whether auth-toggle is supported
  # --- devices / diagnostics / solar / network ---
  /api/devices/vitals                    # PROTOBUF: per-device vitals + ALARM CODES (use: ./pw_api.sh vitals)
  /api/solars                            # solar inverter list (empty = no solar)
  /api/solar_powerwall                   # combined solar+powerwall status
  /api/generators                        # generator config (empty = none)
  /api/system/testing                    # system test status / results
  /api/system/update/status              # gateway OS update state / target version (safe GET)
  /api/troubleshooting/problems          # active problems list
  /api/networks                          # network interfaces + Tesla/internet connectivity
)

# ===================== WRITE / ACTION ENDPOINTS (STATE-CHANGING) =====================
# --- CONFIRMED POSTs (payloads verified on this gateway) ---
#   POST /api/login/Basic   {"username":"installer","email":"<e>","password":"<p>","force_sm_off":false}
#   POST /api/operation     {"real_mode":"backup","backup_reserve_percent":20}        # set mode + reserve
#   POST /api/powerwalls/phase_detection  {}                                          # trigger (needs system STOPPED)
#
# --- WRITE-ONLY (GET returns 405 -> exists, POST to set) ---
#   POST /api/site_info/grid_code  {"grid_code":"60Hz_240V_s_SMC_IEEE1547-2018_Category-III"}  # set grid code
#   POST /api/powerwalls/vitals    (405 on GET; method-restricted)
#
# --- READ+WRITE config/commissioning (GET 200 to read; POST to write; payloads are WIZARD-DRIVEN,
#     verify before sending -- a wrong body can misconfigure the stack) ---
#   POST /api/config                 # write gateway config
#   POST /api/config/completed       # finalize / write commissioning config
#   POST /api/meters/site            # configure site (Neurio) CT meter  (location/CTs/inverted flags)
#   POST /api/meters/solar           # configure solar CT meter
#   POST /api/meters                 # meter mapping
#   POST /api/site_info              # site parameters (caps, net-meter mode, phase)
#   POST /api/site_info/site_name    {"site_name":"KHome","timezone":"America/Chicago"}
#   POST /api/installer              # installer/site params (location, wiring, backup_configuration)
#   POST /api/customer               # customer flags (marketing/privacy/etc.)
#   POST /api/networks               # network interface config (wifi/ethernet)
#   POST /api/system/testing         # start/run a system test (meter/inverter/charge)
#   POST /api/troubleshooting/problems  # (clear/ack path)
#
# --- ACTION GETs (execute ON GET -- run by hand, never in all/discover) ---
#   GET  /api/sitemaster/run         # start sitemaster
#   GET  /api/sitemaster/stop        # stop sitemaster
#   GET  /api/logout                 # end session
#
# --- NOT CLIENT-WRITABLE on this firmware ---
#   POST /api/customer/registration  # 405 (registration is server/Tesla-driven, not client)
#
# --- !!! DO NOT TOUCH !!! ---
#   /api/system/update              # ANY method triggers a firmware-update attempt (GET returns 202).
#                                     == the TEDAPI/26.34 risk that kills local API. Never probe/fire.
#                                     (It errors harmlessly only because the CDN is firewalled + isolated.)

# candidates for "discover" -- safe GETs only; explicitly EXCLUDES /api/system/update
DISCOVER=( "${READONLY[@]}"
  /api/site_info/grid_code /api/powerwalls/vitals          # expect 405 (write-only)
  /api/system/info /api/system/networks /api/gridstatus    # expect 404
)

login
case "$1" in
  "" )
    echo "Tesla BGW2 local API  @ https://$GW   user: $USER   fw: 23.36.100"
    echo "Commands:  <path> | post <path> '<json>' | vitals | all | discover"
    echo
    echo "== READ (GET, verified 200) =="
    for e in "${READONLY[@]}"; do echo "  GET  $e"; done
    echo
    echo "== WRITE (POST / state-changing) =="
    echo "  CONFIRMED:"
    echo "    post /api/operation '{\"real_mode\":\"backup\",\"backup_reserve_percent\":20}'"
    echo "    post /api/powerwalls/phase_detection '{}'"
    echo "  WRITE-ONLY (GET=405):"
    echo "    post /api/site_info/grid_code '{\"grid_code\":\"60Hz_240V_s_SMC_IEEE1547-2018_Category-III\"}'"
    echo "    post /api/powerwalls/vitals '<json>'"
    echo "  CONFIG/COMMISSIONING (verify payload first):"
    echo "    post /api/config            post /api/config/completed"
    echo "    post /api/meters/site       post /api/meters/solar        post /api/meters"
    echo "    post /api/site_info         post /api/site_info/site_name"
    echo "    post /api/installer         post /api/customer            post /api/networks"
    echo "    post /api/system/testing    post /api/troubleshooting/problems"
    echo "  NOT WRITABLE: /api/customer/registration (405, server-driven)"
    echo
    echo "== ACTION GETs (execute; run by hand) =="
    echo "  /api/sitemaster/run (start)   /api/sitemaster/stop (stop)   /api/logout"
    echo
    echo "== !!! DO NOT TOUCH !!! =="
    echo "  /api/system/update  -- ANY method starts a firmware update (GET=202) = TEDAPI risk"
    echo
    echo "ALARM CODES: ./pw_api.sh vitals     FULL DUMP: ./pw_api.sh all     RE-PROBE: ./pw_api.sh discover"
    ;;
  vitals ) echo "== active alarm codes =="; vitals ;;
  all )
    for e in "${READONLY[@]}"; do echo "===== $e ====="; get "$e"; echo; done
    echo "===== alarm codes (vitals) ====="; vitals ;;
  discover )
    echo "live HTTP status (200=ok, 405=write-only, 404=absent):"
    for p in "${DISCOVER[@]}"; do
      code=$(curl -sk -b "$CJAR" -o /dev/null -w "%{http_code}" --max-time 8 "https://$GW$p")
      printf '  %-4s %s\n' "$code" "$p"
    done | sort ;;
  post )
    if [[ -z "$2" ]]; then echo "usage: ./pw_api.sh post <path> '<json-body>'"
    elif [[ "$2" == "/api/system/update"* ]]; then echo "REFUSED: $2 triggers a firmware update (TEDAPI risk)."
    else echo "POST $2  body=${3:-{}}"; post "$2" "$3"; fi ;;
  * )
    if [[ "$1" == "/api/system/update"* || "$1" == "/api/sitemaster/run" || "$1" == "/api/sitemaster/stop" ]]; then
      echo "REFUSED: $1 is state-changing. Run it deliberately with curl if you really mean to."
    else get "$1"; fi ;;
esac
rm -f "$CJAR"
