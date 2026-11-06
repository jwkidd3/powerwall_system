#!/usr/bin/env python3
"""
arb_controller.py — one process that owns the 740 and exposes three front doors:
  schedule  (5pm open / 9am close / SOC early-close)   # Free Days 12 window
  CLI       (island_relay.py)  -- shares the same primitives
  HTTP API  (POST /open, /close, /auto ; GET /state)

Everything routes through one lock-guarded Relay, so a scheduled pulse and an
API call can never fire at once. API calls set mode=manual (scheduler stands
down) and auto-resume at the next schedule boundary, or immediately on /auto.

Run:  ARB_TOKEN=... uvicorn arb_controller:app --host 0.0.0.0 --port 8676
  (the schedule loop starts automatically on app startup)

Env:  ARB_TOKEN   required  -- bearer token for every API call
      GW_IP       default 192.168.91.1   (TEDAPI read, no v1r)
      GW_PWD      gateway password        (enables SOC floor; optional)
      PEAK_START  default 17:00  (Free Days 12: island when the paid window begins)
      PEAK_END    default 09:00  (close for the free charge window; window WRAPS midnight)
      FLOOR_PCT   default 10     (SOC floor %, during island; needs GW_PWD)
      MIN_SOC     default 50     (%; don't island below this at peak start)
      TZ          default America/Chicago
"""
import os
import threading
import time
from datetime import datetime, time as dtime
from zoneinfo import ZoneInfo

from fastapi import FastAPI, Header, HTTPException

# ARB_SIM=1 -> in-memory simulated switch (no GPIO, no 740) for HA integration
# testing. Unset it to drive the real Gruner 740 once it's wired + bench-proven.
if os.environ.get("ARB_SIM"):
    from island_relay_sim import Relay
else:
    from island_relay import Relay

TZ = ZoneInfo(os.environ.get("TZ", "America/Chicago"))


def _parse_hhmm(s, default):
    try:
        h, m = s.split(":")
        return dtime(int(h), int(m))
    except Exception:
        return default


PEAK_START = _parse_hhmm(os.environ.get("PEAK_START", "17:00"), dtime(17, 0))
PEAK_END = _parse_hhmm(os.environ.get("PEAK_END", "09:00"), dtime(9, 0))
FLOOR_PCT = float(os.environ.get("FLOOR_PCT", "10"))   # stop discharging at 10% SOC
MIN_SOC = float(os.environ.get("MIN_SOC", "50"))
TOKEN = os.environ.get("ARB_TOKEN")
POLL_S = 60


def read_state():
    """TEDAPI read (no v1r): {'soc','energy_kwh','grid_ok'} or None on failure.
    Optional — only enables the SOC floor. Controller runs fine without it."""
    gw_pwd = os.environ.get("GW_PWD")
    if not gw_pwd:
        return None
    try:
        import pypowerwall
        host = os.environ.get("GW_IP", "192.168.91.1")
        pw = pypowerwall.Powerwall(host=host, password=gw_pwd[-5:],
                                   email="", gw_pwd=gw_pwd)
        soc = pw.level(scale=True)                 # app-scale % (matches what the app shows)
        return {"soc": soc,
                "energy_kwh": (soc or 0) / 100.0 * 67.5,   # ~67.5 kWh usable (5x PW2)
                "grid_ok": pw.grid_status() == "UP"}
    except Exception:
        return None


def in_peak(now):
    t = now.timetz().replace(tzinfo=None)
    if PEAK_START <= PEAK_END:
        return PEAK_START <= t < PEAK_END
    # window wraps midnight (Free Days: 17:00 -> 09:00)
    return t >= PEAK_START or t < PEAK_END


class Controller:
    def __init__(self):
        self.relay = Relay()
        self.lock = threading.Lock()
        self.mode = "auto"              # 'auto' | 'manual'
        self.commanded = "closed"       # our last commanded target
        self.reason = "boot"
        self.since = datetime.now(TZ).isoformat(timespec="seconds")
        self.last_boundary = None
        self.early_closed = False
        self.relay.close_grid()         # boot = assert safe state
        threading.Thread(target=self._loop, daemon=True).start()

    # -- the one choke point every path goes through --
    def _apply(self, target, reason):
        with self.lock:
            if target == self.commanded:
                self.reason = reason
                return
            if target == "open":
                self.relay.open_island()
            else:
                self.relay.close_grid()
            self.commanded = target
            self.reason = reason
            self.since = datetime.now(TZ).isoformat(timespec="seconds")

    # -- API-facing (manual) --
    def manual(self, target):
        self.mode = "manual"
        self._apply(target, "api")
        return self.state()

    def set_auto(self):
        self.mode = "auto"
        self.reason = "api/auto"
        return self.state()

    def state(self):
        s = read_state()
        return {
            "position": self.relay.position(),   # TRUE pole state from aux
            "commanded": self.commanded,
            "mode": self.mode,
            "reason": self.reason,
            "since": self.since,
            "soc": (s or {}).get("soc"),
            "grid_ok": (s or {}).get("grid_ok"),
        }

    # -- scheduler --
    def _loop(self):
        while True:
            try:
                self._tick()
            except Exception as e:
                print("tick error:", e, flush=True)
            time.sleep(POLL_S)

    def _tick(self):
        now = datetime.now(TZ)
        boundary = "peak" if in_peak(now) else "offpeak"
        if boundary != self.last_boundary:         # crossed 17:00 or 09:00
            self.last_boundary = boundary
            self.early_closed = False
            self.mode = "auto"                      # manual override lasts <= to next edge
        if self.mode == "manual":
            return

        if not in_peak(now):
            self._apply("closed", "offpeak")
            return

        # inside peak window
        s = read_state()
        if s is not None and self.commanded == "closed" and s["soc"] < MIN_SOC:
            return                                  # too low to bother islanding
        if s is not None and not s.get("grid_ok", True) and self.commanded == "closed":
            return                                  # real outage: don't "island" into it
        if self.commanded == "open" and s is not None and s["soc"] is not None and s["soc"] <= FLOOR_PCT:
            self._apply("closed", "soc-floor")      # early close at the 10% floor
            self.early_closed = True
            return
        if not self.early_closed:
            self._apply("open", "peak")


# ----------------------------------------------------------------------------
app = FastAPI(title="Arbitrage 740 Controller")
ctl = None


def _auth(authorization):
    if not TOKEN:
        raise HTTPException(500, "ARB_TOKEN not set on server")
    if authorization != f"Bearer {TOKEN}":
        raise HTTPException(401, "bad or missing token")


@app.on_event("startup")
def _start():
    global ctl
    ctl = Controller()


@app.post("/open")
def api_open(authorization: str = Header(None)):
    _auth(authorization)
    return ctl.manual("open")


@app.post("/close")
def api_close(authorization: str = Header(None)):
    _auth(authorization)
    return ctl.manual("closed")


@app.post("/auto")
def api_auto(authorization: str = Header(None)):
    _auth(authorization)
    return ctl.set_auto()


@app.get("/state")
def api_state(authorization: str = Header(None)):
    _auth(authorization)
    return ctl.state()
