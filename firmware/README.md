# openpult firmware

Zephyr firmware for the openpult BLE → IR bridge (nRF52840). It plays any IR signal the app describes (carrier,
duty cycle, timings, intro and repeat sections), learns codes with an optional receiver, and runs for a year or
more on 3×AA.

- Protocol (contract with the app): [PROTOCOL.md](PROTOCOL.md)
- Build: [docs/firmware/build.md](../docs/firmware/build.md) · Flash: [docs/firmware/flash.md](../docs/firmware/flash.md)
- Options: [docs/firmware/configuration.md](../docs/firmware/configuration.md) ·
  New board: [docs/firmware/porting-a-board.md](../docs/firmware/porting-a-board.md)
- Hardware: [boards](../docs/hardware/boards.md), [wiring](../docs/hardware/wiring.md),
  [power](../docs/hardware/power.md), [IR transmitter](../docs/hardware/ir-transmitter.md),
  [IR receiver](../docs/hardware/ir-receiver.md)
- Checking idle current: [docs/usage/measuring-current.md](../docs/usage/measuring-current.md)

Quick start:

```sh
source ~/zephyrproject/.venv/bin/activate && export ZEPHYR_BASE=~/zephyrproject/zephyr
west build -p -b promicro_nrf52840/nrf52840/uf2 -d firmware/build firmware   # firmware/build/zephyr/zephyr.uf2
make -C firmware/tests/host test                                              # host tests
```
