# 740 Hardening — Boot-assert-close + Independent Watchdog

Two failsafes added 2026-11-08 so the 740 defaults to **CLOSED (grid = safe)** on
every failure path. Latching already survives power loss; these cover the gaps.

## 1. Boot-assert-close (software, no new parts)
On Pi boot, force CLOSED **before** Docker/the controller start — so even if the
container never comes up, the house is grid-connected.

Install on the **controller Pi** (192.168.10.101):
```bash
sudo cp boot_assert_close.sh /home/pi/boot_assert_close.sh
sudo chmod +x /home/pi/boot_assert_close.sh
sudo cp boot-assert-close.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable boot-assert-close.service
```
Test: `sudo systemctl start boot-assert-close.service` → the 740 should clunk closed.
(Uses `pinctrl`, already on Pi OS Bookworm. The controller also closes on its own
init; this is the belt-and-suspenders layer that runs with no Docker.)

## 2. Independent hardware watchdog (Pico + 1 relay)
Covers the real risk latching can't: the Pi opens the island at 5pm, then hangs and
never sends the 9am close. A Pico watches the controller's heartbeat; no beat for
120 s → it pulses the 740 closed, independent of the Pi's GPIO and Docker.

### Parts
- Raspberry Pi Pico (any; ~$4)
- 1-channel relay module (SPDT contacts) — the close interpose
- The **12V→5V buck** (the one you were going to return) → powers the Pico, so the
  watchdog runs on its own supply, not the Pi's 5V

### Heartbeat (already in code)
`island_relay.py` toggles **GPIO23** every tick; `arb_controller._loop` calls
`relay.heartbeat()` after each tick (~15 s). Rebuild/push the container to deploy
(see below). If the control loop hangs, GPIO23 stops toggling → watchdog trips.

### Wiring
```
Pi GPIO23 (Pin 16) ───────────────► Pico GP0        (heartbeat in)
Pi GND            ───────────────► Pico GND         (shared reference)
12V ──► buck ──► 5V ──────────────► Pico VSYS/5V, relay module VCC
Pico GP1 ─────────────────────────► relay module IN
Pico GND ─────────────────────────► relay module GND

Close interpose relay (SPDT) on the 740 RED coil lead:
   COM → 740 red
   NC  → K1 COM            (normal: Pi controls through the H-bridge)
   NO  → +12V
```
At rest the relay is de-energized → red passes through NC to K1 → Pi controls
normally. On trip, the relay energizes ~150 ms → red = +12V while black sits at
−12V (K2 NC) → **CLOSE pulse** → 740 latches closed → relay releases → back to
normal. Closed is safe, so a late/spurious trip only ever errs toward grid.

> If your relay module is **low-level trigger** (like the main board), invert the
> two `CLOSE.value()` lines in `watchdog_pico.py` (idle HIGH, fire LOW).

### Load it
Copy `watchdog_pico.py` to the Pico as **main.py** (Thonny, or drag with the Pico in
MicroPython mode). It runs on power-up.

### Bench test the watchdog
1. Power the Pico; confirm its LED toggles in step with the heartbeat (GPIO23).
2. With the 740 latched **open**, kill the controller: `docker compose stop`.
3. Within ~120 s the Pico LED goes solid and the 740 **clunks closed**. ✓
4. Restart: `docker compose start` → LED resumes toggling, Pi back in control.

## Deploy the heartbeat (container rebuild)
From the Mac:
```bash
cd powerwall_system/control
docker login
./build_push.sh
```
On the controller Pi:
```bash
docker compose down && docker compose pull && docker compose up -d
```
(Also, for the real 740: uncomment gpiozero/lgpio in requirements.txt, drop
`ARB_SIM`, and add the `devices:`/`GPIOZERO_PIN_FACTORY` lines in docker-compose.yml
so the container can reach GPIO17/27/22/23.)
