#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PROJECT="$ROOT/PocketCtrlNative/PocketCtrl.xcodeproj"
fail() { echo "Error: $*" >&2; exit 1; }
usage() {
  echo "Usage: bash script/release_mac.sh preflight|archive|package /path/to/PocketCtrl.app"
  echo "archive requires PROFILE_NAME (installed Developer ID provisioning profile name or UUID)."
  echo "package requires NOTARY_PROFILE (a notarytool Keychain profile); uploads to Apple, not your website."
  echo "Optional: TEAM_ID, SIGN_IDENTITY, DEVELOPER_DIR. See docs/mac-website-release.md."
}
[[ $# -ge 1 ]] || { usage; exit 2; }
case "$1" in preflight|archive|package) ;; --help|-h) usage; exit 0 ;; *) usage; exit 2 ;; esac
[[ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]] || fail "Set DEVELOPER_DIR to a full Xcode installation."
[[ "$(uname -s)" == Darwin ]] || fail "A Mac is required."

case "$1" in
  preflight)
    xcrun xcodebuild -version
    echo "Available local signing identities (Developer ID Application is needed):"
    security find-identity -v -p codesigning
    echo "Provisioning and notarization credentials are checked during archive/package."
    ;;
  archive)
    [[ -n "${PROFILE_NAME:-}" ]] || fail "Set PROFILE_NAME to your installed Developer ID profile for app.pocketctrl.mac."
    mkdir -p "$ROOT/.build/mac-release"
    WORK="$(mktemp -d "$ROOT/.build/mac-release/archive.XXXXXX")"
    # Intentionally no -allowProvisioningUpdates: this never changes the Developer portal.
    xcrun xcodebuild archive \
      -project "$PROJECT" -scheme PocketCtrl -configuration Release \
      -destination 'generic/platform=macOS' \
      -derivedDataPath "$WORK/DerivedData" -archivePath "$WORK/PocketCtrl.xcarchive" \
      -xcconfig "$ROOT/distribution/macos/Website.xcconfig" \
      DEVELOPMENT_TEAM="${TEAM_ID:-PS3A7X5HHS}" \
      CODE_SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}" \
      PROVISIONING_PROFILE_SPECIFIER="$PROFILE_NAME"
    APP="$WORK/PocketCtrl.xcarchive/Products/Applications/PocketCtrl.app"
    bash "$ROOT/script/verify_mac_release.sh" "$APP"
    echo "Signed archive ready (not notarized yet): $APP"
    echo "Next: NOTARY_PROFILE=your-profile bash script/release_mac.sh package \"$APP\""
    ;;
  package)
    [[ $# -eq 2 ]] || { usage; exit 2; }
    [[ -n "${NOTARY_PROFILE:-}" ]] || fail "Set NOTARY_PROFILE to your notarytool Keychain profile."
    SOURCE="$2"
    # Reject invalid builds before copying or contacting Apple's notary service.
    bash "$ROOT/script/verify_mac_release.sh" "$SOURCE"
    mkdir -p "$ROOT/.build/mac-release"
    WORK="$(mktemp -d "$ROOT/.build/mac-release/package.XXXXXX")"
    APP="$WORK/PocketCtrl.app"
    ditto "$SOURCE" "$APP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/notary-upload.zip"
    echo "Submitting this signed Mac build to Apple's notary service."
    xcrun notarytool submit "$WORK/notary-upload.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    bash "$ROOT/script/verify_mac_release.sh" "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
    VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
    BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
    mkdir -p "$ROOT/release-output"
    OUT="$(mktemp -d "$ROOT/release-output/mac.XXXXXX")"
    ZIP="PocketCtrl-$VERSION-$BUILD-mac.zip"
    # Recreate AFTER stapling. Never publish the pre-staple notary-upload.zip.
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ZIP"
    (cd "$OUT" && shasum -a 256 "$ZIP" > "$ZIP.sha256")
    echo "Notarized download: $OUT/$ZIP"
    echo "Checksum: $OUT/$ZIP.sha256"
    # Preserve ZIP compatibility and also create the drag-to-Applications installer.
    bash "$ROOT/script/package_mac_dmg.sh" "$APP"
    echo "Not published. Test a browser-downloaded copy on another Mac before release."
    ;;
esac
