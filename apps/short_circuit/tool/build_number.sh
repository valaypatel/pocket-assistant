#!/usr/bin/env bash
# Prints the build number (Android versionCode) for a build made now: the time, in 10-second
# steps since 2026-01-01 UTC. CI uses the same formula, so whichever build was made last has
# the higher number, wherever it was made, and Android never refuses an update as a downgrade
# (which would force an uninstall and wipe the app's settings and keys).
#
#   flutter build apk --release --build-number="$(tool/build_number.sh)"
#
# Never pass a hand-picked number to --build-number for a build that goes on a phone.
set -euo pipefail
echo $(( ($(date -u +%s) - 1767225600) / 10 ))
