# shellcheck shell=bash disable=SC2154
# Build, SDK, display, hardware features and binder services.
if ((use_rea == 1)); then
  rea_step inspect-adb-device inspect-adb-device "$serial"
  rea_step inspect-adb-display inspect-adb-display "$serial"
  rea_step list-adb-features list-adb-features "$serial"
  rea_step list-adb-services list-adb-services "$serial"
else
  adb_step getprop getprop
  adb_step wm-size wm size
  adb_step wm-density wm density
  adb_step pm-list-features pm list features
  adb_step service-list service list
fi
