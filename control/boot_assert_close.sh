#!/bin/bash
# boot_assert_close.sh — force the 740 to CLOSED (grid = safe state) at boot,
# independent of Docker/the controller. Uses pinctrl (no Python deps on the host).
#
# 2-wire bistable H-bridge: K1=GPIO17=close, K2=GPIO27=open. Low-level-trigger
# board => drive-LOW fires the relay, drive-HIGH = idle/off. Pulse K1 to close.
set -e
P=/usr/bin/pinctrl

# 1) Idle both relays (HIGH = off). Ensures OPEN relay is not asserting.
$P set 27 op dh
$P set 17 op dh
sleep 0.2

# 2) Pulse K1 (close): LOW ~120 ms, then release HIGH. Bistable latches closed.
$P set 17 op dl
sleep 0.12
$P set 17 op dh

logger -t boot_assert_close "740 asserted CLOSED at boot"
