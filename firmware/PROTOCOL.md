# openpult IR bridge — BLE protocol v2

Shared contract between the firmware (`firmware/`) and the iOS app (`app/BraviaKit/Sources/BraviaKit/Blaster*.swift`,
and `app/BraviaKit/Sources/PultIR/`). Any change here must be mirrored on both sides together with the shared vectors in
`testdata/ir_vectors.json`.

The bridge knows nothing about TV protocols: it plays a modulated signal described by the app
(carrier, duty cycle, durations, an *intro* section played once and a *repeat* section played N times and
while a button is held). Toggle bits, checksums and bit layouts are computed by the app.

## Advertising

| Item | Value |
|---|---|
| Device name (scan response) | `OpenPult` |
| Advertised service UUID (adv data, 128-bit) | `7B2A0001-5C1E-4F6B-9D3A-8E4F1C2B7A10` |
| Flags | LE General Discoverable, BR/EDR not supported |
| Address | static random identity, no privacy (iOS keeps the peripheral identifier) |
| TX power | 0 dBm |
| Interval | 152.5 ms for 30 s after boot or disconnect, then 546.25 ms |
| Connectable | yes (security: encryption + pairing policy below) |

## GATT

Service `7B2A0001-5C1E-4F6B-9D3A-8E4F1C2B7A10`:

| Characteristic | UUID | Properties | Permissions |
|---|---|---|---|
| Command | `7B2A0002-5C1E-4F6B-9D3A-8E4F1C2B7A10` | Write (with response) | write encrypted |
| Status  | `7B2A0003-5C1E-4F6B-9D3A-8E4F1C2B7A10` | Read, Notify | read encrypted; CCC write encrypted |
| Capture | `7B2A0004-5C1E-4F6B-9D3A-8E4F1C2B7A10` | Notify | CCC write encrypted |

Standard services:
- Battery Service `0x180F`, Battery Level `0x2A19` (read, notify), percent 0–100.
- Device Information `0x180A`: Model Number `0x2A24` = `openpult-ir`, Firmware Revision `0x2A26` = semver
  (`2.x.y`), Hardware Revision `0x2A27` = Zephyr board target (e.g. `promicro_nrf52840/nrf52840/uf2`).

All Command writes are *write with response*: iOS starts pairing only when an ATT request fails with
Insufficient Encryption / Authentication. Prepared (long) writes are not used (`CONFIG_BT_ATT_PREPARE_COUNT=0`);
the app fragments large signals itself.

### MTU
Firmware: `CONFIG_BT_L2CAP_TX_MTU=247`, `CONFIG_BT_BUF_ACL_RX_SIZE=251`, `CONFIG_BT_BUF_ACL_TX_SIZE=251`,
`CONFIG_BT_CTLR_DATA_LENGTH_MAX=251`. One write carries at most 244 bytes. The app uses
`min(maximumWriteValueLength(for: .withoutResponse), 244)` as the write size (iOS reports 512 for
`.withResponse`, which means a queued long write).

## Commands (Command characteristic, first byte = opcode)

### `0x10` PLAY — one fragment of a signal
```
[0]  0x10
[1]  flags     reserved, 0
[2]  sig_id    press token chosen by the app (1..255, a new one for every new press)
[3]  frag      bit7 = LAST, bits6..0 = fragment index from 0 (a single-fragment signal uses 0x80)
[4…] chunk of the signal blob
```
- Fragment 0 resets the reassembly buffer. A different `sig_id` or a skipped index → error `0x80`, buffer reset.
- Reassembly times out after 2 s. *(Clarified by the firmware: measured from the previous fragment; a 576-byte
  blob at the minimum MTU needs ~36 writes with response, which can take longer than 2 s in total.)*
- On LAST the blob is validated and queued.

### Signal blob (little-endian)
```
off  size
0    2   carrier_hz   u16, 20000..65535
2    1   duty_pct     u8, 10..50; 0 => 33
3    1   min_repeats  u8, 0..20
4    1   table_n      u8, 1..16
5    2   intro_n      u16, number of intro symbols (even, may be 0)
7    2   repeat_n     u16, number of repeat symbols (even, may be 0)
9    …   table        table_n × LEB128 varint, microseconds (1..500000)
…    …   intro        ceil(intro_n / 2) bytes, 4 bits per symbol, high nibble first, padded with 0
…    …   repeat       ceil(repeat_n / 2) bytes, starts on a byte boundary
```
- A symbol is an index into the table. Symbols alternate mark, space, starting with a mark. Each section ends with a
  space, so the inter-frame gap belongs to the section (a fixed period such as NEC 108 ms or SIRC 45 ms is turned
  into `gap = period − frame length` by the app).
- Limits: `2 ≤ intro_n + repeat_n ≤ 1024`, blob ≤ 576 bytes, a single mark ≤ 30 ms, a section ≤ 1 s.
  Otherwise error `0x84`.
- The firmware rounds durations to whole carrier periods against the cumulative time (no drift). Tests allow
  ±1 carrier period per edge.

