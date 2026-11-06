#!/usr/bin/env python3
"""
pw_web.py -- simple local web console for the Tesla Backup Gateway 2 local API.

Runs on YOUR Mac (which can reach the gateway + its self-signed cert). It proxies
browser clicks to https://192.168.10.231, so there are no CORS/cert headaches.

  python3 pw_web.py            # then open http://localhost:8686
  python3 pw_web.py 9000       # use a different port

Safety: /api/system/update is hard-blocked (it triggers a firmware update = TEDAPI risk).
sitemaster run/stop require an explicit confirm in the UI.
Stdlib only -- no pip installs.
"""
import http.server, json, ssl, urllib.request, urllib.error, urllib.parse
import http.cookiejar, re, sys, os
from collections import Counter

GW   = os.environ.get("GW", "192.168.10.231")
EMAIL= os.environ.get("EMAIL", "installer@yahoo.com")
PASS = os.environ.get("PW", "EBHNLAEBUH")
USER = "installer"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else int(os.environ.get("PORT","8726"))
BASE = f"https://{GW}"

_ctx = ssl.create_default_context(); _ctx.check_hostname = False; _ctx.verify_mode = ssl.CERT_NONE
_cj  = http.cookiejar.CookieJar()
_op  = urllib.request.build_opener(urllib.request.HTTPSHandler(context=_ctx),
                                   urllib.request.HTTPCookieProcessor(_cj))

def _blocked(path):
    return path.startswith("/api/system/update") and not path.startswith("/api/system/update/status")

def login():
    data = json.dumps({"username": USER, "email": EMAIL, "password": PASS, "force_sm_off": False}).encode()
    req = urllib.request.Request(BASE + "/api/login/Basic", data=data,
                                 headers={"Content-Type": "application/json"})
    _op.open(req, timeout=10).read()

def gw_get(path):
    try:
        return _op.open(BASE + path, timeout=12).read()
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            try:
                login(); return _op.open(BASE + path, timeout=12).read()
            except Exception as e2:
                return json.dumps({"error": str(e2)}).encode()
        try: return e.read() or json.dumps({"error": e.code}).encode()
        except Exception: return json.dumps({"error": e.code}).encode()
    except Exception as e:
        return json.dumps({"error": str(e)}).encode()

def gw_post(path, body):
    data = (body if isinstance(body, str) else json.dumps(body)).encode() or b"{}"
    req = urllib.request.Request(BASE + path, data=data,
                                 headers={"Content-Type": "application/json"}, method="POST")
    try:
        return _op.open(req, timeout=15).read() or b'{"ok":true}'
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            try:
                login(); return _op.open(req, timeout=15).read() or b'{"ok":true}'
            except Exception as e2:
                return json.dumps({"error": str(e2)}).encode()
        try: return e.read() or json.dumps({"error": e.code}).encode()
        except Exception: return json.dumps({"error": e.code}).encode()
    except Exception as e:
        return json.dumps({"error": str(e)}).encode()

def gw_vitals():
    try:
        raw = _op.open(BASE + "/api/devices/vitals", timeout=12).read()
    except urllib.error.HTTPError:
        login(); raw = _op.open(BASE + "/api/devices/vitals", timeout=12).read()
    toks = re.findall(rb'[A-Za-z]+_[awe][0-9]{2,3}[A-Za-z_]*', raw)
    c = Counter(t.decode() for t in toks)
    return json.dumps([{"count": n, "code": k} for k, n in sorted(c.items(), key=lambda x: -x[1])], indent=2).encode()

READ = {
  "State": ["/api/status", "/api/sitemaster", "/api/operation"],
  "System": ["/api/system_status", "/api/system_status/soe", "/api/system_status/grid_status", "/api/system_status/grid_faults"],
  "Powerwalls": ["/api/powerwalls", "/api/powerwalls/status"],
  "Meters": ["/api/meters", "/api/meters/aggregates", "/api/meters/site", "/api/meters/solar", "/api/meters/status", "/api/meters/readings", "/api/synchrometer/ct_voltage_references"],
  "Config/Commissioning": ["/api/config", "/api/config/completed", "/api/installer", "/api/site_info", "/api/site_info/site_name", "/api/auth/toggle/supported"],
  "Diagnostics": ["/api/system/testing", "/api/system/update/status", "/api/networks", "/api/solars", "/api/solar_powerwall", "/api/generators"],
}
WRITES = [
  {"path": "/api/operation", "body": '{"real_mode":"backup","backup_reserve_percent":20}'},
  {"path": "/api/powerwalls/phase_detection", "body": "{}"},
  {"path": "/api/site_info/grid_code", "body": '{"grid_code":"60Hz_240V_s_SMC_IEEE1547-2018_Category-III"}'},
  {"path": "/api/config", "body": "{}"},
  {"path": "/api/config/completed", "body": "{}"},
  {"path": "/api/meters/site", "body": "{}"},
  {"path": "/api/meters/solar", "body": "{}"},
  {"path": "/api/site_info", "body": "{}"},
  {"path": "/api/site_info/site_name", "body": '{"site_name":"KHome","timezone":"America/Chicago"}'},
  {"path": "/api/installer", "body": "{}"},
  {"path": "/api/networks", "body": "{}"},
  {"path": "/api/system/testing", "body": "{}"},
]

