#!/bin/zsh
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
cat PocketCtrlNative/PocketCtrl/PersistentHostIdentity.swift Tests/HostIdentityCases.swift |
    xcrun swift -sdk "$sdk" -module-cache-path "${TMPDIR:-/tmp}/pocketctrl-identity-test-cache" -
