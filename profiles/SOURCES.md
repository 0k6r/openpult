# Source of the TV profiles

openpult builds its TV profiles from [Flipper-IRDB](https://github.com/Lucaslhm/Flipper-IRDB) (folder `TVs/`) —
a community collection of remote codes for the Flipper Zero. Thank you to everyone who captured and shared their
remotes there.

**No data from Flipper-IRDB is stored in this repository.** The app downloads the files from GitHub on the user's
request and builds the profiles on the phone; developers can build them locally (see
[`docs/ir/profiles.md`](../docs/ir/profiles.md)). The generated files are ignored by git.

- Pinned commit: [`d126fb1b6f1e114c52b4a8c19839ea65e3a9c24d`](https://github.com/Lucaslhm/Flipper-IRDB/tree/d126fb1b6f1e114c52b4a8c19839ea65e3a9c24d)
  (2026-04-12), `TVs/` tree `b078b6acf69b542eaeb8d089d3b91d77d576bbd2`.
- License: Flipper-IRDB's `LICENSE` is CC0-1.0; its README states that commits before
  [`2319685`](https://github.com/Lucaslhm/Flipper-IRDB/commit/2319685f2cbf0cd3f809609622cade14d24fb819)
  (2025-08-07) are not covered. This is why the database is downloaded rather than redistributed.
- The format of the generated files: [`SCHEMA.md`](SCHEMA.md).