PAGE = """<!doctype html><html><head><meta charset=utf-8>
<title>Powerwall Console (26.x)</title>
<meta name=viewport content="width=device-width,initial-scale=1">
<style>
 :root{--bg:#0f1115;--panel:#171a21;--line:#2a2f3a;--fg:#e6e8ec;--mut:#8b93a3;--acc:#4ea1ff;--warn:#ff5a5a;--ok:#39d98a}
 *{box-sizing:border-box} body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.4 ui-sans-serif,system-ui,Segoe UI,Roboto}
 header{padding:12px 16px;border-bottom:1px solid var(--line);display:flex;gap:12px;align-items:center;flex-wrap:wrap}
 header b{font-size:15px} header .gw{color:var(--mut);font-family:ui-monospace,Menlo,monospace}
 .wrap{display:grid;grid-template-columns:320px 1fr;gap:0;height:calc(100vh - 52px)}
 .side{border-right:1px solid var(--line);overflow:auto;padding:12px}
 .grp{margin-bottom:14px} .grp h3{margin:0 0 6px;font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:var(--mut)}
 button{background:var(--panel);color:var(--fg);border:1px solid var(--line);border-radius:7px;padding:7px 9px;margin:0 6px 6px 0;cursor:pointer;font:12px ui-monospace,Menlo,monospace}
 button:hover{border-color:var(--acc)} button.warn{border-color:#5a2a2a} button.warn:hover{border-color:var(--warn)}
 .main{display:flex;flex-direction:column;overflow:hidden}
 .bar{padding:10px 14px;border-bottom:1px solid var(--line);display:flex;gap:10px;align-items:center;flex-wrap:wrap}
 pre{margin:0;padding:14px;overflow:auto;flex:1;font:12px/1.45 ui-monospace,Menlo,monospace;white-space:pre-wrap;word-break:break-word}
 .write{padding:12px 14px;border-top:1px solid var(--line);background:var(--panel)}
 .write h3{margin:0 0 8px;font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:var(--warn)}
 select,textarea,input{background:var(--bg);color:var(--fg);border:1px solid var(--line);border-radius:6px;padding:7px;font:12px ui-monospace,Menlo,monospace}
 textarea{width:100%;min-height:52px;margin:6px 0} .row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
 .send{border-color:#5a2a2a} .send:hover{border-color:var(--warn)}
 .pill{font-size:11px;color:var(--mut)} .status{color:var(--mut);font-size:12px}
 label.chk{color:var(--mut);font-size:12px;display:flex;gap:5px;align-items:center;cursor:pointer}
</style></head><body>
<header><b>Powerwall Gateway Console</b><span class=gw>__GW__ &middot; __USER__</span>
 <button onclick="doLogin()">login</button>
 <button onclick="doLogout()">logout</button>
 <button onclick="call('/api/sitemaster')">sitemaster</button>
 <label class=chk><input type=checkbox id=auto onchange=toggleAuto()> auto-refresh (5s)</label>
 <span class=status id=last></span></header>
<div class=wrap>
 <div class=side id=side></div>
 <div class=main>
  <div class=bar>
    <b style="font-size:11px;letter-spacing:.08em;color:var(--mut)">PROCESS CONTROL</b>
    <span class=pill id=smstat>sitemaster: ?</span>
    <button class=warn onclick="action('/api/sitemaster/run','START sitemaster')">&#9654; start</button>
    <button class=warn onclick="action('/api/sitemaster/stop','STOP sitemaster')">&#9632; stop</button>
    <button onclick="postAction('/api/powerwalls/phase_detection','{}','Run phase detection (system must be STOPPED first)')">phase detect</button>
    <button onclick="postAction('/api/system/testing','{}','Run system self-test')">system test</button>
    <span class=pill id=cur style="margin-left:auto">click an endpoint &rarr;</span>
  </div>
  <pre id=out>Ready. Pick a read on the left, or use the write panel below.</pre>
  <div class=write>
   <h3>⚠ write / state-changing</h3>
   <div class=row>
     <select id=wpath onchange=onWriteSel()></select>
     <button onclick=loadCurrent()>load current</button>
     <button class=send onclick=doPost()>POST</button>
     <span class=pill style="color:var(--warn)">/api/system/update blocked</span>
   </div>
   <div class=pill id=whelp style="margin:5px 0;color:var(--acc)"></div>
   <textarea id=wbody></textarea>
  </div>
 </div>
</div>
<script>
const READ=__READ__, WRITES=__WRITES__;
const CONTROL=[
 {p:'/api/sitemaster/run',label:'START sitemaster',kind:'get'},
 {p:'/api/sitemaster/stop',label:'STOP sitemaster',kind:'get'},
 {p:'/api/powerwalls/phase_detection',body:'{}',label:'Run phase detection (system STOPPED first)',kind:'post'},
 {p:'/api/system/testing',body:'{}',label:'Run system self-test',kind:'post'},
 {p:'/api/logout',label:'Log out the API session',kind:'get'},
];
const side=document.getElementById('side'), out=document.getElementById('out'),
      cur=document.getElementById('cur'), last=document.getElementById('last'),
      wpath=document.getElementById('wpath'), wbody=document.getElementById('wbody');
for(const [grp,paths] of Object.entries(READ)){
  const d=document.createElement('div');d.className='grp';
  d.innerHTML='<h3>'+grp+'</h3>';
  paths.forEach(p=>{const b=document.createElement('button');b.textContent=p.replace('/api/','');b.onclick=()=>call(p);d.appendChild(b);});
  side.appendChild(d);
}
{const cg=document.createElement('div');cg.className='grp';cg.innerHTML='<h3>Control / Actions</h3>';
 CONTROL.forEach(c=>{const b=document.createElement('button');b.className='warn';b.textContent=c.p.replace('/api/','');b.onclick=()=>{c.kind=='post'?postAction(c.p,c.body,c.label):action(c.p,c.label);};cg.appendChild(b);});
 side.appendChild(cg);
 const wg=document.createElement('div');wg.className='grp';wg.innerHTML='<h3>Write (POST) &rarr; loads panel below</h3>';
 WRITES.forEach(w=>{const b=document.createElement('button');b.textContent=w.path.replace('/api/','');b.onclick=()=>selectWrite(w.path);wg.appendChild(b);});
 side.appendChild(wg);}
WRITES.forEach(w=>{const o=document.createElement('option');o.value=w.path;o.textContent=w.path;o.dataset.body=w.body;wpath.appendChild(o);});
const ARGS={
 '/api/operation':'real_mode: "backup" | "self_consumption" | "autonomous"   backup_reserve_percent: 0-100   (e.g. {"real_mode":"backup","backup_reserve_percent":20})',
 '/api/powerwalls/phase_detection':'no args — {} triggers phase detection (system must be STOPPED first)',
 '/api/system/testing':'no args — {} starts the system self-test (meter/inverter/charge)',
 '/api/site_info/grid_code':'grid_code: full code string. e.g. {"grid_code":"60Hz_240V_s_SMC_IEEE1547-2018_Category-III"}',
 '/api/site_info/site_name':'site_name: string   timezone: IANA tz. e.g. {"site_name":"KHome","timezone":"America/Chicago"}',
 '/api/site_info':'site params (max_site_meter_power_kW, net_meter_mode, nominal caps). Click "load current", edit, POST back.',
 '/api/config':'gateway config object. Click "load current" for the editable template, change fields, POST back.',
 '/api/config/completed':'commissioning config bundle. Click "load current", edit, POST back (this is what the wizard finalizes).',
 '/api/meters/site':'site (Neurio) CT meter: CTs, location ("site"), inverted/flip flags. Click "load current" to see the exact fields.',
 '/api/meters/solar':'solar CT meter config. Click "load current" to see fields (empty set for no-solar).',
 '/api/installer':'installer/site params: location, mounting, wiring, backup_configuration, run_sitemaster, verified_config. "load current".',
 '/api/customer':'customer flags: marketing, privacy_notice, grid_services, limited_warranty (booleans). "load current".',
 '/api/networks':'network interface config (wifi/ethernet). "load current" to see current interfaces first.',
};
function onWriteSel(){presetBody();const h=document.getElementById('whelp');h.textContent='args \\u2192 '+(ARGS[wpath.value]||'config object — use "load current" to fetch an editable template');}
function presetBody(){wbody.value=wpath.selectedOptions[0].dataset.body||'{}';}
async function loadCurrent(){const p=wpath.value;cur.textContent='GET '+p+' (as template)';try{const r=await fetch('/call?path='+encodeURIComponent(p));wbody.value=pretty(await r.text());}catch(e){out.textContent='ERROR '+e;}}
function selectWrite(path){wpath.value=path;onWriteSel();document.querySelector('.write').scrollIntoView({behavior:'smooth'});wbody.focus();}
onWriteSel();
function stamp(){last.textContent='updated '+new Date().toLocaleTimeString();}
async function call(path){cur.textContent='GET '+path;try{const r=await fetch('/call?path='+encodeURIComponent(path));const t=await r.text();out.textContent=pretty(t);}catch(e){out.textContent='ERROR '+e;}stamp();}
async function vitals(){cur.textContent='alarm codes (vitals)';try{const r=await fetch('/vitals');out.textContent=await r.text();}catch(e){out.textContent='ERROR '+e;}stamp();}
async function doPost(){const p=wpath.value, b=wbody.value||'{}';if(!confirm('POST '+p+'\\n'+b+'\\n\\nThis writes to the gateway. Continue?'))return;cur.textContent='POST '+p;try{const r=await fetch('/post',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({path:p,body:b})});out.textContent=pretty(await r.text());}catch(e){out.textContent='ERROR '+e;}stamp();}
async function action(p,label){if(!confirm(label+'?\\n\\n'+p))return;cur.textContent='GET '+p;try{const r=await fetch('/call?path='+encodeURIComponent(p));out.textContent=pretty(await r.text());}catch(e){out.textContent='ERROR '+e;}stamp();setTimeout(refreshStatus,1500);}
async function postAction(p,b,label){if(!confirm(label+'?'))return;cur.textContent='POST '+p;try{const r=await fetch('/post',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({path:p,body:b})});out.textContent=pretty(await r.text());}catch(e){out.textContent='ERROR '+e;}stamp();setTimeout(refreshStatus,1500);}
async function refreshStatus(){try{const r=await fetch('/call?path=/api/sitemaster');const d=JSON.parse(await r.text());const s=document.getElementById('smstat');s.textContent='sitemaster: '+(d.status||'?')+(d.running?' \\u00b7 running':'')+(d.can_reboot?(' \\u00b7 '+d.can_reboot):'');s.style.color=(d.status=='StatusUp'&&!d.can_reboot)?'var(--ok)':(d.can_reboot?'var(--warn)':'var(--mut)');}catch(e){}}
async function doLogin(){cur.textContent='login';try{const r=await fetch('/login');out.textContent=pretty(await r.text());}catch(e){out.textContent='ERROR '+e;}stamp();refreshStatus();}
async function doLogout(){if(!confirm('Log out the API session? (next action will auto-login again)'))return;cur.textContent='logout';try{const r=await fetch('/logout');out.textContent=pretty(await r.text());}catch(e){out.textContent='ERROR '+e;}stamp();}
function pretty(t){try{return JSON.stringify(JSON.parse(t),null,2);}catch(e){return t;}}
refreshStatus();
let tmr=null;function toggleAuto(){if(document.getElementById('auto').checked){tmr=setInterval(()=>{const p=cur.textContent.replace(/^GET /,'');if(p.startsWith('/api/'))call(p);},5000);}else clearInterval(tmr);}
</script></body></html>"""

