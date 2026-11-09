# shellcheck shell=bash disable=SC2016
# Kotlin: marker entries in each third-party base APK, and Termux compilers.
# Raw adb and Termux output. A marker shows Kotlin was used; a missing marker
# does not show it was not, because shrinkers can remove these entries.
adb_step kotlin-markers-third-party '
if ! command -v unzip >/dev/null 2>&1; then echo "unknown unzip-not-found"; exit 0; fi
pm list packages -3 -f | sed -e "s/^package://" | while IFS= read -r line; do
  apk="${line%=*}"; pkg="${line##*=}"
  entries="$(unzip -l "$apk" 2>/dev/null)" || { echo "unknown $pkg unreadable-apk"; continue; }
  if printf "%s\n" "$entries" | grep -q -E " (kotlin/|META-INF/.*\.kotlin_module)"; then
    echo "kotlin-marker $pkg"
  else
    echo "no-kotlin-marker $pkg"
  fi
done'
local_step termux-kotlin-tools sh -c \
  'for tool in kotlinc kotlin; do command -v "$tool" || echo "$tool not-found"; done'
