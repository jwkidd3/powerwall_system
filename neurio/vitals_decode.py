#!/usr/bin/env python3
# Decode Tesla gateway /api/devices/vitals (protobuf) -> device vitals dict.
# No external deps. Reads the raw blob on stdin, prints selected meter vitals.
import struct, sys

def readvarint(buf, i):
    shift = res = 0
    while i < len(buf):
        b = buf[i]; i += 1; res |= (b & 0x7f) << shift
        if not (b & 0x80): return res, i
        shift += 7
    return None, i

def parse(buf):
    out = []; i = 0; n = len(buf)
    while i < n:
        key, i = readvarint(buf, i)
        if key is None: break
        field = key >> 3; wt = key & 7
        if wt == 0:
            v, i = readvarint(buf, i); out.append((field, 0, v))
        elif wt == 1:
            if i+8 > n: break
            out.append((field, 1, struct.unpack('<d', buf[i:i+8])[0])); i += 8
        elif wt == 2:
            ln, i = readvarint(buf, i)
            if ln is None or i+ln > n: break
            out.append((field, 2, buf[i:i+ln])); i += ln
        elif wt == 5:
            if i+4 > n: break
            out.append((field, 5, struct.unpack('<f', buf[i:i+4])[0])); i += 4
        else: break
    return out

def astext(b):
    try:
        s = b.decode('utf-8')
        return s if s and all(32 <= ord(c) < 127 for c in s) else None
    except Exception:
        return None

def find_name(buf):
    """Recursively find a device identifier string anywhere in the submessage."""
    for f, wt, val in parse(buf):
        if wt == 2:
            t = astext(val)
            if t and t.startswith(("NEURIO--","STSTSM--","TESYNC--")): return t
            r = find_name(val)
            if r: return r
    return None

def devices(buf):
    """Yield (device_name, {vital_name: value})."""
    for f, wt, val in parse(buf):           # top level: repeated Device
        if wt != 2: continue
        name = find_name(val)
        vitals = {}
        for df, dwt, dval in parse(val):     # vitals: field 2, each {1:name, 4:num, 5:str}
            if df == 2 and dwt == 2:
                vn = None; vv = True
                for vf, vwt, vv2 in parse(dval):
                    if vf == 1 and vwt == 2: vn = astext(vv2)
                    elif vf in (3,4) and vwt in (0,1,5): vv = vv2
                    elif vf == 5 and vwt == 2: vv = astext(vv2)
                if vn: vitals[vn] = vv
        if name: yield name, vitals

def f(v):
    try: return float(v)
    except Exception: return 0.0

data = sys.stdin.buffer.read()
devs = {name: vit for name, vit in devices(data)}

# ---- NEURIO (external, whole-site) ----
for name, v in devs.items():
    if not name.startswith("NEURIO"): continue
    ct0 = f(v.get("NEURIO_CT0_InstRealPower")); ct1 = f(v.get("NEURIO_CT1_InstRealPower"))
    print("NEURIO (external, whole-site)  [%s]" % name.split("--")[-1])
    print("  CT0 %-5s %9.1f W" % (v.get("NEURIO_CT0_Location","?"), ct0))
    print("  CT1 %-5s %9.1f W" % (v.get("NEURIO_CT1_Location","?"), ct1))
    print("  SITE %14.0f W   (%.2f kW)" % (ct0 + ct1, (ct0 + ct1) / 1000))

# ---- internal synchronizer meters + island/grid ----
for name, v in devs.items():
    if not name.startswith("TESYNC"): continue
    for M, label in (("METER_X", "internal, backup-side"), ("METER_Y", "internal, 2nd")):
        a = f(v.get(M+"_CTA_InstRealPower")); b = f(v.get(M+"_CTB_InstRealPower"))
        if a == 0 and b == 0 and f(v.get(M+"_LifetimeEnergyImport")) == 0: continue
        print("\n%s (%s)" % (M, label))
        print("  L1 %6.1f V %6.2f A %8.1f W" % (f(v.get(M+"_VL1N")), f(v.get(M+"_CTA_I")), a))
        print("  L2 %6.1f V %6.2f A %8.1f W" % (f(v.get(M+"_VL2N")), f(v.get(M+"_CTB_I")), b))
        print("  total %8.1f W   (%.2f kW)   lifetime import %.1f kWh  export %.1f kWh" % (
            a + b, (a + b) / 1000, f(v.get(M+"_LifetimeEnergyImport"))/1000, f(v.get(M+"_LifetimeEnergyExport"))/1000))
    gs = v.get("ISLAND_GridState","?").replace("ISLAND_GridState_","")
    conn = "connected" if v.get("ISLAND_GridConnected") is True else "ISLANDED"
    print("\nGRID / ISLAND")
    print("  state: %s (%s)" % (gs, conn))
    print("  L1: main %6.1f V %5.2f Hz / load %6.1f V %5.2f Hz" % (
        f(v.get("ISLAND_VL1N_Main")), f(v.get("ISLAND_FreqL1_Main")),
        f(v.get("ISLAND_VL1N_Load")), f(v.get("ISLAND_FreqL1_Load"))))
    print("  L2: main %6.1f V %5.2f Hz / load %6.1f V %5.2f Hz" % (
        f(v.get("ISLAND_VL2N_Main")), f(v.get("ISLAND_FreqL2_Main")),
        f(v.get("ISLAND_VL2N_Load")), f(v.get("ISLAND_FreqL2_Load"))))
