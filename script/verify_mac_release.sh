#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fail() { echo "Release verification failed: $*" >&2; exit 1; }
[[ $# -eq 1 && -d "$1/Contents" ]] || fail "Pass the path to a signed PocketCtrl.app."
APP="$1"
codesign --verify --deep --strict --verbose=2 "$APP"
DETAILS="$(codesign -dvvv "$APP" 2>&1)"
[[ "$DETAILS" == *"Authority=Developer ID Application:"* ]] || fail "A Developer ID Application signature is required, not Debug/ad hoc/App Store signing."
[[ "$DETAILS" == *"runtime"* ]] || fail "Hardened runtime is missing."
[[ "$DETAILS" == *"Timestamp="* ]] || fail "A secure signing timestamp is required."
[[ -f "$APP/Contents/embedded.provisionprofile" ]] || fail "Missing Developer ID provisioning profile required for this app's data-protection Keychain."
[[ -f "$APP/Contents/Resources/PrivacyInfo.xcprivacy" ]] || fail "Mac privacy manifest is missing from the bundle."
ARCHS="$(lipo -archs "$APP/Contents/MacOS/PocketCtrl")"
[[ " $ARCHS " == *" arm64 "* && " $ARCHS " == *" x86_64 "* ]] || fail "Both Apple silicon and Intel architectures are required."
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pocketctrl-verify.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
codesign -d --entitlements :- "$APP" > "$TMP/entitlements.plist" 2>/dev/null
security cms -D -i "$APP/Contents/embedded.provisionprofile" > "$TMP/profile.plist"
xcrun swift "$ROOT/script/verify_mac_release.swift" \
  "$APP/Contents/Info.plist" "$TMP/entitlements.plist" "$TMP/profile.plist"
echo "Developer ID signature, profile, privacy resource, and universal binary verified."
echo "This does not replace notarization or runtime testing of permissions and pairing."
