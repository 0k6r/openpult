# openpult

**Open-source BLE → IR bridge and iPhone remote for any TV.**
A tiny battery-powered box sits in front of your TV and turns Bluetooth commands from the iPhone app into
infrared — the same signal your original remote sends. It works with TVs whose Wi‑Fi is broken, old CRT sets,
and anything else that listens to a remote control.

[Русская версия](README.ru.md)

- **Any TV.** The bridge plays any IR signal (carrier, timings, repeats); protocols live in the app:
  NEC, Samsung, Sony SIRC, Philips RC5/RC6, Panasonic (Kaseikyo), RCA and more. The app downloads the TV codes of
  [Flipper-IRDB](https://github.com/Lucaslhm/Flipper-IRDB) on request (≈1.3 MB), and an optional receiver lets the
  bridge **learn** buttons from your original remote.
- **A year on AA batteries.** nRF52840 board, 3×AA cells, advertising every ~0.5 s and connected only while the app
  is open.
- **DIY friendly.** About $10 of parts from AliExpress, a few solder joints, a 3D-printed case.
- **Sony BRAVIA over Wi‑Fi too.** For Sony Android TVs the app also speaks Sony IP Control over the home network.
- **English and Russian** user interface.

## How it works

```
iPhone app ──BLE──▶ bridge (nRF52840) ──IR 940 nm──▶ TV sensor
  protocol encoders,     plays the signal:
  brand profiles,        carrier + timings + repeats
  learning decoder
```

## What you need

| Part | Notes |
|---|---|
| nRF52840 board | SuperMini / nice!nano clone (recommended), Seeed XIAO nRF52840, Adafruit Feather nRF52840, nRF52840 Dongle |
| IR LED 940 nm, 5 mm + resistor 180–220 Ω | straight from a GPIO for 5–20 cm; a transistor stage for longer range |
| 3×AA holder + Schottky diode (1N5817 / BAT43) | or 3×AAA, a Li-ion cell, or USB power |
| Optional: IR receiver VS1838B / TSOP38238 | to learn codes from the original remote |
| Optional: SS12D00 switch, 6×6 mm button | power switch and bootloader button |

See [docs/hardware/boards.md](docs/hardware/boards.md), [wiring](docs/hardware/wiring.md) and
[power](docs/hardware/power.md).

## Quick start

1. **Build the bridge** — [docs/hardware/wiring.md](docs/hardware/wiring.md).
2. **Flash the firmware** — download the `.uf2` for your board from Releases, double-tap reset, copy it to the USB
   drive. To build it yourself: [docs/firmware/build.md](docs/firmware/build.md).
3. **Print the case** — [docs/enclosure/printing.md](docs/enclosure/printing.md).
4. **Install the app** — Xcode and a free Apple ID: [docs/app/install.md](docs/app/install.md).
5. **Pair and pick your TV** — switch the bridge on, choose it in the app within 2 minutes, download the TV codes,
   then choose your TV brand, let the app find the power code, or learn the buttons.

## Repository layout

| Path | What |
|---|---|
| `app/` | iOS app (SwiftUI); Swift packages `BraviaKit` (app logic), `PultIR` (IR protocols), `PultProfiles` (TV profile importer) |
| `firmware/` | Zephyr firmware, [`PROTOCOL.md`](firmware/PROTOCOL.md) — the BLE protocol |
| `enclosure/` | parametric 3D-printed case (Python + manifold3d) |
| `profiles/` | format of the TV profiles; the codes themselves are downloaded by the app ([why](docs/ir/profiles.md)) |
| `testdata/` | shared test vectors for the app and the firmware |
| `tools/` | profile importer, vector generator |
| `docs/` | build guides, hardware, protocols |

## Contributing

New TV profiles, boards and protocol decoders are very welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Code: [Apache-2.0](LICENSE). Documentation: CC BY 4.0 ([docs/LICENSE](docs/LICENSE)). TV codes are not part of
this repository — see [profiles/SOURCES.md](profiles/SOURCES.md) and [NOTICE](NOTICE).
