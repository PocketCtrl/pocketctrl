// SPDX-License-Identifier: MPL-2.0

import Foundation
import Security

struct DecodedPairingInvitationCode: Equatable {
    let canonicalCode: String
    let tailscaleAddress: String?
}

enum PairingInvitationCodeError: LocalizedError, Equatable {
    case invalidLength
    case invalidCharacter
    case invalidChecksum
    case unsupportedVersion
    case invalidAddress

    var errorDescription: String? {
        switch self {
        case .invalidLength:
            return "Enter the 12-character Computer Code shown on the Mac."
        case .invalidCharacter:
            return "That Computer Code contains an invalid character."
        case .invalidChecksum:
            return "That Computer Code has a typing mistake. Check it and try again."
        case .unsupportedVersion:
            return "That Computer Code was created by an incompatible PocketCtrl version."
        case .invalidAddress:
            return "That Computer Code contains an invalid Tailscale address."
        }
    }
}

enum PairingInvitationCode {
    static let encodedCharacterCount = 12

    private static let currentVersion: UInt8 = 2
    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    private static let tailscaleBase: UInt32 = 0x6440_0000
    private static let tailscaleMaximumOffset: UInt32 = (1 << 22) - 1
    private static let randomMask: UInt32 = (1 << 25) - 1

    static func generate(tailscaleAddress: String?) -> String {
        let locator = tailscaleAddress.flatMap(tailscaleLocator)
        var randomValue: UInt32 = 0
        if SecRandomCopyBytes(kSecRandomDefault, MemoryLayout<UInt32>.size, &randomValue) != errSecSuccess {
            var uuid = UUID().uuid
            randomValue = withUnsafeBytes(of: &uuid) { bytes in
                bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            }
        }
        randomValue &= randomMask

        let payload = (UInt64(currentVersion) << 48)
            | (locator == nil ? 0 : UInt64(1) << 47)
            | (UInt64(locator ?? 0) << 25)
            | UInt64(randomValue)
        let value = (payload << 8) | UInt64(checksum(payloadBytes(payload)))
        return grouped(base32Encode(value))
    }

    static func decode(_ rawValue: String) throws -> DecodedPairingInvitationCode {
        let normalized = normalized(rawValue)
        guard normalized.count == encodedCharacterCount else {
            throw PairingInvitationCodeError.invalidLength
        }
        guard normalized.allSatisfy({ alphabet.contains($0) }) else {
            throw PairingInvitationCodeError.invalidCharacter
        }
        guard let value = base32Decode(normalized) else {
            throw PairingInvitationCodeError.invalidCharacter
        }
        let payload = value >> 8
        guard checksum(payloadBytes(payload)) == UInt8(value & 0xff) else {
            throw PairingInvitationCodeError.invalidChecksum
        }
        guard UInt8((payload >> 48) & 0x0f) == currentVersion else {
            throw PairingInvitationCodeError.unsupportedVersion
        }

        let hasTailscaleAddress = ((payload >> 47) & 0x01) == 1
        let locator = UInt32((payload >> 25) & UInt64(tailscaleMaximumOffset))
        let tailscaleAddress: String?
        if hasTailscaleAddress {
            guard locator <= tailscaleMaximumOffset else {
                throw PairingInvitationCodeError.invalidAddress
            }
            tailscaleAddress = ipv4String(tailscaleBase + locator)
        } else {
            guard locator == 0 else {
                throw PairingInvitationCodeError.invalidAddress
            }
            tailscaleAddress = nil
        }

        return DecodedPairingInvitationCode(
            canonicalCode: grouped(normalized),
            tailscaleAddress: tailscaleAddress
        )
    }

    static func normalized(_ rawValue: String) -> String {
        rawValue.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func tailscaleLocator(_ address: String) -> UInt32? {
        guard let value = ipv4Value(address),
              value >= tailscaleBase else {
            return nil
        }
        let offset = value - tailscaleBase
        return offset <= tailscaleMaximumOffset ? offset : nil
    }

    private static func ipv4Value(_ address: String) -> UInt32? {
        let parts = address.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        return octets.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func ipv4String(_ value: UInt32) -> String {
        [24, 16, 8, 0]
            .map { String((value >> UInt32($0)) & 0xff) }
            .joined(separator: ".")
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(UInt8(0)) { partial, byte in
            var crc = partial ^ byte
            for _ in 0..<8 {
                crc = crc & 0x80 == 0 ? crc << 1 : (crc << 1) ^ 0x07
            }
            return crc
        }
    }

    private static func payloadBytes(_ payload: UInt64) -> [UInt8] {
        (0..<7).map { index in
            UInt8((payload >> UInt64((6 - index) * 8)) & 0xff)
        }
    }

    private static func base32Encode(_ value: UInt64) -> String {
        var output = ""
        for shift in stride(from: 55, through: 0, by: -5) {
            output.append(alphabet[Int((value >> UInt64(shift)) & 0x1f)])
        }
        return output
    }

    private static func base32Decode(_ encoded: String) -> UInt64? {
        var value: UInt64 = 0
        for character in encoded {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            value = (value << 5) | UInt64(index)
        }
        return value
    }

    private static func grouped(_ value: String) -> String {
        stride(from: 0, to: value.count, by: 4).map { offset in
            let start = value.index(value.startIndex, offsetBy: offset)
            let end = value.index(start, offsetBy: min(4, value.count - offset))
            return String(value[start..<end])
        }.joined(separator: "-")
    }
}