Playback of one press:
- intro and repeat: intro once, then repeat × `min_repeats`;
- repeat only: repeat × `max(1, min_repeats)`;
- intro only: intro × `max(1, min_repeats)`; the intro is then the repeat unit.
- Consecutive presses are separated by at least 90 ms of silence after the previous press.

### `0x11` HOLD — 3 bytes: `11 <sig_id> <count>`
- Nothing is queued. The transmission is extended so that exactly `count` repeat units (clamped 1..20) are played
  counting from the unit currently on air.
- Applies when `sig_id` is the signal on air, or the last one that finished less than
  `max(200 ms, 2 × repeat unit)` ago; in that case only the repeat section is played (no intro).
- *(Clarified by the firmware:)* HOLD never shortens a press — the result is `max(units the press still has to
  play, count)`; it also applies to a press with that `sig_id` still waiting in the queue (its unit count is raised
  when it starts), so a slow queue does not turn a HOLD into a second press.
- Otherwise error `0x83`; the app then sends a regular PLAY.
- The app sends the first HOLD ~100 ms after the press — while the press is still on air, so the TV sees one
  continuous press like a held physical remote and applies its own auto-repeat — then about every 120 ms while the
  button is held, with
  `count = clamp(ceil(180 ms / repeat unit) + 1, 2, 20)` (SIRC 45 ms → 5, NEC 108 ms → 3).
- The firmware never repeats beyond what was requested, so a lost release cannot cause a stuck key.

### `0x02` STOP — 1 byte
Clears the queue and stops learning; the unit currently on air finishes.

### `0x20` LEARN_START — 2 bytes: `20 <timeout_s>` (1..60, 0 → 20)
### `0x21` LEARN_STOP — 1 byte
See *Learning*. Error `0x85` if the board has no receiver.

