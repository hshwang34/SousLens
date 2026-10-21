#!/bin/sh
# Prints the newest installed iOS runtime version that has an available simulator named "$1".
# Used by the root Makefile: a bare `name=` destination resolves to OS:latest, which fails when
# that model only ships with an older runtime (iPhone 15 → iOS 17.x).
sim="${1:?usage: sim-os.sh <simulator name>}"
xcrun simctl list devices available \
  | awk -v sim="$sim" '/^-- iOS/ { os = $3 } index($0, sim " (") { print os }' \
  | sort -V | tail -1
