#!/usr/bin/env python3
"""
island_relay.py — shared GPIO primitives for the Gruner 740 (Plan B).

Single source of truth for the pulse logic, used by the CLI, the scheduler,
and the API. Low-level-trigger opto board => active_high=False (.on() pulls the
pin LOW to fire the relay; pin HIGH at boot => relay OFF, no pulse on power-up).
Latching coil => we only ever PULSE; never hold a coil energized.

Pins (BCM):  SET=GPIO17 (CH1, close/grid)  RESET=GPIO27 (CH2, open/island)
             AUX=GPIO22 (input, pull-up) reads the 740 aux 1-CO = true position

CLI:  python3 island_relay.py open|close|state
"""
import threading
import time

SET_PIN, RESET_PIN, AUX_PIN = 17, 27, 22
PULSE_S = 0.08                      # 80 ms (datasheet min 30 ms; margin)
# Set at bench step 6: True if aux reads "pressed" (NO closed to GND) when the
# MAIN poles are CLOSED. Flip if your aux wiring/polarity turns out inverted.
AUX_CLOSED_WHEN_PRESSED = True


class Relay:
    """Owns the GPIO. Instantiate ONCE per process (one owner, no contention)."""

    def __init__(self):
        from gpiozero import OutputDevice, Button
        self._lock = threading.Lock()
        self._set = OutputDevice(SET_PIN, active_high=False, initial_value=False)
        self._reset = OutputDevice(RESET_PIN, active_high=False, initial_value=False)
        self._aux = Button(AUX_PIN, pull_up=True)

    def _pulse(self, dev):
        # interlock: never energize both coils at once; one pulse at a time
        with self._lock:
            self._set.off()
            self._reset.off()
            dev.on()
            time.sleep(PULSE_S)
            dev.off()

    def close_grid(self):           # SET -> grid-connected (safe state)
        self._pulse(self._set)

    def open_island(self):          # RESET -> islanded (peak discharge)
        self._pulse(self._reset)

    def position(self):
        """Actual pole position from the aux contact: 'closed' | 'open'."""
        pressed = self._aux.is_pressed
        closed = pressed if AUX_CLOSED_WHEN_PRESSED else (not pressed)
        return "closed" if closed else "open"


if __name__ == "__main__":
    import sys
    r = Relay()
    cmd = sys.argv[1] if len(sys.argv) > 1 else "state"
    if cmd == "open":
        r.open_island()
    elif cmd == "close":
        r.close_grid()
    elif cmd != "state":
        print("usage: island_relay.py open|close|state")
        sys.exit(2)
    time.sleep(0.2)
    print(r.position())
