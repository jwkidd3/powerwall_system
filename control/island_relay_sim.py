#!/usr/bin/env python3
"""
island_relay_sim.py — drop-in simulator for island_relay.Relay (NO GPIO, NO 740).

Same interface as the real Relay (close_grid / open_island / position) but keeps
the pole position in memory and logs every action. Lets arb_controller.py run on
any machine so the HA integration (state sensor, buttons, schedule) can be tested
end-to-end BEFORE the Gruner 740 and the relay board physically exist.

Enable it by running the controller with ARB_SIM=1. Swap back to the real relay
simply by removing ARB_SIM once the 740 is bench-proven.

CLI:  python3 island_relay_sim.py open|close|state
"""
import threading
import time

PULSE_S = 0.08                      # mimic the real coil pulse timing


class Relay:
    """In-memory stand-in for the 740. One owner per process, like the real one."""

    def __init__(self):
        self._lock = threading.Lock()
        self._position = "closed"   # boot-safe: grid-connected
        print("[SIM] relay init -> position=closed (no GPIO, no 740)", flush=True)

    def _pulse(self, target):
        with self._lock:
            time.sleep(PULSE_S)
            self._position = target
            print(f"[SIM] pulse -> position={target}", flush=True)

    def close_grid(self):           # SET -> grid-connected (safe state)
        self._pulse("closed")

    def open_island(self):          # RESET -> islanded
        self._pulse("open")

    def position(self):
        return self._position


if __name__ == "__main__":
    import sys
    r = Relay()
    cmd = sys.argv[1] if len(sys.argv) > 1 else "state"
    if cmd == "open":
        r.open_island()
    elif cmd == "close":
        r.close_grid()
    elif cmd != "state":
        print("usage: island_relay_sim.py open|close|state")
        sys.exit(2)
    time.sleep(0.2)
    print(r.position())
