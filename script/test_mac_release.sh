#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pocketctrl-release-tests.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
bash -n "$ROOT/script/release_mac.sh" "$ROOT/script/verify_mac_release.sh" "$ROOT/script/package_mac_dmg.sh"
if NOTARY_PROFILE='' bash "$ROOT/script/package_mac_dmg.sh" "$TMP/missing.app" > "$TMP/missing-notary.log" 2>&1; then
  echo "FAIL: DMG packaging should require a notarization profile" >&2; exit 1
fi
if NOTARY_PROFILE='test-unused' bash "$ROOT/script/package_mac_dmg.sh" "$TMP/missing.app" > "$TMP/missing-dmg-app.log" 2>&1; then
  echo "FAIL: DMG packaging should reject a missing bundle" >&2; exit 1
fi
xcrun swiftc -module-cache-path "$TMP/modules" "$ROOT/script/verify_mac_release.swift" -o "$TMP/verify"
xcrun swift -module-cache-path "$TMP/modules" "$ROOT/script/test_mac_release.swift" "$TMP/verify" "$TMP"
if PROFILE_NAME='' bash "$ROOT/script/release_mac.sh" archive > "$TMP/missing-profile.log" 2>&1; then
  echo "FAIL: archive should require an explicit installed profile" >&2; exit 1
fi
if bash "$ROOT/script/verify_mac_release.sh" "$TMP/missing.app" > "$TMP/missing-app.log" 2>&1; then
  echo "FAIL: verifier should reject a missing bundle" >&2; exit 1
fi
echo "Archive precondition and missing-bundle checks passed. No real certificates or profiles were used."
