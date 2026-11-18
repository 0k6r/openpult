# IR receiver (optional, for learning)

With a demodulating IR receiver the bridge can record the buttons of your original remote; the app decodes the
recording (NEC, RC5, Sony, …) or keeps it as a raw signal. Without a receiver everything else works.

The firmware powers the receiver from a GPIO (`ir-rx-power-gpios`) only while learning — a receiver draws
0.4–1.5 mA, which would drain AA cells in months. Optionally a second GPIO serves as its ground
(`ir-rx-gnd-gpios`), so the module plugs straight into three adjacent header pins. The default pins
([boards.md](boards.md)) follow the VS1838B order OUT–GND–VCC.

## Modules

Pin orders differ — check yours before plugging it in. Reversing VCC and GND on these parts usually kills them.

| Part | Pins (lens facing you, legs down, left to right) | Supply | Notes |
|---|---|---|---|
| **VS1838B** (bare, 3 legs) | OUT, GND, VCC | 2.7–5.5 V, ~0.5 mA | Cheapest; matches the default pin order. |
| **TSOP38238** (Vishay) | OUT, GND, VS | 2.5–5.5 V, ~0.35 mA | Better noise immunity; same order as VS1838B. |
| **TSOP4838 / TSOP34838** | OUT, GND, VS | 2.5–5.5 V | Same order. |
| **KY-022 module** | varies by vendor: often `S` (OUT), middle (VCC), `−` (GND) | 3.3–5 V, 1–3 mA with its LED | Has an indicator LED and a pull-up; read the silkscreen. With the middle pin as VCC it does **not** fit the default three-pin order — wire it with jumpers or change the pins in the overlay. |

All of them output **low while they receive a carrier** (that is why `ir-rx-gpios` is `GPIO_ACTIVE_LOW`) and have an
internal pull-up, so no external resistor is needed. A 38 kHz receiver also picks up 36 and 40 kHz remotes well
enough for learning; the carrier frequency itself cannot be measured through a demodulating receiver (the app
derives it from the protocol).

## Wiring (SuperMini defaults)

```
SuperMini              VS1838B / TSOP38238
P0.20 (D3) ◄────────── OUT
P0.22 (D4) ─────────── GND      (GPIO held low)
P0.24 (D5) ──────────► VCC      (GPIO high only while learning)
```

Optional but recommended: a 100 nF capacitor between the module's VCC and GND legs, as close to the module as
possible. Keep it small: a larger capacitor makes the supply GPIO charge it through its output driver at power-on.

With a real ground and supply instead of GPIOs, remove `ir-rx-gnd-gpios` (and `ir-rx-power-gpios`, if the module is
on a switched supply of its own) from the overlay.

## How learning works

After LEARN_START the firmware powers the receiver, waits 20 ms, and timestamps every edge of its output with a
1 MHz timer (GPIOTE → PPI → TIMER capture, so the timestamps do not depend on interrupt latency). A capture ends
after a space longer than 130 ms, 512 durations, or 1 s, and is sent to the app as Capture notifications. Bursts
shorter than 6 durations are treated as noise. Point the original remote at the receiver from 5–30 cm and press
the button briefly once; holding it records the repeat frames too, which helps the app recognise the protocol.

Fluorescent lamps, sunlight and some LED TV backlights produce noise; learn away from them.
