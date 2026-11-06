#!/bin/zsh
GW=192.168.10.98; EMAIL="installer@yahoo.com"; PW="ESCPRNPWAS"; C=$(mktemp)
login(){ curl -sk -c "$C" -X POST --max-time 8 https://$GW/api/login/Basic -H "Content-Type: application/json" -d "{\"username\":\"installer\",\"email\":\"$EMAIL\",\"password\":\"$PW\",\"force_sm_off\":false}" 2>/dev/null; }
login >/dev/null
echo "watching B commission ($GW): ~45min. version / tesla / can_reboot / PWcount / cc"
prev=""
for i in $(seq 1 360); do
  ST=$(curl -sk --max-time 6 "https://$GW/api/status" 2>/dev/null)
  if [[ "$ST" != \{* ]]; then line="API DOWN (installing/rebooting)"; login >/dev/null
  else
    SM=$(curl -sk -b "$C" --max-time 6 "https://$GW/api/sitemaster" 2>/dev/null)
    PWc=$(curl -sk -b "$C" --max-time 6 "https://$GW/api/powerwalls" 2>/dev/null)
    CFG=$(curl -sk -b "$C" --max-time 6 "https://$GW/api/config/completed" 2>/dev/null)
    [[ "$SM" != \{* ]] && { r=$(login); [[ "$r" != *token* ]] && { line="AUTH LOST (pw may have changed post-update)"; }; }
    [ -z "$line" ] && line=$(ST="$ST" SM="$SM" PWc="$PWc" CFG="$CFG" python3 -c '
import os,json
def j(s):
 try:return json.loads(s)
 except:return {}
st=j(os.environ["ST"]);sm=j(os.environ["SM"]);pw=j(os.environ["PWc"]);cfg=j(os.environ["CFG"])
ver=st.get("version"); c=len(pw.get("powerwalls",[])); cc=cfg.get("commission_count")
flags=""
if ver and not str(ver).startswith("26.18.3"): flags+="  <<< VERSION CHANGED to %s"%ver
if c>0: flags+="  <<< %d PW ENUMERATED"%c
if isinstance(cc,int) and cc>0: flags+="  <<< COMMISSIONED cc=%s"%cc
print("ver=%s tesla=%s can_reboot=%r PW=%s cc=%s%s"%(ver,sm.get("connected_to_tesla"),sm.get("can_reboot"),c,cc,flags))')
  fi
  [ "$line" != "$prev" ] && { printf "%s  %s\n" "$(date '+%H:%M:%S')" "$line"; prev="$line"; }
  line=""; sleep 15
done
rm -f "$C"; echo "[B commission watch ended]"
