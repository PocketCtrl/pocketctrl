// SPDX-License-Identifier: MPL-2.0

import Foundation
import CryptoKit
import Network

struct PocketCtrlHostControlSettings: Decodable {
    var destinationAddress: String?
    var videoPort: String?
    var audioPort: String?
    var inputPort: String?
    var captureWidth: Double?
    var fps: Double?
    var bitrateMbps: Double?
    var adaptiveBitrateEnabled: Bool?
    var audioEnabled: Bool?
    var remoteInputEnabled: Bool?
    var keepAwakeWhileHosting: Bool?
    var autoStartHosting: Bool?
    var launchAtLoginEnabled: Bool?
    var localDiscoveryEnabled: Bool?
    var displayID: UInt32?
}

struct PocketCtrlHostControlSnapshot: Encodable {
    let app: String
    let isHosting: Bool
    let status: String
    let fps: Int
    let bitrateMbps: Double
    let ports: Ports
    let settings: Settings
    let setup: Setup

    struct Ports: Encodable {
        let video: String
        let audio: String
        let input: String
    }

    struct Settings: Encodable {
        let displayID: UInt32
        let captureWidth: Double
        let fps: Double
        let bitrateMbps: Double
        let adaptiveBitrateEnabled: Bool
        let audioEnabled: Bool
        let remoteInputEnabled: Bool
        let keepAwakeWhileHosting: Bool
        let autoStartHosting: Bool
        let launchAtLoginEnabled: Bool
        let localDiscoveryEnabled: Bool
    }

    struct Setup: Encodable {
        let localNetwork: Bool
        let directCapture: Bool
        let screenRecording: Bool
        let accessibility: Bool
    }

}

struct PocketCtrlHostPairingSnapshot: Encodable {
    let hostName: String
    let localAddress: String
    let tailscaleAddress: String
    let hostID: String
    let pairingURL: String
    let manualPairingCode: String
    let manualPairingExpiresAt: String
    let manualPairingRequestPort: UInt16
}

struct PocketCtrlHostControlError: Codable {
    let error: String
}

struct ManualPairingResponse: Codable {
    let pairingURL: String
    let hostName: String
    let expiresAt: String
    let credentialID: String
}

struct PendingManualPairingRequest: Identifiable, Equatable {
    let id: UUID
    let viewerName: String
    let sourceAddress: String
    let routeDescription: String
    let deviceFingerprint: String
    let requestedAt: Date
}

fileprivate struct ManualPairingWireRequest: Codable {
    let protocolVersion: Int
    let viewerName: String?
    let clientPublicKey: Data
    let proof: Data
}

fileprivate struct ManualPairingWireResponse: Codable {
    let status: Int
    let error: String?
    let serverPublicKey: Data?
    let sealedPayload: Data?
}

fileprivate enum ManualPairingCrypto {
    static let protocolVersion = 3

    static func requestProof(
        code: String,
        viewerName: String?,
        clientPublicKey: Data
    ) -> Data {
        let authenticationKey = SymmetricKey(data: SHA256.hash(data: Data(PairingInvitationCode.normalized(code).utf8)))
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: requestTranscript(viewerName: viewerName, clientPublicKey: clientPublicKey),
            using: authenticationKey
        )
        return Data(authenticationCode)
    }

    static func requestProofIsValid(_ request: ManualPairingWireRequest, code: String) -> Bool {
        guard request.protocolVersion == protocolVersion,
              (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: request.clientPublicKey)) != nil else {
            return false
        }
        let authenticationKey = SymmetricKey(data: SHA256.hash(data: Data(PairingInvitationCode.normalized(code).utf8)))
        return HMAC<SHA256>.isValidAuthenticationCode(
            request.proof,
            authenticating: requestTranscript(viewerName: request.viewerName, clientPublicKey: request.clientPublicKey),
            using: authenticationKey
        )
    }

    static func seal(
        _ plaintext: Data,
        for clientPublicKeyData: Data,
        code: String
    ) throws -> (serverPublicKey: Data, sealedPayload: Data) {
        let clientPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientPublicKeyData)
        let serverPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let sharedSecret = try serverPrivateKey.sharedSecretFromKeyAgreement(with: clientPublicKey)
        let key = derivedEncryptionKey(sharedSecret: sharedSecret, code: code)
        let sealedBox = try ChaChaPoly.seal(plaintext, using: key)
        return (serverPrivateKey.publicKey.rawRepresentation, sealedBox.combined)
    }

    static func open(
        _ sealedPayload: Data,
        serverPublicKeyData: Data,
        clientPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        code: String
    ) throws -> Data {
        let serverPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverPublicKeyData)
        let sharedSecret = try clientPrivateKey.sharedSecretFromKeyAgreement(with: serverPublicKey)
        let key = derivedEncryptionKey(sharedSecret: sharedSecret, code: code)
        return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealedPayload), using: key)
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

