#!/bin/zsh
# Builds the openpult iOS app and installs it on a connected iPhone.
# A free Apple ID signs apps for 7 days: run this script again after that.
#
# Usage: ./install.sh [device-udid]
# The device defaults to OPENPULT_DEVICE from Config/Local.xcconfig.
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f Config/Local.xcconfig ]]; then
  echo "Create Config/Local.xcconfig first: cp Config/Local.xcconfig.example Config/Local.xcconfig" >&2
  exit 1
fi

DEVICE="${1:-$(sed -n 's/^OPENPULT_DEVICE *= *//p' Config/Local.xcconfig | tr -d '[:space:]')}"
if [[ -z "$DEVICE" ]]; then
  echo "No device: pass a UDID or set OPENPULT_DEVICE in Config/Local.xcconfig." >&2
  echo "Connected devices:" >&2
  xcrun devicectl list devices >&2 || true
  exit 1
fi

xcodebuild -project Pult.xcodeproj -scheme Pult -configuration Release \
  -destination "id=$DEVICE" -derivedDataPath build/dd -allowProvisioningUpdates -quiet build

xcrun devicectl device install app --device "$DEVICE" build/dd/Build/Products/Release-iphoneos/Pult.app
echo "Done: the app is installed."