### `0xF0` ENTER_BOOTLOADER — 3 bytes: `F0 55 AA`
The write response is sent first; ~150 ms later the firmware sets `NRF_POWER->GPREGRET = 0x57` and resets into the
UF2 bootloader (USB drive `NICENANO` or the board's own name). Error `0x85` on boards without a UF2 bootloader.

### `0x01` SEND (legacy v1, deprecated, removed in protocol 3)
`[0x01][flags bit0 HOLD][bits 12|15|20][dev_lo][dev_hi][cmd][frames 3..20]` — a Sony SIRC code (frames 0 → 3).
The firmware converts it into a repeat section (T = 600 µs, 40 kHz, 45 ms period) and plays it with the universal
player; HOLD follows the v1 rule (same code on air or finished < 200 ms ago → extend to `frames` frames).
Apps talking to `proto_ver ≥ 2` always use PLAY, Sony included.

### Errors (ATT application error codes returned for the write)
| Code | Meaning |
|---|---|
| `0x80` | malformed payload (opcode, length, fragment order, bad magic) |
| `0x81` | queue full (8 presses or 2048 bytes of signal data) |
| `0x82` | unsupported SIRC bit count (legacy SEND) |
| `0x83` | HOLD has nothing to extend |
| `0x84` | signal not supported (carrier, length, long mark, blob limits; also any malformed blob: truncated varint, wrong total size, symbol ≥ `table_n`) |
| `0x85` | feature not available on this board (no receiver, no UF2 bootloader) |

## Learning
- Optional demodulating receiver (VS1838B, TSOP38238, KY-022) powered from a GPIO (`ir-rx-power-gpios`, optional
  `ir-rx-gnd-gpios`) only while learning; otherwise its ~0.4 mA would drain the batteries.
- After LEARN_START: power the receiver, wait 20 ms, capture both edges (GPIOTE + 1 MHz timer). The output is
  active low: the first falling edge starts a mark.
- A capture ends after a space > 130 ms, 512 durations, or 1.0 s after the first edge. Bursts shorter than
  6 durations are noise and are ignored. One capture per LEARN_START; learning ends on capture, timeout, STOP or PLAY
  *(firmware: also on a legacy SEND or a successful HOLD — anything that transmits, so the bridge never records its
  own signal)*.
- 130 ms keeps several repeats of NEC / RC5 / Kaseikyo (74–96 ms gaps) in one capture so the app can see the
  intro / repeat structure.
- The carrier cannot be measured (the receiver demodulates); the app derives it from the decoded protocol.
- While learning, the 10-minute idle disconnect is suspended.

Capture notifications:
```
[0]   capture_id   counter of captures
[1]   frag         bit7 = LAST, bits6..0 = index
fragment 0: [2] flags (bit0 TRUNCATED, bit1 TIMEOUT = no signal, count = 0)
            [3-4] count u16 LE
            [5…] durations: LEB128 varint µs, mark/space starting with a mark
next:       [2…] continuation (split only on varint boundaries)
```

## Status — 12 bytes (read / notify); v1 apps read the first 8
```
[0]    proto_ver = 2
[1]    flags: bit0 transmitting, bit1 pairing window open, bit2 battery low, bit3 learning, bit4 external power
[2-3]  battery_mV u16 LE (estimated cell-stack voltage incl. diode drop compensation; 0 if externally powered)
[4]    queue_free (0..8)
[5]    last_error (0 = none, otherwise an error code above)
[6-7]  uptime_min u16 LE (saturates at 65535)
[8]    caps: bit0 PLAY, bit1 LEARN (receiver present), bit2 legacy SEND, bit3 UF2 bootloader
[9-10] max_blob u16 LE (576)
[11]   reserved, 0
```
Notified on connect (once subscribed), when flags or queue_free change, and after every battery measurement.
The app relies on `proto_ver` and `caps`, not on DIS strings.

## Security / pairing policy
- LE Secure Connections, Just Works, bonding; up to 2 bonds, the oldest is overwritten.
- New pairing is accepted only if (a) there are no bonds yet, or (b) within 120 s after power-on.
  `CONFIG_BT_SMP_ALLOW_UNAUTH_OVERWRITE=y`, so re-pairing after "Forget This Device" on the iPhone works inside the
  window.
- A connection that is not encrypted within 30 s is dropped (the timer is paused while SMP is in progress).
- A connection without commands for 10 minutes is dropped.
- `CONFIG_BT_GATT_SERVICE_CHANGED=y` so iOS refreshes its GATT cache after a firmware update.
- Reset of pairing: iPhone Settings → Bluetooth → OpenPult → Forget, power-cycle the bridge, pair within 120 s.

## Connection parameters
Peripheral requests interval 15–30 ms, latency 0, supervision timeout 4 s.

## Battery
- SAADC on VDDHDIV5 at boot, on connect and every 10 minutes, never during IR transmission.
- `battery_mV = measured_VDDH_mV + CONFIG_OPENPULT_BATT_DIODE_MV` (250 by default).
- Percent from per-cell voltage (`CONFIG_OPENPULT_BATT_CELLS`, 3 by default), piecewise linear:
  1.50 V → 100, 1.30 V → 60, 1.20 V → 35, 1.10 V → 15, 1.00 V → 0. Low flag below 1.10 V per cell.
- USB-powered builds (`CONFIG_OPENPULT_USB_POWERED`) report flags bit4 and battery 100 %.

## Reference vectors
Machine-readable copy: `testdata/ir_vectors.json` (used by Swift and firmware host tests).

### Sony Power as PLAY (12-bit SIRC, value 0xA90)
Table `[2400, 600, 1200, 25800]`, `min_repeats = 3`, repeat only, 26 symbols:
```
10 00 01 80                          PLAY, sig_id 1, single fragment
40 9C 21 03 04 00 00 1A 00           40000 Hz, 33 %, min 3, 4 entries, intro 0, repeat 26
E0 12  D8 04  B0 09  C8 C9 01        2400, 600, 1200, 25800
01 21 11 21 11 21 11 11 21 11 11 11 13
```
35 bytes. 25800 = 45000 µs period − 19200 µs of frame.

### SIRC codes (legacy SEND and IRCC mapping)
| Key | IRCC | bits | dev | cmd | Value (transmission order, MSB-first written) |
|---|---|---|---|---|---|
| Power | `AAAAAQAAAAEAAAAVAw==` | 12 | 1 | 21 | `0xA90` |
| WakeUp | `AAAAAQAAAAEAAAAuAw==` | 12 | 1 | 46 | `0x750` |
| PowerOff | `AAAAAQAAAAEAAAAvAw==` | 12 | 1 | 47 | `0xF50` |
| Num1 | `AAAAAQAAAAEAAAAAAw==` | 12 | 1 | 0 | `0x010` |
| VolumeUp | `AAAAAQAAAAEAAAASAw==` | 12 | 1 | 18 | `0x490` |
| Back | `AAAAAgAAAJcAAAAjAw==` | 15 | 151 | 35 | `0x62E9` |
| Options | `AAAAAgAAAJcAAAA2Aw==` | 15 | 151 | 54 | `0x36E9` |
| Hdmi1 | `AAAAAgAAABoAAABaAw==` | 15 | 26 | 90 | `0x2D58` |

SIRC timing: T = 600 µs, carrier 40 kHz, duty 1/3. Frame = start mark 4T + space 1T, then per bit mark 2T (1) or
1T (0) followed by space 1T; frames start every 45 ms (75 slots of T).

IRCC format (13 bytes after base64): `u32 BE type | u32 BE device | u32 BE command | u8 0x03`;
type 1 = 12-bit, 2 = 15-bit, 3 = 20-bit (device field = `device5 | extended8 << 5`).

## Changes from v1
- New: PLAY / HOLD (universal signals with fragmentation), LEARN_START / LEARN_STOP, Capture characteristic,
  Status bytes 8–11, errors `0x83`–`0x85`, DIS Hardware Revision, device name `OpenPult`.
- Unencrypted connections are dropped after 30 s (was 10 s); CCCs require encryption.
- ENTER_BOOTLOADER answers before rebooting.
- SEND (`0x01`) is deprecated.
