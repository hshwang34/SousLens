#!/bin/sh
# Picks the iOS simulator for `make ios-check` / `make ios-smoke`.
#
#   sim-pick.sh name "iPhone 15"   -> the simulator name to use
#   sim-pick.sh os   "iPhone 15"   -> its iOS runtime version
#
# If a simulator with the requested name is available, it is used on the newest runtime that has
# it (a bare `name=` destination resolves to OS:latest, which fails when that model only ships with
# an older runtime, e.g. iPhone 15 -> iOS 17.x). If not (a machine with only newer runtimes), it
# falls back to a stock iPhone on the newest installed iOS runtime, so the check still runs.
# CI passes SIM explicitly and gets exactly that device.
what="${1:?usage: sim-pick.sh name|os <simulator name>}"
want="${2:?usage: sim-pick.sh name|os <simulator name>}"
xcrun simctl list devices available | awk -v want="$want" -v what="$what" '
  /^-- iOS / { os = $3; next }
  /^--/ { os = ""; next }
  os != "" && match($0, /^ +.* \([0-9A-F-]+\)/) {
    line = $0; sub(/^ +/, "", line); sub(/ \([0-9A-F-]+\).*$/, "", line)
    if (line == want) { if (wantOS == "" || vcmp(os, wantOS) > 0) wantOS = os }
    # Stock phones only ("iPhone 17", "iPhone 16e", "iPhone 17 Pro"), never custom-named clones.
    if (line ~ /^iPhone [0-9]+[a-z]*( Pro| Pro Max| Plus)?$/) {
      if (fbOS == "" || vcmp(os, fbOS) > 0 || (os == fbOS && rank(line) < rank(fbName))) { fbOS = os; fbName = line }
    }
  }
  function rank(n) { return (n ~ /Pro|Plus/) ? 1 : 0 }
  function vcmp(a, b,   x, y, i, n) {
    n = split(a, x, "."); split(b, y, ".")
    for (i = 1; i <= 3; i++) { if ((x[i] + 0) != (y[i] + 0)) return (x[i] + 0) - (y[i] + 0) }
    return 0
  }
  END {
    if (wantOS != "") { name = want; ver = wantOS } else { name = fbName; ver = fbOS }
    print (what == "name") ? name : ver
  }'
