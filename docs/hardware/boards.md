# Supported boards

All boards use the nRF52840. Pins below are the defaults from `firmware/boards/*.overlay`; change them there
([porting-a-board.md](../firmware/porting-a-board.md)). The receiver pins are chosen so that a bare VS1838B
(pin order OUT–GND–VCC) plugs straight into three adjacent header pins.

| Board | Build target | IR TX | RX OUT / GND / VCC | Power input | Battery measured on | Bootloader |
|---|---|---|---|---|---|---|
| **nRF52840 SuperMini**, nice!nano v2 clones (recommended) | `promicro_nrf52840/nrf52840/uf2` | P0.17 (D2) | P0.20 / P0.22 / P0.24 (D3 / D4 / D5) | `B+` (VDDH), 2.5–5.5 V | VDDH/5, internal | UF2 `NICENANO`, app at 0x26000 |
| **Seeed XIAO nRF52840** (Sense) | `xiao_ble/nrf52840` | P0.02 (D0) | P0.03 / P0.28 / P0.29 (D1 / D2 / D3) | `BAT` pads (Li-ion, on-board charger) or `5V` | BAT divider 1M/510k on P0.31 | UF2 `XIAO-SENSE`, app at 0x27000 |
| **Adafruit Feather nRF52840 Express** | `adafruit_feather_nrf52840/nrf52840/uf2` | P1.08 (D5) | P0.07 / P0.26 / P0.27 (D6 / D9 / D10) | JST battery (Li-ion, on-board charger) or USB | VBAT divider 100k/100k on P0.29 | UF2 `FTHR840BOOT`, app at 0x26000 |
| **Nordic nRF52840 Dongle** (PCA10059) | `nrf52840dongle/nrf52840` | P0.17 | P0.20 / P0.22 / P0.24 | USB | none (`CONFIG_OPENPULT_USB_POWERED`) | nRF5 SDK USB DFU, app at 0x1000 |

All boards use PWM1 for the carrier and TIMER2 for learning.

## Notes per board

**SuperMini / nice!nano clones.** The cheapest option (~$3–5) and the reference hardware. Powered on `B+`, the chip
runs in high-voltage mode with its own regulator, so 3×AA through a diode work directly. Avoid P0.09/P0.10 (NFC
antenna pads; freed as GPIO by the board but noisy), P0.13 (switches the `VCC` output pin; the firmware keeps it
low with a gpio-hog) and P0.15 (the on-board LED). Idle current depends on the batch — see
[measuring-current.md](../usage/measuring-current.md). Whether DC/DC can be enabled depends on the clone; most
recent SuperMini boards have the REG1 inductor, check before enabling ([configuration.md](../firmware/configuration.md)).

**XIAO nRF52840.** Small and well documented; DC/DC is enabled by the board files. Battery measurement assumes a
Li-ion cell on the `BAT` pads (`CONFIG_OPENPULT_BATT_LI_ION`, set in `boards/xiao_ble.conf`). P0.14 enables the
battery divider and is held low permanently: driving it high would put the full battery voltage on P0.31. The
on-board QSPI flash is put into deep power-down at boot. If you power it from 3×AA on the `5V` pin instead, the
firmware cannot see that battery: build with `-DCONFIG_OPENPULT_USB_POWERED=y`.

**Feather nRF52840 Express.** Easy to prototype with, but not a low-power board: the NeoPixel and the always-on
VBAT divider draw roughly 0.5–1 mA that the firmware cannot switch off. Use it on USB or with a large Li-ion cell.

**nRF52840 Dongle.** For a USB charger next to the TV. No UF2 bootloader: `ENTER_BOOTLOADER` returns `0x85`;
flashing is described in [flash.md](../firmware/flash.md). The GPIO pads are on the board edge (labels `0.17`,
`0.20`, …).

## What the capabilities mean for the app

The bridge reports in Status `caps`: PLAY and legacy SEND always; LEARN only if the overlay defines `ir-rx-gpios`;
UF2 only with `uf2-bootloader`. The DIS *Hardware Revision* string is the build target, e.g.
`promicro_nrf52840/nrf52840/uf2`.