enum ManualPairingTransport {
    static func request(
        code: String,
        viewerName: String?,
        host: String,
        port: UInt16 = ManualPairingRequestServer.port
    ) async throws -> ManualPairingResponse {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation
        let request = ManualPairingWireRequest(
            protocolVersion: ManualPairingCrypto.protocolVersion,
            viewerName: viewerName,
            clientPublicKey: publicKey,
            proof: ManualPairingCrypto.requestProof(
                code: code,
                viewerName: viewerName,
                clientPublicKey: publicKey
            )
        )
        let payload = try JSONEncoder().encode(request)
        let responseData = try await ManualPairingWireClient(host: host, port: port).send(payload)
        let response = try JSONDecoder().decode(ManualPairingWireResponse.self, from: responseData)
        guard response.status == 200 else {
            throw ManualPairingClientError(response.error ?? "The Mac did not approve the pairing request.")
        }
        guard let serverPublicKey = response.serverPublicKey,
              let sealedPayload = response.sealedPayload else {
            throw ManualPairingClientError("The Mac returned an incomplete pairing response.")
        }
        let plaintext = try ManualPairingCrypto.open(
            sealedPayload,
            serverPublicKeyData: serverPublicKey,
            clientPrivateKey: privateKey,
            code: code
        )
        return try JSONDecoder().decode(ManualPairingResponse.self, from: plaintext)
    }
}

