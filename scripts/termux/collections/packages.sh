# shellcheck shell=bash disable=SC2154
# Installed packages, third-party and system listed separately.
if ((use_rea == 1)); then
  rea_step list-adb-packages-third-party list-adb-packages "$serial" --scope third_party
  rea_step list-adb-packages-system list-adb-packages "$serial" --scope system
else
  adb_step pm-list-packages-third-party pm list packages -f -3
  adb_step pm-list-packages-system pm list packages -f -s
fi
