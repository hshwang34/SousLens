#!/bin/sh
# Brief 009 / DECISIONS #19: the public SousLens app must not link Meta's DAT SDK or
# ExternalAccessory, nor carry DAT Info.plist keys. Usage: check-no-dat.sh <path/to/SousLens.app>
set -eu
app="${1:?usage: check-no-dat.sh <path/to/SousLens.app>}"
[ -d "$app" ] || { echo "check-no-dat: $app not found" >&2; exit 2; }
fail=0
note() { echo "check-no-dat: FAIL: $*" >&2; fail=1; }

# 1. No DAT frameworks embedded.
if ls "$app/Frameworks" 2>/dev/null | grep -q '^MWDAT'; then
  note "MWDAT framework embedded: $(ls "$app/Frameworks" | grep '^MWDAT' | tr '\n' ' ')"
fi
# 2. No load command for DAT or ExternalAccessory in any Mach-O of the app (main binary plus
#    the Debug-only *.debug.dylib).
for bin in "$app/$(basename "$app" .app)" "$app"/*.dylib; do
  [ -f "$bin" ] || continue
  if otool -L "$bin" | grep -Eiq 'MWDAT|ExternalAccessory'; then
    note "$(basename "$bin") links: $(otool -L "$bin" | grep -Ei 'MWDAT|ExternalAccessory' | tr -s ' \t' ' ')"
  fi
  # 3. No DAT symbols referenced or defined.
  if nm -m "$bin" 2>/dev/null | grep -q 'MWDAT'; then
    note "$(basename "$bin") references MWDAT symbols"
  fi
done
# 4. No DAT / ExternalAccessory Info.plist keys.
for key in MWDAT UISupportedExternalAccessoryProtocols; do
  if /usr/libexec/PlistBuddy -c "Print :$key" "$app/Info.plist" >/dev/null 2>&1; then
    note "Info.plist has $key"
  fi
done
[ "$fail" -eq 0 ] && echo "check-no-dat: OK — $(basename "$app") links no DAT, no ExternalAccessory, no DAT plist keys."
exit "$fail"
