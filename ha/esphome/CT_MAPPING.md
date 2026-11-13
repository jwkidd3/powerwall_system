# Emporia CT mapping

Maps each CT input to its circuit number, name and physical configuration for the three
Emporia Vue Gen3 units. Source of truth for the YAML is `emporia-1.yaml`, `emporia-2.yaml`
and `emporia-3.yaml`; circuit numbers and names come from `panel_permit/panel-directory.html`
and `panel_permit/nonbackup-panel-directory.html`.

| Unit | Panel | Config |
|---|---|---|
| Emporia 1 | Backup panel (Square D QO142M200PCVP) | `emporia-1.yaml` |
| Emporia 2 | Non-backup panel (Square D QO130L200PG) | `emporia-2.yaml` |
| Emporia 3 | Gen panel (5 Powerwall breakers + 150A feeder) | `emporia-3.yaml` |

## Legs (relative, not colors)

"Phase A / BLACK" and "Phase B / RED" are **relative**. They do not refer to conductor
insulation color (the mains are both black).

- **Phase A** = the leg of the breaker the Emporia's BLACK voltage lead is on.
- **Phase B** = the opposite leg, where the RED lead is.
- Each CT's `phase_id` must be the leg of the conductor it is clamped on.
- Verify a leg with a meter (about 0 V to the BLACK lead's breaker = same leg, about
  240 V = opposite leg) or by the load test below.

**Load test:** turn on a load on the circuit and read its power in HA. Normal reading =
`phase_id` is right. **0 W** = wrong leg (the `*pos` filter clips the negative), so switch
`phase_id` to the other leg and reflash over WiFi.

## Emporia 1 — backup panel

Mains CTs: **A** (phase A / BLACK) and **B** (phase B / RED) on the two service/feeder hots.

| CT input | Circuit # | Name | Amps | Breaker | Leg (`phase_id`) |
|---|---|---|---|---|---|
| 1 | 2 | Garage plugs | 20 | 1P | A |
| 2 | 3 | MWBC (CAFI) | 15 | 1P | B |
| 3 | 4 | Kitchen outlets | 20 | 1P | B |
| 4 | 5 | Bedroom 1 & 2 | 15 | 1P | A |
| 5 | 6 | Dining / front room | 15 | 1P | A |
| 6 | 7 | Lights + plugs, garage | 15 | 1P | B |
| 7 | 10 | Kitchen lights | 15 | 1P | A |
| 8 | 12 | Mud room plugs | 20 | 1P | B |
| 9 | 13 | Master BR | 15 | 1P | A |
| 10 | 14 | Kitchen island | 20 | 1P | A |
| 11 | 15 | Office | 15 | 1P | B |
| 12 | 16 | Internet | 20 | 1P | B |
| 13 | 19 | Washroom plugs | 20 | 1P | B |
| 14 | 20 | Upstairs bath | 15 | 1P | B |
| 15 | 21 | Downstairs Air | 40 | 2P, `multiply: 2` | A |
| 16 | 22 | Upstairs Air | 25 | 2P, `multiply: 2` | A |

Not monitored: circuits 17 and 18 (dropped, only 16 inputs), 38 Neurio, 39 GEN backfeed 150A,
42 Surge protector. The single-pole `phase_id` values are assumed from the standard panel
pattern and must be verified.

Moved to the non-backup panel (keep their numbers): 8 Pool pump, 9 EV charger, 11 Dryer,
23 Mini-split.

Voltage leads: breaker **40** (BLACK / L1) and **41** (RED / L2). WHITE and BLUE to the neutral bar.

## Emporia 2 — non-backup panel

Mains CTs: **A** (phase A / BLACK) and **B** (phase B / RED) on the panel's feeder hots.

| CT input | Circuit # | Name | Amps | Breaker | Leg (`phase_id`) |
|---|---|---|---|---|---|
| 1 | 8 | Pool pump | 25 | 2P, `multiply: 2` | A |
| 2 | 9 | EV charger | 50 | 2P, `multiply: 2` | A |
| 3 | 11 | Dryer | 30 | 2P, `multiply: 2` | A |
| 4 | 23 | Sunroom mini-split | 20 | 2P, `multiply: 2` | A |

Not monitored: 37 Surge protector.

Voltage leads: breaker **35** (BLACK / L1) and **36** (RED / L2). WHITE and BLUE to the neutral bar.

## Emporia 3 — gen panel

Signed power (no `*pos` filter). Arrows point **toward the backup panel / away from the
Powerwalls**, so positive = batteries discharging into the house, negative = charging.

| CT input | Measures | Breaker | Leg (`phase_id`) |
|---|---|---|---|
| A | 150A feeder, one 1/0 hot | | A (BLACK) |
| B | 150A feeder, the other 1/0 hot | | B (RED) |
| 1 | Powerwall 1 | 30A 2P, `multiply: 2` | A |
| 2 | Powerwall 2 | 30A 2P, `multiply: 2` | A |
| 3 | Powerwall 3 | 30A 2P, `multiply: 2` | A |
| 4 | Powerwall 4 | 30A 2P, `multiply: 2` | A |
| 5 | Powerwall 5 | 30A 2P, `multiply: 2` | A |

Voltage leads on two stacked breakers in the gen panel; WHITE and BLUE to its neutral bar.

## Physical notes

- **Branch CTs (50A)** plug into the numbered ports across the top of the unit. Clamp ONE hot
  conductor only, never the neutral and never both hots. For 2P circuits either hot works.
- **Mains CTs (200A)** plug into ports **A** and **B** on the right side.
- **CT arrows** ("Breaker ->") point toward the breakers (toward the load). Gen panel unit:
  point them toward the backup panel instead.
- **Updating:** after the first wired flash, changes go over WiFi. Compile, upload and exit:
  `esphome run emporia-N.yaml --device <ip> --no-logs`. Known IPs: Emporia 1 `192.168.10.44`,
  Emporia 2 `192.168.10.103`. Confirm the run ended with "OTA successful".
  - `esphome run` without `--no-logs` compiles and uploads, then stays attached to the device
    logs until Ctrl-C.
  - `esphome upload` does **not** compile. It re-sends the last build, so edited YAML does not
    take effect. Use `run` (or `esphome compile` first).
- **After an update:** reload the device in HA (Settings > Devices & Services > ESPHome >
  device > Reload). Renamed sensors appear as new entities, so delete the old unavailable ones.
  Each circuit has two sensors: live power (W) and a Daily Energy sensor (kWh, resets at midnight).
