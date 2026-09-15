#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
{
    printf 'import Foundation\nimport CoreGraphics\n'
    printf 'struct NSEvent { let deltaX: CGFloat; let deltaY: CGFloat }\n'
    printf 'struct PointerHarness { var videoContentRect: CGRect; var remoteVideoSize: CGSize\n'
    # Compile the actual Mac delta conversion methods, without capturing a mouse.
    sed -n '/^    private func normalizedRelativeDelta/,/^    private func beginMouseCapture/{ /^    private func beginMouseCapture/!p; }' PocketCtrlNative/PocketCtrl/RemoteVideoView.swift | sed 's/private func/func/g'
    printf '}\n'
    cat Tests/MacPointerCases.swift
} | xcrun swift -sdk "$sdk" -module-cache-path "${TMPDIR:-/tmp}/pocketctrl-pointer-test-cache" -
