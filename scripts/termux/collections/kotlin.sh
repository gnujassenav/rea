# shellcheck shell=bash disable=SC2016
# Kotlin: marker entries in each third-party base APK, and Termux compilers.
# Raw adb and Termux output. For each APK the file holds a header line, the
# archive entries under kotlin/ or named *.kotlin_module exactly as unzip
# lists them, and unzip's exit code. Listed entries show Kotlin was used; no
# entries do not show it was not, because shrinkers can remove them.
adb_probe_step kotlin-markers-third-party '
command -v unzip >/dev/null || { echo "unzip is not available on this device" >&2; exit 127; }
packages="$(pm list packages -3 -f)" || exit $?
printf "%s\n" "$packages" | sed -e "s/^package://" | while IFS= read -r line; do
  [ -n "$line" ] || continue
  apk="${line%=*}"
  printf "== package=%s apk=%s\n" "${line##*=}" "$apk"
  entries="$(unzip -l "$apk" 2>&1)"
  code=$?
  printf "%s\n" "$entries" | grep -E " (kotlin/|META-INF/.*\.kotlin_module)"
  printf "unzip-exit=%s\n" "$code"
done'
for tool in kotlinc kotlin; do
  local_probe_step "termux-$tool" "command -v $tool"
done
