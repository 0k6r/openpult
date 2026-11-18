# Building the firmware

The firmware is a [Zephyr](https://zephyrproject.org) application in `firmware/`, built with `west` against
Zephyr **v4.5.0** and the Zephyr SDK (only the `arm-zephyr-eabi` toolchain is needed). The protocol logic lives in
a plain C library, `firmware/lib/irplay/`, which also builds and runs on your computer (host tests).

Prebuilt `.uf2` files are attached to the GitHub Releases; you only need this page to change the firmware or to
port it to another board.

## 1. Tools

macOS (Homebrew):

```sh
brew install cmake ninja gperf dtc ccache wget python@3.13
```

Debian/Ubuntu:

```sh
sudo apt install --no-install-recommends git cmake ninja-build gperf ccache dfu-util device-tree-compiler \
  wget python3-dev python3-venv xz-utils file make gcc
```

Python 3.10–3.14 works; if a Zephyr script misbehaves on the newest Python, create the venv with 3.13.

## 2. Zephyr workspace (once, ~2.6 GB)

Only the modules the nRF52840 build needs are fetched, shallow:

```sh
python3 -m venv ~/zephyrproject/.venv
source ~/zephyrproject/.venv/bin/activate
pip install west

west init -m https://github.com/zephyrproject-rtos/zephyr --mr v4.5.0 --clone-opt=--depth=1 ~/zephyrproject
cd ~/zephyrproject
west config manifest.project-filter -- \
  '-.*,+cmsis,+cmsis_6,+hal_nordic,+mbedtls,+tf-psa-crypto,+tf-psa-crypto-drivers,+segger,+picolibc'
west update --narrow -o=--depth=1
pip install -r zephyr/scripts/requirements-base.txt
west sdk install -b ~/zephyrproject -t arm-zephyr-eabi
```

The repository does not have to live inside the workspace.

## 3. Build

From the repository root, in a shell with the venv active:

```sh
source ~/zephyrproject/.venv/bin/activate
export ZEPHYR_BASE=~/zephyrproject/zephyr

west build -p -b promicro_nrf52840/nrf52840/uf2 -d firmware/build firmware
```

| Board | `-b` |
|---|---|
| nRF52840 SuperMini, nice!nano v2 clones | `promicro_nrf52840/nrf52840/uf2` |
| Seeed XIAO nRF52840 / Sense | `xiao_ble/nrf52840` / `xiao_ble/nrf52840/sense` |
| Adafruit Feather nRF52840 Express | `adafruit_feather_nrf52840/nrf52840/uf2` |
| Nordic nRF52840 Dongle | `nrf52840dongle/nrf52840` |

Output: `firmware/build/zephyr/zephyr.uf2` (the dongle uses `zephyr.hex`). Flashing: [flash.md](flash.md).

`-p` (pristine) is only needed when you switch boards or configuration files; plain `west build -d firmware/build`
rebuilds incrementally.

### Debug build

```sh
west build -p -b promicro_nrf52840/nrf52840/uf2 -d firmware/build-debug firmware -- -DEXTRA_CONF_FILE=debug.conf
```

Adds a USB serial console with logs (`CONFIG_LOG`, Bluetooth at info level, the firmware at debug level),
assertions, and lights the board LED while IR is transmitted. `firmware/CMakeLists.txt` adds `debug.overlay`
automatically, which turns the USB controller back on. The debug build draws milliamps in idle (USB, logging) — use
it on the bench, not on batteries.

Logs appear about 4 s after reset:

```sh
screen /dev/cu.usbmodem* 115200      # macOS; Linux: /dev/ttyACM0
```

### Sizes (v2.0.0)

| Board | Release flash / RAM | Debug flash / RAM |
|---|---|---|
| promicro_nrf52840/nrf52840/uf2 | 167.4 KB / 53.3 KB | 250.6 KB / 65.8 KB |
| xiao_ble/nrf52840 | 172.2 KB / 53.4 KB | 256.9 KB / 66.0 KB |
| adafruit_feather_nrf52840/nrf52840/uf2 | 173.6 KB / 53.0 KB | 260.0 KB / 65.3 KB |
| nrf52840dongle/nrf52840 | 166.9 KB / 53.3 KB | 249.1 KB / 65.8 KB |

## 4. Host tests

The OS-independent part (blob parser, fragment reassembly, press queue and HOLD rules, SIRC builder, carrier
quantisation, capture encoding, Status encoding, battery curves) is tested with the system C compiler, AddressSanitizer
and UBSan, against the shared vectors in `testdata/ir_vectors.json`:

```sh
make -C firmware/tests/host test
```

The Makefile turns the JSON into a C header with a small Python script (`python3 -I`), so the C and Swift tests
check the same bytes. Regenerate the vectors after a protocol change with `python3 tools/gen_ir_vectors.py` and
check them with `--check`.

## Layout

```
firmware/
  PROTOCOL.md                BLE protocol (contract with the app)
  CMakeLists.txt, Kconfig    application, CONFIG_OPENPULT_* options
  prj.conf, debug.conf       production / debug configuration
  VERSION                    firmware version (DIS Firmware Revision)
  boards/                    one overlay (+ optional .conf) per board
  dts/                       openpult,ir-bridge binding, shared overlay part
  lib/irplay/                protocol logic, plain C, no OS
  src/
    main.c                   start-up, Status, battery, capture delivery
    ble.c                    GATT service, advertising, pairing policy, timeouts
    ir.c                     command handling, transmit scheduling, learning
    battery.c                SAADC measurement
    ir_hal.h                 transmitter/receiver backend interface
    hal/nrf/                 nRF52 backend: PWM streaming, GPIOTE + TIMER capture
  tests/host/                host tests
```
