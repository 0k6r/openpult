# IR transmitter

The firmware drives one pin (`ir-tx-gpios`) with the modulated carrier: high = LED on, pulsed at the carrier
frequency (usually 36–40 kHz) with the duty cycle from the signal (usually 33 %). Between commands the pin is low.
Use a **940 nm** IR LED (5 mm, e.g. TSAL6200, IR333, or any "940 nm IR emitter"); 850 nm LEDs are visible as a red
glow and less efficient for TV receivers.

Range depends almost only on the peak LED current:

| Option | Peak current | Typical range | Parts |
|---|---|---|---|
| A. LED straight from the GPIO | 7–9 mA | 3–20 cm (often ~1 m in line of sight) | LED + 180–220 Ω |
| B. NPN transistor | 50–100 mA per LED | 3–6 m | S8050 / 2N2222 / BC337, 470 Ω, 27–33 Ω per LED, 220 µF |
| C. N-MOSFET, 1–3 LEDs | 100 mA per LED | 5–10 m, wide coverage | AO3400, 100 Ω, 100 kΩ, 27–33 Ω per LED, 470 µF |

The bridge is meant to sit 3–20 cm in front of the TV's IR window, where option A is enough and costs nothing in
battery life. B and C are for a bridge placed across the room.

## A. LED straight from the GPIO

```
GPIO (ir-tx) ──[ 180–220 Ω ]──►|── GND
                              LED: anode (long leg) to the resistor, cathode (flat side) to GND
```

With `CONFIG_OPENPULT_TX_HIGH_DRIVE=y` (default) the pin uses the nRF52840 high-drive mode, specified for 5 mA with
at most 0.4 V drop at VDD ≥ 2.7 V. With VDD = 3.3 V and an LED forward voltage of ~1.2 V:

    I ≈ (3.3 V − ~0.5 V − 1.2 V) / 220 Ω ≈ 7 mA        (180 Ω: ≈ 9 mA)

Do not go below 150 Ω. The average current while transmitting is tiny (7 mA × 33 % duty × ~40 % of the frame
being marks ≈ 1 mA, for a fraction of a second per press).

## B. NPN low-side switch

```
LED supply ──┬──────────────[ 27–33 Ω ]──►|──┐   (one resistor per LED, LEDs in parallel)
(B+ or 3V3)  │                          LED   │
           220 µF                              C
             │     GPIO ──[ 470 Ω ]─────────── B   S8050 / 2N2222 / BC337
GND ─────────┴──────────────────────────────── E
```

Take the LED supply from `B+` (after the Schottky diode) or from the battery side of the switch; not from the
board's 3V3 regulator, which is not rated for 100 mA pulses on most boards.

- **LED resistor** for ~100 mA from fresh 3×AA (≈4.2 V on `B+`), LED Vf ≈ 1.4 V at 100 mA, VCE(sat) ≈ 0.2 V:
  R = (4.2 − 1.4 − 0.2) / 0.1 ≈ 26 Ω → **27 Ω**. As the cells drain to 1.0 V each (2.75 V on `B+`) the current
  falls to ≈ 45 mA, still well above option A. Peak power 0.27 W, average far below: 1/4 W resistors are fine.
- **Base resistor**: drive the transistor into saturation with a forced gain of ~20: I_B ≈ 100 mA / 20 = 5 mA →
  R_B = (3.3 − 0.75) / 5 mA ≈ 510 Ω → **470 Ω**. Keep `CONFIG_OPENPULT_TX_HIGH_DRIVE=y` for this base current.
- **Two or three LEDs**: put them in parallel, each with its own resistor (in series they would need more than
  2.8 V of headroom and stop working as the cells drain). For more than ~150 mA total, use option C: a GPIO
  cannot supply the base current.
- **Capacitor**: 220 µF (6.3 V or more) across the LED supply, close to the LEDs. AA cells and the diode have
  internal resistance; without it the 100 mA bursts make `VDDH` dip.

## C. N-MOSFET (AO3400)

```
LED supply ──┬──[ 27–33 Ω ]──►|──┬──[ 27–33 Ω ]──►|──┐
             │                   │  (up to 3 LEDs)     │
           470 µF                                      D
             │   GPIO ──[ 100 Ω ]──┬────────────────── G   AO3400 (SOT-23)
             │                  [ 100 kΩ ]             S
GND ─────────┴─────────────────────┴────────────────── ┘
```

AO3400 is a logic-level N-MOSFET (VGS(th) 0.65–1.45 V, RDS(on) ≈ 30–50 mΩ at 2.5–4.5 V gate drive), so 3.3 V on
the gate switches it fully. The 100 Ω resistor limits the gate charge current, the 100 kΩ pull-down keeps the LEDs
off while the chip resets (the pin floats until the firmware configures it). No base current: the MOSFET can switch
an amp, the limit is the LEDs (100 mA continuous / ~1 A pulsed for TSAL6200) and the battery. With three LEDs at
100 mA the bursts are 300 mA: use the 470 µF capacitor, and expect AA cells to last noticeably less if the bridge
is used a lot.

`CONFIG_OPENPULT_TX_HIGH_DRIVE` may be disabled with a MOSFET.

## KY-005 and similar modules

The KY-005 "IR transmitter module" is just an LED on a small board with pins `S`, middle and `−`. Many versions have
no series resistor; others have one of unknown value. Check with a multimeter: if `S`–`−` looks like a bare diode,
add 180–220 Ω in series (option A) or drive the module from option B/C. The middle pin is usually unconnected.

## Active-low drivers

If the driver turns the LED on with a **low** level (e.g. a PNP high-side switch), declare the pin
`GPIO_ACTIVE_LOW` in the overlay; the firmware inverts the carrier and idles the pin high.

## Checking the transmitter

A phone camera (usually the front one, which has no IR filter) shows the LED flashing when a button is pressed. A
VS1838B on a breadboard ([ir-receiver.md](ir-receiver.md)) with an LED on its output is a more reliable test: it
only reacts to a carrier around 38 kHz.
