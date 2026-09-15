// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation

enum LocalDiscoveryService {
    static let domain = "local."
    static let type = "_pocketctrl._udp."
    static let protocolVersion = "1"
}

struct LocalDiscoveryAdvertisement: Equatable {
    let hostID: String
    let hostName: String
    let videoPort: String
    let audioPort: String
    let inputPort: String
    let localAddress: String
    let tailscaleAddress: String
    let macAddress: String
}

final class LocalDiscoveryAdvertiser: NSObject, NetServiceDelegate {
    var onStatusChange: ((String) -> Void)?

    private var service: NetService?
    private var lastAdvertisement: LocalDiscoveryAdvertisement?

    func publish(_ advertisement: LocalDiscoveryAdvertisement) {
        guard advertisement != lastAdvertisement else { return }
        stop()

        guard let videoPort = Int32(advertisement.videoPort), videoPort > 0 else {
            onStatusChange?("Local discovery paused: video port is invalid.")
            return
        }

        lastAdvertisement = advertisement
        PocketCtrlHostDiagnostics.connection("discovery.publishRequested host=\(PocketCtrlHostDiagnostics.identifierTag(advertisement.hostID)) hasLocalAddress=\(!advertisement.localAddress.isEmpty && advertisement.localAddress != "Not detected") videoPort=\(videoPort)")
        let serviceName = "PocketCtrl \(advertisement.hostID.prefix(8))"
        let service = NetService(
            domain: LocalDiscoveryService.domain,
            type: LocalDiscoveryService.type,
            name: serviceName,
            port: videoPort
        )
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: txtRecord(for: advertisement)))
        self.service = service
        service.publish()
        onStatusChange?("Local discovery starting...")
    }

    func stop() {
        service?.stop()
        service?.delegate = nil
        service = nil
        lastAdvertisement = nil
    }

    func netServiceDidPublish(_ sender: NetService) {
        onStatusChange?("Local discovery on")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        onStatusChange?("Local discovery failed: \(errorDict)")
    }

    private func txtRecord(for advertisement: LocalDiscoveryAdvertisement) -> [String: Data] {
        // Discovery advertises routing metadata only. Device credentials are never
        // included, so scanning the LAN cannot grant access.
        [
            "v": LocalDiscoveryService.protocolVersion,
            "id": advertisement.hostID,
            "name": advertisement.hostName,
            "video": advertisement.videoPort,
            "audio": advertisement.audioPort,
            "input": advertisement.inputPort,
            "local": IPNetwork.pairingLocalHost(advertised: advertisement.localAddress) ?? "",
            "tailscale": advertisement.tailscaleAddress,
            "mac": advertisement.macAddress
        ].compactMapValues { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed == "Not detected" ? nil : Data(trimmed.utf8)
        }
    }
}

struct DiscoveredPocketCtrlHost {
    let hostID: String
    let hostName: String?
    let localAddress: String
    let videoPort: String?
    let audioPort: String?
    let inputPort: String?
    let tailscaleAddress: String?
    let macAddress: String?
}

final class LocalDiscoveryBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    var onStatusChange: ((String) -> Void)?
    var onHostResolved: ((DiscoveredPocketCtrlHost) -> Void)?

    private let browser = NetServiceBrowser()
    private var targetHostID: String?
    private var servicesByName: [String: NetService] = [:]

    func start() {
        start(targetHostID: nil)
    }

    func start(targetHostID: String?) {
        stop()
        self.targetHostID = targetHostID?.trimmingCharacters(in: .whitespacesAndNewlines)
        browser.delegate = self
        browser.searchForServices(ofType: LocalDiscoveryService.type, inDomain: LocalDiscoveryService.domain)
        onStatusChange?("Searching local Wi-Fi for PocketCtrl hosts...")
    }

    func stop() {
        browser.stop()
        browser.delegate = nil
        servicesByName.values.forEach {
            $0.stop()
            $0.delegate = nil
        }
        servicesByName.removeAll()
        targetHostID = nil
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        servicesByName[service.name] = service
        service.delegate = self
        service.resolve(withTimeout: 2)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        onStatusChange?("Local discovery failed: \(errorDict)")
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = discoveredHost(from: sender) else { return }
        onHostResolved?(host)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        onStatusChange?("Could not resolve \(sender.name): \(errorDict)")
    }

    private func discoveredHost(from service: NetService) -> DiscoveredPocketCtrlHost? {
        guard let txt = service.txtRecordData().map(NetService.dictionary(fromTXTRecord:)),
              text("v", in: txt) == LocalDiscoveryService.protocolVersion,
              let hostID = text("id", in: txt),
              !hostID.isEmpty else {
            return nil
        }

        if let targetHostID, !targetHostID.isEmpty, hostID != targetHostID {
            return nil
        }

        let resolvedAddresses = Self.ipAddresses(from: service)
        let resolvedAddress = resolvedAddresses.first {
            !NetworkAddressPolicy.isTailscaleAddress($0) && !IPNetwork.isLoopback($0)
        } ?? resolvedAddresses.first
        // A remote interface scope is not meaningful on this device.
        let fallbackAddress = IPNetwork.pairingLocalHost(advertised: text("local", in: txt))
        guard let localAddress = resolvedAddress ?? fallbackAddress,
              !localAddress.isEmpty else {
            return nil
        }

        return DiscoveredPocketCtrlHost(
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
