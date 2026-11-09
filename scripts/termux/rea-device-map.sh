#!/usr/bin/env bash
# Collect a read-only map of the Android device this Termux session runs on.
#
# Every step is a read: REA's read-kind ADB operations, or raw device and
# Termux commands for facts REA has no operation for. Nothing is installed,
# pushed, started or stopped. See docs/guides/android/termux-on-device.md.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: rea-device-map.sh [options]

  --serial <serial>      Try only this serial, exactly as `adb devices`
                         reports it. Repeatable. Default: every row adb
                         lists, whatever its state.
  --output <dir>         New or empty directory for the results.
                         Default: ./rea-device-map-<UTC timestamp>
  --adb-only             Skip REA and save raw adb output instead; the files
                         are not REA Evidence. The script also does this, and
                         says so, when REA is missing or cannot start.
  --only <a,b,...>       Run only these collections.
  --skip <a,b,...>       Run every collection except these.
  --collections <dir>    Also load collections from this directory.
                         Repeatable. A later file replaces an earlier one
                         with the same name.
  --list                 List the available collections and exit.
  --help                 Show this help.

Environment:
  REA_BIN        Path of one executable that starts REA (no arguments).
                 Default: scripts/rea.mjs of the repository copy this
                 script is in, when it is built; otherwise `rea` from PATH.
  REA_ADB_PATH   Absolute path to adb. Default: adb from PATH.

Exit codes:
  0  every step succeeded
  1  a prerequisite is missing (adb, a listed device, output dir)
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

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

serials=()
output=""
adb_only=0
only=""
skip=""
list_only=0
collection_dirs=("$script_dir/collections")
while (($# > 0)); do
  case "$1" in
    --serial)
      need_value "$1" "$#"
      serials+=("$2")
      shift 2
      ;;
    --output)
      need_value "$1" "$#"
      output="$2"
      shift 2
      ;;
    --only)
      need_value "$1" "$#"
      only="$2"
      shift 2
      ;;
    --skip)
      need_value "$1" "$#"
      skip="$2"
      shift 2
      ;;
    --collections)
      need_value "$1" "$#"
      collection_dirs+=("$2")
      shift 2
      ;;
    --adb-only)
      adb_only=1
      shift
      ;;
    --list)
      list_only=1
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

# Collections are *.sh files; the file name without .sh is the collection name.
declare -A collection_file=()
collection_names=()
for dir in "${collection_dirs[@]}"; do
  if [[ ! -d "$dir" ]]; then
    printf 'Collections directory not found: %s\n' "$dir" >&2
    exit 1
  fi
  for file in "$dir"/*.sh; do
    [[ -f "$file" ]] || continue
    name="$(basename "$file" .sh)"
    [[ -n "${collection_file[$name]:-}" ]] || collection_names+=("$name")
    collection_file[$name]="$file"
  done
done
if ((${#collection_names[@]} == 0)); then
  printf 'No collections found in: %s\n' "${collection_dirs[*]}" >&2
  exit 1
fi

if ((list_only == 1)); then
  for name in "${collection_names[@]}"; do
    # The second line of a collection file is its one-line description.
    printf '%-12s %s\n' "$name" "$(sed -n '2s/^# *//p' "${collection_file[$name]}")"
  done
  exit 0
fi