private final class ManualPairingWireClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "pocketctrl.manual.pairing.client.\(UUID().uuidString)")
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
                self?.finish(.failure(ManualPairingClientError("The Mac did not respond to the pairing request.")))
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
            guard buffer.count <= ManualPairingRequestServer.maximumWireBytes else {
                self.finish(.failure(ManualPairingClientError("The Mac returned an invalid pairing response.")))
                return
            }
            if buffer.count >= 4 {
                let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard length > 0, length <= ManualPairingRequestServer.maximumWirePayloadBytes else {
                    self.finish(.failure(ManualPairingClientError("The Mac returned an invalid pairing response.")))
                    return
                }
                if buffer.count >= Int(length) + 4 {
                    self.finish(.success(buffer.subdata(in: 4..<(Int(length) + 4))))
                    return
                }
            }
            if isComplete {
                self.finish(.failure(ManualPairingClientError("The Mac closed the pairing connection early.")))
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

final class ManualPairingRequestServer: @unchecked Sendable {
    static let port: UInt16 = 47778
    private static let maximumFrameBytes = 64 * 1024
    fileprivate static let maximumWirePayloadBytes: UInt32 = UInt32(maximumFrameBytes)
    fileprivate static let maximumWireBytes = maximumFrameBytes + 4

    private var listener: NWListener?
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    private var activeConnectionsBySource: [String: Int] = [:]
    private var readTimeouts: [ObjectIdentifier: DispatchWorkItem] = [:]
    private weak var model: RemoteDesktopModel?
    private let queue = DispatchQueue(label: "pocketctrl.manual.pairing.server")
    private var failedAttemptsBySource: [String: [Date]] = [:]
    private var globalFailedAttempts: [Date] = []
    private let attemptWindow: TimeInterval = 60
    private let maximumSourceAttempts = 5
    private let maximumGlobalAttempts = 30
    private let maximumActiveConnections = 16
    private let maximumActiveConnectionsPerSource = 3
    private let frameReadTimeout: TimeInterval = 10

    func start(model: RemoteDesktopModel) {
        self.model = model
        guard listener == nil else { return }

        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    NSLog("PocketCtrl manual pairing server failed: \(error.localizedDescription)")
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            NSLog("PocketCtrl manual pairing server listening on port \(Self.port)")
        } catch {
            NSLog("PocketCtrl manual pairing server failed to start: \(error.localizedDescription)")
        }
    }

    func stop(allowActiveConnectionsToFinish: Bool = false) {
        listener?.cancel()
        listener = nil
        guard !allowActiveConnectionsToFinish else { return }
        queue.sync {
            readTimeouts.values.forEach { $0.cancel() }
            readTimeouts.removeAll()
            activeConnections.values.forEach { $0.cancel() }
            activeConnections.removeAll()
            activeConnectionsBySource.removeAll()
        }
    }

    private nonisolated func handle(_ connection: NWConnection) {
        let sourceAddress = Self.sourceAddress(from: connection.endpoint)
        guard activeConnections.count < maximumActiveConnections,
              activeConnectionsBySource[sourceAddress, default: 0] < maximumActiveConnectionsPerSource else {
            connection.cancel()
            Task { @MainActor [weak self] in
                guard let self, !self.isRateLimited(sourceAddress: sourceAddress) else { return }
                self.recordFailedAttempt(sourceAddress: sourceAddress)
            }
            return
        }
        let connectionID = ObjectIdentifier(connection)
        activeConnections[connectionID] = connection
        activeConnectionsBySource[sourceAddress, default: 0] += 1
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.removeActiveConnection(id: connectionID, sourceAddress: sourceAddress)
            default:
                break
            }
        }
        connection.start(queue: queue)
        let readTimeout = DispatchWorkItem { [weak self, weak connection] in
            guard let self,
                  let connection,
                  self.removeActiveConnection(id: connectionID, sourceAddress: sourceAddress) != nil else {
                return
            }
            connection.cancel()
            Task { @MainActor [weak self] in
                guard let self, !self.isRateLimited(sourceAddress: sourceAddress) else { return }
                self.recordFailedAttempt(sourceAddress: sourceAddress)
            }
        }
        readTimeouts[connectionID] = readTimeout
        queue.asyncAfter(deadline: .now() + frameReadTimeout, execute: readTimeout)
        receiveFrame(on: connection, accumulated: Data())
    }

    @discardableResult
    private nonisolated func removeActiveConnection(
        id: ObjectIdentifier,
        sourceAddress: String
    ) -> NWConnection? {
        guard let connection = activeConnections.removeValue(forKey: id) else { return nil }
        readTimeouts.removeValue(forKey: id)?.cancel()
        let remaining = max(0, activeConnectionsBySource[sourceAddress, default: 1] - 1)
        if remaining == 0 {
            activeConnectionsBySource.removeValue(forKey: sourceAddress)
        } else {
            activeConnectionsBySource[sourceAddress] = remaining
        }
        return connection
    }

    private nonisolated func receiveFrame(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var requestData = accumulated
            if let data {
                requestData.append(data)
            }

            guard requestData.count <= Self.maximumFrameBytes + 4 else {
                self.rejectMalformed(status: 413, message: "Pairing request is too large.", on: connection)
                return
            }

            if let error {
                NSLog("PocketCtrl manual pairing receive failed: \(error.localizedDescription)")
                connection.cancel()
                return
            }

            if requestData.count >= 4 {
                let length = requestData.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard length > 0, length <= Self.maximumFrameBytes else {
                    self.rejectMalformed(status: 400, message: "Malformed pairing request.", on: connection)
                    return
                }
                if requestData.count >= Int(length) + 4 {
                    self.cancelReadTimeout(for: ObjectIdentifier(connection))
                    let payload = requestData.subdata(in: 4..<(Int(length) + 4))
                    Task { @MainActor [weak self] in
                        self?.process(payload, sourceEndpoint: connection.endpoint, on: connection)
                    }
                    return
                }
            }

            if isComplete {
                self.rejectMalformed(status: 400, message: "Incomplete pairing request.", on: connection)
                return
            }

            self.receiveFrame(on: connection, accumulated: requestData)
        }
    }

    private nonisolated func cancelReadTimeout(for connectionID: ObjectIdentifier) {
        readTimeouts.removeValue(forKey: connectionID)?.cancel()
    }

    @MainActor
    private func process(_ payload: Data, sourceEndpoint: NWEndpoint, on connection: NWConnection) {
        let sourceAddress = Self.sourceAddress(from: sourceEndpoint)
        guard !isRateLimited(sourceAddress: sourceAddress) else {
            sendError(status: 429, message: "Too many pairing attempts. Close pairing and try again later.", on: connection)
            return
        }
        guard let model else {
            sendError(status: 503, message: "Host model is not available.", on: connection)
            return
        }
        guard let request = try? JSONDecoder().decode(ManualPairingWireRequest.self, from: payload),
              request.protocolVersion == ManualPairingCrypto.protocolVersion else {
            recordFailedAttempt(sourceAddress: sourceAddress)
            sendError(status: 400, message: "Unsupported pairing protocol.", on: connection)
            return
        }
        let invitationCode = model.manualPairingCode
        guard ManualPairingCrypto.requestProofIsValid(request, code: invitationCode) else {
            recordFailedAttempt(sourceAddress: sourceAddress)
            sendError(status: 401, message: ManualPairingApprovalError.invalidCode.message, on: connection)
            return
        }

        let routeDescription = NetworkAddressPolicy.isTailscaleAddress(sourceAddress) ? "Tailscale" : "Local Wi-Fi"
        let fingerprint = Data(SHA256.hash(data: request.clientPublicKey).prefix(8))
            .map { String(format: "%02X", $0) }
            .joined()

        model.handleManualPairingRequest(
            code: invitationCode,
            viewerName: request.viewerName,
            sourceAddress: sourceAddress,
            routeDescription: routeDescription,
            deviceFingerprint: fingerprint
        ) { result in
            switch result {
            case .success(let response):
                do {
                    let plaintext = try JSONEncoder().encode(response)
                    let sealed = try ManualPairingCrypto.seal(
                        plaintext,
                        for: request.clientPublicKey,
                        code: invitationCode
                    )
                    self.send(
                        ManualPairingWireResponse(
                            status: 200,
                            error: nil,
                            serverPublicKey: sealed.serverPublicKey,
                            sealedPayload: sealed.sealedPayload
                        ),
                        on: connection
                    ) { [weak self] delivered in
                        Task { @MainActor [weak self] in
                            if delivered {
                                self?.model?.finalizeIssuedPairingCredential(id: response.credentialID)
                            } else {
                                self?.model?.discardIssuedPairingCredential(id: response.credentialID)
                            }
                        }
                    }
                } catch {
                    Task { @MainActor [weak self] in
                        self?.model?.discardIssuedPairingCredential(id: response.credentialID)
                    }
                    self.sendError(status: 500, message: "Could not encrypt the pairing response.", on: connection)
                }
            case .failure(let error):
                self.sendError(status: error.statusCode, message: error.message, on: connection)
            }
        }
    }

    @MainActor
    private func isRateLimited(sourceAddress: String) -> Bool {
        let cutoff = Date().addingTimeInterval(-attemptWindow)
        globalFailedAttempts.removeAll { $0 < cutoff }
        failedAttemptsBySource[sourceAddress, default: []].removeAll { $0 < cutoff }
        return globalFailedAttempts.count >= maximumGlobalAttempts
            || failedAttemptsBySource[sourceAddress, default: []].count >= maximumSourceAttempts
    }

    @MainActor
    private func recordFailedAttempt(sourceAddress: String) {
        let now = Date()
        globalFailedAttempts.append(now)
        failedAttemptsBySource[sourceAddress, default: []].append(now)
    }

    private nonisolated func rejectMalformed(status: Int, message: String, on connection: NWConnection) {
        Task { @MainActor [weak self] in
            guard let self else {
                connection.cancel()
                return
            }
            let sourceAddress = Self.sourceAddress(from: connection.endpoint)
            guard !self.isRateLimited(sourceAddress: sourceAddress) else {
                self.sendError(status: 429, message: "Too many pairing attempts. Close pairing and try again later.", on: connection)
                return
            }
            self.recordFailedAttempt(sourceAddress: sourceAddress)
            self.sendError(status: status, message: message, on: connection)
        }
    }

    private func sendError(status: Int, message: String, on connection: NWConnection) {
        send(
            ManualPairingWireResponse(status: status, error: message, serverPublicKey: nil, sealedPayload: nil),
            on: connection
        )
    }

    private func send(
        _ response: ManualPairingWireResponse,
        on connection: NWConnection,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard let payload = try? JSONEncoder().encode(response) else {
            completion?(false)
            connection.cancel()
            return
        }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { error in
            if let error {
                NSLog("PocketCtrl manual pairing send failed: \(error.localizedDescription)")
            }
            completion?(error == nil)
            connection.cancel()
        })
    }

    private static func sourceAddress(from endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else {
            return endpoint.debugDescription
        }
        return host.debugDescription
    }
}

