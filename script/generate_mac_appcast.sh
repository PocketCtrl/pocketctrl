#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "Error: $*" >&2; exit 1; }
[[ $# -eq 2 ]] || fail 'Usage: bash script/generate_mac_appcast.sh /path/to/notarized.dmg v1.0.1'
DMG="$1"
TAG="$2"
[[ -f "$DMG" && "$DMG" == *.dmg ]] || fail 'Supply the final notarized DMG.'
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Use a release tag such as v1.0.1.'
BIN="${SPARKLE_BIN:-$ROOT/.build/sparkle-tools/bin}"
[[ -x "$BIN/generate_appcast" && -x "$BIN/generate_keys" ]] || fail 'Set SPARKLE_BIN to the resolved Sparkle distribution bin directory.'
EXPECTED=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$ROOT/PocketCtrlNative/PocketCtrl/Info.plist")
ACTUAL=$("$BIN/generate_keys" --account app.pocketctrl.mac -p)
[[ "$ACTUAL" == "$EXPECTED" ]] || fail 'The update signing key does not match PocketCtrl. Do not generate a replacement key.'
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature "$DMG"
mkdir -p "$ROOT/release-output"
OUT=$(mktemp -d "$ROOT/release-output/appcast.XXXXXX")
ditto "$DMG" "$OUT/$(basename "$DMG")"
"$BIN/generate_appcast" --account app.pocketctrl.mac --maximum-deltas 0 \
    --download-url-prefix "https://github.com/PocketCtrl/pocketctrl/releases/download/$TAG/" \
    -o "$OUT/appcast.xml" "$OUT"
echo "Generated: $OUT/appcast.xml"
echo 'Upload appcast.xml and this exact DMG to the SAME GitHub release; mark it Latest only after testing.'
echo 'Nothing has been published.'
