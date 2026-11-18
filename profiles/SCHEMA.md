# TV profile format (schema 1)

Profiles describe which IR code to send for each key of the openpult remote. They are built from
[Flipper-IRDB](https://github.com/Lucaslhm/Flipper-IRDB) — on the phone by the app (`PultProfiles`, after the user
downloads the database) or on a computer by `tools/profiles/import_flipper_irdb.py`. Both produce byte-identical
files in this layout; none of them is committed (see [`SOURCES.md`](SOURCES.md) and `docs/ir/profiles.md`).

```
profiles/               (generated; only SCHEMA.md and SOURCES.md are in git)
  index.json            brands and source
  brands/<brand-id>.json profiles of one brand
  power_scan.json       unique power codes, most common first
```

All files are UTF-8 JSON. Readers must ignore unknown fields so that optional fields can be added within schema 1;
a breaking change increments `schema`.

## index.json

```json
{
  "schema": 1,
  "source": {"db": "Flipper-IRDB", "url": "https://github.com/Lucaslhm/Flipper-IRDB",
             "commit": "<40-char sha>", "license": "CC0-1.0", "note": "<optional license remark>"},
  "brands": [
    {"id": "samsung", "name": "Samsung", "file": "brands/samsung.json", "profiles": 55}
  ]
}
```

| Field | Meaning |
|---|---|
| `schema` | format version, `1` |
| `source.commit` | Flipper-IRDB commit the profiles were built from |
| `source.note` | optional; currently the upstream README remark about commits not covered by CC0 |
| `brands[].id` | `[a-z0-9]+(-[a-z0-9]+)*`, unique, sorted; also the file name |
| `brands[].name` | display name (the Flipper-IRDB folder name) |
| `brands[].profiles` | number of profiles in the brand file |

## brands/&lt;brand-id&gt;.json

An array of profiles, most likely first (`weight` descending, then the number of mapped keys).

```json
{
  "id": "samsung-1",
  "brand": "Samsung",
  "name": "Samsung TV (BN59-01175N)",
  "models": ["BN59-01175N"],
  "weight": 1,
  "source": ["TVs/Samsung/Samsung_BN59-01175N.ir"],
  "keys": {
    "power": {"p": "Samsung32", "a": 7, "c": 2},
    "mute": {"raw": {"f": 38000, "d": 33, "i": [], "r": [4500, 4500, 560, 1690, 560, 40000]}}
  },
  "extra": [
    {"name": "Tools", "cmd": {"p": "Samsung32", "a": 7, "c": 75}}
  ]
}
```

| Field | Meaning |
|---|---|
| `id` | `<brand-id>-<n>`, `n` = position in the file from 1. Stable for a given source commit only |
| `name` | display name: brand + models or file label, ≤ 120 characters; unique within the brand (`#2` suffix if needed) |
| `models` | model or remote numbers guessed from the source file names (may be empty) |
| `weight` | number of source files with exactly this set of codes |
| `source` | source files merged into this profile, sorted; `TVs/...` from Flipper-IRDB, `contrib/TVs/...` from `tools/profiles/contrib` |
| `keys` | app key → command, in the key order below; only keys the remote has |
| `extra` | other buttons, in file order, with their original (cleaned) names; codes already used by a key are not repeated |

### Keys

`RemoteKey.rawValue` of the app, in this order:

`power powerOff wakeUp input home back options up down left right confirm volumeUp volumeDown mute channelUp
channelDown play pause stop rewind forward previous next red green yellow blue num0 … num9 display subtitles
audioTrack guide hdmi1 hdmi2 hdmi3 hdmi4 menu exit teletext lastChannel`

`power` is a toggle, `powerOff` / `wakeUp` are discrete off / on. `play` and `pause` hold the same command when the
remote has a single play/pause button. Button names are mapped by `tools/profiles/key_aliases.json`.

### Commands

A command is either a decoded code or a raw signal.

**Decoded** — `{"p": <protocol>, "a": <address>, "c": <command>}`. `p` is the Flipper protocol name, `a` and `c` are
UInt32 values (Flipper stores them as 4 little-endian bytes: `address: 07 00 00 00` → 7). The app encodes them.

