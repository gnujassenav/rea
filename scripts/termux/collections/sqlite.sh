# shellcheck shell=bash
# SQLite: device binary, open databases, database files in shared storage.
# Raw adb and Termux output. The adb shell user cannot read other apps'
# private databases; dumpsys dbinfo reports only what the system exposes.
adb_probe_step sqlite3-binary 'command -v sqlite3'
adb_step dumpsys-dbinfo dumpsys dbinfo
adb_probe_step shared-storage-database-files \
  'find /sdcard/ -type f \( -name "*.db" -o -name "*.sqlite" -o -name "*.sqlite3" \)'
local_probe_step termux-sqlite3 'command -v sqlite3 && sqlite3 --version'
