#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail

MODE="${1:-run}"
APP_NAME="PocketCtrl"
BUNDLE_ID="app.pocketctrl.mac"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/PocketCtrlNative/PocketCtrl.xcodeproj"
DERIVED_DATA="$ROOT_DIR/.build/codex/PocketCtrlDerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
XCODEBUILD="/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

"$XCODEBUILD" \
  -project "$PROJECT" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  build

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    /usr/bin/lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
