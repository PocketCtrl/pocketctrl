// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation

/// Identical in the macOS and iOS targets. Keep address parsing out of the
/// encrypted packet formats: a paired device's identity is not its IP address.
enum IPNetwork {
    struct Interface {
        let name: String
        let address: String
        let netmask: String?
    }

    static func unbracketed(_ value: String) -> String {
        var host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast()).replacingOccurrences(of: "%25", with: "%")
        }
        return host
    }

    static func normalized(_ value: String) -> String {
        let host = unbracketed(value)
        var v4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            return ipv4String(v4) ?? host
        }
        let pieces = host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        guard let literal = pieces.first else { return host }
        var v6 = in6_addr()
        guard String(literal).withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 else {
            return host.lowercased()
        }
        if let mapped = mappedIPv4(v6) { return mapped }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &v6, &buffer, socklen_t(buffer.count)) != nil else { return host }
        var result = String(cString: buffer)
        if pieces.count == 2 {
            let zone = String(pieces[1])
            let index = UInt32(zone) ?? zone.withCString { if_nametoindex($0) }
            result += "%" + (index == 0 ? zone : String(index))
        }
        return result
    }

    static func ipv6Bytes(_ value: String) -> [UInt8]? {
        let host = unbracketed(value).split(separator: "%", maxSplits: 1).first.map(String.init) ?? ""
        var address = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
    }

    /// Preserve legacy IPv4 preference, then routable IPv6, then scoped Bonjour
    /// link-local addresses. A scope ID is only valid on the receiving device.
    static func preference(_ value: String) -> Int {
        ipv6Bytes(value) == nil ? 0 : (isLinkLocal(value) ? 2 : 1)
    }

    static func pairingLocalHost(advertised: String?, connectedHost: String? = nil) -> String? {
        // Only supply connectedHost after authenticating a pairing response.
        if let connectedHost, isPrivateOrLocal(connectedHost),
           !isTailscale(connectedHost), !isLoopback(connectedHost) {
            return normalized(connectedHost)
        }
        guard let advertised, !isUnspecified(advertised) else { return nil }
        let host = normalized(advertised)
        // Numeric/name interface scopes from the remote Mac are not portable.
        guard ipv6Bytes(host) == nil || !isLinkLocal(host) else { return nil }
        return host
    }

    static func isNumeric(_ value: String) -> Bool {
        var address = in_addr()
        return normalized(value).withCString { inet_pton(AF_INET, $0, &address) } == 1 || ipv6Bytes(value) != nil
    }

    static func pairingTailscaleCandidates(codeHost: String?, advertisedHost: String?) -> [String] {
        var hosts: [String] = []
        if let codeHost, isTailscale(codeHost) { hosts.append(normalized(codeHost)) }
        // The compact code embeds only IPv4; QR/link metadata can additionally
        // locate an IPv6-only Tailscale host without changing the code format.
        if let advertisedHost, ipv6Bytes(advertisedHost) != nil, isTailscale(advertisedHost) {
            let host = normalized(advertisedHost)
            if !hosts.contains(host) { hosts.append(host) }
        }
        return hosts
    }

    static func pairingTailscaleHost(advertised: String?, connectedHost: String? = nil) -> String {
        // Only supply connectedHost after authenticating a pairing response.
        if let connectedHost, isTailscale(connectedHost) { return normalized(connectedHost) }
        return advertised.map(normalized) ?? ""
    }

    static func isLoopback(_ value: String) -> Bool {
        let host = normalized(value)
        return ipv4Octets(host)?.first == 127 || host == "::1"
    }

    static func isUnspecified(_ value: String) -> Bool {
        let host = normalized(value)
        return host.isEmpty || host == "0.0.0.0" || host == "::"
    }

    static func isLinkLocal(_ value: String) -> Bool {
        let host = normalized(value)
        if let bytes = ipv4Octets(host), bytes[0] == 169 && bytes[1] == 254 { return true }
        guard let bytes = ipv6Bytes(host) else { return false }
        return bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
    }

    static func isTailscale(_ value: String) -> Bool {
        let host = normalized(value)
        if let parts = ipv4Octets(host) { return parts[0] == 100 && (64...127).contains(parts[1]) }
        guard let bytes = ipv6Bytes(host) else { return false }
        return Array(bytes.prefix(6)) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
    }

    static func isPrivateOrLocal(_ value: String) -> Bool {
        let host = normalized(value)
        if isLoopback(host) || isLinkLocal(host) { return true }
        if let parts = ipv4Octets(host) {
            return parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1]))
                || (parts[0] == 192 && parts[1] == 168)
        }
        guard let bytes = ipv6Bytes(host), bytes[0] != 0xff, !isUnspecified(host) else { return false }
        if bytes[0] & 0xfe == 0xfc { return true }
        // LAN IPv6 addresses are often globally scoped, not private/ULA.
        return subnetCache.snapshot().contains {
            !$0.name.hasPrefix("utun") && sameSubnet(host, $0.address, netmask: $0.netmask)
        }
    }

    // Classification can run for every authenticated video datagram when the
    // sender uses an alternate IPv6 address. Do not enumerate interfaces at
    // packet rate. Route selection still calls interfaces() directly.
    private static let subnetCache = LocalSubnetCache()

    private final class LocalSubnetCache: @unchecked Sendable {
        private let lock = NSLock()
        private var expiresAt = Date.distantPast
        private var entries: [Interface] = []

        func snapshot() -> [Interface] {
            lock.lock()
            defer { lock.unlock() }
            let now = Date()
            if now >= expiresAt {
                entries = IPNetwork.interfaces()
                expiresAt = now.addingTimeInterval(1)
            }
            return entries
        }
    }

    static func sameSubnet(_ lhs: String, _ rhs: String, netmask: String?) -> Bool {
        guard let netmask else { return false }
        if let left = ipv6Bytes(lhs), let right = ipv6Bytes(rhs), let mask = ipv6Bytes(netmask) {
            guard mask.contains(where: { $0 != 0 }) else { return false }
            let leftZone = normalized(lhs).split(separator: "%").dropFirst().first
            let rightZone = normalized(rhs).split(separator: "%").dropFirst().first
            if isLinkLocal(lhs), let leftZone, let rightZone, leftZone != rightZone { return false }
            return zip(zip(left, right), mask).allSatisfy { ($0.0.0 & $0.1) == ($0.0.1 & $0.1) }
        }
        guard let left = ipv4Octets(lhs), let right = ipv4Octets(rhs), let mask = ipv4Octets(netmask),
              mask.contains(where: { $0 != 0 }) else { return false }
        return zip(zip(left, right), mask).allSatisfy { ($0.0.0 & $0.1) == ($0.0.1 & $0.1) }
    }

    static func interfaces() -> [Interface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [Interface] = []
        var item: UnsafeMutablePointer<ifaddrs>? = first
        while let current = item {
            defer { item = current.pointee.ifa_next }
            let interface = current.pointee
            guard interface.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = interface.ifa_addr,
                  let host = hostString(address, length: socklen_t(address.pointee.sa_len)),
                  !isLoopback(host), !isUnspecified(host) else { continue }
            let name = String(cString: interface.ifa_name)
            let mask = interface.ifa_netmask.flatMap { hostString($0, length: socklen_t($0.pointee.sa_len)) }
            result.append(Interface(name: name, address: host, netmask: mask))
        }
        return result
    }

    private static func ipv4Octets(_ value: String) -> [UInt8]? {
        let host = normalized(value)
        var address = in_addr()
        guard host.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return nil }
        return host.split(separator: ".").compactMap { UInt8($0) }
    }

    static func makeUDPSocket() -> Int32 {
        let descriptor = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return descriptor }
        var ipv6Only: Int32 = 0
        guard setsockopt(descriptor, IPPROTO_IPV6, IPV6_V6ONLY, &ipv6Only, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            let code = errno
            close(descriptor)
            errno = code
            return -1
        }
        return descriptor
    }

    static func anyAddress(port: UInt16) -> sockaddr_in6 {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        return address
    }

    /// Uses system resolution for DNS64/NAT64. IPv4 results are mapped only for
    /// the dual-stack socket API, never by inventing a NAT64 network prefix.
    static func destination(host: String, port: UInt16) -> sockaddr_in6? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP
        hints.ai_flags = AI_DEFAULT
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(unbracketed(host), String(port), &hints, &list) == 0 else { return nil }
        defer { freeaddrinfo(list) }
        var item = list
        while let current = item {
            defer { item = current.pointee.ai_next }
            guard let pointer = current.pointee.ai_addr else { continue }
            if current.pointee.ai_family == AF_INET6 {
                return UnsafeRawPointer(pointer).assumingMemoryBound(to: sockaddr_in6.self).pointee
            }
            if current.pointee.ai_family == AF_INET {
                let v4 = UnsafeRawPointer(pointer).assumingMemoryBound(to: sockaddr_in.self).pointee
                guard let host = ipv4String(v4.sin_addr) else { continue }
                var v6 = anyAddress(port: port)
                guard ("::ffff:" + host).withCString({ inet_pton(AF_INET6, $0, &v6.sin6_addr) }) == 1 else { continue }
                return v6
            }
        }
        return nil
    }

    static func hostString(_ pointer: UnsafePointer<sockaddr>, length: socklen_t) -> String? {
        guard length >= MemoryLayout<sockaddr>.size,
              pointer.pointee.sa_family == sa_family_t(AF_INET) || pointer.pointee.sa_family == sa_family_t(AF_INET6),
              length >= (pointer.pointee.sa_family == sa_family_t(AF_INET) ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size) else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(pointer, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return normalized(String(cString: buffer))
    }

    static func hostString(_ address: sockaddr_storage, length: socklen_t) -> String? {
        var address = address
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { hostString($0, length: length) }
        }
    }

    private static func ipv4String(_ address: in_addr) -> String? {
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer)
    }

    private static func mappedIPv4(_ address: in6_addr) -> String? {
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        guard bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff else { return nil }
        return bytes.suffix(4).map(String.init).joined(separator: ".")
    }
}
