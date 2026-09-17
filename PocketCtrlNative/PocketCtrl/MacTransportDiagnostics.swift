// SPDX-License-Identifier: MPL-2.0

#if POCKETCTRL_NETWORK_DIAGNOSTICS
import Darwin
import Foundation
import Network
import OSLog

enum MacDiagnosticTransport: String, CaseIterable, Identifiable {
    case dualStack, ipv4, networkFramework
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dualStack: return "1. Existing dual-stack UDP"
        case .ipv4: return "2. Native IPv4 UDP"
        case .networkFramework: return "3. Network framework UDP"
        }
    }
    static let preference = "diagnosticMediaTransport"
}

/// Test-build-only transport comparison. Receives already encrypted video
/// datagrams for authenticated viewers; never changes pairing or permissions.
final class MacTransportDiagnostics {
    private static let logger = Logger(subsystem: "app.pocketctrl.mac", category: "TransportComparison")
    private let mode: MacDiagnosticTransport
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.pocketctrl.transport-comparison")
    private var ipv4Socket: Int32 = -1
    private var connections: [String: NWConnection] = [:]
    private var pending = 0
    private var stopped = false
    private var successes = 0
    private var failures = 0
    private var lastReport: TimeInterval = -.infinity
    private var lastError: Int32?
    private var lastFeedbackReport: TimeInterval = -.infinity

    init(mode: MacDiagnosticTransport? = nil) {
        self.mode = mode ?? MacDiagnosticTransport(rawValue: UserDefaults.standard.string(forKey: MacDiagnosticTransport.preference) ?? "") ?? .dualStack
        Self.logger.notice("Video comparison started mode=\(self.mode.rawValue, privacy: .public); send completion is not proof of video delivery")
    }

    func send(_ data: Data, host: String, port: UInt16, baseline: UDPMultiPeerSender) throws {
        if mode == .networkFramework {
            try sendWithNetworkFramework(data, host: host, port: port)
            return
        }
        do {
            if mode == .dualStack {
                try baseline.send(data, toHost: host, port: port)
            } else {
                try sendWithIPv4(data, host: host, port: port)
            }
            record(error: nil)
        } catch {
            if case let UDPSocketError.sendFailed(code) = error { record(error: code) }
            else { record(error: EINVAL) }
            throw error
        }
    }

    private func sendWithIPv4(_ data: Data, host: String, port: UInt16) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { throw UDPSocketError.sendFailed(EBADF) }
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian
        guard IPNetwork.normalized(host).withCString({ inet_pton(AF_INET, $0, &destination.sin_addr) }) == 1 else {
            throw UDPSocketError.sendFailed(EAFNOSUPPORT)
        }
        if ipv4Socket < 0 {
            ipv4Socket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard ipv4Socket >= 0 else { throw UDPSocketError.sendFailed(errno) }
            var buffer: Int32 = 64 * 1024
            setsockopt(ipv4Socket, SOL_SOCKET, SO_SNDBUF, &buffer, socklen_t(MemoryLayout<Int32>.size))
            var service: Int32 = NET_SERVICE_TYPE_RV
            setsockopt(ipv4Socket, SOL_SOCKET, SO_NET_SERVICE_TYPE, &service, socklen_t(MemoryLayout<Int32>.size))
        }
        let sent = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(ipv4Socket, bytes.baseAddress, data.count, MSG_DONTWAIT, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == data.count else { throw UDPSocketError.sendFailed(errno) }
    }

    private func sendWithNetworkFramework(_ data: Data, host: String, port: UInt16) throws {
        let key = "\(host):\(port)"
        lock.lock()
        guard !stopped, pending < 32 else {
            lock.unlock()
            throw UDPSocketError.sendFailed(EAGAIN)
        }
        let connection: NWConnection
        if let existing = connections[key] {
            connection = existing
        } else {
            guard connections.count < 16, let endpointPort = NWEndpoint.Port(rawValue: port) else {
                lock.unlock()
                throw UDPSocketError.sendFailed(ENOBUFS)
            }
            connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .udp)
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: Self.logger.notice("Network framework UDP ready (not a delivery acknowledgement)")
                case .waiting(let error), .failed(let error): self?.record(error: Self.code(error))
                default: break
                }
            }
            connections[key] = connection
            connection.start(queue: queue)
        }
        pending += 1
        lock.unlock()
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.lock.lock()
            self.pending -= 1
            self.lock.unlock()
            self.record(error: error.map(Self.code))
        })
    }

    private static func code(_ error: NWError) -> Int32 {
        switch error {
        case .posix(let code): return code.rawValue
        case .dns(let code): return code
        case .tls(let code): return code
        default: return -1
        }
    }

    private func record(error: Int32?) {
        lock.lock()
        if error == nil { successes += 1 } else { failures += 1 }
        let now = ProcessInfo.processInfo.systemUptime
        let report = now - lastReport >= 5 || (lastError != error && now - lastReport >= 1)
        if report { lastReport = now; lastError = error }
        let successCount = successes
        let failureCount = failures
        lock.unlock()
        if report {
            Self.logger.notice("Video comparison mode=\(self.mode.rawValue, privacy: .public) sendCompletions=\(successCount, privacy: .public) failures=\(failureCount, privacy: .public) errorCode=\(error ?? 0, privacy: .public)")
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        if ipv4Socket >= 0 { close(ipv4Socket); ipv4Socket = -1 }
        let active = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        for connection in active { connection.cancel() }
    }

    func recordViewerFeedback(fps: Int, frames: Int, chunks: Int) {
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let report = now - lastFeedbackReport >= 5
        if report { lastFeedbackReport = now }
        lock.unlock()
        if report {
            Self.logger.notice("Authenticated viewer feedback mode=\(self.mode.rawValue, privacy: .public) fps=\(fps, privacy: .public) completedFrames=\(frames, privacy: .public) receivedChunks=\(chunks, privacy: .public)")
        }
    }
    deinit { stop() }
}
#endif
