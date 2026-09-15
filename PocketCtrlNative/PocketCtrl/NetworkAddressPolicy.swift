// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation

enum NetworkAddressPolicy {
    static func normalized(_ value: String) -> String {
        IPNetwork.normalized(value)
    }

    static func shouldAcceptDetectedPeer(configuredHost: String, detectedHost: String) -> Bool {
        let configuredHost = normalized(configuredHost)
        let detectedHost = normalized(detectedHost)
        guard !detectedHost.isEmpty, !IPNetwork.isUnspecified(detectedHost) else { return false }

        if isTailscaleAddress(configuredHost) {
            return isTailscaleAddress(detectedHost)
        }

        if isPrivateOrLocalAddress(configuredHost) || !IPNetwork.isNumeric(configuredHost) {
            return isTailscaleAddress(detectedHost) || isPrivateOrLocalAddress(detectedHost)
        }

        return detectedHost == configuredHost
    }

    /// Use only after the datagram has authenticated successfully. A paired Mac
    /// can move between LAN and Tailscale while a session is active, and macOS
    /// may source UDP from either interface during that handoff.
    static func shouldAcceptAuthenticatedStreamPeer(configuredHost: String, sourceHost: String?) -> Bool {
        let configuredHost = normalized(configuredHost)
        guard let rawSourceHost = sourceHost else { return false }
        let sourceHost = normalized(rawSourceHost)
        guard !configuredHost.isEmpty,
              !sourceHost.isEmpty,
              !IPNetwork.isUnspecified(sourceHost) else {
            return false
        }
        if sourceHost == configuredHost {
            return true
        }

        let configuredRouteIsPrivate = isTailscaleAddress(configuredHost)
            || isPrivateOrLocalAddress(configuredHost)
            || configuredHost.lowercased().hasSuffix(".ts.net")
            || !IPNetwork.isNumeric(configuredHost)
        guard configuredRouteIsPrivate else { return false }

        return isTailscaleAddress(sourceHost) || isPrivateOrLocalAddress(sourceHost)
    }

    static func isTailscaleAddress(_ address: String) -> Bool {
        IPNetwork.isTailscale(address)
    }

    static func isPrivateOrLocalAddress(_ address: String) -> Bool {
        IPNetwork.isPrivateOrLocal(address)
    }

    static func isOnSameSubnet(peerAddress: String, interfaceAddress: String, netmask: String) -> Bool {
        IPNetwork.sameSubnet(peerAddress, interfaceAddress, netmask: netmask)
    }

    private static func ipv4Octets(_ address: String) -> [Int]? {
        let trimmed = normalized(address)
        var parsed = in_addr()
        guard trimmed.withCString({ inet_pton(AF_INET, $0, &parsed) }) == 1 else {
            return nil
        }
        let parts = trimmed.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else {
            return nil
        }
        return parts
    }

    private static func ipv4Value(_ address: String) -> UInt32? {
        guard let octets = ipv4Octets(address) else { return nil }
        return octets.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
