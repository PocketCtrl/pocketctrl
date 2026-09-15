// SPDX-License-Identifier: MPL-2.0

import CryptoKit
import Foundation
import Network

struct MobileManualPairingResponse: Codable {
    let pairingURL: String
    let hostName: String
    let expiresAt: String
}

struct MobileManualPairingClientError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private struct MobileManualPairingWireRequest: Codable {
    let protocolVersion: Int
    let viewerName: String?
    let clientPublicKey: Data
    let proof: Data
}

private struct MobileManualPairingWireResponse: Codable {
    let status: Int
    let error: String?
    let serverPublicKey: Data?
    let sealedPayload: Data?
}

enum MobileManualPairingTransport {
    private static let protocolVersion = 3

    static func request(
        code: String,
        viewerName: String?,
        host: String,
        port: UInt16 = 47778
    ) async throws -> MobileManualPairingResponse {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation
        let request = MobileManualPairingWireRequest(
            protocolVersion: protocolVersion,
            viewerName: viewerName,
            clientPublicKey: publicKey,
            proof: requestProof(code: code, viewerName: viewerName, clientPublicKey: publicKey)
        )
        let payload = try JSONEncoder().encode(request)
        let responseData = try await MobileManualPairingWireClient(host: host, port: port).send(payload)
        let response = try JSONDecoder().decode(MobileManualPairingWireResponse.self, from: responseData)
        guard response.status == 200 else {
            throw MobileManualPairingClientError(message: response.error ?? "The Mac did not approve the pairing request.")
        }
        guard let serverPublicKeyData = response.serverPublicKey,
              let sealedPayload = response.sealedPayload else {
            throw MobileManualPairingClientError(message: "The Mac returned an incomplete pairing response.")
        }

        let serverPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverPublicKeyData)
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: serverPublicKey)
        let encryptionKey = derivedEncryptionKey(sharedSecret: sharedSecret, code: code)
        let plaintext = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealedPayload), using: encryptionKey)
        return try JSONDecoder().decode(MobileManualPairingResponse.self, from: plaintext)
    }

    private static func requestProof(code: String, viewerName: String?, clientPublicKey: Data) -> Data {
        let authenticationKey = SymmetricKey(data: SHA256.hash(data: Data(PairingInvitationCode.normalized(code).utf8)))
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: requestTranscript(viewerName: viewerName, clientPublicKey: clientPublicKey),
            using: authenticationKey
        )
        return Data(authenticationCode)
    }

    private static func requestTranscript(viewerName: String?, clientPublicKey: Data) -> Data {
        var transcript = Data("PocketCtrl pairing request v3\u{0}".utf8)
        transcript.append(Data((viewerName ?? "").utf8))
        transcript.append(0)
        transcript.append(clientPublicKey)
        return transcript
    }

    private static func derivedEncryptionKey(sharedSecret: SharedSecret, code: String) -> SymmetricKey {
        sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(SHA256.hash(data: Data(PairingInvitationCode.normalized(code).utf8))),
            sharedInfo: Data("PocketCtrl pairing response v3".utf8),
            outputByteCount: 32
        )
    }
}

private final class MobileManualPairingWireClient: @unchecked Sendable {
    private static let maximumPayloadBytes: UInt32 = 64 * 1024
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "pocketctrl.mobile.manual.pairing.client.\(UUID().uuidString)")
    private var completion: ((Result<Data, Error>) -> Void)?
    private var didSend = false

    init(host: String, port: UInt16) {
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
    }

    func send(_ payload: Data) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(payload: payload) { result in
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        queue.async { [weak self] in
            self?.finish(.failure(CancellationError()))
        }
    }

    private func start(payload: Data, completion: @escaping (Result<Data, Error>) -> Void) {
        queue.async {
            self.completion = completion
            self.connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.sendFrame(payload)
                case .failed(let error):
                    self.finish(.failure(error))
                case .cancelled:
                    self.finish(.failure(CancellationError()))
                default:
                    break
                }
            }
            self.connection.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + 70) { [weak self] in
                self?.finish(.failure(MobileManualPairingClientError(message: "The Mac did not respond to the pairing request.")))
            }
        }
    }

    private func sendFrame(_ payload: Data) {
        guard !didSend else { return }
        didSend = true
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
            } else {
                self.receiveFrame(accumulated: Data())
            }
        })
    }

    private func receiveFrame(accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            if let error {
                self.finish(.failure(error))
                return
            }
            guard buffer.count <= Int(Self.maximumPayloadBytes) + 4 else {
                self.finish(.failure(MobileManualPairingClientError(message: "The Mac returned an invalid pairing response.")))
                return
            }
            if buffer.count >= 4 {
                let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard length > 0, length <= Self.maximumPayloadBytes else {
                    self.finish(.failure(MobileManualPairingClientError(message: "The Mac returned an invalid pairing response.")))
                    return
                }
                if buffer.count >= Int(length) + 4 {
                    self.finish(.success(buffer.subdata(in: 4..<(Int(length) + 4))))
                    return
                }
            }
            if isComplete {
                self.finish(.failure(MobileManualPairingClientError(message: "The Mac closed the pairing connection early.")))
                return
            }
            self.receiveFrame(accumulated: buffer)
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard let completion else { return }
        self.completion = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        completion(result)
    }
}
