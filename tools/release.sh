#!/usr/bin/env bash
# Builds the release files on your computer and publishes a GitHub release with the free `gh` CLI.
# The files are named like the artifacts of .github/workflows/ci.yml:
#   openpult-<board>-release.uf2 / -debug.uf2 (the nRF52840 Dongle: .hex), openpult-enclosure-stl.zip
#
#   git tag -a v0.2.0 -m "openpult v0.2.0" && git push origin v0.2.0
#   tools/release.sh v0.2.0 [--prerelease] [--draft]
#
# Versions with a suffix (v1.0.0-rc.1) are always published as pre-releases.
# Needs: the Zephyr workspace (docs/firmware/build.md), `gh auth login`.
set -euo pipefail
cd "$(dirname "$0")/.."
trap 'exit 130' INT

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
  echo "usage: tools/release.sh vX.Y.Z [--prerelease] [--draft]" >&2
  exit 2
fi
shift
FLAGS=()
for arg in "$@"; do
  case "$arg" in
    --prerelease|--draft) FLAGS+=("$arg") ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
if [[ "$VERSION" == *-* && " ${FLAGS[*]-} " != *" --prerelease "* ]]; then FLAGS+=(--prerelease); fi

fail() { echo "$*" >&2; exit 1; }

# --- Preconditions, before anything slow --------------------------------------------------------------------------
status=$(git status --porcelain) || fail "not a git checkout"
[[ -z "$status" ]] || fail "The working tree has uncommitted changes; commit or stash them first."
git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null || fail "Tag $VERSION not found: create it first (see the header)."
tagged=$(git rev-parse "$VERSION^{commit}")
[[ "$(git rev-parse HEAD)" == "$tagged" ]] || fail "HEAD is not $VERSION: check out the tag (git switch --detach $VERSION)."
remote=$(git ls-remote origin "refs/tags/$VERSION^{}" "refs/tags/$VERSION") || fail "cannot reach origin"
[[ "$remote" == *"$tagged"* ]] || fail "Tag $VERSION is not on origin (or points elsewhere): git push origin $VERSION"
gh auth status >/dev/null 2>&1 || fail "gh is not logged in: gh auth login"
if gh release view "$VERSION" >/dev/null 2>&1; then fail "Release $VERSION already exists."; fi

firmware_version=$(awk -F' *= *' '
  /^VERSION_MAJOR/ {M=$2} /^VERSION_MINOR/ {m=$2} /^PATCHLEVEL/ {p=$2} /^EXTRAVERSION/ {e=$2}
  END {printf "%s.%s.%s%s", M, m, p, (e != "" ? "-" e : "")}' firmware/VERSION)

# --- Checks and builds ---------------------------------------------------------------------------------------------
tools/check.sh || fail "tools/check.sh failed"

OUT="$PWD/build/release-$VERSION"
rm -rf "$OUT"
mkdir -p "$OUT/dist"

export ZEPHYR_BASE="${ZEPHYR_BASE:-$HOME/zephyrproject/zephyr}"
activate="${ZEPHYR_VENV:-$HOME/zephyrproject/.venv}/bin/activate"
# shellcheck disable=SC1090
if [[ -f "$activate" ]]; then source "$activate"; fi
command -v west >/dev/null || fail "west not found: see docs/firmware/build.md"

# Keep in sync with the matrix in .github/workflows/ci.yml.
for board in promicro_nrf52840/nrf52840/uf2 xiao_ble/nrf52840 adafruit_feather_nrf52840/nrf52840/uf2 nrf52840dongle/nrf52840; do
  name="${board%%/*}"
  for kind in release debug; do
    echo "Building firmware: $board ($kind)"
    extra=()
    if [[ $kind == debug ]]; then extra=(-- -DEXTRA_CONF_FILE=debug.conf); fi
    west build -p -b "$board" -d "$OUT/$name-$kind" firmware ${extra[@]+"${extra[@]}"} >"$OUT/$name-$kind.log" 2>&1 ||
      { tail -20 "$OUT/$name-$kind.log"; fail "firmware build failed: $board ($kind)"; }
    for ext in uf2 hex; do
      file="$OUT/$name-$kind/zephyr/zephyr.$ext"
      # UF2 boards ship the .uf2; the Dongle (nrfutil) ships the .hex.
      if [[ -f "$file" && ( $ext == uf2 || ! -f "$OUT/$name-$kind/zephyr/zephyr.uf2" ) ]]; then
        cp "$file" "$OUT/dist/openpult-$name-$kind.$ext"
      fi
    done
  done
done

echo "Building the enclosure"
rm -rf enclosure/out
enclosure/.venv/bin/python enclosure/build.py --all >/dev/null
enclosure/.venv/bin/python enclosure/check.py >/dev/null
(cd enclosure/out && zip -qrX "$OUT/dist/openpult-enclosure-stl.zip" . -i '*.stl')

ls -l "$OUT/dist"
notes="Firmware $firmware_version (BLE protocol v2). Flashing: docs/firmware/flash.md. Enclosure: docs/enclosure/printing.md. App: docs/app/install.md."
gh release create "$VERSION" --verify-tag ${FLAGS[@]+"${FLAGS[@]}"} --title "openpult $VERSION" --notes "$notes" "$OUT"/dist/*
