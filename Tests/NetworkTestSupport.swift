import Darwin
import Foundation
import CryptoKit
enum PocketCtrlHostDiagnostics {
    static func write(_ message: String) {}
    static func connection(_ message: String) {}
    static func identifierTag(_ value: String?) -> String { ClientDiagnostics.identifierTag(value) }
}
enum ClientDiagnostics {
    static var connectionEvents: [String] = []
    static func write(_ message: String) {}
    static func connection(_ message: String) { connectionEvents.append(message) }
    static func identifierTag(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "none" }
        return SHA256.hash(data: Data(value.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
struct ClientReceivedDatagram { let data: Data; let senderAddress: String? }

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
    print("PASS: \(message)")
}
func unusedUDPPort() -> UInt16 {
    let fd = IPNetwork.makeUDPSocket()
    precondition(fd >= 0)
    defer { close(fd) }
    var address = IPNetwork.anyAddress(port: 0)
    var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
    let result = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            guard Darwin.bind(fd, $0, length) == 0 else { return Int32(-1) }
            return getsockname(fd, $0, &length)
        }
    }
    precondition(result == 0, "UDP test bind failed: \(String(cString: strerror(errno)))")
    return UInt16(bigEndian: address.sin6_port)
}
