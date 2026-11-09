# shellcheck shell=bash
# PostgreSQL: server processes and packages on the device and in Termux.
# Raw adb and Termux output, then the lines of it that name PostgreSQL.
# Listening ports are not checked: Android does not let the adb shell user
# list other apps' sockets.
adb_step all-processes ps -A
match_step postgres-processes all-processes.txt 'postgres|postmaster'
adb_step all-packages pm list packages
match_step postgres-packages all-packages.txt 'postgres|psql'
# One probe per tool: `command -v` reports a single name in some shells.
for tool in postgres psql pg_ctl; do
  local_probe_step "termux-$tool" "command -v $tool"
done
local_step termux-all-processes ps -A
local_match_step termux-postgres-processes termux-all-processes.txt 'postgres|postmaster'
