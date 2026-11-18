# Porting to another nRF52840 board

Any nRF52840 board that Zephyr supports can run the bridge. A port is one devicetree overlay (and optionally a
Kconfig fragment) in `firmware/boards/`; no C code changes.

## 1. Find the board target

```sh
west boards | grep -i 52840
```

The overlay file name is the board target with `/` replaced by `_`, e.g. `xiao_ble/nrf52840` →
`boards/xiao_ble_nrf52840.overlay`. A file named after the board only (`boards/xiao_ble.overlay`) covers all its
variants. Zephyr picks `boards/<target>.conf` the same way.

## 2. Write the overlay

Start from the SuperMini overlay (`boards/promicro_nrf52840_nrf52840_uf2.overlay`):

```dts
#include "../dts/openpult_common.dtsi"      /* switches unused peripherals off */

/ {
	openpult {
		compatible = "openpult,ir-bridge";
		ir-pwm = <&pwm1>;                           /* required */
		ir-tx-gpios = <&gpio0 17 GPIO_ACTIVE_HIGH>; /* required */

		/* optional receiver for learning */
		ir-rx-gpios = <&gpio0 20 GPIO_ACTIVE_LOW>;
		ir-rx-gnd-gpios = <&gpio0 22 GPIO_ACTIVE_LOW>;
		ir-rx-power-gpios = <&gpio0 24 GPIO_ACTIVE_HIGH>;
		ir-rx-timer = <&timer2>;

		battery = <&vbatt>;                         /* optional */
		uf2-bootloader;                             /* only with a UF2 bootloader */
		suspend-devices = <&qspi_flash>;            /* optional, needs CONFIG_PM_DEVICE */
	};

	vbatt: vbatt {
		compatible = "voltage-divider";
		io-channels = <&adc 0>;
		output-ohms = <1>;
		full-ohms = <5>;
	};
};

&adc {
	channel@0 {
		reg = <0>;
		zephyr,gain = "ADC_GAIN_1_2";
		zephyr,reference = "ADC_REF_INTERNAL";
		zephyr,acquisition-time = <ADC_ACQ_TIME(ADC_ACQ_TIME_MICROSECONDS, 40)>;
		zephyr,input-positive = <NRF_SAADC_VDDHDIV5>;
		zephyr,resolution = <12>;
		zephyr,oversampling = <3>;
	};
};
```

The properties are documented in `firmware/dts/bindings/openpult,ir-bridge.yaml`:

| Property | Notes |
|---|---|
| `ir-pwm` | PWM instance for the carrier. Must be **disabled** (`openpult_common.dtsi` disables `pwm0` and `pwm1`); the firmware drives it through nrfx. |
| `ir-tx-gpios` | IR LED or driver input. `GPIO_ACTIVE_LOW` is supported (e.g. a PNP high-side driver). Any GPIO except the NFC pins (P0.09/P0.10, unless the board frees them) and pins the board uses. |
| `ir-rx-gpios` | Receiver output, `GPIO_ACTIVE_LOW` (the modules pull low on a carrier). Enables learning. |
| `ir-rx-power-gpios` | Receiver supply, switched on only while learning. A GPIO can supply the 0.4–1.5 mA a receiver needs. |
| `ir-rx-gnd-gpios` | Optional: a GPIO held low as the receiver's ground, so the module fits three adjacent pins. |
| `ir-rx-timer` | TIMER for edge timestamps; **not** TIMER0/TIMER1 (Bluetooth controller). Leave the node disabled. |
| `battery` | A `voltage-divider` node: ADC channel and ratio. VDDH/5 (powered on `VDDH`/`B+`): `output-ohms = <1>`, `full-ohms = <5>`. An external divider: the real resistor values. |
| `uf2-bootloader` | The board has an Adafruit-style UF2 bootloader (GPREGRET `0x57`). |
| `suspend-devices` | Devices put to sleep at boot, typically an unused QSPI flash (needs `CONFIG_NORDIC_QSPI_NOR=y` and `CONFIG_PM_DEVICE=y` in the board `.conf`). |

Also in the overlay:

- **Pins that must have a fixed level**: use a `gpio-hog` (see the SuperMini's VCC switch on P0.13 and the XIAO's
  battery divider enable on P0.14).
- **ADC channel**: one `channel@N` per `io-channels` entry. For an external divider pick a gain so that the divided
  full-battery voltage stays below the full scale (internal reference 0.6 V / gain; e.g. gain 1/6 → 3.6 V).

## 3. Kconfig fragment (optional)

`boards/<target>.conf`, for example a board measuring a Li-ion cell directly:

```
CONFIG_OPENPULT_BATT_LI_ION=y
CONFIG_OPENPULT_BATT_CELLS=1
CONFIG_OPENPULT_BATT_DIODE_MV=0
```

Check the board's link address too: a UF2 board must link the application into its code partition
(`CONFIG_USE_DT_CODE_PARTITION=y`). The build prints `start address:` for the `.uf2` — it must match the
bootloader (0x26000 for S140 6.x layouts, 0x27000 for S140 7.x).

## 4. Build and check

```sh
west build -p -b <target> -d firmware/build-<name> firmware
west build -p -b <target> -d firmware/build-<name>-debug firmware -- -DEXTRA_CONF_FILE=debug.conf
```

In `firmware/build-<name>/zephyr/zephyr.dts` check that the `openpult` node, the PWM and TIMER instances are as
intended and that `pwm1`/`timer2` are `disabled`. On hardware: the debug build logs the board target at boot,
the LED lights while transmitting, and Status `caps` shows LEARN/UF2 as expected.

Then add the board to [boards.md](../hardware/boards.md) and the CI build matrix.

## Other SoC families

The firmware talks to the IR hardware only through `firmware/src/ir_hal.h` (transmit a section, power the
transmitter, receive edges with microsecond timestamps). The nRF52 implementation is in `src/hal/nrf/`. Another
family (e.g. ESP32 with its RMT peripheral) needs its own `src/hal/<family>/` implementing that header and
`platform.h`, plus a `CMakeLists.txt` entry; the protocol library is shared unchanged.
