#!/usr/bin/env python3
"""Poll the Orbi (port 443 / SSL) and print JSON of attached devices with the
satellite each is on. Used by a Home Assistant command_line sensor.

Place at /config/orbi_devices.py on the HAOS box. pynetgear is already present
(the Netgear integration depends on it). Password comes from ORBI_PASS env.

  ORBI_HOST=192.168.10.45 ORBI_PASS=... python3 /config/orbi_devices.py
"""
import os
import json
from pynetgear import Netgear

# Map each access-point radio MAC to a friendly name. Rename the satellites
# once you know which is which (group by AP in the card and match locations).
AP_NAMES = {
    "C8:9E:43:C5:A7:C5": "Router",
    "E0:46:EE:20:C4:90": "Garage",
    "34:98:B5:EB:70:A7": "Office",
    "34:98:B5:EC:90:1B": "Game Room",
}

host = os.environ.get("ORBI_HOST", "192.168.10.45")
pw = os.environ.get("ORBI_PASS")

n = Netgear(password=pw, host=host, user="admin", port=443, ssl=True)
devs = n.get_attached_devices_2() or []

out = []
for d in devs:
    m = (d.conn_ap_mac or "").upper()
    out.append({
        "name": d.name,
        "ip": d.ip,
        "ap": AP_NAMES.get(m, m or "?"),
        "band": d.type,          # 2.4GHz / 5GHz / wired
        "signal": d.signal,
        "link_rate": d.link_rate,
    })

out.sort(key=lambda x: (x["ap"], (x["name"] or "").lower()))
print(json.dumps({"count": len(out), "devices": out}))
