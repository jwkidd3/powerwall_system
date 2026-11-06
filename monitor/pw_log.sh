#!/bin/zsh
# pw_log.sh -- real-time EVENT log for the gateway + Powerwalls.
# Polls the gateway every INTERVAL seconds and prints a timestamped line
# ONLY when a watched value changes (state machine, not a dashboard).
# Also appends every line to pw_events.log.
#
# Usage:
#   ./pw_log.sh            poll every 3s
#   ./pw_log.sh 5          poll every 5s
#
# Watched: block-update, cloud-isolation, island state, mode/reserve,
#          per-PW inverter state / backup_ready / firmware / SOE / power,
#          grid-load-battery power flow, grid export, alerts.

GW=192.168.10.231
EMAIL="installer@yahoo.com"
PW="EBHNLAEBUH"
INTERVAL=${1:-3}
LOGFILE="$(dirname "$0")/pw_events.log"

GW="$GW" EMAIL="$EMAIL" PWPASS="$PW" INTERVAL="$INTERVAL" LOGFILE="$LOGFILE" python3 <<'PY'
import os, sys, json, subprocess, tempfile, time, datetime

GW=os.environ["GW"]; EMAIL=os.environ["EMAIL"]; PWPASS=os.environ["PWPASS"]
INTERVAL=float(os.environ["INTERVAL"]); LOGFILE=os.environ["LOGFILE"]
COOKIE=tempfile.mktemp()
logf=open(LOGFILE,"a")

def login():
    subprocess.run(["curl","-sk","-c",COOKIE,"-X","POST",
        "https://%s/api/login/Basic"%GW,"-H","Content-Type: application/json",
        "-d",json.dumps({"username":"installer","email":EMAIL,"password":PWPASS,"force_sm_off":False})],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def get(path):
    for attempt in (0,1):
        r=subprocess.run(["curl","-sk","-b",COOKIE,"--max-time","10","https://%s%s"%(GW,path)],
                         capture_output=True, text=True)
        s=r.stdout.strip()
        if s.startswith("{") or s.startswith("["):
            try: return json.loads(s)
            except Exception: return {}
        login()   # empty / auth problem -> re-login once, retry
    return {}

def emit(scope, msg):
    line="%s  %-7s %s" % (datetime.datetime.now().strftime("%H:%M:%S"), scope, msg)
    print(line, flush=True)
    logf.write(line+"\n"); logf.flush()

def pbucket(x):     # power -> nearest 100 W, for change detection
    if not isinstance(x,(int,float)): return None
    return int(round(x/100.0))*100

prev={}        # watched_key -> last value
ppow={}        # power keys -> last EMITTED bucket (hysteresis)
seen={}        # serial -> tag, currently present on the bus
dropped=set()  # serials that dropped off (rebooting), awaiting rejoin

def watch(scope, key, val, is_power=False):
    """Record val; emit a line if it changed (power uses >=200W hysteresis)."""
    k=scope+"|"+key
    if is_power:
        b=pbucket(val)
        if b is None: return
        last=ppow.get(k)
        if last is None:
            ppow[k]=b; prev[k]=b
        elif abs(b-last)>=200:
            emit(scope, "%s %sW -> %sW%s" % (key, last, b,
                 "   <-- EXPORT" if (key=="grid" and b<=-200) else ""))
            ppow[k]=b
        return
    old=prev.get(k, "__INIT__")
    if old=="__INIT__":
        prev[k]=val
        emit(scope, "%s = %s" % (key, val))      # baseline on first sight
    elif old!=val:
        emit(scope, "%s  %s -> %s" % (key, old, val))
        prev[k]=val

login()
emit("LOG", "started -- polling %s every %ss  (Ctrl-C to stop)" % (GW, INTERVAL))

try:
  while True:
    sm  = get("/api/sitemaster")
    ss  = get("/api/system_status")
    gr  = get("/api/system_status/grid_status")
    op  = get("/api/operation")
    agg = get("/api/meters/aggregates")
    prob= get("/api/troubleshooting/problems")

    # --- system / gateway ---
    if sm:
        reboot=str(sm.get("can_reboot",""))
        watch("SYSTEM","status", sm.get("status"))
        watch("SYSTEM","running", sm.get("running"))
        watch("SYSTEM","block-update", "YES" if "update" in reboot.lower() else "no")
        watch("SYSTEM","cloud-isolated", sm.get("connected_to_tesla")==False)
    if gr:
        watch("SYSTEM","island", gr.get("grid_status"))
    if op:
        watch("SYSTEM","mode", op.get("real_mode"))
        watch("SYSTEM","reserve%", op.get("backup_reserve_percent"))

    # --- power flow ---
    if agg:
        for nm in ("site","load","battery","solar"):
            m=agg.get(nm) or {}
            lbl="grid" if nm=="site" else nm
            watch("FLOW", lbl, m.get("instant_power"), is_power=True)
        site=agg.get("site") or {}
        exp=site.get("energy_exported")
        if isinstance(exp,(int,float)):
            watch("FLOW","export-kWh", round(exp/1000.0,1))

    # --- per Powerwall (keyed by serial); track presence so a reboot
    #     drop-out logs one clean line instead of every field going empty ---
    present=set()
    for b in (ss.get("battery_blocks") or []):
        sn=b.get("PackageSerialNumber")
        if not sn: continue                      # unit mid-reboot, no serial yet
        if not b.get("version"): continue        # not fully reporting this tick
        present.add(sn)
        tag="PW:"+sn[-4:]
        if sn not in seen:
            seen[sn]=tag
            emit(tag,"rejoined bus" if sn in dropped else "seen")
            dropped.discard(sn)
        watch(tag,"inverter", b.get("pinv_state"))
        watch(tag,"grid-state", b.get("pinv_grid_state"))
        watch(tag,"backup_ready", b.get("backup_ready"))
        watch(tag,"disabled", b.get("disabled_reason") or "none")
        watch(tag,"firmware", b.get("version"))
        full=b.get("nominal_full_pack_energy") or 0
        rem =b.get("nominal_energy_remaining") or 0
        watch(tag,"SOE%", int(round(rem/full*100)) if full else 0)
        watch(tag,"power", b.get("p_out"), is_power=True)
        for fl in ("wobble_detected","charge_power_clamped","off_grid"):
            if b.get(fl): watch(tag, fl, True)
    # units we knew about that vanished this tick -> rebooting
    for sn in list(seen.keys()):
        if sn not in present and sn not in dropped:
            emit(seen[sn],"dropped off bus (rebooting / updating)")
            dropped.add(sn)
            for k in [k for k in prev if k.startswith(seen[sn]+"|")]: prev.pop(k,None)
            del seen[sn]

    # --- alerts ---
    al=prob.get("problems") if isinstance(prob,dict) else None
    watch("ALERT","count", len(al) if al else 0)
    if al:
        for a in al:
            nm=a.get("name") or a.get("summary") or str(a)
            watch("ALERT","active", nm)

    time.sleep(INTERVAL)
except KeyboardInterrupt:
    emit("LOG","stopped")
    sys.exit(0)
PY
