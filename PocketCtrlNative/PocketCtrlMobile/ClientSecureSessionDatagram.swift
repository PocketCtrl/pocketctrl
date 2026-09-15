// SPDX-License-Identifier: MPL-2.0

import CryptoKit
import Foundation

enum ClientSecureSessionChannel: UInt8 {
    case video = 1
    case audio = 2
}

enum ClientSecureSessionDatagram {
    private static let magic = Data([0x50, 0x43, 0x53, 0x45])
    private static let version: UInt8 = 1

    static func open(
        _ datagram: Data,
        channel: ClientSecureSessionChannel,
        credentialID: String,
        secret: String
    ) -> Data? {
        guard datagram.count > 7 + 28,
              datagram.prefix(4) == magic,
              datagram[4] == version,
              datagram[5] == channel.rawValue else {
            return nil
        }
        let identifierLength = Int(datagram[6])
        let headerLength = 7 + identifierLength
        guard identifierLength > 0,
              datagram.count > headerLength + 28,
              let encodedIdentifier = String(data: datagram.subdata(in: 7..<headerLength), encoding: .utf8),
              encodedIdentifier == credentialID else {
            return nil
        }
        do {
            let box = try ChaChaPoly.SealedBox(combined: datagram.dropFirst(headerLength))
            return try ChaChaPoly.open(
                box,
                using: key(secret: secret, credentialID: credentialID, channel: channel),
                authenticating: datagram.prefix(headerLength)
            )
        } catch {
            return nil
        }
    }

    private static func key(secret: String, credentialID: String, channel: ClientSecureSessionChannel) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(secret.utf8)),
            salt: Data(credentialID.utf8),
            info: Data("PocketCtrl session channel \(channel.rawValue) v1".utf8),
            outputByteCount: 32
        )
    }
}
