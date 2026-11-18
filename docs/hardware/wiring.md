# Wiring

Two builds per board:

- **Minimal** — power, an IR LED with a resistor straight from a GPIO, a reset button. Enough for a bridge placed
  3–20 cm in front of the TV.
- **Range + learning** — a transistor driver for one to three LEDs ([ir-transmitter.md](ir-transmitter.md),
  option B/C) and a receiver for learning ([ir-receiver.md](ir-receiver.md)).

Pins are the firmware defaults ([boards.md](boards.md)); to use others, edit the board overlay.

## nRF52840 SuperMini / nice!nano clone

Header (component side up, USB at the top), left column: `P0.06 P0.08 GND GND P0.17 P0.20 P0.22 P0.24 P1.00
P0.11 P1.04 P1.06`; right column: `B+ GND RST 3V3 P0.31 P0.29 P0.02 P1.15 P1.13 P1.11 P0.10 P0.09`.

### Minimal

```
 + 3×AA ──► SS12D00 ──►|── B+            1N5817 / BAT43, band (cathode) towards B+
 − 3×AA ────────────────── GND

 P0.17 ──[ 220 Ω ]──►|── GND            IR LED 940 nm: long leg (anode) to the resistor

 RST ──[ button ]── GND                 double press = UF2 bootloader
```

| Pin | Part |
|---|---|
| `B+` | battery + through switch and Schottky diode |
| `GND` | battery − , LED cathode, button |
| `P0.17` | 220 Ω → IR LED anode |
| `RST` | push button to `GND` |

### Range + learning

```
 + 3×AA ──► SS12D00 ──►|──┬── B+
 − 3×AA ──────────────────│── GND ──────────────────────────────┐
                          │                                     │
                        220 µF                                  │
                          │                                     │
                          ├──[ 27 Ω ]──►|──┐                    │
                          └──[ 27 Ω ]──►|──┤   2 IR LEDs        │
                                          C                     │
 P0.17 ──[ 470 Ω ]─────────────────────── B   S8050 / 2N2222    │
                                          E ────────────────────┘

 P0.20 (D3) ◄── OUT ┐
 P0.22 (D4) ─── GND ├ VS1838B / TSOP38238, plugged straight into the header
 P0.24 (D5) ──► VCC ┘
```

| Pin | Part |
|---|---|
| `B+` | battery + through switch and diode; LED supply; 220 µF to `GND` |
| `P0.17` | 470 Ω → NPN base (or 100 Ω → AO3400 gate with 100 kΩ to `GND`) |
| `P0.20` | receiver OUT |
| `P0.22` | receiver GND (GPIO held low) |
| `P0.24` | receiver VCC (on only while learning) |
| `RST` | push button to `GND` |

## Seeed XIAO nRF52840

Pads (component side up, USB at the top), left: `D0 D1 D2 D3 D4 D5 D6`; right: `5V GND 3V3 D10 D9 D8 D7`; battery
pads `BAT+`/`BAT−` on the back.

### Minimal

```
 Li-ion cell ── BAT+ / BAT−       (charged over USB)      or  3×AA ──► switch ──►|── 5V, − to GND
 D0 (P0.02) ──[ 220 Ω ]──►|── GND
```

### Range + learning

```
 BAT+ ──┬──[ 27 Ω ]──►|──┐
      220 µF            C
 D0 ──[ 470 Ω ]──────── B   S8050
 GND ──┴─────────────── E

 D1 (P0.03) ◄── OUT ┐
 D2 (P0.28) ─── GND ├ VS1838B
 D3 (P0.29) ──► VCC ┘
```

| Pin | Part |
|---|---|
| `D0` / P0.02 | LED resistor (minimal) or transistor base |
| `D1` / P0.03 | receiver OUT |
| `D2` / P0.28 | receiver GND |
| `D3` / P0.29 | receiver VCC |
| `BAT+`/`BAT−` | Li-ion cell (measured by the firmware) |

With 3×AA on `5V` the board cannot measure the pack: build with `-DCONFIG_OPENPULT_USB_POWERED=y`.

## Adafruit Feather nRF52840 Express

Long header: `… 13 12 11 10 9 6 5 SCL SDA`; short header has `3V`, `GND`, `A0–A5`.

### Minimal

```
 LiPo ── JST battery connector (or USB)
 D5 (P1.08) ──[ 220 Ω ]──►|── GND
```

### Range + learning

```
 BAT ──┬──[ 27 Ω ]──►|──┐
     220 µF            C
 D5 ──[ 470 Ω ]─────── B   S8050
 GND ─┴─────────────── E

 D6  (P0.07) ◄── OUT
 D9  (P0.26) ─── GND      VS1838B on three adjacent header pins
 D10 (P0.27) ──► VCC
```

| Pin | Part |
|---|---|
| `D5` / P1.08 | LED resistor or transistor base |
| `D6` / P0.07 | receiver OUT |
| `D9` / P0.26 | receiver GND |
| `D10` / P0.27 | receiver VCC |
| `BAT` | LED supply for the transistor stage |

## nRF52840 Dongle

Powered from a USB charger. Edge pads are labelled with the GPIO number.

```
 0.17 ──[ 220 Ω ]──►|── GND                (minimal)

 VBUS ──[ 33 Ω ]──►|── C  S8050,  0.17 ──[ 470 Ω ]── B,  E ── GND     (range; VBUS = 5 V)
 0.20 ◄── OUT,  0.22 ── GND,  0.24 ──► VCC                      (learning)
```

From `VBUS` (5 V) use 33–39 Ω per LED for ~100 mA: (5.0 − 1.4 − 0.2) / 0.1 ≈ 34 Ω.

| Pad | Part |
|---|---|
| `0.17` | LED resistor or transistor base |
| `0.20` | receiver OUT |
| `0.22` | receiver GND |
| `0.24` | receiver VCC |

## Checks before closing the case

1. Measure the voltage on `B+`/`VDDH` (battery minus ~0.1–0.25 V) and `3V3`/`VDD` (≈3.3 V; if it reads ≈1.8 V
   the regulator output is not configured in UICR and the LED will be weak).
2. Measure the idle current: [measuring-current.md](../usage/measuring-current.md).
3. Press a button in the app and watch the LED through a phone camera.
