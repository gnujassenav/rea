#!/usr/bin/env bash
# Collect a read-only map of the Android device this Termux session runs on.
#
# Every step is a read: REA's read-kind ADB operations, or with --adb-only the
# device commands those operations wrap. Nothing is installed, pushed, started
# or stopped. See docs/guides/android/termux-on-device.md.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: rea-device-map.sh [options]

  --serial <serial>   Device serial exactly as `adb devices` reports it.
                      Required when more than one device is connected.
  --output <dir>      New or empty directory for the results.
                      Default: ./rea-device-map-<UTC timestamp>
  --adb-only          Skip REA and save raw adb output instead. Use it when
                      REA cannot start; the files are not REA Evidence.
  --usage-stats       Also save raw `dumpsys usagestats` (per-app usage
                      history). REA has no operation for it, so this file is
                      raw adb output even without --adb-only.
  --help              Show this help.

Environment:
  REA_BIN        Path of one executable that starts REA (no arguments).
                 Default: this checkout's scripts/rea.mjs when built,
                 otherwise `rea` from PATH.
  REA_ADB_PATH   Absolute path to adb. Default: adb from PATH.

Exit codes:
  0  every step succeeded
  1  a prerequisite is missing (adb, REA, a connected device, output dir)
  2  invalid option
  3  the collection ran, but one or more steps failed; see SUMMARY.tsv
EOF
}

# need_value <option> <argument count>: an option's value must follow it.
need_value() {
  if (($2 < 2)); then
    printf 'Option %s needs a value.\n\n' "$1" >&2
    usage >&2
    exit 2
  fi
}

serial=""
output=""
adb_only=0
usage_stats=0
while (($# > 0)); do
  case "$1" in
    --serial)
      need_value "$1" "$#"
      serial="$2"
      shift 2
      ;;
    --output)
      need_value "$1" "$#"
      output="$2"
      shift 2
      ;;
    --adb-only)
      adb_only=1
      shift
      ;;
    --usage-stats)
      usage_stats=1
      shift
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# Prerequisites are reported, never installed.
adb_bin="${REA_ADB_PATH:-adb}"
if ! command -v "$adb_bin" >/dev/null 2>&1; then
  printf 'adb was not found (%s). In Termux: pkg install android-tools\n' "$adb_bin" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
rea=()
if ((adb_only == 0)); then
  if [[ -n "${REA_BIN:-}" ]]; then
    # One executable path, kept whole so a path with spaces still works.
    rea=("$REA_BIN")
  elif [[ -f "$repo_root/scripts/rea.mjs" && -d "$repo_root/dist" ]] &&
    command -v node >/dev/null 2>&1; then
    rea=(node "$repo_root/scripts/rea.mjs")
  elif command -v rea >/dev/null 2>&1; then
    rea=(rea)
  else
    cat >&2 <<'EOF'
REA was not found. Build this checkout (npm ci && npm run build:termux), set
REA_BIN, or rerun with --adb-only to save raw adb output instead.
EOF
    exit 1
  fi
  # Fail once, with REA's own message, instead of once per step.
  if ! rea_error="$("${rea[@]}" --version 2>&1 >/dev/null)"; then
    printf 'REA did not start (%s --version):\n%s\n' "${rea[*]}" "$rea_error" >&2
    printf 'Fix the build or REA_BIN, or rerun with --adb-only.\n' >&2
    exit 1
  fi
fi

# Resolve the device. Only a serial in state `device` can answer.
if ! devices_output="$("$adb_bin" devices 2>&1)"; then
  printf 'adb devices failed:\n%s\n' "$devices_output" >&2
  exit 1
fi
# Rows follow the header line; adb may print daemon notices before it.
mapfile -t ready < <(printf '%s\n' "$devices_output" | tr -d '\r' |
  awk 'seen && $2 == "device" { print $1 } /^List of devices attached/ { seen = 1 }')
