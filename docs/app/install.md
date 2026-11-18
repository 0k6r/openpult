# Installing the iPhone app

The app is not in the App Store. You build it yourself with Xcode and a free Apple ID, or sideload the unsigned
`.ipa` from Releases.

## Option 1 — build with Xcode (free Apple ID)

Requirements: a Mac with Xcode 16 or newer, an iPhone with iOS 17+, a USB cable.

1. In Xcode → Settings → Accounts, add your Apple ID. A *Personal Team* appears; note its 10-character Team ID.
2. On the iPhone enable *Developer Mode*: Settings → Privacy & Security → Developer Mode (iOS asks to restart).
3. Configure signing:
   ```sh
   cd app
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   ```
   Edit `Config/Local.xcconfig`:
   - `DEVELOPMENT_TEAM` — your Team ID;
   - `OPENPULT_BUNDLE_ID` — any unique id, e.g. `com.yourname.openpult` (a free team cannot use an id taken by
     someone else);
   - `OPENPULT_DEVICE` — the iPhone UDID from `xcrun devicectl list devices`.
4. Connect the iPhone and run:
   ```sh
   ./install.sh
   ```
5. The first launch fails with *untrusted developer*. On the iPhone open Settings → General → VPN & Device
   Management → your Apple ID → Trust.

A free Apple ID signs apps for **7 days**. After that the app stops opening — run `./install.sh` again (your
settings and pairing are kept).

You can also open `app/Pult.xcodeproj` in Xcode, pick your iPhone and press Run.

## Option 2 — sideload the unsigned IPA

Each release contains an unsigned `Pult.ipa`. Tools such as AltStore, SideStore or Sideloadly re-sign it with your
Apple ID (the same 7-day limit applies, AltStore/SideStore can refresh it automatically).

## Permissions

- **Bluetooth** — asked when you first switch to the IR bridge.
- **Local Network** — asked when the app searches for a Sony TV on Wi‑Fi (only for the Sony network mode).

## Troubleshooting

- *"Unable to install"*: check that Developer Mode is on and the device is unlocked.
- *"No profiles for 'com.example…' were found"*: change `OPENPULT_BUNDLE_ID` to something unique.
- *Free account limit*: a free team can have at most 3 sideloaded apps installed at the same time.