# in_list <name> <comma list>
in_list() {
  [[ ",$2," == *",$1,"* ]]
}
selected=()
for requested in ${only//,/ } ${skip//,/ }; do
  if [[ -z "${collection_file[$requested]:-}" ]]; then
    printf 'Unknown collection: %s. Available: %s\n' "$requested" "${collection_names[*]}" >&2
    exit 2
  fi
done
for name in "${collection_names[@]}"; do
  if [[ -n "$only" ]] && ! in_list "$name" "$only"; then continue; fi
  if [[ -n "$skip" ]] && in_list "$name" "$skip"; then continue; fi
  selected+=("$name")
done
if ((${#selected[@]} == 0)); then
  printf 'No collection is selected.\n' >&2
  exit 2
fi

# Prerequisites are reported, never installed.
adb_bin="${REA_ADB_PATH:-adb}"
if ! command -v "$adb_bin" >/dev/null 2>&1; then
  printf 'adb was not found (%s). In Termux: pkg install android-tools\n' "$adb_bin" >&2
  exit 1
fi

rea=()
use_rea=0
rea_notice=""
if ((adb_only == 0)); then
  if [[ -n "${REA_BIN:-}" ]]; then
    # One executable path, kept whole so a path with spaces still works.
    rea=("$REA_BIN")
  elif [[ -f "$repo_root/scripts/rea.mjs" && -d "$repo_root/dist" ]] &&
    command -v node >/dev/null 2>&1; then
    # This script sits inside a built copy of the REA repository.
    rea=(node "$repo_root/scripts/rea.mjs")
  elif command -v rea >/dev/null 2>&1; then
    rea=(rea)
  else
    rea_notice="REA was not found (no REA_BIN, no built repository copy, no rea on PATH)."
  fi
  # Start REA once. If it cannot start, say why and continue with raw adb
  # instead of stopping or failing every step.
  if ((${#rea[@]} > 0)); then
    if rea_error="$("${rea[@]}" --version 2>&1 >/dev/null)"; then
      use_rea=1
    else
      rea_notice="REA did not start (${rea[*]} --version): $rea_error"
    fi
  fi
  if ((use_rea == 0)); then
    printf '%s\nContinuing with raw adb output, which is not REA Evidence.\n' "$rea_notice" >&2
  fi
fi

# List every row adb reports. A row is tried whatever its state: the state
# column is adb's own label, and a row that cannot answer fails its steps.
if ! devices_output="$("$adb_bin" devices 2>&1)"; then
  printf 'adb devices failed:\n%s\n' "$devices_output" >&2
  exit 1
fi
declare -A listed_state=()
listed=()
# Rows follow the header line; adb may print daemon notices before it.
while IFS=$'\t' read -r row_serial row_state; do
  [[ -n "$row_serial" ]] || continue
  listed+=("$row_serial")
  listed_state[$row_serial]="$row_state"
done < <(printf '%s\n' "$devices_output" | tr -d '\r' |
  awk 'seen && NF >= 2 { print $1 "\t" $2 } /^List of devices attached/ { seen = 1 }')

if ((${#serials[@]} == 0)); then
  if ((${#listed[@]} == 0)); then
    cat >&2 <<'EOF'
adb lists no device. Pair and connect Wireless debugging first:
  adb pair localhost:<pairing port>
  adb connect localhost:<connect port>
EOF
    exit 1
  fi
  serials=("${listed[@]}")
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
printf 'target\tadb_state\tcollection\tstep\tsource\texit_code\tfile\n' >"$summary"
failures=0
partial="$output/.partial"

# Set per target before its collections run.
target=""
target_dir=""
target_state=""
collection=""
serial=""
declare -A local_done=()

# Marks the end of a probe's output with the probed command's real exit code.
exit_trailer='rea-device-map-exit='

# record <relative dir> <step> <source> <file> <command...>
# Every published byte comes from the command that ran in this invocation; the
# script writes no placeholder, default or remembered result. A step that
# succeeds publishes its file. A step that fails publishes nothing under the
# results: its output and stderr move to failures/ instead.
#   ok_codes         exit codes that count as success (default "0")
#   require_trailer  1 when the output must end with the exit trailer
record() {
  local dir="$1" step="$2" source="$3" file="$4" code=0 dest
  shift 4
  rm -f "$partial" "$partial.stderr"
  "$@" >"$partial" 2>"$partial.stderr" || code=$?
  if [[ "${require_trailer:-0}" == 1 ]] && ((code == 0)) &&
    ! tail -n 1 "$partial" | grep -q -E "^${exit_trailer}[0-9]+\$"; then
    # The transport ended before the probed command reported its exit code.
    printf 'rea-device-map: output ended without the exit trailer\n' >>"$partial.stderr"
    code=125
  fi
  if in_list "$code" "${ok_codes:-0}"; then
    dest="$dir"
  else
    dest="failures/$dir"
    failures=$((failures + 1))
  fi
  mkdir -p "$output/$dest"
  local saved="$dest/$file"
  if [[ "$dest" == failures/* && ! -s "$partial" ]]; then
    # A failed step that printed nothing leaves only its stderr, if any.
    rm -f "$partial"
    saved="-"
  else
    mv "$partial" "$output/$dest/$file"
  fi
  if [[ -s "$partial.stderr" ]]; then
    mv "$partial.stderr" "$output/$dest/$file.stderr"
    [[ "$saved" != "-" ]] || saved="$dest/$file.stderr"
  else
    rm -f "$partial.stderr"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$target" "$target_state" \
    "$collection" "$step" "$source" "$code" "$saved" >>"$summary"
  if [[ "$dest" == failures/* ]]; then
    printf '  failed (%s): %s/%s\n' "$code" "$collection" "$step" >&2
  elif ((code == 0)); then
    printf '  ok: %s/%s\n' "$collection" "$step"
  else
    printf '  ok (exit %s): %s/%s\n' "$code" "$collection" "$step"
  fi
}

# Helpers for collection files.

# rea_step <step> <rea command and arguments...>: one REA operation, saved as
# Evidence JSON. Pass "$serial" yourself where the operation takes one.
rea_step() {
  local step="$1"
  shift
  record "$target_dir" "$step" rea "$step.json" "${rea[@]}" "$@" --format json
}

# adb_step <step> <device shell words...>: one device shell command. Pass a
# single string to run a pipeline in the device's shell.
adb_step() {
  local step="$1"
  shift
  record "$target_dir" "$step" adb "$step.txt" "$adb_bin" -s "$serial" shell "$@"
}

# adb_probe_step <step> <device shell string>: a device command whose non-zero
# exit is an answer, not a failure (a tool that is absent, a search that hits
# an unreadable directory). The file holds the command's output followed by
# one trailer line with its real exit code. A missing trailer means the device
# did not answer, and the step fails.
adb_probe_step() {
  local step="$1" probe="$2"
  require_trailer=1 record "$target_dir" "$step" adb "$step.txt" \
    "$adb_bin" -s "$serial" shell "$probe"$'\n'"echo \"${exit_trailer}\$?\""
}

# match_step <step> <published file of this device> <extended regex>: the
# lines of an already published file that match, case-insensitively. Exit
# code 1 means no line matched and publishes an empty file.
match_step() {
  match_in "$target_dir" "$@"
}

# run_local <function> <arguments...>: record under termux/, once per run.
run_local() {
  local saved_target="$target" saved_state="$target_state"
  [[ -z "${local_done[$collection/$2]:-}" ]] || return 0
  local_done[$collection/$2]=1
  target="termux"
  target_state="local"
  "$@"
  target="$saved_target"
  target_state="$saved_state"
}

# local_step <step> <command...>: one command in this Termux session. It runs
# once per collection run, not once per device.
local_step() {
  run_local local_record "$@"
}
local_record() {
  local step="$1"
  shift
  record "termux" "$step" termux "$step.txt" "$@"
}

# local_probe_step <step> <shell string>: adb_probe_step for this Termux session.
local_probe_step() {
  run_local local_probe_record "$@"
}
local_probe_record() {
  require_trailer=1 record "termux" "$1" termux "$1.txt" \
    sh -c "$2"$'\n'"echo \"${exit_trailer}\$?\""
}

# local_match_step <step> <published termux file> <extended regex>
local_match_step() {
  run_local match_in "termux" "$@"
}

# match_in <relative dir> <step> <published file> <extended regex>
match_in() {
  local dir="$1" step="$2" from="$3" pattern="$4"
  if [[ ! -f "$output/$dir/$from" ]]; then
    # shellcheck disable=SC2016
    record "$dir" "$step" derived "$step.txt" \
      sh -c 'echo "source file was not published: $1" >&2; exit 2' sh "$from"
    return 0
  fi
  ok_codes="0,1" record "$dir" "$step" derived "$step.txt" \
    grep -i -E -e "$pattern" "$output/$dir/$from"
}

printf 'Output: %s\nCollections: %s\n' "$output" "${selected[*]}"

target="adb-client"
target_state="local"
target_dir="adb-client"
collection="client"
if ((use_rea == 1)); then
  rea_step inspect-adb-client inspect-adb-client
  rea_step list-adb-devices list-adb-devices
else
  record "$target_dir" adb-version adb adb-version.txt "$adb_bin" version
  record "$target_dir" adb-devices adb adb-devices.txt "$adb_bin" devices -l
fi

index=0
for serial in "${serials[@]}"; do
  index=$((index + 1))
  target="$serial"
  target_state="${listed_state[$serial]:-not-listed}"
  # Serials can hold characters a directory name should not.
  target_dir="devices/$index-$(printf '%s' "$serial" | tr -c 'A-Za-z0-9._-' '_')"
  printf '\nDevice %s of %s: %s (adb state: %s)\n' "$index" "${#serials[@]}" \
    "$serial" "$target_state"
  for collection in "${selected[@]}"; do
    # shellcheck source=/dev/null
    source "${collection_file[$collection]}"
  done
done

printf '\nSummary: %s\n' "$summary"
if [[ -n "$rea_notice" ]]; then
  printf 'REA was not used: %s\n' "$rea_notice" >&2
fi
if ((failures > 0)); then
  printf '%s step(s) failed; their output is under %s/failures.\n' "$failures" "$output" >&2
  exit 3
fi
