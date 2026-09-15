// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation

enum ClientWakeOnLANError: LocalizedError {
    case invalidMACAddress
    case invalidBroadcastAddress
    case socketFailed(String)
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidMACAddress:
            return "Enter a valid 12-digit MAC address."
        case .invalidBroadcastAddress:
            return "Enter a valid IPv4 broadcast address."
        case .socketFailed(let message):
            return "Socket failed: \(message)"
        case .sendFailed(let message):
            return "Send failed: \(message)"
        }
    }
}

struct ClientWakeOnLANSendResult {
    let sentTargets: [String]
    let lastError: Error?

    var didSend: Bool {
        !sentTargets.isEmpty
    }
}

enum ClientWakeOnLANSender {
    static func sendBurst(
        macAddress: String,
        broadcastAddresses: [String],
        ports: [UInt16],
        repetitions: Int = 6,
        spacing: TimeInterval = 0.08
    ) async -> ClientWakeOnLANSendResult {
        await Task.detached(priority: .userInitiated) {
            var sentTargets: [String] = []
            var lastError: Error?

            for _ in 0..<max(repetitions, 1) {
                for broadcastAddress in broadcastAddresses {
                    for port in ports {
                        do {
                            try send(macAddress: macAddress, broadcastAddress: broadcastAddress, port: port)
                            sentTargets.append("\(broadcastAddress):\(port)")
                        } catch {
                            lastError = error
                        }
                    }
                }
                let delay = UInt64(max(spacing, 0) * 1_000_000_000)
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
            }

            var seen = Set<String>()
            let uniqueTargets = sentTargets.filter { seen.insert($0).inserted }
            return ClientWakeOnLANSendResult(sentTargets: uniqueTargets, lastError: lastError)
        }.value
    }

    static func send(macAddress: String, broadcastAddress: String, port: UInt16) throws {
        let macBytes = try parseMACAddress(macAddress)
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 {
            packet.append(contentsOf: macBytes)
        }

        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else {
            throw ClientWakeOnLANError.socketFailed(Self.lastPOSIXError())
        }
        defer { close(descriptor) }

        var broadcastEnabled: Int32 = 1
        let optionResult = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_BROADCAST,
            &broadcastEnabled,
            socklen_t(MemoryLayout<Int32>.size)
        )
        guard optionResult == 0 else {
            throw ClientWakeOnLANError.socketFailed(Self.lastPOSIXError())
        }

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian

        let addressResult = broadcastAddress.withCString {
            inet_pton(AF_INET, $0, &destination.sin_addr)
        }
        guard addressResult == 1 else {
            throw ClientWakeOnLANError.invalidBroadcastAddress
        }

        let sentBytes = packet.withUnsafeBytes { packetBytes in
            withUnsafePointer(to: &destination) { destinationPointer in
                destinationPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    sendto(
                        descriptor,
                        packetBytes.baseAddress,
                        packet.count,
                        0,
                        socketAddress,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }

        guard sentBytes == packet.count else {
            throw ClientWakeOnLANError.sendFailed(Self.lastPOSIXError())
        }
    }

    private static func parseMACAddress(_ value: String) throws -> [UInt8] {
        let cleaned = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .uppercased()

        guard cleaned.count == 12,
              cleaned.allSatisfy({ $0.isHexDigit }) else {
            throw ClientWakeOnLANError.invalidMACAddress
        }

        var bytes: [UInt8] = []
        var index = cleaned.startIndex
        for _ in 0..<6 {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            let byteString = String(cleaned[index..<nextIndex])
            guard let byte = UInt8(byteString, radix: 16) else {
                throw ClientWakeOnLANError.invalidMACAddress
            }
            bytes.append(byte)
            index = nextIndex
        }
        return bytes
    }

    private static func lastPOSIXError() -> String {
        String(cString: strerror(errno))
    }
}
