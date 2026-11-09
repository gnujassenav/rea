# shellcheck shell=bash disable=SC2016
# PostgreSQL: server processes and packages on the device and in Termux.
# Raw adb and Termux output. Listening ports are not checked: Android does
# not let the adb shell user list other apps' sockets.
adb_step postgres-processes \
  'ps -A | grep -i -e "[p]ostgres" -e "[p]ostmaster" || echo none-observed'
adb_step postgres-packages \
  'pm list packages | grep -i -e postgres -e psql || echo none-observed'
local_step termux-postgres-tools sh -c \
  'for tool in postgres psql pg_ctl; do command -v "$tool" || echo "$tool not-found"; done'
local_step termux-postgres-processes sh -c \
  'ps -A 2>/dev/null | grep -i -e "[p]ostgres" -e "[p]ostmaster" || echo none-observed'
