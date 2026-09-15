#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
{
    cat Tests/AudioSessionStubs.swift Tests/SpeechInputStubs.swift
    sed '/^import AVFoundation$/d' PocketCtrlNative/PocketCtrlMobile/ClientAudioSession.swift
    sed '/^import AVFoundation$/d; /^import Speech$/d' PocketCtrlNative/PocketCtrlMobile/ClientSpeechInput.swift
    cat Tests/SpeechInputCases.swift
} | xcrun swift -sdk "$sdk" -module-cache-path "${TMPDIR:-/tmp}/pocketctrl-audio-test-cache" -
