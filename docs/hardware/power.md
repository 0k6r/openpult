# Power

The nRF52840 can run from 1.7–3.6 V on `VDD`, or from 2.5–5.5 V on `VDDH` through its internal regulator
("high-voltage mode"). The SuperMini's `B+` pin is `VDDH`, which makes a 3-cell pack the simplest supply.

## Options

| Supply | Board input | Firmware configuration | Notes |
|---|---|---|---|
| **3×AA alkaline + Schottky diode** (recommended) | SuperMini `B+` | default (`CELLS=3`, `DIODE_MV=250`) | 2.75–4.6 V on `VDDH`; 1–3 years |
| **3×AAA alkaline + diode** | SuperMini `B+` | default | same voltages, ~40 % of the AA capacity |
| **3×NiMH + diode** | SuperMini `B+` | default | 3.3–4.0 V; the alkaline curve shows ~35 % for a full NiMH pack — fine as a trend |
| **1 Li-ion / LiPo cell** | SuperMini `B+` (no diode), XIAO `BAT`, Feather JST | `CONFIG_OPENPULT_BATT_LI_ION=y`, `CELLS=1`, `DIODE_MV=0` (preset for XIAO and Feather) | recharged by the board's charger over USB |
| **USB** (charger, TV USB port) | USB connector, dongle | `CONFIG_OPENPULT_USB_POWERED=y` (preset for the dongle) | Status reports external power; a TV port may switch off with the TV |

**Never use:**

- **4 alkaline cells** (6.4 V fresh) or anything else above 5.5 V on `VDDH`;
- **lithium AA/AAA primary cells** (Li-FeS2, "Ultimate Lithium"): 1.8 V per cell fresh, 5.4 V for three — the
  absolute limit is a few hundred millivolts away, and the voltage stays flat until the cell is empty, so the
  battery gauge is useless;
- a Li-ion cell **together with** AA cells, or a Li-ion cell on `B+` **through** the diode (it could never be
  charged).

## 3×AA wiring (SuperMini)

```
 + 3×AA ──► SS12D00 switch ──►|── B+        Schottky diode, anode (no band) to the battery,
 − 3×AA ─────────────────────────── GND     cathode (band) to B+
```

The diode does two jobs:

1. **Reverse-polarity protection** for cells inserted the wrong way.
2. **Blocks the on-board Li-ion charger.** nice!nano-style boards charge `B+` to 4.2 V whenever USB is connected
   (e.g. while flashing). Without the diode that current would flow into the alkaline cells, which then leak or
   swell. With the diode the board simply runs from USB.

Use a Schottky diode rated for the peak LED current: **1N5817** or **SS14** (1 A) for any transmitter, **BAT43**
(200 mA) is enough for a GPIO-driven LED. Its forward drop is ~0.1 V in idle and ~0.2–0.3 V at the milliamps the
chip draws while measuring; the firmware adds `CONFIG_OPENPULT_BATT_DIODE_MV` (250 mV) to the measured `VDDH`, so
the reported voltage is a slight overestimate of the pack.

## Battery gauge

Measured with the SAADC at boot, when a phone connects, and every 10 minutes, never while transmitting (the LED
current sags the cells). Alkaline curve per cell: 1.50 V → 100 %, 1.30 V → 60 %, 1.20 V → 35 %, 1.10 V → 15 %,
1.00 V → 0 %; Status raises *battery low* below 1.10 V per cell. The chip keeps working down to 2.5 V on `VDDH`
(≈ 0.92 V per cell after the diode), but the IR output weakens as `VDD` follows the falling supply.

## Energy budget (SuperMini, 3×AA, GPIO-driven LED)

| State | Current | Per day | Charge per day |
|---|---|---|---|
| Idle, advertising every 546 ms | 20–90 µA (clone dependent) | ~23.5 h | 0.5–2.1 mAh |
| Connected (app open, plus up to 10 min after the last command) | 150–300 µA | ~30 min | 0.1–0.15 mAh |
| Transmitting (CPU, crystal, LED) | 3–5 mA | 100 presses × 0.25 s | ~0.03 mAh |
| **Total** | | | **≈ 0.7–2.3 mAh** |

Alkaline AA cells deliver roughly 2000–2500 mAh at these currents, so the pack lasts well beyond a year; idle
current dominates. Measure yours: [measuring-current.md](../usage/measuring-current.md). A transistor driver
(100–300 mA bursts) adds about 0.3–1 mAh per 100 presses.

The firmware helps by advertising slowly (152.5 ms for 30 s after power-on or disconnect, then 546.25 ms),
dropping connections idle for 10 minutes, turning on the crystal oscillator only while transmitting, powering the
receiver only while learning, and having no console, USB or logging in the production build.
