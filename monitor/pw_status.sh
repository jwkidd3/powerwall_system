#!/bin/zsh
# pw_status.sh -- list every battery the gateway sees and its state,
# from /api/system_status (per-Powerwall) + /api/system_status/soe (aggregate).
#
# Usage:
#   ./pw_status.sh                 one read, print, exit
#   ./pw_status.sh -m [interval]   monitor: refresh every interval s (default 5)
#   ./pw_status.sh 5               (bare number = monitor interval)

GW=192.168.10.231
EMAIL="installer@yahoo.com"
PW="EBHNLAEBUH"

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

fetch() {  # $1 = api path -> stdout
  curl -sk -b "$C" --max-time 10 "https://$GW$1"
}

read_once() {
  SS=$(fetch /api/system_status)
  if [ -z "$SS" ] || [[ "$SS" != \{* ]]; then   # cookie expired -> re-login once
    login
    SS=$(fetch /api/system_status)
  fi
  SOE=$(fetch /api/system_status/soe)
  GRID=$(fetch /api/system_status/grid_status)
  PROB=$(fetch /api/troubleshooting/problems)
  SM=$(fetch /api/sitemaster)
  AGG=$(fetch /api/meters/aggregates)
  OP=$(fetch /api/operation)
  GWS=$(fetch /api/status)
  RATED=13500   # PW2 rated full-pack Wh, for degradation reference
  SS="$SS" SOE="$SOE" GRID="$GRID" PROB="$PROB" SM="$SM" AGG="$AGG" OP="$OP" GWS="$GWS" RATED="$RATED" python3 <<'PY'
import os, json
def j(s):
    try: return json.loads(s)
    except Exception: return {}
ss  = j(os.environ.get("SS",""))
soe = j(os.environ.get("SOE",""))
grid= j(os.environ.get("GRID",""))
prob= j(os.environ.get("PROB",""))
sm  = j(os.environ.get("SM",""))
agg = j(os.environ.get("AGG",""))
op  = j(os.environ.get("OP",""))
gws = j(os.environ.get("GWS",""))
rated = float(os.environ.get("RATED","13500"))

gw_ver = gws.get("version")            # gateway firmware (update target)
gw_hash = (gws.get("git_hash") or "")[:14]

# --- system/commissioning state ---
if sm:
    st_sm = sm.get("status","?")
    run   = sm.get("running")
    reboot= sm.get("can_reboot","")
    tesla = sm.get("connected_to_tesla")
    updating = "YES" if "update" in str(reboot).lower() else "no"
    print("System    : %s  running=%s  firmware-update-in-progress=%s" % (st_sm, run, updating))
    if gw_ver:
        print("Gateway FW : %s  (update target for all Powerwalls)" % gw_ver)
    iso = "ISOLATED (ok)" if tesla is False else ("CONNECTED TO TESLA (!)" if tesla else "?")
    print("Cloud link : connected_to_tesla=%s  -> %s" % (tesla, iso))
    if updating == "YES":
        print("            (gateway is syncing Powerwall firmware -- do NOT power down; charging waits)")

# --- operating mode / reserve ---
if op:
    print("Mode       : %s   backup_reserve=%s%%" % (op.get("real_mode","?"), op.get("backup_reserve_percent","?")))

# --- live power flow (meters/aggregates) ---
if agg:
    def mw(name):
        m = agg.get(name) or {}
        return m.get("instant_power")
    s_p = mw("site"); l_p = mw("load"); b_p = mw("battery"); so_p = mw("solar")
    def w(x): return ("%.0f W" % x) if isinstance(x,(int,float)) else "?"
    # site>0 = importing from grid; battery<0 = charging, >0 = discharging
    flow_grid = ""
    if isinstance(s_p,(int,float)):
        flow_grid = "  (import)" if s_p > 50 else ("  (EXPORT!)" if s_p < -50 else "  (idle)")
    flow_bat = ""
    if isinstance(b_p,(int,float)):
        flow_bat = "  (charging)" if b_p < -50 else ("  (discharging)" if b_p > 50 else "  (idle)")
    print("Power flow : grid %s%s   load %s   battery %s%s%s" % (
        w(s_p), flow_grid, w(l_p), w(b_p), flow_bat,
        ("   solar %s" % w(so_p)) if isinstance(so_p,(int,float)) and so_p else ""))
    site = agg.get("site") or {}
    exp = site.get("energy_exported"); imp = site.get("energy_imported")
    if isinstance(exp,(int,float)):
        print("Grid energy: imported %.1f kWh / exported %.1f kWh  %s" % (
            (imp or 0)/1000, exp/1000,
            "<- non-export: exported should stay ~0" ))

blocks = ss.get("battery_blocks") or []
if not blocks:
    print("no battery_blocks returned (none commissioned, or gateway not reporting)")
else:
    gs = grid.get("grid_status","?")
    agg = soe.get("percentage")
    tot_full = ss.get("nominal_full_pack_energy")
    tot_rem  = ss.get("nominal_energy_remaining")
    print("Powerwalls: %d   grid: %s   site SOE: %s%%   pack: %s / %s kWh" % (
        len(blocks), gs,
        ("%.1f" % agg) if isinstance(agg,(int,float)) else "?",
        ("%.1f" % (tot_rem/1000)) if isinstance(tot_rem,(int,float)) else "?",
        ("%.1f" % (tot_full/1000)) if isinstance(tot_full,(int,float)) else "?"))
    print("-"*78)
    for i,b in enumerate(blocks,1):
        sn   = (b.get("PackageSerialNumber") or "?")
        dis  = b.get("disabled_reason") or ""
        full = b.get("nominal_full_pack_energy") or 0
        rem  = b.get("nominal_energy_remaining") or 0
        soe_b= (rem/full*100) if full else 0
        pout = b.get("p_out") or 0
        vout = b.get("v_out") or 0
        iout = b.get("i_out") or 0
        ech  = b.get("energy_charged") or 0
        edis = b.get("energy_discharged") or 0
        bok  = b.get("backup_ready")
        soh  = (full/rated*100) if full else 0
        st   = "DISABLED (%s)" % dis if dis else "active"
        flow = "idle"
        if pout >  50: flow = "discharging"
        elif pout < -50: flow = "charging"
        ver  = b.get("version") or ""
        pinv = b.get("pinv_state") or "?"
        pgs  = b.get("pinv_grid_state") or "?"
        fout = b.get("f_out")
        offg = b.get("off_grid")
        fw_ok = " (==gateway)" if ver and gw_hash and ver.startswith(gw_hash[:len(ver)]) else (" (updating->%s)" % gw_hash if gw_hash else "")
        # surface fault-ish flags only when set
        flags = [k for k in ("wobble_detected","charge_power_clamped") if b.get(k)]
        if offg: flags.append("off_grid")
        print("PW%d" % i)
        print("  Serial    : %s" % sn)
        print("  State     : %s" % st)
        print("  Inverter  : %s / %s" % (pinv, pgs))
        print("  Ready     : backup_ready=%s" % bok)
        print("  Charge    : %.1f %% SOE" % soe_b)
        print("  Charging  : %s" % flow)
        print("  Power     : %.0f W" % pout)
        print("  Voltage   : %.1f V%s" % (vout, ("   freq %.2f Hz" % fout) if isinstance(fout,(int,float)) else ""))
        print("  Current   : %.1f A" % iout)
        print("  Firmware  : %s%s" % (ver or "?", fw_ok))
        print("  Capacity  : %.2f kWh full-pack  (%.0f%% of 13.5 rated)" % (full/1000, soh))
        print("  Lifetime  : charged %.0f kWh / discharged %.0f kWh" % (ech/1000, edis/1000))
        if flags:
            print("  FLAGS     : %s" % ", ".join(flags))
    al = prob.get("problems") if isinstance(prob, dict) else None
    print("-"*78)
    if al:
        print("ALERTS (%d):" % len(al))
        for a in al:
            print("  ! %s" % (a.get("name") or a.get("summary") or a))
    else:
        print("alerts: none")
PY
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
    frame=$(read_once)
    printf '\033[H'
    {
      printf '== Powerwall battery status ==  %s   (every %ss, Ctrl-C to stop)\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$INTERVAL"
      printf -- '------------------------------------------------------------------------------\n'
      printf '%s\n' "$frame"
    } | sed $'s/$/\033[K/'
    printf '\033[J'
    sleep "$INTERVAL"
  done
fi
