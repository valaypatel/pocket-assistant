#!/usr/bin/env bash
# Flash Circuit with a firmware build from GitHub, onto the board plugged in over USB.
#
#   tools/flash-release.sh                 the newest release (tag firmware-v*)
#   tools/flash-release.sh firmware-v0.2.0 a specific release
#   tools/flash-release.sh --run 123456    the build from a GitHub Actions run (before it is released)
#   tools/flash-release.sh --dir ./dist    files you already have (bootloader.bin, partition-table.bin, circuit-app*.bin)
#
# Options: --port /dev/cu.usbmodemXXXX   --yes (no question)   --dry-run (download and check, do not flash)
#
# Needs: gh (signed in, the repository is private) and esptool (pip install esptool).
#
# Only the bootloader, partition table and app are written, each at its own address. The
# board's saved Wi-Fi, pairing and notes key live in flash between them and are left alone, so
# this never makes you pair again or loses a note. Never flash a single merged image at 0x0
# and never run erase_flash: either one wipes that area.
set -euo pipefail

REPO="valaypatel/pocket-assistant"
tag="" run="" dir="" port="" yes=0 dry=0

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run) run="${2:?--run needs a run id}"; shift 2 ;;
    --dir) dir="${2:?--dir needs a folder}"; shift 2 ;;
    --port) port="${2:?--port needs a device}"; shift 2 ;;
    --yes) yes=1; shift ;;
    --dry-run) dry=1; shift ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    firmware-v*|latest) tag="$1"; shift ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done
[[ -n "$run$dir" && -n "$tag" ]] && die "choose one of: a release tag, --run or --dir"

# esptool under any of its names
esptool=()
if command -v esptool >/dev/null 2>&1; then esptool=(esptool)
elif command -v esptool.py >/dev/null 2>&1; then esptool=(esptool.py)
elif python3 -m esptool version >/dev/null 2>&1; then esptool=(python3 -m esptool)
else die "esptool is not installed (pip install esptool)"; fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ---- get the three files ----------------------------------------------------------------
if [[ -n "$dir" ]]; then
  [[ -d "$dir" ]] || die "$dir is not a folder"
  cp "$dir"/*.bin "$work"/ 2>/dev/null || die "no .bin files in $dir"
  [[ -f "$dir/SHA256SUMS" ]] && cp "$dir/SHA256SUMS" "$work"/
  label="files from $dir"
elif [[ -n "$run" ]]; then
  command -v gh >/dev/null || die "gh is not installed"
  gh run download "$run" --repo "$REPO" -n circuit-firmware -D "$work" >/dev/null \
    || die "could not download the circuit-firmware artifact of run $run (it expires after 30 days)"
  label="GitHub Actions run $run"
else
  command -v gh >/dev/null || die "gh is not installed"
  if [[ -z "$tag" || "$tag" == "latest" ]]; then
    tag="$(gh release list --repo "$REPO" --limit 30 --json tagName --jq '[.[].tagName | select(startswith("firmware-v"))][0] // empty')"
    [[ -n "$tag" ]] || die "there is no firmware release yet. Publish one with:
    git tag firmware-v0.1.0 && git push origin firmware-v0.1.0
  or flash a build that is not released yet:  $0 --run <run id>   (gh run list --workflow firmware.yml)"
  fi
  gh release download "$tag" --repo "$REPO" -D "$work" >/dev/null \
    || die "could not download release $tag"
  label="release $tag"
fi

boot="$work/bootloader.bin"
parts="$work/partition-table.bin"
app="$(find "$work" -maxdepth 1 -name 'circuit-app*.bin' | head -1)"
bootdata="$work/ota_data_initial.bin"  # resets the boot slot to ota_0; optional for older releases
[[ -f "$boot" && -f "$parts" && -n "$app" ]] \
  || die "expected bootloader.bin, partition-table.bin and circuit-app*.bin; got: $(ls "$work" | tr '\n' ' ')"

# ---- check them -------------------------------------------------------------------------
size() { wc -c <"$1" | tr -d ' '; }
(( $(size "$boot") < 65536 )) || die "bootloader.bin is too big to be a bootloader (is this a merged image? do not flash that)"
(( $(size "$parts") <= 4096 )) || die "partition-table.bin is too big to be a partition table"
(( $(size "$app") <= 0x320000 )) || die "the app does not fit its 3.1 MB app slot"
if [[ -f "$work/SHA256SUMS" ]]; then
  sum() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
  (cd "$work" && sum -c SHA256SUMS >/dev/null 2>&1) \
    && echo "Checksums match." || die "a downloaded file does not match SHA256SUMS; not flashing"
else
  echo "No SHA256SUMS with these files; skipping the checksum check."
fi

echo "Firmware: $label"
echo "  bootloader $(size "$boot") B, partition table $(size "$parts") B, $(basename "$app") $(size "$app") B"

# ---- find the board ---------------------------------------------------------------------
if [[ -z "$port" ]]; then
  ports=()
  for p in /dev/cu.usbmodem* /dev/cu.usbserial* /dev/ttyACM* /dev/ttyUSB*; do
    [[ -e "$p" ]] && ports+=("$p")
  done
  (( ${#ports[@]} > 0 )) || die "no board found. Plug Circuit in over USB, or pass --port"
  (( ${#ports[@]} == 1 )) || die "several serial devices found (${ports[*]}); pass --port"
  port="${ports[0]}"
fi
if command -v lsof >/dev/null 2>&1 && lsof "$port" >/dev/null 2>&1; then
  die "$port is in use by another program (a serial monitor?). Close it and run this again"
fi
echo "Board: $port"

if (( dry )); then
  echo "Dry run: checked everything, flashed nothing."
  exit 0
fi
if (( ! yes )); then
  read -r -p "Flash it? Your settings, pairing and notes key stay. [y/N] " answer
  [[ "$answer" == [yY]* ]] || { echo "Cancelled."; exit 0; }
fi

bootdata_args=()
[[ -f "$bootdata" ]] && bootdata_args=(0x650000 "$bootdata")

# ---- flash ------------------------------------------------------------------------------
"${esptool[@]}" --chip esp32s3 --port "$port" --baud 460800 --after hard_reset \
  write_flash --flash_mode dio --flash_size 8MB --flash_freq 80m \
  0x0 "$boot" 0x8000 "$parts" 0x10000 "$app" ${bootdata_args[@]+"${bootdata_args[@]}"}
echo "Done. Circuit is restarting; its settings, pairing and notes key were not touched."
