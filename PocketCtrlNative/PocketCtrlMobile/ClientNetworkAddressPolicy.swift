// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation

enum ClientNetworkAddressPolicy {
    /// A fresh Bonjour result for the paired identity may cross local subnets.
    /// Saved addresses still need a subnet check; never substitute a VPN route.
    static func localWiFiHost(savedHost: String, discoveredHost: String?, deviceHost: String, deviceNetmask: String?) -> String? {
        if let discoveredHost {
            let host = normalized(discoveredHost)
            if isPrivateOrLocalAddress(host), !isTailscaleHost(host), !IPNetwork.isLoopback(host), !IPNetwork.isUnspecified(host) {
                return host
            }
        }
        let host = normalized(savedHost)
        guard !IPNetwork.isLoopback(host),
              shouldTryLocalRoute(localHost: host, deviceHost: deviceHost, deviceNetmask: deviceNetmask) else { return nil }
        return host
    }

    static func normalized(_ value: String) -> String {
        IPNetwork.normalized(value)
    }

    static func shouldAcceptDetectedPeer(configuredHost: String, detectedHost: String) -> Bool {
        let configuredHost = normalized(configuredHost)
        let detectedHost = normalized(detectedHost)
        guard !detectedHost.isEmpty, !IPNetwork.isUnspecified(detectedHost) else { return false }

        if IPNetwork.isNumeric(configuredHost) {
            return detectedHost == configuredHost
        }

        if configuredHost.lowercased().hasSuffix(".ts.net") {
            return false
        }

        if !IPNetwork.isNumeric(configuredHost) {
            return isTailscaleAddress(detectedHost) || isPrivateOrLocalAddress(detectedHost)
        }

        return false
    }

    /// Validates the source address only after the stream datagram has been
    /// authenticated with the paired device credential. A paired Mac can move
    /// between LAN and Tailscale while a session is active, and macOS may
    /// source UDP from either interface during that handoff.
    static func shouldAcceptAuthenticatedStreamPeer(configuredHost: String, sourceHost: String?) -> Bool {
        let configuredHost = normalized(configuredHost)
        guard let rawSourceHost = sourceHost else { return false }
        let sourceHost = normalized(rawSourceHost)
        guard !configuredHost.isEmpty,
              !sourceHost.isEmpty,
              !IPNetwork.isUnspecified(sourceHost) else {
            return false
        }
        if configuredHost == sourceHost {
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

    /// iOS exposes VPN tunnels, including Tailscale, as `utun` interfaces.
    /// Carriers may assign 100.64.0.0/10 CGNAT addresses to cellular
    /// (`pdp_ip`) interfaces; those are not a Tailscale route, so an address
    /// in the Tailscale range only counts when it belongs to a tunnel.
    static func isTailscaleInterface(name: String, address: String) -> Bool {
        isTailscaleAddress(address) && name.lowercased().hasPrefix("utun")
    }

    static func isTailscaleHost(_ address: String) -> Bool {
        isTailscaleAddress(normalized(address))
    }

    static func isPrivateOrLocalAddress(_ address: String) -> Bool {
        IPNetwork.isPrivateOrLocal(address)
    }

    static func likelySameLocalNetwork(_ lhs: String, _ rhs: String) -> Bool {
        guard isPrivateOrLocalAddress(lhs),
              isPrivateOrLocalAddress(rhs),
              !isTailscaleAddress(lhs),
              !isTailscaleAddress(rhs),
              let left = ipv4Octets(lhs),
              let right = ipv4Octets(rhs) else {
            return false
        }

        return left[0] == right[0] && left[1] == right[1] && left[2] == right[2]
    }

    static func shouldTryLocalRoute(localHost: String, deviceHost: String, deviceNetmask: String? = nil) -> Bool {
        let localHost = normalized(localHost)
        let deviceHost = normalized(deviceHost)
        if IPNetwork.ipv6Bytes(localHost) != nil {
            guard !isTailscaleAddress(localHost), !IPNetwork.isLoopback(localHost),
                  !IPNetwork.isUnspecified(localHost) else { return false }
            if IPNetwork.sameSubnet(localHost, deviceHost, netmask: deviceNetmask) { return true }
            return IPNetwork.interfaces().contains {
                !$0.name.hasPrefix("utun") && IPNetwork.sameSubnet(localHost, $0.address, netmask: $0.netmask)
            }
        }
        guard isPrivateOrLocalAddress(localHost),
              isPrivateOrLocalAddress(deviceHost),
              !isTailscaleAddress(localHost),
              !isTailscaleAddress(deviceHost) else {
            return false
        }

        if let deviceNetmask,
           addressesShareIPv4Network(localHost, deviceHost, netmask: deviceNetmask) {
            return true
        }

        return likelySameLocalNetwork(localHost, deviceHost)
    }

    static func localRouteRejectionReason(localHost: String, deviceHost: String, deviceNetmask: String? = nil) -> String? {
        let localHost = normalized(localHost)
        let deviceHost = normalized(deviceHost)

        if shouldTryLocalRoute(localHost: localHost, deviceHost: deviceHost, deviceNetmask: deviceNetmask) { return nil }
        if IPNetwork.ipv6Bytes(localHost) != nil { return "Mac IPv6 address is not on an active local interface" }
        guard !localHost.isEmpty else { return "Mac local address is empty" }
        guard !deviceHost.isEmpty else { return "iPhone has no Wi-Fi/local IPv4 address" }
        guard isPrivateOrLocalAddress(localHost), !isTailscaleAddress(localHost) else {
            return "Mac local address is not a private LAN IPv4 address"
        }
        guard isPrivateOrLocalAddress(deviceHost), !isTailscaleAddress(deviceHost) else {
            return "iPhone local address is not a private LAN IPv4 address"
        }
        guard shouldTryLocalRoute(localHost: localHost, deviceHost: deviceHost, deviceNetmask: deviceNetmask) else {
            if let deviceNetmask, !deviceNetmask.isEmpty {
                return "Mac local address is outside the iPhone Wi-Fi subnet \(deviceHost)/\(deviceNetmask)"
            }
            return "Mac local address is not on the same /24 as the iPhone"
        }

        return nil
    }

    static func ipv4Octets(_ address: String) -> [Int]? {
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

    private static func addressesShareIPv4Network(_ lhs: String, _ rhs: String, netmask: String) -> Bool {
        guard let left = ipv4Octets(lhs),
              let right = ipv4Octets(rhs),
              let mask = ipv4Octets(netmask) else {
            return false
        }

        return zip(zip(left, right), mask).allSatisfy { element in
            let ((leftOctet, rightOctet), maskOctet) = element
            return (leftOctet & maskOctet) == (rightOctet & maskOctet)
        }
    }
}