@MainActor
final class PocketCtrlHostControlServer {
    nonisolated static let port: UInt16 = 47777
    nonisolated private static let maximumRequestBytes = 64 * 1024

    private var listener: NWListener?
    private weak var model: RemoteDesktopModel?
    private let queue = DispatchQueue(label: "pocketctrl.host.control.server")
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    func start(model: RemoteDesktopModel) {
        self.model = model
        guard listener == nil else { return }

        do {
            let parameters = NWParameters.tcp
            if let localAddress = IPv4Address("127.0.0.1") {
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(localAddress), port: NWEndpoint.Port(rawValue: Self.port)!)
            }
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    NSLog("PocketCtrl host control server failed: \(error.localizedDescription)")
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            NSLog("PocketCtrl host control server listening on 127.0.0.1:\(Self.port)")
        } catch {
            NSLog("PocketCtrl host control server failed to start: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private nonisolated func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulated: Data())
    }

    private nonisolated func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var requestData = accumulated
            if let data {
                requestData.append(data)
            }

            guard requestData.count <= Self.maximumRequestBytes else {
                Task { @MainActor [weak self] in
                    self?.send(.json(status: 413, body: PocketCtrlHostControlError(error: "Request is too large")), on: connection)
                }
                return
            }

            if let error {
                NSLog("PocketCtrl host control receive failed: \(error.localizedDescription)")
                connection.cancel()
                return
            }

            if let request = HTTPRequest(data: requestData) {
                Task { @MainActor [weak self] in
                    guard let self else {
                        connection.cancel()
                        return
                    }
                    let response = self.response(for: request)
                    self.send(response, on: connection)
                }
                return
            }

            if isComplete {
                Task { @MainActor [weak self] in
                    self?.send(.json(status: 400, body: PocketCtrlHostControlError(error: "Malformed HTTP request")), on: connection)
                }
                return
            }

            self.receiveRequest(on: connection, accumulated: requestData)
        }
    }

    private func response(for request: HTTPRequest) -> HTTPResponse {
        guard let model else {
            return .json(status: 503, body: PocketCtrlHostControlError(error: "Host model is not available"))
        }
        guard request.hostIsLoopback else {
            return .json(status: 403, body: PocketCtrlHostControlError(error: "Host control is loopback-only"))
        }
        guard request.originIsAllowed else {
            return .json(status: 403, body: PocketCtrlHostControlError(error: "Browser-origin requests are not allowed"))
        }
        guard request.isAuthorized(using: model.hostControlToken) else {
            return .json(status: 401, body: PocketCtrlHostControlError(error: "A valid PocketCtrl control token is required"))
        }

        switch (request.method, request.path) {
        case ("GET", "/status"), ("GET", "/settings"):
            return .json(body: model.hostControlSnapshot())

        case ("GET", "/pairing"):
            return .json(body: model.hostPairingSnapshot())

        case ("POST", "/start"):
            model.startHost()
            return .json(body: model.hostControlSnapshot())

        case ("POST", "/stop"):
            model.stopHost()
            return .json(body: model.hostControlSnapshot())

        case ("POST", "/restart"):
            model.restartHostWithCurrentSettings()
            return .json(body: model.hostControlSnapshot())

        case ("POST", "/settings"):
            guard request.hasJSONContentType else {
                return .json(status: 415, body: PocketCtrlHostControlError(error: "Settings requests must use application/json"))
            }
            guard let settings = try? JSONDecoder().decode(PocketCtrlHostControlSettings.self, from: request.body) else {
                return .json(status: 400, body: PocketCtrlHostControlError(error: "Settings body must be JSON"))
            }
            model.applyHostControlSettings(settings)
            return .json(body: model.hostControlSnapshot())

        default:
            return .json(status: 404, body: PocketCtrlHostControlError(error: "Unknown endpoint"))
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.data, completion: .contentProcessed { error in
            if let error {
                NSLog("PocketCtrl host control send failed: \(error.localizedDescription)")
            }
            connection.cancel()
        })
    }
}

