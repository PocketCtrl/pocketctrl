#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
{
    printf 'import Foundation\n'
    sed -n '/^enum ClientStreamQualityProfile/,/^enum ClientControlPayloadType/{ /^enum ClientControlPayloadType/!p; }' PocketCtrlNative/PocketCtrlMobile/ClientModel.swift
    cat PocketCtrlNative/PocketCtrl/ViewerStreamSettings.swift
    sed -n '/^struct ViewerFeedback/,/^struct ViewerZoomRegion/{ /^struct ViewerZoomRegion/!p; }' PocketCtrlNative/PocketCtrl/RemoteInput.swift
    printf 'enum FeedbackAggregationFixture {\n'
    sed -n '/^    private static func aggregate(feedbacks:/,/^final class SecureMultiPeerDatagramSender/{ /^final class SecureMultiPeerDatagramSender/!p; }' PocketCtrlNative/PocketCtrl/SecureSessionDatagram.swift | sed 's/private static func/static func/g'
    sed '$d' Tests/StreamQualityHarness.swift
    sed -n '/^    private func updateAdaptiveVideoState/,/^    private func restartStreamForCurrentQualityProfile/{ /^    private func restartStreamForCurrentQualityProfile/!p; }' PocketCtrlNative/PocketCtrl/VideoPipeline.swift | sed -e 's/private func/func/g' -e 's/private var/var/g'
    printf '}\n'
    sed '$d' Tests/ViewerQualityFeedbackHarness.swift
    sed -n '/^    func setStreamSettings/,/^    private func startKeepalive/{ /^    private func startKeepalive/!p; }' PocketCtrlNative/PocketCtrl/VideoPipeline.swift | sed 's/private func/func/g'
    printf '}\n'
    cat Tests/StreamQualityCases.swift
} | xcrun swift -sdk "$sdk" -module-cache-path "${TMPDIR:-/tmp}/pocketctrl-quality-test-cache" -
