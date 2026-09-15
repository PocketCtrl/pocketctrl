#!/bin/zsh
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
{
    cat Tests/AudioSessionStubs.swift
    sed '/^import AVFoundation$/d' PocketCtrlNative/PocketCtrlMobile/ClientAudioSession.swift
    cat Tests/AudioSessionCases.swift
} | xcrun swift -sdk "$sdk" -module-cache-path "${TMPDIR:-/tmp}/pocketctrl-audio-test-cache" -
