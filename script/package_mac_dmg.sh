#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fail() { echo "Error: $*" >&2; exit 1; }
[[ $# -eq 1 ]] || fail "Usage: NOTARY_PROFILE=your-profile bash script/package_mac_dmg.sh /path/to/notarized/PocketCtrl.app"
[[ -n "${NOTARY_PROFILE:-}" ]] || fail "Set NOTARY_PROFILE to your notarytool Keychain profile."
SOURCE="$1"
bash "$ROOT/script/verify_mac_release.sh" "$SOURCE"
xcrun stapler validate "$SOURCE"
spctl --assess --type execute --verbose=2 "$SOURCE"
IDENTITY="$(codesign -dvv "$SOURCE" 2>&1 | sed -n 's/^Authority=\(Developer ID Application:.*\)$/\1/p')"
[[ -n "$IDENTITY" ]] || fail "Cannot identify the app's Developer ID signer."
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SOURCE/Contents/Info.plist")
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ && "$BUILD" =~ ^[0-9]+(\.[0-9]+)*$ ]] || fail "Invalid version/build for release filename."
mkdir -p "$ROOT/.build/mac-release" "$ROOT/release-output"
WORK="$(mktemp -d "$ROOT/.build/mac-release/dmg.XXXXXX")"
MOUNT="$WORK/mounted"
MOUNTED=false
cleanup() {
  if [[ "$MOUNTED" == true ]]; then
    hdiutil detach "$MOUNT" >/dev/null || echo "Detach the installer volume manually: $MOUNT" >&2
  fi
}
trap cleanup EXIT
mkdir -p "$WORK/staging" "$MOUNT"
ditto "$SOURCE" "$WORK/staging/PocketCtrl.app"
ln -s /Applications "$WORK/staging/Applications"
hdiutil create -fs HFS+ -format UDRW -volname "PocketCtrl $VERSION ($BUILD) - Drag to Applications" \
  -srcfolder "$WORK/staging" "$WORK/layout.dmg"
hdiutil attach "$WORK/layout.dmg" -mountpoint "$MOUNT" -nobrowse
MOUNTED=true
# Finder writes the saved window layout into .DS_Store; requires a logged-in Mac desktop.
osascript "$ROOT/script/layout_mac_dmg.applescript" "$MOUNT"
sync
hdiutil detach "$MOUNT"
MOUNTED=false
NAME="PocketCtrl-$VERSION-$BUILD-mac.dmg"
hdiutil convert "$WORK/layout.dmg" -format UDZO -imagekey zlib-level=9 -o "$WORK/$NAME"
codesign --force --sign "$IDENTITY" --timestamp "$WORK/$NAME"
codesign --verify --strict --verbose=2 "$WORK/$NAME"
echo "Submitting the signed installer disk image to Apple's notary service."
xcrun notarytool submit "$WORK/$NAME" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$WORK/notarization.json"
/usr/bin/plutil -p "$WORK/notarization.json"
[[ "$(/usr/bin/plutil -extract status raw -o - "$WORK/notarization.json")" == Accepted ]] || fail "Apple rejected the DMG; inspect the submission ID in $WORK/notarization.json."
xcrun stapler staple "$WORK/$NAME"
xcrun stapler validate "$WORK/$NAME"
spctl --assess --type open --context context:primary-signature --verbose=2 "$WORK/$NAME"
hdiutil verify "$WORK/$NAME"
# Only completed, validated installers appear in release-output.
OUT="$(mktemp -d "$ROOT/release-output/mac-dmg.XXXXXX")"
ditto "$WORK/$NAME" "$OUT/$NAME"
(cd "$OUT" && shasum -a 256 "$NAME" > "$NAME.sha256")
echo "Notarized installer: $OUT/$NAME"
echo "Checksum: $OUT/$NAME.sha256"
echo "Not published. Test the disk image before uploading it and changing the website download URL."
