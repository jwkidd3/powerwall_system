#!/bin/zsh
# pw_summary.sh -- one-shot commissioning summary for the gateway (default B = .98 / 26.34.1).
# Usage:
#   ./pw_summary.sh              one snapshot
#   ./pw_summary.sh 10           refresh every 10s (Ctrl-C to stop)
#   GW=192.168.10.231 PW=EBHNLAEBUH ./pw_summary.sh   point at A instead

GW=${GW:-192.168.10.98}
EMAIL=${EMAIL:-installer@yahoo.com}
PW=${PW:-ESCPRNPWAS}
INT=${1:-}
C=$(mktemp)

login(){ curl -sk -c "$C" -X POST --max-time 8 https://$GW/api/login/Basic -H "Content-Type: application/json" \
  -d "{\"username\":\"installer\",\"email\":\"$EMAIL\",\"password\":\"$PW\",\"force_sm_off\":false}" >/dev/null 2>&1; }
g(){ curl -sk -b "$C" --max-time 8 "https://$GW$1" 2>/dev/null; }

login
snap(){
  local ST SM SS CFG OP
  ST=$(g /api/status); SM=$(g /api/sitemaster); SS=$(g /api/system_status); CFG=$(g /api/config/completed); OP=$(g /api/operation); AG=$(g /api/meters/aggregates)
  [[ "$CFG" != \{* ]] && { login; CFG=$(g /api/config/completed); }
  ST="$ST" SM="$SM" SS="$SS" CFG="$CFG" OP="$OP" AG="$AG" GW="$GW" python3 <<'PY'
import os,json
def j(s):
  try:return json.loads(s)
  except:return {}
st=j(os.environ["ST"]);sm=j(os.environ["SM"]);ss=j(os.environ["SS"]);cfg=j(os.environ["CFG"]);op=j(os.environ["OP"]);ag=j(os.environ["AG"])
gw=os.environ["GW"]
print("="*60)
print("GATEWAY  %s  fw=%s" % (gw, st.get("version","?")))
print("  sitemaster=%s running=%s  tesla=%s  can_reboot=%r"
      % (sm.get("status"), sm.get("running"), sm.get("connected_to_tesla"), sm.get("can_reboot")))
print("  commission_count=%s   mode=%s reserve=%s%%"
      % (cfg.get("commission_count"), op.get("real_mode"), op.get("backup_reserve_percent")))
bl=ss.get("battery_blocks") or []
gw_fw=(st.get("version") or "")[:8]
done=sum(1 for b in bl if (b.get("version") or "").startswith("dcee") or (b.get("version") or "")[:8]==gw_fw)
rdy=sum(1 for b in bl if b.get("backup_ready"))
avail=ss.get("available_blocks")
tot=ss.get("nominal_full_pack_energy"); rem=ss.get("nominal_energy_remaining")
print("POWERWALLS  %d found | available=%s | on-gw-fw=%d/%d | backup_ready=%d/%d"
      % (len(bl), avail, done, len(bl), rdy, len(bl)))
if isinstance(tot,(int,float)) and tot:
    print("  pack: %.1f / %.1f kWh (%.0f%%)" % (rem/1000, tot/1000, rem/tot*100))
for b in bl:
    sn=(b.get("PackageSerialNumber") or "?")[-4:]
    full=b.get("nominal_full_pack_energy") or 0; r=b.get("nominal_energy_remaining") or 0
    soe=("%d%%"%(r/full*100)) if full else "-"
    dis=",".join(b.get("disabled_reasons") or []) or "ok"
    print("  %s  %-8s %-14s rdy=%-5s fw=%s %s"
          % (sn, b.get("OpSeqState","?"), b.get("pinv_state","?"), b.get("backup_ready"), (b.get("version") or "")[:8], "%s %s"%(soe,"" if dis=="ok" else "["+dis+"]")))
def mw(k):
    m=ag.get(k) or {}; p=m.get("instant_power"); return ("%dW"%round(p)) if isinstance(p,(int,float)) else "-"
print("METERS  site=%s  load=%s  battery=%s  solar=%s" % (mw("site"),mw("load"),mw("battery"),mw("solar")))
# verdict
cc=cfg.get("commission_count")
if isinstance(cc,int) and cc>0 and avail and rdy==len(bl) and len(bl)>0 and not sm.get("can_reboot"):
    print("STATUS: *** COMMISSIONED & ARMED ***")
elif sm.get("can_reboot"):
    print("STATUS: working -- %s" % sm.get("can_reboot"))
else:
    print("STATUS: cc=%s avail=%s ready=%d/%d (not yet committed/armed)" % (cc,avail,rdy,len(bl)))
PY
}

if [ -z "$INT" ]; then snap; rm -f "$C"
else
  trap 'rm -f "$C"; exit 0' INT TERM
  while true; do clear; date '+%Y-%m-%d %H:%M:%S'; snap; sleep "$INT"; done
fi
