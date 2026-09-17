#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# Read-only, bounded capture. Logs stay in ignored local build output.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
umask 077
mkdir -p "$ROOT/.build/network-diagnostics"
OUT="$(mktemp -d "$ROOT/.build/network-diagnostics/capture.XXXXXX")"
PREDICATE='(subsystem == "app.pocketctrl.mac" AND (category == "TransportComparison" OR category == "LocalNetworkRecovery")) OR (process == "PocketCtrl" AND subsystem == "com.apple.network" AND (eventMessage CONTAINS[c] "prohibited" OR eventMessage CONTAINS[c] "unsatisfied")) OR (process == "nehelper" AND eventMessage CONTAINS[c] "app.pocketctrl.mac")'
echo "Capturing PocketCtrl network diagnostics for five minutes: $OUT"
echo "No permissions, connections, or hosting settings are changed. Logs may contain local network metadata; do not publish them."
/usr/bin/log show --last 10m --style compact --info --predicate "$PREDICATE" > "$OUT/recent.log"
/usr/bin/log stream --timeout 5m --style compact --level info --predicate "$PREDICATE" > "$OUT/live.log"
echo "Capture complete: $OUT"