private extension RemoteDesktopModel {
    func hostControlSnapshot() -> PocketCtrlHostControlSnapshot {
        refreshNetworkAddresses()

        return PocketCtrlHostControlSnapshot(
            app: "pocketctrl-host",
            isHosting: isHosting,
            status: isHosting ? "hosting" : "stopped",
            fps: hostFPS,
            bitrateMbps: hostBitrateMbps,
            ports: .init(video: hostVideoPort, audio: hostAudioPort, input: hostInputPort),
            settings: .init(
                displayID: selectedDisplayID,
                captureWidth: captureWidth,
                fps: fps,
                bitrateMbps: bitrateMbps,
                adaptiveBitrateEnabled: adaptiveBitrateEnabled,
                audioEnabled: hostAudioEnabled,
                remoteInputEnabled: remoteInputEnabled,
                keepAwakeWhileHosting: keepAwakeWhileHosting,
                autoStartHosting: autoStartHosting,
                launchAtLoginEnabled: launchAtLoginEnabled,
                localDiscoveryEnabled: allowLocalDiscovery
            ),
            setup: .init(
                localNetwork: localNetworkApproved,
                directCapture: directCaptureApproved,
                screenRecording: screenRecordingGranted,
                accessibility: accessibilityGranted
            )
        )
    }