mapfile -t not_ready < <(printf '%s\n' "$devices_output" | tr -d '\r' |
  awk 'seen && NF >= 2 && $2 != "device" { print $1 " (" $2 ")" }
    /^List of devices attached/ { seen = 1 }')
if [[ -z "$serial" ]]; then
  if ((${#ready[@]} == 0)); then
    if ((${#not_ready[@]} > 0)); then
      printf 'adb lists these, but none is in state "device":\n' >&2
      printf '  %s\n' "${not_ready[@]}" >&2
    fi
    cat >&2 <<'EOF'
No device is ready. Pair and connect Wireless debugging first:
  adb pair localhost:<pairing port>
  adb connect localhost:<connect port>
EOF
    exit 1
  fi
  if ((${#ready[@]} > 1)); then
    printf 'More than one device is connected; pass --serial. Found:\n' >&2
    printf '  %s\n' "${ready[@]}" >&2
    cat >&2 <<'EOF'
After pairing, adb can list the same phone twice: once as localhost:<port>
and once under an adb-...._adb-tls-connect._tcp name. Either serial works.
EOF
    exit 1
  fi
  serial="${ready[0]}"
else
  found=0
  for candidate in "${ready[@]}"; do
    [[ "$candidate" == "$serial" ]] && found=1
  done
  if ((found == 0)); then
    printf 'Serial %s is not connected in state "device". Connected:\n' "$serial" >&2
    printf '  %s\n' "${ready[@]:-(none)}" >&2
    exit 1
  fi
fi

if [[ -z "$output" ]]; then
  output="rea-device-map-$(date -u +%Y%m%dT%H%M%SZ)"
fi
if [[ -e "$output" && -n "$(ls -A "$output" 2>/dev/null)" ]]; then
  printf 'Output directory %s exists and is not empty.\n' "$output" >&2
  exit 1
fi
mkdir -p "$output"
chmod 700 "$output"

summary="$output/SUMMARY.tsv"
printf 'step\tsource\texit_code\tfile\n' >"$summary"
failures=0

# record <step> <source> <file> <command...>: run one read, keep going on failure.
record() {
  local step="$1" source="$2" file="$3" code=0
  shift 3
  "$@" >"$output/$file" 2>"$output/$file.stderr" || code=$?
  [[ -s "$output/$file.stderr" ]] || rm -f "$output/$file.stderr"
  printf '%s\t%s\t%s\t%s\n' "$step" "$source" "$code" "$file" >>"$summary"
  if ((code != 0)); then
    failures=$((failures + 1))
    printf '  failed (%s): %s\n' "$code" "$step" >&2
  else
    printf '  ok: %s\n' "$step"
  fi
}

rea_step() {
  local step="$1"
  shift
  record "$step" rea "$step.json" "${rea[@]}" "$@" --format json
}

adb_step() {
  local step="$1"
  shift
  record "$step" adb "$step.txt" "$adb_bin" -s "$serial" shell "$@"
}

printf 'Device: %s\nOutput: %s\n' "$serial" "$output"

if ((adb_only == 0)); then
  rea_step inspect-adb-client inspect-adb-client
  rea_step list-adb-devices list-adb-devices
  rea_step inspect-adb-device inspect-adb-device "$serial"
  rea_step inspect-adb-display inspect-adb-display "$serial"
  rea_step list-adb-features list-adb-features "$serial"
  rea_step list-adb-services list-adb-services "$serial"
  rea_step list-adb-packages-third-party list-adb-packages "$serial" --scope third_party
  rea_step list-adb-packages-system list-adb-packages "$serial" --scope system
  rea_step list-adb-processes list-adb-processes "$serial"
  rea_step inspect-adb-window inspect-adb-window "$serial"
else
  record adb-version adb adb-version.txt "$adb_bin" version
  record adb-devices adb adb-devices.txt "$adb_bin" devices -l
  adb_step getprop getprop
  adb_step wm-size wm size
  adb_step wm-density wm density
  adb_step pm-list-features pm list features
  adb_step service-list service list
  adb_step pm-list-packages-third-party pm list packages -f -3
  adb_step pm-list-packages-system pm list packages -f -s
  adb_step ps ps -A
  adb_step dumpsys-window dumpsys window
fi

if ((usage_stats == 1)); then
  adb_step dumpsys-usagestats dumpsys usagestats
fi

printf '\nSummary: %s\n' "$summary"
if ((failures > 0)); then
  printf '%s step(s) failed; the file of each failed step, or its .stderr, holds the reason.\n' "$failures" >&2
  exit 3
fi
