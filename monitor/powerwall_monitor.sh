#!/bin/zsh

# Config Configuration
GW="192.168.10.231"
EMAIL="installer@yahoo.com"
PW="XJDYUSKMDK"
COOKIE_FILE="/tmp/tcookie"

# Ensure python3 is available for formatting
if ! command -v python3 &> /dev/null; then
    echo "Error: python3 is required to parse JSON strings."
    exit 1
fi

echo "================================================="
echo "   TESLA POWERWALL 2 SYSTEM DIAGNOSTICS & METRICS"
echo "================================================="

# 1. Heartbeat Check
ver=$(curl -sk --max-time 5 "https://$GW/api/status" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("version","?"))' 2>/dev/null)
if [ -z "$ver" ]; then
    echo "❌ Gateway NOT reachable at $GW"
    exit 1
fi
echo "✅ Gateway Status: Connected"
echo "📟 Firmware Version: $ver"

# 2. Authenticate Installer Session
curl -sk -c "$COOKIE_FILE" -X POST "https://$GW/api/login/Basic"   -H "Content-Type: application/json"   -d "{\"username\":\"installer\",\"email\":\"$EMAIL\",\"password\":\"$PW\",\"force_sm_off\":false}" >/dev/null

if [ ! -f "$COOKIE_FILE" ] || [ ! -s "$COOKIE_FILE" ]; then
    echo "❌ Authentication Failure: Session token could not be generated."
    exit 1
fi
echo "🔑 Auth Token: Generated successfully"

# 3. Real-Time Energy Flow Metrics
echo "\n⚡ [REAL-TIME POWER CHANNELS]"
curl -sk -b "$COOKIE_FILE" "https://$GW/api/meters/aggregates" 2>/dev/null | python3 -c '
import sys,json
try:
    d=json.load(sys.stdin)
    for channel in ["load", "solar", "battery", "site"]:
        if channel in d:
            power = d[channel].get("instant_power", 0.0)
            current = d[channel].get("instant_current", 0.0)
            voltage = d[channel].get("instant_average_voltage", 0.0)
            print("  🔹 %-10s : %8.1f W  |  %6.2f A  |  %6.1f V" % (channel.capitalize(), power, current, voltage))
except Exception as e:
    print("  Error parsing energy aggregates:", e)
'

# 4. State of Charge (SoE) - Using raw /api/powerwalls endpoint
echo "\n🔋 [BATTERY CAPACITY & HEALTH]"
curl -sk -b "$COOKIE_FILE" "https://$GW/api/powerwalls" 2>/dev/null | python3 -c '
import sys,json
try:
    d=json.load(sys.stdin)
    if isinstance(d, dict) and "powerwalls" in d:
        pws = d["powerwalls"]
        if len(pws) > 0:
            charge = d.get("charge", 0.0)
            print("  🔹 System Charge (Raw Loop) : %.2f%%" % charge)
            for i, pw in enumerate(pws):
                sn = pw.get("sequence_id", i)
                v = pw.get("v_out", 0.0)
                print("  🔸 Powerwall Pack [%s]      : %.1f V Out" % (sn, v))
        else:
            print("  ⚠️ No active powerwall modules returned in array.")
    else:
        print("  🔹 Reading standard SOE path...")
except Exception as e:
    print("  Error parsing storage capacity:", e)
'

# 5. Grid Topology and Connection Status
echo "\n🌐 [GRID INTELLIGENCE & TELEMETRY]"
curl -sk -b "$COOKIE_FILE" "https://$GW/api/system_status/grid_status" 2>/dev/null | python3 -c '
import sys,json
try:
    d=json.load(sys.stdin)
    status = d.get("grid_status", "Unknown")
    services = d.get("grid_services_active", False)
    print("  🔹 Operating Status     : %s" % status)
    print("  🔹 Grid Services Active  : %s" % services)
except Exception as e:
    print("  Error parsing grid parameters:", e)
'

# 6. Global Site Control Status
echo "\n🖥️  [SITEMASTER INFRASTRUCTURE]"
curl -sk -b "$COOKIE_FILE" "https://$GW/api/sitemaster" 2>/dev/null | python3 -c '
import sys,json
try:
    d=json.load(sys.stdin)
    print("  🔹 Cloud Connectivity    : Connected=%s" % d.get("connected_to_tesla", False))
    print("  🔹 Primary State Machine : Running State=%s" % d.get("status", "?"))
except Exception as e:
    print("  Error parsing primary sitemaster parameters:", e)
'

# 7. Physical Interface Network Allocation Tables
echo "\n📡 [INTERFACE HARDWARE CONFIGURATION]"
curl -sk -b "$COOKIE_FILE" "https://$GW/api/networks" 2>/dev/null | python3 -c '
import sys,json
try:
    d=json.load(sys.stdin)
    if isinstance(d, list):
        print("  %-16s %-10s %-12s %-12s" % ("INTERFACE", "ACTIVE", "TESLA_CLOUD", "LAN_INTERNET"))
        print("  -------------------------------------------------------------")
        for net in d:
            print("  %-16s %-10s %-12s %-12s" % (
                net.get("network_name", "Unknown")[:16],
                str(net.get("active", False)),
                str(net.get("lastTeslaConnected", False)),
                str(net.get("lastInternetConnected", False))
            ))
except Exception as e:
    print("  Error mapping physical components:", e)
'
echo "=================================================\n"
