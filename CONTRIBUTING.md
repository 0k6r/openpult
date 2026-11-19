# Contributing to openpult

Thanks for helping! The most useful contributions are TV profiles, new boards and protocol decoders.

## Ground rules

- **The BLE protocol is a contract.** If you change [`firmware/PROTOCOL.md`](firmware/PROTOCOL.md), update the
  firmware, the app and the shared vectors in `testdata/ir_vectors.json` (regenerate with
  `python3 tools/gen_ir_vectors.py`) in the same pull request.
- **Tests come with the change.** Run `tools/check.sh` before opening a pull request (add `--firmware` when you touch
  `firmware/`). It runs the same checks as the CI workflow: vectors, translations, the Python importer, firmware host
  tests, the Swift packages, the iOS build and the enclosure.
- **No TV code databases in the repository.** The app downloads Flipper-IRDB itself (see
  [docs/ir/profiles.md](docs/ir/profiles.md)). Test fixtures are hand-written; do not copy codes from Flipper-IRDB,
  irdb, LIRC or GPL projects into the repository.
- **Two importers, one result.** `tools/profiles/import_flipper_irdb.py` (reference) and the Swift port in
  `app/BraviaKit/Sources/PultProfiles` must produce byte-identical profiles. Change both, regenerate
  `tools/profiles/fixtures/expected/` and `python3 tools/profiles/gen_import_vectors.py`.
- **Both languages.** User-facing text is English in code with a Russian translation in the String Catalogs
  (`app/Pult/*.xcstrings`, `app/BraviaKit/Sources/BraviaKit/Resources/Localizable.xcstrings`);
  `python3 tools/l10n/check_catalogs.py` must pass.
- English for code, comments and docs. Russian translations of user-facing docs are welcome.

## Add or fix a TV profile

1. Learn the buttons in the app (*⋯ → Learn buttons*) and export the remote (*⋯ → Share remote*,
   `remote.openpult.json`), or capture them with a Flipper Zero.
2. Contribute the `.ir` file to [Flipper-IRDB](https://github.com/Lucaslhm/Flipper-IRDB) — the app picks it up with
   *Check for updates*. If you cannot, open an issue with the exported file using the *New TV profile* template.
3. See [docs/ir/profiles.md](docs/ir/profiles.md) for how the profiles are built.

## Add a board

1. Add `firmware/boards/<board>.overlay` (and `.conf` if needed) mapping the IR LED, the optional receiver and the
   battery ADC — see [docs/firmware/porting-a-board.md](docs/firmware/porting-a-board.md).
2. Add the board to the CI build matrix and to [docs/hardware/boards.md](docs/hardware/boards.md).
3. If the board needs a different case, add a preset in `enclosure/params.py`.

## Add an IR protocol

1. Implement the codec in `app/BraviaKit/Sources/PultIR/Codecs/` using the shared pulse-distance or Manchester
   helpers.
2. Add encode/decode round-trip tests with jitter, and at least one vector from a public source.
3. Document timings and sources in [docs/ir/protocols.md](docs/ir/protocols.md).

## Pull requests

Keep them focused, describe how you tested (which TV, board, remote), and include photos of hardware changes when
it helps.

## Releasing

The main repository builds releases locally (GitHub Actions are not used there; the workflows in `.github/` still
work in forks that have Actions):

```sh
tools/check.sh --firmware
git tag -a vX.Y.Z -m "openpult vX.Y.Z" && git push origin vX.Y.Z
tools/release.sh vX.Y.Z            # add --prerelease for previews
```

`tools/release.sh` builds the firmware for every board, packs the STL files of all enclosure variants and publishes the
GitHub release with `gh`.
