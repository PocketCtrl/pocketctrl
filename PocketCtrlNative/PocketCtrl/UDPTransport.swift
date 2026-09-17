// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation

protocol DatagramSending: AnyObject {
    func send(_ data: Data) throws
    func stop()
}

protocol DatagramReceiving: AnyObject {
    func receive(maxSize: Int) -> Data?
    func receiveWithSource(maxSize: Int) -> ReceivedDatagram?
    func stop()
}

struct ReceivedDatagram {
    let data: Data
    let sourceHost: String?
}

extension DatagramReceiving {
    func receiveWithSource(maxSize: Int) -> ReceivedDatagram? {
        receive(maxSize: maxSize).map { ReceivedDatagram(data: $0, sourceHost: nil) }
    }
}

enum UDPSocketError: LocalizedError, CustomStringConvertible {
    case socketCreationFailed(Int32)
    case invalidAddress(String)
    case bindFailed(Int32)
    case sendFailed(Int32)

    var description: String {
        errorDescription ?? "UDP socket error"
    }

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed(let errnoCode):
            return "Socket creation failed: \(String(cString: strerror(errnoCode)))"
        case .invalidAddress(let address):
            return "Invalid network address or hostname: \(address)"
        case .bindFailed(let errnoCode):
            if errnoCode == EADDRINUSE {
                return "Input/video port is already in use on this Mac. Stop the other session or choose a different port."
            }
            return "Could not bind UDP port: \(String(cString: strerror(errnoCode)))"
        case .sendFailed(let errnoCode):
            return "Send failed: \(String(cString: strerror(errnoCode)))"
        }
    }
}

final class UDPSender: DatagramSending {
    private var socketFD: Int32
    private var destination: sockaddr_in6
    private let destinationLock = NSLock()

    init(host: String, port: UInt16) throws {
        socketFD = IPNetwork.makeUDPSocket()
        guard socketFD >= 0 else {
            throw UDPSocketError.socketCreationFailed(errno)
        }
        UDPSocketTuning.configureLowLatencySender(socketFD, serviceType: NET_SERVICE_TYPE_RD, sendBufferBytes: 16 * 1024, setNonBlocking: true)

        guard let destination = Self.makeDestination(host: host, port: port) else {
            close(socketFD)
            throw UDPSocketError.invalidAddress(host)
        }
        self.destination = destination
    }

    deinit {
        stop()
    }

    func send(_ data: Data) throws {
        guard socketFD >= 0 else { throw UDPSocketError.sendFailed(EBADF) }
        destinationLock.lock()
        var destinationCopy = destination
        destinationLock.unlock()
        let sent = data.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return withUnsafePointer(to: &destinationCopy) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.sendto(socketFD, base, data.count, MSG_DONTWAIT, socketAddress, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }

        guard sent == data.count else {
            throw UDPSocketError.sendFailed(errno)
        }
    }

    func updateDestination(host: String, port: UInt16) throws {
        guard let destination = Self.makeDestination(host: host, port: port) else {
            throw UDPSocketError.invalidAddress(host)
        }

        destinationLock.lock()
        self.destination = destination
        destinationLock.unlock()
    }

    func stop() {
        guard socketFD >= 0 else { return }
        close(socketFD)
        socketFD = -1
    }

    private static func makeDestination(host: String, port: UInt16) -> sockaddr_in6? {
        UDPAddress.makeDestination(host: host, port: port)
    }
}

final class UDPMultiPeerSender: DatagramSending {
    private var socketFD: Int32
    // Sending, rebuilding, and stopping must not race over a reused descriptor.
    private let socketLock = NSLock()
    private var destinations: [String: sockaddr_in6] = [:]
    private var routedDestinations: [String: sockaddr_in6] = [:]
    private let destinationLock = NSLock()

    init() throws {
        socketFD = IPNetwork.makeUDPSocket()
        guard socketFD >= 0 else {
            throw UDPSocketError.socketCreationFailed(errno)
        }
        UDPSocketTuning.configureLowLatencySender(socketFD, serviceType: NET_SERVICE_TYPE_RV, sendBufferBytes: 64 * 1024, setNonBlocking: true)
    }

