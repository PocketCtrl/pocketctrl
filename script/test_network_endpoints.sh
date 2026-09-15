#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
cmp PocketCtrlNative/PocketCtrl/IPNetwork.swift PocketCtrlNative/PocketCtrlMobile/IPNetwork.swift
{
    cat Tests/NetworkTestSupport.swift PocketCtrlNative/PocketCtrl/IPNetwork.swift PocketCtrlNative/PocketCtrl/NetworkAddressPolicy.swift PocketCtrlNative/PocketCtrlMobile/ClientNetworkAddressPolicy.swift PocketCtrlNative/PocketCtrl/PairingInvitationCode.swift PocketCtrlNative/PocketCtrl/UDPTransport.swift
    # Expose only the parser to fixtures; do not start Bonjour searches.
    sed 's/private func discoveredHost/func discoveredHost/' PocketCtrlNative/PocketCtrl/LocalDiscoveryAdvertiser.swift
    sed -n '/^struct ClientDiscoveredHost/,$p' PocketCtrlNative/PocketCtrlMobile/ClientLocalDiscoveryBrowser.swift | sed -e 's/private func discoveredHost/func discoveredHost/' -e 's/private var targetHostID/var targetHostID/'
    sed -n '/^final class ClientUDPReceiver/,/^final class ClientH264Decoder/{ /^final class ClientH264Decoder/!p; }' PocketCtrlNative/PocketCtrlMobile/ClientVideoPipeline.swift
    cat Tests/DiscoveryEndpointCases.swift
    cat Tests/NetworkEndpointCases.swift
} | xcrun swift -sdk "$sdk" -module-cache-path "${TMPDIR:-/tmp}/pocketctrl-network-test-cache" -
