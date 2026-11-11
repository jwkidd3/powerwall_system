# watchdog_pico.py — MicroPython, runs on a Raspberry Pi Pico as main.py.
#
# INDEPENDENT failsafe: watches the controller's heartbeat. If the heartbeat
# stops (controller hung/crashed/Pi stalled) for TIMEOUT, it forces the 740
# CLOSED (grid = safe) by pulsing an interpose relay — entirely independent of
# the Pi's GPIO and the Docker container.
#
# Covers the one failure latching can't: the Pi opens the island at 5pm, then
# hangs and never sends the 9am close. Closed is always safe, so firing late or
# spuriously only ever errs toward grid-connected.
#
# Wiring:
#   Pi GPIO23 (heartbeat out) ---> Pico GP0 (in)          [share grounds]
#   Pico GP1 (out) ---> close-relay module IN
#   Pico powered from the 12V->5V buck (own supply, NOT the Pi's 5V)
#   Close-relay (SPDT) interposed on the 740 RED coil lead:
#       COM -> 740 red ; NC -> K1 COM (normal Pi path) ; NO -> +12V
#   Firing pulses the relay ~150 ms: red->+12 while black sits at -12 -> CLOSE
#   pulse -> 740 latches closed -> relay releases -> red back to the Pi path.
from machine import Pin
import time

HB   = Pin(0, Pin.IN, Pin.PULL_DOWN)   # GP0  <- Pi GPIO23 heartbeat
CLOSE = Pin(1, Pin.OUT)                # GP1  -> close-relay IN (active HIGH here;
LED  = Pin(25, Pin.OUT)                #        if your module is low-level trigger,
CLOSE.value(0)                         #        invert: idle .value(1), fire .value(0))

TIMEOUT_MS = 120_000      # fire if no heartbeat edge for 120 s (controller ticks ~15 s)
PULSE_MS   = 150          # close-relay energize time

last = time.ticks_ms()
prev = HB.value()

def fire_close():
    CLOSE.value(1); time.sleep_ms(PULSE_MS); CLOSE.value(0)

while True:
    v = HB.value()
    if v != prev:                      # any edge = controller alive
        prev = v
        last = time.ticks_ms()
        LED.toggle()                   # visual: following the heartbeat
    if time.ticks_diff(time.ticks_ms(), last) > TIMEOUT_MS:
        LED.value(1)                   # solid LED = watchdog tripped
        fire_close()
        last = time.ticks_ms()         # re-arm; re-fires each TIMEOUT until heartbeat returns
    time.sleep_ms(50)
