# Measuring the idle current

Battery life is decided by the current the bridge draws while idle (advertising, no phone connected). It is worth
measuring once per board: clone boards differ, and a firmware or wiring mistake shows up as milliamps instead of
microamps.

## What you need

- A multimeter with a µA range (200 µA or 2000 µA), or better a current profiler (Nordic PPK2, µCurrent,
  Joulescope) that also shows the advertising pulses.
- A jumper wire to short the meter.
- The **production** build (the debug build keeps USB and logging on and draws several milliamps).
- USB **disconnected** — with USB plugged in the board runs from USB, not from the battery.

## Procedure

1. Put the meter in series with the battery plus: battery + → meter → switch → diode → `B+`.
2. **Short the meter with the jumper** and switch the bridge on. At boot and during the first 30 s of fast
   advertising the current peaks at several milliamps; on the µA range the meter's shunt (often 100 Ω–1 kΩ) would
   drop so much voltage that the board resets.
3. Wait at least 40 s (fast advertising ends after 30 s), make sure no phone is connected (close the app, or turn
   off Bluetooth on the phone), then **remove the jumper**.
4. Read the value over 10–20 s. Advertising every 546 ms makes a plain multimeter jump; take the average of the
   readings or use the meter's min/max/average function. Put the jumper back before pressing buttons or connecting
   the app.

## What to expect

| Reading | Meaning |
|---|---|
| **20–90 µA** | Normal for a SuperMini without DC/DC. With DC/DC enabled (if the board has the inductors) expect the lower end. |
| 3–10 µA | Not advertising: the firmware probably crashed or hangs at boot (try the debug build and read the log). |
| ~0.5–1 mA | The chip does not sleep: debug build, USB powered, or a peripheral left on. On some clones the 32 kHz crystal does not start and the firmware hangs waiting for it — enable the RC oscillator ([configuration.md](../firmware/configuration.md)). |
| **~700 µA** | Known hardware leak of older SuperMini batches, which have a 5.6 kΩ pull-up resistor that conducts permanently. The firmware cannot fix it: replace the resistor (see the board's schematic) or use a newer board. |
| several mA | Wiring: the IR LED stuck on (pin configured wrong, transistor without base resistor), the receiver powered permanently, a Feather's NeoPixel. |

Connected to a phone the bridge draws 150–300 µA (connection events every 15–30 ms); the firmware drops the link
after 10 minutes without commands.

## Other checks while the meter is in place

- **Supply voltages:** `B+` ≈ battery − diode drop; `3V3`/`VDD` ≈ 3.3 V. A `VDD` of ≈1.8 V means the REGOUT0 value in
  UICR was never set (the nice!nano bootloader sets it to 3.3 V) — the IR LED will be weak.
- **Transmission:** with the jumper in place, a button press draws a few milliamps for a fraction of a second
  (bare LED) or bursts of 100–300 mA (transistor driver).
- **Learning:** while the app is learning, the receiver adds its 0.4–1.5 mA; afterwards the current must fall back
  to the idle value.