    func hostPairingSnapshot() -> PocketCtrlHostPairingSnapshot {
        refreshNetworkAddresses()

        return PocketCtrlHostPairingSnapshot(
            hostName: Self.currentHostDisplayName,
            localAddress: localAddress,
            tailscaleAddress: tailscaleAddress,
            hostID: hostID,
            pairingURL: lanPairingQRCodePayload,
            manualPairingCode: manualPairingCode,
            manualPairingExpiresAt: ISO8601DateFormatter().string(from: manualPairingExpiresAt),
            manualPairingRequestPort: ManualPairingRequestServer.port
        )
    }

    func applyHostControlSettings(_ settings: PocketCtrlHostControlSettings) {
        if let destinationAddress = settings.destinationAddress {
            hostDestinationAddress = NetworkAddressPolicy.normalized(destinationAddress)
        }
        if let videoPort = settings.videoPort { hostVideoPort = videoPort }
        if let audioPort = settings.audioPort { hostAudioPort = audioPort }
        if let inputPort = settings.inputPort { hostInputPort = inputPort }
        if let captureWidth = settings.captureWidth { self.captureWidth = captureWidth }
        if let fps = settings.fps { self.fps = fps }
        if let bitrateMbps = settings.bitrateMbps { self.bitrateMbps = bitrateMbps }
        if let adaptiveBitrateEnabled = settings.adaptiveBitrateEnabled { self.adaptiveBitrateEnabled = adaptiveBitrateEnabled }
        if let audioEnabled = settings.audioEnabled { hostAudioEnabled = audioEnabled }
        if let remoteInputEnabled = settings.remoteInputEnabled { self.remoteInputEnabled = remoteInputEnabled }
        if let keepAwakeWhileHosting = settings.keepAwakeWhileHosting { self.keepAwakeWhileHosting = keepAwakeWhileHosting }
        if let autoStartHosting = settings.autoStartHosting { self.autoStartHosting = autoStartHosting }
        if let launchAtLoginEnabled = settings.launchAtLoginEnabled { self.launchAtLoginEnabled = launchAtLoginEnabled }
        if let localDiscoveryEnabled = settings.localDiscoveryEnabled { allowLocalDiscovery = localDiscoveryEnabled }
        if let displayID = settings.displayID { selectedDisplayID = displayID }

        applyHostSettingsIfRunning()
    }

