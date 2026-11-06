#!/usr/bin/env python3
"""pw_tedapi.py -- local TEDAPI snapshot for the commissioned BGW2 (26.34.1).

Replaces the retired installer-login scripts (installer role is now locked
behind physical access). Talks to the gateway over its OWN network only:
join Wi-Fi TEG-1E1 (or wire a host onto 192.168.91.x), then run this.
This is exactly what the HA Pi will do with pypowerwall.

Run with the project venv:
    ../pwvenv/bin/python pw_tedapi.py           one snapshot
    ../pwvenv/bin/python pw_tedapi.py 30         refresh every 30s (Ctrl-C to stop)

Env overrides:  GWPW=<gateway password>  GWIP=<gateway ip, default 192.168.91.1>
"""
import os, sys, time, datetime
from pypowerwall.tedapi import TEDAPI

GWPW = os.environ.get("GWPW", "CDRSNFJAZR")      # gateway sticker password (TEG-1E1 / TEDAPI)
GWIP = os.environ.get("GWIP", "192.168.91.1")     # gateway AP address
INT  = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 0


def snap(t):
    st = t.get_status() or {}
    ctrl = st.get("control", {}) or {}
    ss = ctrl.get("systemStatus", {}) or {}
    isl = ctrl.get("islanding", {}) or {}
    ma = ctrl.get("meterAggregates", []) or []
    bl = t.get_blocks() or {}

    full = ss.get("nominalFullPackEnergyWh") or 0
    rem = ss.get("nominalEnergyRemainingWh") or 0
    soc = (rem / full * 100) if full else 0
    flows = {m.get("location"): m.get("realPowerW") for m in ma}

    print("=" * 72)
    print("GATEWAY %s  fw=%s  uptime=%.1fh"
          % (t.get_din(), t.get_firmware_version(),
             (t.get_gateway_uptime() or {}).get("uptime_ms", 0) / 3.6e6))
    print("  grid_ok=%s  contactor_closed=%s" % (isl.get("gridOK"), isl.get("contactorClosed")))
    print("  PACK  %.1f / %.1f kWh  (%.1f%%)" % (rem / 1000, full / 1000, soc))
    b = flows.get("BATTERY"); s = flows.get("SITE"); ld = flows.get("LOAD"); sol = flows.get("SOLAR")
    def w(x): return ("%+dW" % round(x)) if isinstance(x, (int, float)) else "-"
    print("  FLOW  site=%s  load=%s  battery=%s  solar=%s   (battery<0 = charging)"
          % (w(s), w(ld), w(b), w(sol)))
    print("  %-14s %-20s %-16s %6s %6s %5s" % ("UNIT", "pinv_state", "grid", "V", "Hz", "SOE"))
    for sn, d in bl.items():
        f = d.get("nominal_full_pack_energy") or 0
        r = d.get("nominal_energy_remaining") or 0
        soe = ("%.0f%%" % (r / f * 100)) if f else "-"
        dis = ",".join(d.get("disabled_reasons") or [])
        print("  %-14s %-20s %-16s %6.1f %6.2f %5s %s"
              % (sn.split("TG")[-1], d.get("pinv_state"), d.get("pinv_grid_state"),
                 d.get("v_out") or 0, d.get("f_out") or 0, soe,
                 ("[" + dis + "]") if dis else ""))


def main():
    t = TEDAPI(GWPW, host=GWIP)
    if not t.get_din():
        print("Could not reach gateway at %s -- are you on Wi-Fi TEG-1E1?" % GWIP)
        sys.exit(1)
    if INT == 0:
        snap(t)
        return
    try:
        while True:
            os.system("clear")
            print(datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
            snap(t)
            time.sleep(INT)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
