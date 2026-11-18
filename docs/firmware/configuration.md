# Configuration

Two layers configure a build:

- **Kconfig** (`firmware/prj.conf`, `boards/<board>.conf`, or `-DCONFIG_...=` on the command line) — behaviour:
  battery chemistry, learning, drive strength, logging.
- **Devicetree** (`boards/<board>.overlay`) — wiring: which pins, PWM and TIMER instances, battery divider. See
  [porting-a-board.md](porting-a-board.md).

There are no board-specific `#ifdef`s in the code; everything board-related comes from these two.

## openpult options

| Option | Default | Meaning |
|---|---|---|
| `CONFIG_OPENPULT_BATT_CELLS` | 3 | Cells in series. The charge percentage is computed per cell. |
| `CONFIG_OPENPULT_BATT_DIODE_MV` | 250 | Added to the measured voltage: the drop of the Schottky diode between the battery and `B+`. 0 if the battery is measured directly. |
| `CONFIG_OPENPULT_BATT_LI_ION` | n | Li-ion curve (4.20 V = 100 %, 3.30 V = 0 %, low below 3.50 V) instead of the alkaline curve (1.50 V = 100 %, 1.00 V = 0 %, low below 1.10 V per cell). Set by the XIAO and Feather board files together with `CELLS=1`, `DIODE_MV=0`. |
| `CONFIG_OPENPULT_USB_POWERED` | n | No battery: Status reports external power (flags bit 4, `battery_mV = 0`), the Battery Service reports 100 %. Set for the dongle. |
| `CONFIG_OPENPULT_LEARN` | y | Learning through a receiver on `ir-rx-gpios`. Without that devicetree property the bridge does not report the LEARN capability and LEARN_START fails with `0x85`. |
| `CONFIG_OPENPULT_TX_HIGH_DRIVE` | y | High drive strength (H0H1) on the IR output, for an LED driven straight from the pin. Turn off with a transistor driver. |
| `CONFIG_OPENPULT_DEBUG_LED` | n | Light `led0` while transmitting (enabled by `debug.conf`). |
| `CONFIG_OPENPULT_LOG_LEVEL_*` | off | Log level of the firmware modules (`debug.conf` sets DBG). |

Example: a SuperMini on 2×AA (VDDH needs at least 2.5 V, so the pack lasts down to about 1.3 V per cell):

```sh
west build -b promicro_nrf52840/nrf52840/uf2 -d firmware/build firmware -- -DCONFIG_OPENPULT_BATT_CELLS=2
```

## Fixed by the protocol

`prj.conf` sets what [PROTOCOL.md](../../firmware/PROTOCOL.md) requires; change these only together with the app:

- device name `OpenPult`, 0 dBm, two simultaneous connections, static random address (no privacy);
- LE Secure Connections, Just Works, bonding, 2 bonds with the oldest overwritten,
  `CONFIG_BT_SMP_ALLOW_UNAUTH_OVERWRITE=y` (re-pairing after *Forget This Device*);
- ATT MTU 247 / data length 251, no prepared writes;
- connection parameters 15–30 ms, latency 0, 4 s timeout;
- DIS: model `openpult-ir`, firmware revision from `firmware/VERSION`, hardware revision = board target.

## Low-power switches in the devicetree

Both live, commented out, in `firmware/dts/openpult_common.dtsi`:

**DC/DC regulators.** The nRF52840 has two regulators: REG0 (VDDH → VDD, used when powered on `B+`/`VDDH`) and REG1
(VDD → 1.3 V core). Their DC/DC modes cut the idle and radio current noticeably, but **only work if the board has
the inductors** (REG0: on `DCCH`; REG1: between `DCC` and `DEC4`). Enabling DC/DC on a board without them leaves the
chip without a core supply; recovery needs SWD ([flash.md](flash.md)). XIAO and the dongle already enable both in
their board files; for the SuperMini check your clone's schematic or look for the small inductors next to the chip.

```dts
&reg0 { status = "okay"; };
&reg1 { regulator-initial-mode = <NRF5X_REG_MODE_DCDC>; };
```

**32.768 kHz source.** Some clone boards ship with a missing or dead 32 kHz crystal; the firmware then hangs at boot
waiting for it (no advertising, ~1 mA). The internal RC oscillator fixes that at the cost of periodic calibration
(a few µA):

```dts
&lfclk { k32src = "rc"; k32src-accuracy-ppm = <500>; };
```

In Zephyr 4.5 this property replaces the older `CONFIG_CLOCK_CONTROL_NRF_K32SRC_RC`, which only exists with the
deprecated legacy clock driver.

## Peripherals switched off

`openpult_common.dtsi` disables `uart0`, `i2c0/1`, `spi0..3`, `pwm0`, `pwm1` (used directly by the firmware),
`usbd` and the 802.15.4 radio, so no driver initialises them. The production build also has no console, no logging
and no USB stack. Unused QSPI flash chips are put into deep power-down at boot (`suspend-devices`).