| `p` | address bits | command bits |
|---|---|---|
| `NEC` | 8 | 8 |
| `NECext` | 16 | 16 |
| `NEC42` | 13 | 8 |
| `NEC42ext` | 26 | 16 |
| `Samsung32` | 8 | 8 |
| `RC5` | 5 | 6 |
| `RC5X` | 5 | 7 |
| `RC6` | 8 | 8 |
| `SIRC` | 5 | 7 |
| `SIRC15` | 8 | 7 |
| `SIRC20` | 13 | 7 |
| `Kaseikyo` | 26 | 10 |
| `RCA` | 4 | 8 |
| `Pioneer` | 8 | 8 |

The widths are the limits the Flipper firmware enforces; codes outside them are dropped on import. Carrier, timing
and bit layout are defined by the protocol; the Flipper Zero encoders (`lib/infrared` in the Flipper firmware) are
the reference for how `a` and `c` are laid out. Two examples: `NEC` `a`/`c` are 8-bit values and the encoder adds
the inverted bytes; `NECext` `a`/`c` are the 16-bit fields as sent (`address: 86 05 00 00`, `command: 0F F0 00 00`
→ `a = 0x0586`, `c = 0xF00F`).

**Raw** — `{"raw": {"f": <carrier Hz>, "d": <duty %>, "i": [...], "r": [...]}}`. `i` (intro) is played once, then
`r` (repeat) is played as often as the app decides and while the key is held — exactly the `intro` / `repeat`
sections of protocol v2 (`firmware/PROTOCOL.md`). Durations are microseconds, alternating mark/space starting with a
mark; each section has even length and ends with a space (the gap before the next frame).

Guarantees for every raw command (checked by `tools/profiles/test_import.py`):

- `20000 ≤ f ≤ 65535`, `10 ≤ d ≤ 50` (Flipper `duty_cycle: 0.33` → 33);
- `2 ≤ len(i) + len(r) ≤ 1024`, `r` is not empty;
- every duration is in `50..500000` (the protocol accepts from 1 µs; anything under 50 µs is receiver
  noise), every mark ≤ 30 ms, each section sums to ≤ 1 s;
- at most 16 distinct durations in `i + r` (the protocol v2 table), blob ≤ 576 bytes.

So the app can build the PLAY blob directly: table = distinct durations in order of first appearance.

How a Flipper recording (one press, captured by a demodulating receiver) becomes `i` / `r`:

1. A recording ending with a mark gets a 40 000 µs space; one ending inside a frame (space ≤ 20 ms) has its last
   space set to 40 000 µs.
2. It is split into frames after every space longer than 20 ms. Trailing lone marks (frames of one mark) are
   dropped when the recording has a real frame, and so is a last frame cut off by the end of the recording (shorter
   than the previous one and matching its start). A recording made only of lone marks is noise and is dropped.
3. Repeated frames are kept once: `A A A` → `r = A`; `A B B` or `A B` → `i = A`, `r = B` (e.g. NEC frame + repeat
   code); `A B A B` → `r = A B` (frame pairs such as Sharp); anything else → `r` = the whole recording. Frames
   match when they have the same length and each duration is within 25 % (at least 200 µs); the kept frame keeps
   its recorded trailing gap.
4. Durations of `i + r` are clustered: each value is replaced by the count-weighted mean of its cluster, and every
   member stays within ±5 % of it.
5. Signals that still break a limit above are dropped (and counted by the importer).

## power_scan.json

Unique power codes for "find my TV" scanning, most common first:

```json
[
  {"cmd": {"p": "NEC", "a": 4, "c": 8}, "brands": ["LG", "Vizio", "Hisense"], "weight": 55}
]
```

`cmd` is the profile's `power` key, or `wakeUp` when the profile has no `power`. `weight` = total `weight` of the
profiles using the code, `brands` sorted by their share. Sorted by `weight`, then number of brands.

## Stability

The importer is deterministic: files, profiles, keys and arrays are written in a fixed order, so re-importing the
same commit gives byte-identical output (`OPENPULT_IRDB=<checkout> python3 -I -m unittest discover -s
tools/profiles` verifies it). Profile ids can change when the source commit changes; store a user's choice as
brand id + `source` paths + commands, not as the id alone.