    convenience init(host: String, port: UInt16) throws {
        try self.init()
        do {
            _ = try addDestination(host: host, port: port)
        } catch {
            close(socketFD)
            socketFD = -1
            throw error
        }
    }

    func send(_ data: Data, toHost host: String, port: UInt16) throws {
        socketLock.lock()
        defer { socketLock.unlock() }
        guard socketFD >= 0 else { throw UDPSocketError.sendFailed(EBADF) }
        let key = "\(host):\(port)"
        destinationLock.lock()
        let cached = routedDestinations[key]
        destinationLock.unlock()
        guard var destination = cached ?? UDPAddress.makeDestination(host: host, port: port) else {
            throw UDPSocketError.invalidAddress(host)
        }
        if cached == nil {
            destinationLock.lock()
            if routedDestinations.count >= 128 { routedDestinations.removeAll() }
            routedDestinations[key] = destination
            destinationLock.unlock()
        }
        let sent = data.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.sendto(socketFD, base, data.count, MSG_DONTWAIT, socketAddress, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
        guard sent == data.count else {
            throw UDPSocketError.sendFailed(errno)
        }
    }

    deinit {
        stop()
    }

    @discardableResult
    func addDestination(host: String, port: UInt16) throws -> Bool {
        guard let destination = UDPAddress.makeDestination(host: host, port: port) else {
            throw UDPSocketError.invalidAddress(host)
        }

        let key = "\(host):\(port)"
        destinationLock.lock()
        let isNew = destinations[key] == nil
        destinations[key] = destination
        let destinationCount = destinations.count
        destinationLock.unlock()

        if isNew {
            NSLog("PocketCtrl UDP fanout added destination; count=\(destinationCount)")
            PocketCtrlHostDiagnostics.write("udp fanout added destination count=\(destinationCount)")
        }
        return isNew
    }

    func replaceDestinations(withHost host: String, port: UInt16) throws {
        guard let destination = UDPAddress.makeDestination(host: host, port: port) else {
            throw UDPSocketError.invalidAddress(host)
        }
        destinationLock.lock()
        destinations = ["\(host):\(port)": destination]
        destinationLock.unlock()
        NSLog("PocketCtrl UDP stream destination replaced")
        PocketCtrlHostDiagnostics.write("udp stream destination replaced")
    }

    func send(_ data: Data) throws {
        socketLock.lock()
        defer { socketLock.unlock() }
        guard socketFD >= 0 else { throw UDPSocketError.sendFailed(EBADF) }
        destinationLock.lock()
        let destinationCopies = destinations
        destinationLock.unlock()

        var firstError: Int32?
        var sentCount = 0
        for (_, var destination) in destinationCopies {
            let sent = data.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return withUnsafePointer(to: &destination) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                        Darwin.sendto(socketFD, base, data.count, MSG_DONTWAIT, socketAddress, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }
            }

            if sent == data.count {
                sentCount += 1
            } else {
                let errnoCode = errno
                firstError = firstError ?? errnoCode
                NSLog("PocketCtrl UDP fanout send failed: \(String(cString: strerror(errnoCode)))")
            }
        }

        guard sentCount > 0 else {
            throw UDPSocketError.sendFailed(firstError ?? EHOSTUNREACH)
        }
    }

    /// Refresh a socket whose local-network policy may predate user approval.
    /// Does not change permissions, destinations, or authenticated sessions.
    func recreateSocket() throws {
        socketLock.lock()
        defer { socketLock.unlock() }
        guard socketFD >= 0 else { throw UDPSocketError.sendFailed(EBADF) }
        let replacement = IPNetwork.makeUDPSocket()
        guard replacement >= 0 else { throw UDPSocketError.socketCreationFailed(errno) }
        UDPSocketTuning.configureLowLatencySender(replacement, serviceType: NET_SERVICE_TYPE_RV, sendBufferBytes: 64 * 1024, setNonBlocking: true)
        let previous = socketFD
        socketFD = replacement
        close(previous)
    }

