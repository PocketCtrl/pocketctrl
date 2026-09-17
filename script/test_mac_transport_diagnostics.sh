#!/bin/zsh
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
cat Tests/NetworkTestSupport.swift \
    PocketCtrlNative/PocketCtrl/IPNetwork.swift \
    PocketCtrlNative/PocketCtrl/UDPTransport.swift \
    PocketCtrlNative/PocketCtrl/MacTransportDiagnostics.swift \
    Tests/MacTransportDiagnosticCases.swift | \
    xcrun swift -D POCKETCTRL_NETWORK_DIAGNOSTICS -sdk "$sdk" \
    -module-cache-path "${TMPDIR:-/tmp}/pocketctrl-diagnostic-test-cache" -
