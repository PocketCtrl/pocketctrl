// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation

enum LocalDiscoveryService {
    static let domain = "local."
    static let type = "_pocketctrl._udp."
    static let protocolVersion = "1"
}

struct ClientDiscoveredHost {
    let hostID: String
    let hostName: String?
    let localAddress: String
    let videoPort: String?
    let audioPort: String?
    let inputPort: String?
    let tailscaleAddress: String?
    let macAddress: String?
}

final class ClientLocalDiscoveryBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    var onStatusChange: ((String) -> Void)?
    var onHostResolved: ((ClientDiscoveredHost) -> Void)?
    /// `true` when iOS refuses the search because Local Network access is
    /// denied for this app; `false` once a search finds a service again.
    var onLocalNetworkAccessDenied: ((Bool) -> Void)?

    /// kDNSServiceErr_PolicyDenied: the Local Network permission is off.
    static let localNetworkPolicyDeniedErrorCode = -72008

    private let browser = NetServiceBrowser()
    private var targetHostID = ""
    private var acceptsAnyHost = false
    private var servicesByName: [String: NetService] = [:]
    private var searchActive = false
    private var foundCount = 0
    private var resolvedCount = 0
    private var mismatchCount = 0
    private var errorCount = 0
    private var invalidRecordCount = 0

    var diagnosticSummary: String {
        "discoveryActive=\(searchActive) found=\(foundCount) resolved=\(resolvedCount) identityMismatches=\(mismatchCount) invalidRecords=\(invalidRecordCount) errors=\(errorCount)"
    }

    private func beginDiagnostics() {
        searchActive = true
        foundCount = 0
        resolvedCount = 0
        mismatchCount = 0
        errorCount = 0
        invalidRecordCount = 0
        ClientDiagnostics.connection("discovery.searchStarted mode=\(acceptsAnyHost ? "pairing" : "savedMac") expectedHost=\(ClientDiagnostics.identifierTag(targetHostID))")
    }

    func start(targetHostID: String) {
        let normalizedHostID = targetHostID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHostID.isEmpty else {
            stop()
            onStatusChange?("Local discovery waiting for pairing.")
            return
        }

        stop()
        self.targetHostID = normalizedHostID
        acceptsAnyHost = false
        beginDiagnostics()
        browser.delegate = self
        browser.searchForServices(ofType: LocalDiscoveryService.type, inDomain: LocalDiscoveryService.domain)
        onStatusChange?("Searching local Wi-Fi for paired Mac...")
    }

    func startAnyHostSearch() {
        stop()
        targetHostID = ""
        acceptsAnyHost = true
        beginDiagnostics()
        browser.delegate = self
        browser.searchForServices(ofType: LocalDiscoveryService.type, inDomain: LocalDiscoveryService.domain)
        onStatusChange?("Searching local Wi-Fi for PocketCtrl hosts...")
    }

    func stop() {
        if searchActive {
            ClientDiagnostics.connection("discovery.searchStopped \(diagnosticSummary)")
        }
        searchActive = false
        browser.stop()
        browser.delegate = nil
        acceptsAnyHost = false
        servicesByName.values.forEach {
            $0.stop()
            $0.delegate = nil
        }
        servicesByName.removeAll()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        foundCount += 1
        if foundCount <= 10 {
            ClientDiagnostics.connection("discovery.serviceFound count=\(foundCount) resolving=true")
        }
        servicesByName[service.name] = service
        service.delegate = self
        service.resolve(withTimeout: 2)
        onLocalNetworkAccessDenied?(false)
        onStatusChange?("Found a PocketCtrl host on local Wi-Fi. Resolving...")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        errorCount += 1
        ClientDiagnostics.connection("discovery.searchFailed errors=\(errorDict) \(diagnosticSummary)")
        if errorDict[NetService.errorCode]?.intValue == Self.localNetworkPolicyDeniedErrorCode {
            onLocalNetworkAccessDenied?(true)
            onStatusChange?("Local Network access is off for PocketCtrl. Allow it in Settings.")
            return
        }
        onStatusChange?("Local discovery failed: \(errorDict)")
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        resolvedCount += 1
        guard let host = discoveredHost(from: sender) else { return }
        if resolvedCount <= 10 {
            ClientDiagnostics.connection("discovery.resolved expectedHost=\(ClientDiagnostics.identifierTag(targetHostID)) advertisedHost=\(ClientDiagnostics.identifierTag(host.hostID)) identityMatches=\(host.hostID == targetHostID) pairingSearch=\(acceptsAnyHost)")
        }
        if acceptsAnyHost {
            onHostResolved?(host)
            return
        }
        guard host.hostID == targetHostID else {
            mismatchCount += 1
            if mismatchCount <= 10 {
                ClientDiagnostics.connection("discovery.ignored reason=hostIdentityMismatch expectedHost=\(ClientDiagnostics.identifierTag(targetHostID)) advertisedHost=\(ClientDiagnostics.identifierTag(host.hostID))")
            }
            onStatusChange?("Found another PocketCtrl host, not the paired Mac.")
            return
        }
        onHostResolved?(host)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        errorCount += 1
        if errorCount <= 10 {
            ClientDiagnostics.connection("discovery.resolveFailed errors=\(errorDict)")
        }
        onStatusChange?("Could not resolve \(sender.name): \(errorDict)")
    }

    private func discoveredHost(from service: NetService) -> ClientDiscoveredHost? {
        guard let txt = service.txtRecordData().map(NetService.dictionary(fromTXTRecord:)),
              text("v", in: txt) == LocalDiscoveryService.protocolVersion,
              let hostID = text("id", in: txt),
              !hostID.isEmpty else {
            invalidRecordCount += 1
            if invalidRecordCount <= 10 {
                ClientDiagnostics.connection("discovery.invalidRecord reason=missingIdentityOrUnsupportedVersion")
            }
            onStatusChange?("Found a PocketCtrl host without a pairing identity. Rescan the Mac QR.")
            return nil
        }

        // Prefer the socket address returned by Bonjour because it reflects the
        // current LAN route after Wi-Fi changes. TXT local is only a fallback for
        // edge cases where resolution omits usable IP addresses.
        let resolvedAddresses = Self.ipAddresses(from: service)
        let resolvedAddress = resolvedAddresses.first {
            !ClientNetworkAddressPolicy.isTailscaleAddress($0) && !IPNetwork.isLoopback($0)
        } ?? resolvedAddresses.first
        // A remote interface scope is not meaningful on this device.
        let fallbackAddress = IPNetwork.pairingLocalHost(advertised: text("local", in: txt))
        guard let localAddress = resolvedAddress ?? fallbackAddress,
              !localAddress.isEmpty else {
            invalidRecordCount += 1
            if invalidRecordCount <= 10 {
                ClientDiagnostics.connection("discovery.invalidRecord reason=noUsableAddress")
            }
            return nil
        }

        return ClientDiscoveredHost(
            hostID: hostID,
            hostName: text("name", in: txt),
            localAddress: localAddress,
            videoPort: text("video", in: txt),
            audioPort: text("audio", in: txt),
            inputPort: text("input", in: txt),
            tailscaleAddress: text("tailscale", in: txt),
            macAddress: text("mac", in: txt)
        )
    }

    private func text(_ key: String, in txt: [String: Data]) -> String? {
        txt[key].flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func ipAddresses(from service: NetService) -> [String] {
        service.addresses?.compactMap { data in
            data.withUnsafeBytes { rawBuffer -> String? in
                guard let baseAddress = rawBuffer.baseAddress else { return nil }
                let sockaddrPointer = baseAddress.assumingMemoryBound(to: sockaddr.self)
                return IPNetwork.hostString(sockaddrPointer, length: socklen_t(data.count))
            }
        }.sorted { IPNetwork.preference($0) < IPNetwork.preference($1) } ?? []
    }
}
