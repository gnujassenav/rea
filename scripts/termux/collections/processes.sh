# shellcheck shell=bash disable=SC2154
# Running processes and the focused window.
if ((use_rea == 1)); then
  rea_step list-adb-processes list-adb-processes "$serial"
  rea_step inspect-adb-window inspect-adb-window "$serial"
else
  adb_step ps ps -A
  adb_step dumpsys-window dumpsys window
fi
