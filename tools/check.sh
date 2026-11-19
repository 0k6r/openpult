#!/usr/bin/env bash
# Runs the checks of .github/workflows/ci.yml on your computer (macOS with Xcode).
#
#   tools/check.sh              everything except the slow parts below
#   tools/check.sh --firmware   also build the firmware (release + debug) for every board; needs the Zephyr workspace
#                               (docs/firmware/build.md); ZEPHYR_BASE defaults to ~/zephyrproject/zephyr
#   tools/check.sh --irdb       also compare the Python and Swift importers on the real Flipper-IRDB at the pinned
#                               commit (like .github/workflows/irdb-parity.yml); downloads it into build/check
set -euo pipefail
cd "$(dirname "$0")/.."
trap 'exit 130' INT

FIRMWARE=0
IRDB=0
for arg in "$@"; do
  case "$arg" in
    --firmware) FIRMWARE=1 ;;
    --irdb) IRDB=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# Keep in sync with the matrix in .github/workflows/ci.yml.
BOARDS=(promicro_nrf52840/nrf52840/uf2 xiao_ble/nrf52840 adafruit_feather_nrf52840/nrf52840/uf2 nrf52840dongle/nrf52840)
IRDB_COMMIT=d126fb1b6f1e114c52b4a8c19839ea65e3a9c24d   # IRDBPin.commit in the app

SCRATCH="${OPENPULT_CHECK_DIR:-$PWD/build/check}"
mkdir -p "$SCRATCH"
FAILED=()
if [[ -t 1 ]]; then BOLD=$'\033[1m' GREEN=$'\033[32m' RED=$'\033[31m' RESET=$'\033[0m'; else BOLD= GREEN= RED= RESET=; fi

step() {
  local name="$1"; shift
  printf '\n%s== %s%s\n' "$BOLD" "$name" "$RESET"
  if "$@"; then
    printf '%sok%s  %s\n' "$GREEN" "$RESET" "$name"
  else
    printf '%sFAILED%s  %s\n' "$RED" "$RESET" "$name"
    FAILED+=("$name")
  fi
}

no_tv_database() {
  # Flipper-IRDB data is downloaded by the app; only hand-written fixtures may be in git.
  local files bad irs
  files=$(git -c core.quotePath=false ls-files) || { echo "not a git checkout" >&2; return 1; }
  bad=$(grep -E '^profiles/(index\.json|power_scan\.json|brands/|LICENSE$)' <<<"$files" || true)
  irs=$(grep -E '\.ir$' <<<"$files" | grep -vE '^tools/profiles/(fixtures|contrib)/' || true)
  if [[ -n "$bad$irs" ]]; then printf 'Not allowed in git:\n%s\n%s\n' "$bad" "$irs"; return 1; fi
}

vectors() {
  python3 -I -X utf8 tools/gen_ir_vectors.py --check &&
    python3 -I -X utf8 tools/profiles/gen_import_vectors.py --check
}

translations() {
  python3 -I tools/l10n/check_catalogs.py --quiet && python3 -I -m unittest discover -s tools/l10n
}

importer() { python3 -I -X utf8 -m unittest discover -s tools/profiles; }

firmware_host() { make -s -C firmware/tests/host test; }

swift_packages() { swift test --package-path app/BraviaKit --scratch-path "$SCRATCH/swiftpm"; }

ios_app() {
  xcodebuild -project app/Pult.xcodeproj -scheme Pult -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$SCRATCH/xcode" \
    CODE_SIGNING_ALLOWED=NO -quiet build
}

enclosure() {
  local venv=enclosure/.venv
  [[ -x "$venv/bin/python" ]] || python3 -m venv "$venv" || return 1
  # Reinstall whenever requirements.txt changes (or a previous install did not finish).
  if ! cmp -s enclosure/requirements.txt "$venv/.requirements"; then
    "$venv/bin/pip" install -q -r enclosure/requirements.txt && cp enclosure/requirements.txt "$venv/.requirements" || return 1
  fi
  "$venv/bin/python" enclosure/build.py --all >/dev/null &&
    "$venv/bin/python" enclosure/check.py >/dev/null &&
    "$venv/bin/python" -m pytest -q enclosure/tests
}

zephyr_env() {
  export ZEPHYR_BASE="${ZEPHYR_BASE:-$HOME/zephyrproject/zephyr}"
  local activate="${ZEPHYR_VENV:-$HOME/zephyrproject/.venv}/bin/activate"
  # shellcheck disable=SC1090
  if [[ -f "$activate" ]]; then source "$activate"; fi
  command -v west >/dev/null || { echo "west not found: see docs/firmware/build.md" >&2; return 1; }
}

firmware_builds() {
  zephyr_env || return 1
  local board name failed=0
  for board in "${BOARDS[@]}"; do
    name="${board%%/*}"
    echo "west build $board (release, debug)"
    west build -p -b "$board" -d "$SCRATCH/fw-$name" firmware >"$SCRATCH/fw-$name.log" 2>&1 ||
      { tail -20 "$SCRATCH/fw-$name.log"; failed=1; }
    west build -p -b "$board" -d "$SCRATCH/fw-$name-debug" firmware -- -DEXTRA_CONF_FILE=debug.conf \
      >"$SCRATCH/fw-$name-debug.log" 2>&1 || { tail -20 "$SCRATCH/fw-$name-debug.log"; failed=1; }
  done
  return $failed
}

irdb_parity() {
  local irdb="$SCRATCH/flipper-irdb" expected="$SCRATCH/irdb-expected"
  if [[ "$(git -C "$irdb" rev-parse HEAD 2>/dev/null || true)" != "$IRDB_COMMIT" ]]; then
    rm -rf "$irdb" && git init -q "$irdb" &&
      git -C "$irdb" remote add origin https://github.com/Lucaslhm/Flipper-IRDB.git &&
      git -C "$irdb" fetch -q --depth 1 origin "$IRDB_COMMIT" &&
      git -C "$irdb" checkout -q FETCH_HEAD || return 1
  fi
  rm -rf "$expected"
  # The database is untrusted data: read it, never run anything from it.
  python3 -I -X utf8 tools/profiles/import_flipper_irdb.py --irdb "$irdb" --commit "$IRDB_COMMIT" --out "$expected" >/dev/null &&
    OPENPULT_IRDB="$irdb" OPENPULT_PROFILES_EXPECTED="$expected" \
      swift test --package-path app/BraviaKit --scratch-path "$SCRATCH/swiftpm" --filter 'PultProfilesTests|InfraredTests|GitObjectHashTests'
}

step "No TV code database in git" no_tv_database
step "Test vectors" vectors
step "Translations" translations
step "Profile importer (Python)" importer
step "Firmware host tests" firmware_host
step "Swift packages" swift_packages
step "iOS app (simulator build)" ios_app
step "Enclosure" enclosure
if (( FIRMWARE )); then step "Firmware builds" firmware_builds; fi
if (( IRDB )); then step "Flipper-IRDB parity" irdb_parity; fi

echo
if (( ${#FAILED[@]} )); then
  printf '%s%d check(s) failed:%s %s\n' "$RED" "${#FAILED[@]}" "$RESET" "${FAILED[*]}"
  exit 1
fi
printf '%sAll checks passed.%s\n' "$GREEN" "$RESET"
