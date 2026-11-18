# TV profiles

The app matches your TV against the TV remotes collected in
[Flipper-IRDB](https://github.com/Lucaslhm/Flipper-IRDB) (folder `TVs/`). **The codes are not part of this
repository and are not bundled with the app**: the app downloads them from GitHub when you tap *Download TV codes*
and builds the profiles on the phone. This page explains how that works, how to add your TV, and how to build the
profiles on a computer for development.

## Why the codes are downloaded

Flipper-IRDB's `LICENSE` is CC0-1.0, but its README adds that commits before
[`2319685`](https://github.com/Lucaslhm/Flipper-IRDB/commit/2319685f2cbf0cd3f809609622cade14d24fb819)
(2025-08-07, the commit that added the license) are not covered — and most files in `TVs/` are older than that.
So openpult does not redistribute the database. The phone fetches it directly from the original repository, for the
user's own use, the same way it would fetch any public file.

## How the app gets the database

1. On request, the app reads the file list of `TVs/` at a pinned commit (or, with *Check for updates*, the newest
   commit on `main`) through the GitHub API — 2 to 4 API calls — and downloads the files (≈1.3 MB, ≈400 files) from
   `raw.githubusercontent.com`.
2. Every file is checked against its git blob SHA-1, and every folder against its git tree SHA up to `TVs/`. For the
   pinned commit the `TVs/` tree must equal the SHA built into the app, so a tampered response cannot change the
   content.
3. The upstream `LICENSE` is checked; if it changes, the app refuses to import and says why.
4. The importer (`app/BraviaKit/Sources/PultProfiles`, a Swift port of `tools/profiles/import_flipper_irdb.py`)
   builds the profiles in the format described in [`profiles/SCHEMA.md`](../../profiles/SCHEMA.md) and stores them
   in the app's Application Support folder (excluded from backups). Downloaded files are kept, so an update fetches
   only what changed and a newer app version can rebuild without the network.

Requests go only to `api.github.com` and `raw.githubusercontent.com`, only when you ask, with the user agent
`openpult/<version>` and no device identifiers. GitHub sees the phone's IP address, as with any download. The
GitHub API allows 60 unauthenticated requests per hour per IP address; if a shared mobile IP hits the limit, the
app says when to retry.

Without the database the app still works: the built-in Sony profile and learning buttons from the original remote
need no download. A TV remote you already set up is a snapshot of its codes and keeps working when the database is
updated or deleted.

## Add your TV

### 1. Get the codes

Any of these produce a Flipper `.ir` file:

- a Flipper Zero: *Infrared → Learn New Remote*, one button at a time;
- the app: learn the buttons, then *⋯ → Share remote* exports them;
- writing it by hand if you know the protocol, address and command.

Name the buttons the way Flipper-IRDB does — `Power`, `Vol_up`, `Vol_dn`, `Ch_next`, `Ch_prev`, `Mute`, `Up`,
`Down`, `Left`, `Right`, `Ok`, `Back`, `Exit`, `Menu`, `Home`, `Source`, `Info`, `0`…`9`, `Red`, `Green`,
`Yellow`, `Blue`, `Play`, `Pause`, `Stop` — so they map to app keys. Other names are kept as extra buttons. The full
list of recognised names is `app/BraviaKit/Sources/PultProfiles/Resources/key_aliases.json`.

```
Filetype: IR signals file
Version: 1
#
name: Power
type: parsed
protocol: NEC
address: 04 00 00 00
command: 08 00 00 00
#
name: Vol_up
type: raw
frequency: 38000
duty_cycle: 0.330000
data: 9024 4512 564 564 564 1692 ...
```

`address` / `command` are 4 bytes, little-endian. Raw `data` are microseconds, mark first.

### 2. Contribute upstream

Open a pull request to [Flipper-IRDB](https://github.com/Lucaslhm/Flipper-IRDB) with your file in
`TVs/<Brand>/<Brand>_<Model>.ir` (follow their contributing rules; new submissions there are CC0-1.0). Once it is
merged, *Check for updates* in the app picks it up — everyone using Flipper-IRDB benefits.

If you cannot contribute upstream, open an issue here with the exported file (*New TV profile* template).

## Build the profiles on a computer

For development, testing the importer, or reviewing the name mapping:

```sh
git clone --depth 1 https://github.com/Lucaslhm/Flipper-IRDB.git /tmp/flipper-irdb
python3 -I tools/profiles/import_flipper_irdb.py --irdb /tmp/flipper-irdb --out profiles/
```

The generated `profiles/index.json`, `profiles/brands/` and `profiles/power_scan.json` are ignored by git — never
commit them.

- Python 3.8+, standard library only. Run it with `-I` and from the repository, never from inside the checkout:
  the database is untrusted data and is only read (no symlinks followed, files over 1 MiB, unsafe file names and
  folders nested deeper than 8 levels skipped, at most 256 buttons per file).
- The Python importer is the reference for the Swift port: both must produce byte-identical files. The test suites
  check this on hand-written fixtures (`tools/profiles/fixtures/`), and on a full checkout when
  `OPENPULT_IRDB=/tmp/flipper-irdb` and `OPENPULT_PROFILES_EXPECTED=<python output>` are set.
- The importer prints a report: files used, codes per type, every skipped code with the reason and an example file,
  protocol frequencies, size. `--report report.json` saves it, `--name-stats 150` lists the most frequent button
  names and the key each maps to (`extra (UNREVIEWED)` marks names nobody has looked at yet).

## What the importer does

1. Reads every file in `TVs/` that starts with `Filetype: IR signals file`. The brand is the folder name (or the
   first word of a file placed directly in `TVs/`).
2. Parses each block; malformed ones are skipped and counted: bad hex, unknown protocol, address/command wider than
   the protocol, missing fields, unnamed buttons. A block without `type:` is accepted when its fields say which type
   it is.
3. Raw signals are converted to intro/repeat sections and checked against protocol v2: carrier 20–65.535 kHz, duty
   10–50 %, 2–1024 durations of 50 µs–500 ms, marks ≤ 30 ms, sections ≤ 1 s, ≤ 16 distinct durations after
   ±5 % clustering. Recordings made only of isolated pulses are treated as noise. Signals that do not fit are dropped
   and counted. See `profiles/SCHEMA.md` for the exact rules.
4. Button names are matched to app keys through `key_aliases.json` (case, spaces, `_` and inner `-` ignored; a
   trailing `-` counts, so `Vol-` is volume down). When several buttons match one key, the earlier alias wins
   (`Ok` beats `Enter`). Letter buttons become colors only when the whole set is present (`A B C D` on Samsung,
   `R G Y B` on Panasonic). Everything else goes to `extra` under its original name; exact duplicates are dropped.
5. Files of one brand with exactly the same codes are merged into one profile; `weight` counts them.
6. `power_scan.json` collects the distinct `power` (or `wakeUp`) codes over all profiles.

### Improving the name mapping

If a frequent button lands in `extra` but means an app key, add its name to the key in `key_aliases.json` (aliases
are tried in order, the first match wins), regenerate the golden files (`tools/profiles/fixtures/expected/`) and
the vectors (`python3 tools/profiles/gen_import_vectors.py`), and check that both the Python and the Swift tests
pass. Names that are not app keys can be added to `extraNames` to mark them as reviewed.