def render():
    return (PAGE.replace("__GW__", GW)
                .replace("__USER__", USER)
                .replace("__READ__", json.dumps(READ))
                .replace("__WRITES__", json.dumps(WRITES)))

class H(http.server.BaseHTTPRequestHandler):
    def _s(self, code, body, ctype="application/json"):
        b = body if isinstance(body, bytes) else body.encode()
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path == "/": return self._s(200, render(), "text/html; charset=utf-8")
        if u.path == "/vitals": return self._s(200, gw_vitals())
        if u.path == "/login":
            try: login(); return self._s(200, b'{"ok":true,"msg":"session refreshed (logged in)"}')
            except Exception as e: return self._s(200, json.dumps({"error": str(e)}).encode())
        if u.path == "/logout": return self._s(200, gw_get("/api/logout"))
        if u.path == "/call":
            path = urllib.parse.parse_qs(u.query).get("path", [""])[0]
            if not path.startswith("/api/"): return self._s(400, b'{"error":"bad path"}')
            if _blocked(path): return self._s(403, b'{"error":"refused: /api/system/update triggers a firmware update (TEDAPI risk)"}')
            return self._s(200, gw_get(path))
        return self._s(404, b'{"error":"not found"}')
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); raw = self.rfile.read(n) if n else b"{}"
        try: j = json.loads(raw)
        except Exception: j = {}
        path = j.get("path", ""); body = j.get("body", "{}")
        if not path.startswith("/api/"): return self._s(400, b'{"error":"bad path"}')
        if _blocked(path): return self._s(403, b'{"error":"refused: firmware update blocked"}')
        return self._s(200, gw_post(path, body))
    def log_message(self, *a): pass

if __name__ == "__main__":
    try: login()
    except Exception as e: print("warning: initial login failed (%s) -- will retry on first call" % e)
    print("Powerwall console:  http://localhost:%d   (gateway %s)   Ctrl-C to stop" % (PORT, GW))
    http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