    static var currentHostDisplayName: String {
        let localizedName = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let localizedName, !localizedName.isEmpty {
            return localizedName
        }

        let hostName = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        return hostName.isEmpty ? "Mac" : hostName
    }
}

private struct HTTPRequest {
    private static let maximumBodyBytes = 48 * 1024

    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    var hostIsLoopback: Bool {
        guard let host = headers["host"]?.lowercased() else { return false }
        return host == "localhost:\(PocketCtrlHostControlServer.port)"
            || host == "127.0.0.1:\(PocketCtrlHostControlServer.port)"
    }

    var originIsAllowed: Bool {
        headers["origin"] == nil && headers["sec-fetch-site"] == nil
    }

    var hasJSONContentType: Bool {
        headers["content-type"]?
            .lowercased()
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "application/json"
    }

    func isAuthorized(using token: String) -> Bool {
        let expectedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expectedToken.isEmpty,
              let authorization = headers["authorization"] else {
            return false
        }

        let parts = authorization.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              parts[0].caseInsensitiveCompare("Bearer") == .orderedSame else {
            return false
        }

        return Self.constantTimeEqual(parts[1], expectedToken)
    }

    init?(data: Data) {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let bodyStart = headerRange.upperBound
        guard let contentLength = Int(headers["content-length"] ?? "0"),
              contentLength >= 0,
              contentLength <= Self.maximumBodyBytes,
              bodyStart <= data.count,
              contentLength <= data.count - bodyStart else {
            return nil
        }

        method = requestParts[0].uppercased()
        path = URLComponents(string: requestParts[1])?.path ?? requestParts[1]
        self.headers = headers
        body = data[bodyStart..<(bodyStart + contentLength)]
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }

        var difference: UInt8 = 0
        for (leftByte, rightByte) in zip(left, right) {
            difference |= leftByte ^ rightByte
        }
        return difference == 0
    }
}

private struct HTTPResponse {
    let status: Int
    let contentType: String
    let body: Data

    var data: Data {
        var response = Data()
        let statusText = status == 200 ? "OK" : "Error"
        let header = """
        HTTP/1.1 \(status) \(statusText)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        response.append(Data(header.utf8))
        response.append(body)
        return response
    }

    static func json<T: Encodable>(status: Int = 200, body: T) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(body)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }
}
