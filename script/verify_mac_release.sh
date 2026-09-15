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
if /usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist" >/dev/null 2>&1; then
  FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
  [[ -d "$FRAMEWORK" ]] || fail "Sparkle is linked but not embedded."
  codesign --verify --deep --strict "$FRAMEWORK"
  APP_TEAM=$(printf '%s\n' "$DETAILS" | sed -n 's/^TeamIdentifier=//p')
  FRAMEWORK_TEAM=$(codesign -dvv "$FRAMEWORK" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  [[ -n "$APP_TEAM" && "$FRAMEWORK_TEAM" == "$APP_TEAM" ]] || fail "Sparkle must be embedded and signed by the app's team."
  for HELPER in "$FRAMEWORK/Versions/Current/Autoupdate" \
    "$FRAMEWORK/Versions/Current/Updater.app" \
    "$FRAMEWORK/Versions/Current/XPCServices/Downloader.xpc" \
    "$FRAMEWORK/Versions/Current/XPCServices/Installer.xpc"; do
    [[ -e "$HELPER" ]] || fail "Sparkle helper missing: $HELPER"
    HELPER_DETAILS=$(codesign -dvvv "$HELPER" 2>&1)
    [[ "$HELPER_DETAILS" == *"Authority=Developer ID Application:"* && "$HELPER_DETAILS" == *"Timestamp="* ]] || fail "Export the archive to Developer ID-sign and timestamp Sparkle helpers before packaging."
  done
fi
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