    func stop() {
        socketLock.lock()
        defer { socketLock.unlock() }
        guard socketFD >= 0 else { return }
        close(socketFD)
        socketFD = -1
    }
}

/// Monotonic, bounded retries while the first Local Network decision settles.
/// Successful sends clear the episode, but keep a cooldown against socket churn.
struct LocalNetworkSendRecovery {
    private(set) var firstFailure: TimeInterval?
    private(set) var attempts = 0
    private var lastAttempt: TimeInterval = -.infinity

    mutating func failed(at now: TimeInterval) -> Bool {
        if firstFailure == nil { firstFailure = now }
        // Leave retries available if the user takes a while to answer the OS
        // prompt. Never recreate per packet or retry indefinitely after denial.
        let delays: [TimeInterval] = [2, 2, 4, 8, 16, 30]
        guard attempts < delays.count, now - lastAttempt >= delays[attempts] else { return false }
        attempts += 1
        lastAttempt = now
        return true
    }

    func shouldWarn(at now: TimeInterval) -> Bool {
        guard let firstFailure else { return false }
        return now - firstFailure >= 15
    }

    mutating func succeeded() {
        firstFailure = nil
        attempts = 0
    }
}

private enum UDPAddress {
    static func makeDestination(host: String, port: UInt16) -> sockaddr_in6? {
        IPNetwork.destination(host: host, port: port)
    }
}

private enum UDPSocketTuning {
    static func configureLowLatencySender(_ socketFD: Int32, serviceType: Int32, sendBufferBytes: Int32, setNonBlocking: Bool) {
        var noSigPipe: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var sendBuffer = sendBufferBytes
        setsockopt(socketFD, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size))

        var serviceType = serviceType
        setsockopt(socketFD, SOL_SOCKET, SO_NET_SERVICE_TYPE, &serviceType, socklen_t(MemoryLayout<Int32>.size))

        var tos: Int32 = IPTOS_LOWDELAY
        setsockopt(socketFD, IPPROTO_IP, IP_TOS, &tos, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(socketFD, IPPROTO_IPV6, IPV6_TCLASS, &tos, socklen_t(MemoryLayout<Int32>.size))

        if setNonBlocking {
            let flags = fcntl(socketFD, F_GETFL, 0)
            if flags >= 0 {
                _ = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)
            }
        }
    }
}

final class UDPReceiver: DatagramReceiving {
    private var socketFD: Int32

    init(port: UInt16) throws {
        socketFD = IPNetwork.makeUDPSocket()
        guard socketFD >= 0 else {
            throw UDPSocketError.socketCreationFailed(errno)
        }

        var reuseAddress: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, socklen_t(MemoryLayout<Int32>.size))

        var address = IPNetwork.anyAddress(port: port)

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(socketFD, socketAddress, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }

        guard bindResult == 0 else {
            let errnoCode = errno
            close(socketFD)
            PocketCtrlHostDiagnostics.write("udp receiver bind failed port=\(port) errno=\(errnoCode) message=\(String(cString: strerror(errnoCode)))")
            throw UDPSocketError.bindFailed(errnoCode)
        }
        PocketCtrlHostDiagnostics.write("udp receiver bound port=\(port)")
    }

    deinit {
        stop()
    }

    func receive(maxSize: Int = 65_535) -> Data? {
        receiveWithSource(maxSize: maxSize)?.data
    }

    func receiveWithSource(maxSize: Int = 65_535) -> ReceivedDatagram? {
        guard socketFD >= 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: maxSize)
        var sourceAddress = sockaddr_storage()
        var sourceLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let count = withUnsafeMutablePointer(to: &sourceAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                recvfrom(socketFD, &buffer, maxSize, 0, socketAddress, &sourceLength)
            }
        }
        guard count > 0 else { return nil }
        return ReceivedDatagram(data: Data(buffer[0..<count]), sourceHost: IPNetwork.hostString(sourceAddress, length: sourceLength))
    }

    func stop() {
        guard socketFD >= 0 else { return }
        Darwin.shutdown(socketFD, SHUT_RDWR)
        close(socketFD)
        socketFD = -1
    }

}
