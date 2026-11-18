# Flashing

## UF2 boards (SuperMini / nice!nano, XIAO nRF52840, Feather nRF52840)

These boards ship with an Adafruit-style UF2 bootloader: in bootloader mode they appear as a USB drive and accept a
`.uf2` file. No programmer and no software needed.

1. Connect the board over USB.
2. Enter the bootloader: **double-tap reset** (two short presses within half a second; on the SuperMini short the
   `RST` pin to `GND` twice, or use the reset button wired from `RST` to `GND`). The LED starts pulsing and a drive
   appears:

   | Board | Drive name |
   |---|---|
   | SuperMini / nice!nano | `NICENANO` |
   | XIAO nRF52840 | `XIAO-SENSE` (also on the non-Sense board) |
   | Feather nRF52840 Express | `FTHR840BOOT` |

3. Copy `zephyr.uf2` to the drive. The board writes it and restarts; the drive disappears. macOS may complain that
   the disk was not ejected properly — that is expected.

The battery may stay connected: on the SuperMini the Schottky diode stops the on-board charger from pushing current
into the AA cells ([power.md](../hardware/power.md)).

### Without touching the board

Once the bridge runs openpult firmware, the app can put it into the bootloader by sending `ENTER_BOOTLOADER`
(`F0 55 AA`). The bridge answers the write, then about 150 ms later sets
`NRF_POWER->GPREGRET = 0x57` and resets; the bootloader sees the magic value and opens the USB drive. A USB cable to
a computer is still needed to copy the file.

The bridge only offers this when its devicetree node has `uf2-bootloader` (Status `caps` bit 3); otherwise the
command fails with `0x85`.

## nRF52840 Dongle

The dongle has Nordic's nRF5 SDK USB DFU bootloader, not UF2.

1. Press the small side button (RESET, the one marked SW2) while plugging the dongle in, or press it once while it is
   plugged in: the red LED pulses.
2. Flash `firmware/build/zephyr/zephyr.hex` with **nRF Connect for Desktop → Programmer** (select the dongle, add the
   hex file, *Write*), or with `nrfutil`:

   ```sh
   nrfutil nrf5sdk-tools pkg generate --hw-version 52 --sd-req=0x00 \
     --application firmware/build/zephyr/zephyr.hex --application-version 1 openpult.zip
   nrfutil nrf5sdk-tools dfu usb-serial -pkg openpult.zip -p /dev/cu.usbmodem*
   ```

`ENTER_BOOTLOADER` is not supported on the dongle (`0x85`).

## Recovering a board

If the board no longer enters the bootloader (DC/DC enabled on a board without inductors, damaged bootloader),
use SWD: connect a debug probe (J-Link, any CMSIS-DAP probe, a Raspberry Pi Pico running *debugprobe*) to the
`SWDIO`, `SWCLK`, `GND` and `3V3` pads and reinstall the board's UF2 bootloader (for the SuperMini: the nice!nano
build of Adafruit_nRF52_Bootloader, which includes the SoftDevice S140 6.1.1 it expects). Then flash the `.uf2` as
usual. The application alone can also be written over SWD without touching the bootloader:

```sh
west flash -d firmware/build --runner pyocd        # or --runner jlink
```
