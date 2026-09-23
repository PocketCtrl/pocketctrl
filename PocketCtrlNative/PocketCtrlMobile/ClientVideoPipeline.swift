// SPDX-License-Identifier: MPL-2.0

import AVFoundation
import CoreMedia
import Darwin
import Foundation
import OSLog
import VideoToolbox

enum ClientStreamColorProfile {
    static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    static let colorPrimaries = kCVImageBufferColorPrimaries_P3_D65
    static let transferFunction = kCVImageBufferTransferFunction_sRGB
    static let yCbCrMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2

    static var pixelBufferAttributes: [CFString: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVImageBufferColorPrimariesKey: colorPrimaries,
            kCVImageBufferTransferFunctionKey: transferFunction,
            kCVImageBufferYCbCrMatrixKey: yCbCrMatrix
        ]
    }
}

struct ClientVideoStats {
    let fps: Int
    let chunks: Int
    let frames: Int
    let skippedFrames: Int
    let receivedBytes: Int
    let receivedMbps: Double
    let size: CGSize
    let keyframeRequested: Bool
}

struct ClientReceivedDatagram {
    let data: Data
    let senderAddress: String?
}

enum ClientStreamVideoCodec: String {
    case h264 = "H.264"
    case hevc = "HEVC"
}

final class ClientUDPReceiver {
    private var socketFD: Int32
    private let port: UInt16

    init(port: UInt16) throws {
        self.port = port
        socketFD = IPNetwork.makeUDPSocket()
        guard socketFD >= 0 else {
            ClientDiagnostics.write("udp receiver socket creation failed port=\(port) errno=\(errno)")
            throw NSError(domain: "PocketCtrlMobile.UDP", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Could not create UDP socket"])
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
            let message = errnoCode == EADDRINUSE
                ? "Video port \(port) is already in use on this iPhone. Disconnect the other session or choose another video port."
                : "Could not bind UDP port \(port): \(String(cString: strerror(errnoCode)))"
            ClientDiagnostics.write("udp receiver bind failed port=\(port) errno=\(errnoCode) message=\(message)")
            throw NSError(domain: "PocketCtrlMobile.UDP", code: Int(errnoCode), userInfo: [NSLocalizedDescriptionKey: message])
        }
        ClientDiagnostics.write("udp receiver bound port=\(port)")
    }

    deinit {
        stop()
    }

    func receive(maxSize: Int = 65_535) -> ClientReceivedDatagram? {
        guard socketFD >= 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: maxSize)
        var source = sockaddr_storage()
        var sourceLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let count = withUnsafeMutablePointer(to: &source) { sourcePointer in
            sourcePointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                recvfrom(socketFD, &buffer, maxSize, 0, socketAddress, &sourceLength)
            }
        }
        guard count > 0 else {
            let errnoCode = errno
            if socketFD >= 0 && errnoCode != EINTR {
                ClientDiagnostics.write("udp receiver recv returned count=\(count) port=\(port) errno=\(errnoCode) message=\(String(cString: strerror(errnoCode)))")
            }
            return nil
        }
        return ClientReceivedDatagram(data: Data(buffer[0..<count]), senderAddress: IPNetwork.hostString(source, length: sourceLength))
    }

    func stop() {
        guard socketFD >= 0 else { return }
        ClientDiagnostics.write("udp receiver stopping port=\(port)")
        Darwin.shutdown(socketFD, SHUT_RDWR)
        close(socketFD)
        socketFD = -1
    }

}

final class ClientH264Decoder {
    var onFrameDecoded: ((CVPixelBuffer) -> Void)?
    var onVideoSizeChanged: ((CGSize) -> Void)?

    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var callbackRefcon: UnsafeMutableRawPointer?
    private var activeCodec: ClientStreamVideoCodec?
    private var sps: Data?
    private var pps: Data?
    private var vps: Data?
    private var hevcSPS: Data?
    private var hevcPPS: Data?

    func invalidate() {
        if let decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
            VTDecompressionSessionInvalidate(decompressionSession)
            self.decompressionSession = nil
        }

        if let callbackRefcon {
            Unmanaged<ClientH264Decoder>.fromOpaque(callbackRefcon).release()
            self.callbackRefcon = nil
        }
    }

    func decode(frame: VideoFramePacket) {
        let units = H264AnnexB.splitNALUnits(frame.payload)
        guard !units.isEmpty else { return }

        let codec = detectCodec(from: units)
        var sampleUnits: [Data] = []
        var shouldConfigure = activeCodec != codec

        for unit in units {
            switch codec {
            case .h264:
                guard let type = H264AnnexB.nalType(unit) else { continue }
                switch type {
                case 7:
                    sps = unit
                    shouldConfigure = true
                case 8:
                    pps = unit
                    shouldConfigure = true
                case 5:
                    shouldConfigure = true
                    sampleUnits.append(unit)
                default:
                    if type != 6 {
                        sampleUnits.append(unit)
                    }
                }
            case .hevc:
                guard let type = H264AnnexB.hevcNalType(unit) else { continue }
                switch type {
                case 32:
                    vps = unit
                    shouldConfigure = true
                case 33:
                    hevcSPS = unit
                    shouldConfigure = true
                case 34:
                    hevcPPS = unit
                    shouldConfigure = true
                case 39, 40:
                    continue
                default:
                    if (16...21).contains(type) {
                        shouldConfigure = true
                    }
                    sampleUnits.append(unit)
                }
            }
        }

        if shouldConfigure || decompressionSession == nil {
            configureSessionIfPossible(codec: codec)
        }

        guard let decompressionSession, let formatDescription, !sampleUnits.isEmpty else {
            return
        }

        let avccData = H264AnnexB.avccSampleData(fromNALUnits: sampleUnits)
        guard let sampleBuffer = makeSampleBuffer(avccData: avccData, formatDescription: formatDescription, presentationTimestampUS: frame.presentationTimestampUS) else {
            return
        }

        VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    private func detectCodec(from units: [Data]) -> ClientStreamVideoCodec {
        if units.contains(where: { unit in
            guard let type = H264AnnexB.hevcNalType(unit) else { return false }
            return type == 32 || type == 33 || type == 34
        }) {
            return .hevc
        }

        if units.contains(where: { unit in
            guard let type = H264AnnexB.nalType(unit) else { return false }
            return type == 7 || type == 8
        }) {
            return .h264
        }

        return activeCodec ?? .h264
    }

    private func configureSessionIfPossible(codec: ClientStreamVideoCodec) {
        let status: OSStatus
        switch codec {
        case .h264:
            status = configureH264FormatDescription()
        case .hevc:
            status = configureHEVCFormatDescription()
        }

        guard status == noErr, let formatDescription else {
            ClientDiagnostics.write("video decoder format description failed codec=\(codec.rawValue) status=\(status)")
            return
        }

        activeCodec = codec
        recreateDecompressionSession(formatDescription: formatDescription, codec: codec)
    }

    private func configureH264FormatDescription() -> OSStatus {
        guard let sps, let pps else { return OSStatus(-50) }

        return sps.withUnsafeBytes { spsBuffer in
            pps.withUnsafeBytes { ppsBuffer in
                guard let spsBase = spsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsBase = ppsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return OSStatus(-50)
                }

                let parameterSetPointers = [spsBase, ppsBase]
                let parameterSetSizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: parameterSetPointers,
                    parameterSetSizes: parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDescription
                )
            }
        }
    }

    private func configureHEVCFormatDescription() -> OSStatus {
        guard let vps, let hevcSPS, let hevcPPS else { return OSStatus(-50) }

        return vps.withUnsafeBytes { vpsBuffer in
            hevcSPS.withUnsafeBytes { spsBuffer in
                hevcPPS.withUnsafeBytes { ppsBuffer in
                    guard let vpsBase = vpsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let spsBase = spsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let ppsBase = ppsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return OSStatus(-50)
                    }

                    let parameterSetPointers = [vpsBase, spsBase, ppsBase]
                    let parameterSetSizes = [vps.count, hevcSPS.count, hevcPPS.count]

                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: parameterSetPointers,
                        parameterSetSizes: parameterSetSizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &formatDescription
                    )
                }
            }
        }
    }

    private func recreateDecompressionSession(formatDescription: CMVideoFormatDescription, codec: ClientStreamVideoCodec) {
        invalidate()

        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        onVideoSizeChanged?(CGSize(width: Int(dimensions.width), height: Int(dimensions.height)))
        let callbackRefcon = Unmanaged.passRetained(self).toOpaque()
        self.callbackRefcon = callbackRefcon

        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { decompressionOutputRefCon, _, status, _, imageBuffer, _, _ in
                guard status == noErr,
                      let decompressionOutputRefCon,
                      let imageBuffer else {
                    return
                }

                let decoder = Unmanaged<ClientH264Decoder>
                    .fromOpaque(decompressionOutputRefCon)
                    .takeUnretainedValue()
                decoder.onFrameDecoded?(imageBuffer)
            },
            decompressionOutputRefCon: callbackRefcon
        )

        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: ClientStreamColorProfile.pixelBufferAttributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &decompressionSession
        )

        if createStatus != noErr {
            ClientDiagnostics.write("video decoder session failed codec=\(codec.rawValue) status=\(createStatus)")
            Unmanaged<ClientH264Decoder>.fromOpaque(callbackRefcon).release()
            self.callbackRefcon = nil
        }
    }

    private func makeSampleBuffer(avccData: Data, formatDescription: CMVideoFormatDescription, presentationTimestampUS: UInt64) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avccData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avccData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == noErr, let blockBuffer else { return nil }

        let replaceStatus = avccData.withUnsafeBytes { buffer in
            CMBlockBufferReplaceDataBytes(with: buffer.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: avccData.count)
        }
        guard replaceStatus == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(presentationTimestampUS), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = avccData.count
        var sampleBuffer: CMSampleBuffer?

        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr else { return nil }
        return sampleBuffer
    }
}

final class ClientVideoReceiver {
    var onComputerUse: ((ComputerUseFragment) -> Void)?
    private static let logger = Logger(subsystem: "PocketCtrlMobile", category: "VideoReceiver")

    var renderer: ((CVPixelBuffer) -> Void)?
    var onStats: ((ClientVideoStats) -> Void)?
    var onFrameDecoded: (() -> Void)?
    var onVideoSizeChanged: ((CGSize) -> Void)?
    var onFocusedWindowRegion: ((ClientFocusedWindowRegion?) -> Void)?
    var onPeerAddress: ((String) -> Void)?
    var onRecoveryNeeded: ((Int, CGSize) -> Void)?
    private var lastFocusedWindowRegion: ClientFocusedWindowRegion?

    private let receiver: ClientUDPReceiver
    private let expectedSourceHost: String
    private let credentialID: String
    private let credentialSecret: String
    private let reassembler = VideoFrameReassembler()
    private let decoder = ClientH264Decoder()
    private let receiveQueue = DispatchQueue(label: "pocketctrl.mobile.video.receiver", qos: .userInteractive)
    private var isRunning = true
    private var frameCounter = 0
    private var completedFrameCounter = 0
    private var receivedChunkCounter = 0
    private var receivedByteCounter = 0
    private var skippedFrameCounter = 0
    private var lastCompletedFrameID: UInt32?
    private var lastStatsDate = Date()
    private var videoSize = CGSize(width: 16, height: 9)
    private var keyframeRequestPending = true
    private var lastRecoveryRequestDate = Date.distantPast
    private var hasLoggedFirstDatagram = false
    private var hasLoggedFirstFrame = false
    private var hasLoggedFirstDecode = false
    private var hasLoggedUnexpectedSource = false
    private var hasLoggedAlternateSource = false
    private var rawDatagramCounter = 0
    private var authenticationRejectionCounter = 0
    private var filteredDatagramCounter = 0
    private var parseFailureCounter = 0
    private var lateFrameDropCounter = 0
    private var undecodedCompleteFrameCounter = 0

    init(port: UInt16, expectedSourceHost: String, credentialID: String, credentialSecret: String) throws {
        self.expectedSourceHost = ClientNetworkAddressPolicy.normalized(expectedSourceHost)
        self.credentialID = credentialID
        self.credentialSecret = credentialSecret
        ClientDiagnostics.write("video receiver init port=\(port) hasExpectedSource=\(!self.expectedSourceHost.isEmpty)")
        receiver = try ClientUDPReceiver(port: port)
        decoder.onVideoSizeChanged = { [weak self] size in
            guard let self, self.videoSize != size else { return }
            self.videoSize = size
            ClientDiagnostics.write("video receiver decoder size changed width=\(Int(size.width)) height=\(Int(size.height))")
            self.onVideoSizeChanged?(size)
        }
        decoder.onFrameDecoded = { [weak self] pixelBuffer in
            self?.handleDecodedFrame(pixelBuffer)
        }
    }

    deinit {
        stop()
    }

    func start() {
        receiveQueue.async { [weak self] in
            guard let self else { return }
            Self.logger.info("Video receiver loop started.")
            ClientDiagnostics.write("video receiver loop started hasExpectedSource=\(!self.expectedSourceHost.isEmpty)")
            while self.isRunning, let datagram = self.receiver.receive() {
                self.rawDatagramCounter += 1
                if self.rawDatagramCounter == 1 {
                    ClientDiagnostics.connection("video.firstRawPacket credential=\(ClientDiagnostics.identifierTag(self.credentialID))")
                }
                if self.rawDatagramCounter <= 10 || self.rawDatagramCounter % 100 == 0 {
                    ClientDiagnostics.write("video receiver raw datagram count=\(self.rawDatagramCounter) bytes=\(datagram.data.count) hasSender=\(datagram.senderAddress != nil)")
                }
                // AI events share the port, but have their own authenticated channel key.
                if datagram.data.count > 5, datagram.data[5] == ClientSecureSessionChannel.computerUse.rawValue {
                    if let plaintext = ClientSecureSessionDatagram.open(datagram.data, channel: .computerUse,
                        credentialID: self.credentialID, secret: self.credentialSecret),
                       self.shouldAcceptAuthenticatedVideoDatagram(from: datagram.senderAddress),
                       let fragment = try? JSONDecoder().decode(ComputerUseFragment.self, from: plaintext) {
                        self.onComputerUse?(fragment)
                    }
                    continue
                }
                guard let plaintext = ClientSecureSessionDatagram.open(
                    datagram.data,
                    channel: .video,
                    credentialID: self.credentialID,
                    secret: self.credentialSecret
                ) else {
                    self.authenticationRejectionCounter += 1
                    if self.authenticationRejectionCounter <= 3 {
                        ClientDiagnostics.connection("video.authenticationRejected count=\(self.authenticationRejectionCounter) credential=\(ClientDiagnostics.identifierTag(self.credentialID)) reason=invalidEncryptedDatagram")
                    }
                    continue
                }
                guard self.shouldAcceptAuthenticatedVideoDatagram(from: datagram.senderAddress) else { continue }
                if !self.hasLoggedFirstDatagram {
                    self.hasLoggedFirstDatagram = true
                    Self.logger.info("First UDP video datagram received. bytes=\(datagram.data.count, privacy: .public) sender=\(datagram.senderAddress ?? "unknown", privacy: .private)")
                    ClientDiagnostics.write("video receiver first accepted datagram bytes=\(datagram.data.count)")
                }
                guard let chunk = UDPVideoFraming.parseDatagram(plaintext) else {
                    self.parseFailureCounter += 1
                    if self.parseFailureCounter <= 10 || self.parseFailureCounter % 50 == 0 {
                        ClientDiagnostics.write("video receiver parse failure count=\(self.parseFailureCounter) bytes=\(datagram.data.count)")
                    }
                    continue
                }
                if let senderAddress = datagram.senderAddress {
                    self.onPeerAddress?(senderAddress)
                }
                self.receivedChunkCounter += 1
                self.receivedByteCounter += datagram.data.count
                guard let frame = self.reassembler.push(chunk) else { continue }
                self.publishFocusedWindowRegionIfNeeded(frame.focusedWindowRegion)
                // Do not decode completed frames that arrive after a newer
                // frame has already moved the decoder forward. They add latency
                // and can briefly show stale desktop state.
                guard !self.shouldDropLateFrame(frame.frameID) else {
                    self.lateFrameDropCounter += 1
                    if self.lateFrameDropCounter <= 5 || self.lateFrameDropCounter % 50 == 0 {
                        ClientDiagnostics.write("video receiver dropped late frame count=\(self.lateFrameDropCounter) frameID=\(frame.frameID)")
                    }
                    continue
                }
                let skippedFrames = self.recordCompletedFrameID(frame.frameID)
                if !self.hasLoggedFirstFrame {
                    self.hasLoggedFirstFrame = true
                    Self.logger.info("First complete video frame assembled. frameID=\(frame.frameID, privacy: .public) payloadBytes=\(frame.payload.count, privacy: .public)")
                    ClientDiagnostics.write("video receiver first complete frame frameID=\(frame.frameID) payloadBytes=\(frame.payload.count) skippedFrames=\(skippedFrames)")
                }
                if skippedFrames > 0 {
                    // Missing frame IDs usually mean UDP loss. H.264 P-frames
                    // may depend on the lost frame, so ask the host to cut a
                    // new independent frame instead of waiting for corruption
                    // to age out naturally.
                    self.keyframeRequestPending = true
                    self.requestRecoveryIfNeeded(skippedFrames: skippedFrames)
                }
                self.requestRecoveryIfWaitingForDecoder(frame: frame)
                self.decoder.decode(frame: frame)
            }
            Self.logger.info("Video receiver loop stopped.")
            ClientDiagnostics.write("video receiver loop stopped rawDatagrams=\(self.rawDatagramCounter) acceptedChunks=\(self.receivedChunkCounter) completedFrames=\(self.completedFrameCounter) filtered=\(self.filteredDatagramCounter) parseFailures=\(self.parseFailureCounter)")
        }
    }

    private func shouldAcceptAuthenticatedVideoDatagram(from senderAddress: String?) -> Bool {
        let accepted = ClientNetworkAddressPolicy.shouldAcceptAuthenticatedStreamPeer(
            configuredHost: expectedSourceHost,
            sourceHost: senderAddress
        )
        if !accepted {
            filteredDatagramCounter += 1
            if !hasLoggedUnexpectedSource || filteredDatagramCounter <= 10 || filteredDatagramCounter % 100 == 0 {
                hasLoggedUnexpectedSource = true
                Self.logger.warning("Ignored video from unexpected sender. expected=\(self.expectedSourceHost, privacy: .private) sender=\(senderAddress ?? "unknown", privacy: .private)")
                ClientDiagnostics.write("video receiver ignored unexpected sender count=\(filteredDatagramCounter)")
            }
        } else if let senderAddress,
                  ClientNetworkAddressPolicy.normalized(senderAddress) != expectedSourceHost,
                  !hasLoggedAlternateSource {
            hasLoggedAlternateSource = true
            Self.logger.info("Accepted authenticated video from alternate Mac address. expected=\(self.expectedSourceHost, privacy: .private) sender=\(senderAddress, privacy: .private)")
            ClientDiagnostics.write("video receiver accepted authenticated alternate sender")
        }
        return accepted
    }

    private func publishFocusedWindowRegionIfNeeded(_ region: ClientFocusedWindowRegion?) {
        guard lastFocusedWindowRegion != region else { return }
        lastFocusedWindowRegion = region
        onFocusedWindowRegion?(region)
    }

    func stop() {
        isRunning = false
        ClientDiagnostics.write("video receiver stop requested rawDatagrams=\(rawDatagramCounter) acceptedChunks=\(receivedChunkCounter) completedFrames=\(completedFrameCounter)")
        receiver.stop()
        let decoder = decoder
        // VTDecompressionSessionWaitForAsynchronousFrames can block briefly
        // when the Mac sleeps or the stream dies. Keep that cleanup off the
        // main actor so settings and reconnect controls stay responsive.
        receiveQueue.async {
            decoder.invalidate()
        }
    }

    private func handleDecodedFrame(_ pixelBuffer: CVPixelBuffer) {
        guard isRunning else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        renderer?(pixelBuffer)
        onFrameDecoded?()
        if !hasLoggedFirstDecode {
            hasLoggedFirstDecode = true
            undecodedCompleteFrameCounter = 0
            Self.logger.info("First decoded pixel buffer delivered. width=\(width, privacy: .public) height=\(height, privacy: .public)")
            ClientDiagnostics.write("video receiver first decoded pixel buffer width=\(width) height=\(height)")
        }
        recordDecodedFrame()
    }

    private func recordDecodedFrame() {
        frameCounter += 1
        let now = Date()
        let interval = now.timeIntervalSince(lastStatsDate)
        guard interval >= 1.0 else { return }

        let shouldRequestKeyframe = keyframeRequestPending || skippedFrameCounter > 0
        let stats = ClientVideoStats(
            fps: Int((Double(frameCounter) / interval).rounded()),
            chunks: receivedChunkCounter,
            frames: completedFrameCounter,
            skippedFrames: skippedFrameCounter,
            receivedBytes: receivedByteCounter,
            receivedMbps: (Double(receivedByteCounter * 8) / interval) / 1_000_000,
            size: videoSize,
            keyframeRequested: shouldRequestKeyframe
        )
        ClientDiagnostics.write("video receiver stats fps=\(stats.fps) mbps=\(String(format: "%.3f", stats.receivedMbps)) frames=\(stats.frames) chunks=\(stats.chunks) skipped=\(stats.skippedFrames) bytes=\(stats.receivedBytes) keyframeRequested=\(stats.keyframeRequested)")
        onStats?(stats)
        keyframeRequestPending = false
        frameCounter = 0
        completedFrameCounter = 0
        receivedChunkCounter = 0
        receivedByteCounter = 0
        skippedFrameCounter = 0
        lastStatsDate = now
    }

    private func shouldDropLateFrame(_ frameID: UInt32) -> Bool {
        guard let lastCompletedFrameID else { return false }
        return frameID <= lastCompletedFrameID
    }

    private func recordCompletedFrameID(_ frameID: UInt32) -> Int {
        completedFrameCounter += 1
        defer { lastCompletedFrameID = frameID }
        guard let lastCompletedFrameID, frameID > lastCompletedFrameID + 1 else { return 0 }
        let skipped = Int(frameID - lastCompletedFrameID - 1)
        skippedFrameCounter += skipped
        return skipped
    }

    private func requestRecoveryIfNeeded(skippedFrames: Int) {
        let now = Date()
        guard now.timeIntervalSince(lastRecoveryRequestDate) >= 0.35 else { return }
        lastRecoveryRequestDate = now
        Self.logger.warning("Requesting immediate video recovery. skippedFrames=\(skippedFrames, privacy: .public)")
        ClientDiagnostics.write("video receiver recovery requested skippedFrames=\(skippedFrames) size=\(Int(videoSize.width))x\(Int(videoSize.height))")
        onRecoveryNeeded?(skippedFrames, videoSize)
    }

    private func requestRecoveryIfWaitingForDecoder(frame: VideoFramePacket) {
        guard !hasLoggedFirstDecode else { return }
        undecodedCompleteFrameCounter += 1
        let hasDecoderConfig = frameContainsDecoderConfig(frame)
        if undecodedCompleteFrameCounter <= 5 || undecodedCompleteFrameCounter % 30 == 0 || hasDecoderConfig {
            ClientDiagnostics.write("video receiver waiting for first decode completeFrames=\(undecodedCompleteFrameCounter) frameID=\(frame.frameID) payloadBytes=\(frame.payload.count) hasDecoderConfig=\(hasDecoderConfig)")
        }

        guard undecodedCompleteFrameCounter == 1 || undecodedCompleteFrameCounter % 12 == 0 else { return }
        keyframeRequestPending = true
        requestRecoveryIfNeeded(skippedFrames: 0)
    }

    private func frameContainsDecoderConfig(_ frame: VideoFramePacket) -> Bool {
        H264AnnexB.splitNALUnits(frame.payload).contains { unit in
            if let h264Type = H264AnnexB.nalType(unit), h264Type == 5 || h264Type == 7 || h264Type == 8 {
                return true
            }
            if let hevcType = H264AnnexB.hevcNalType(unit), hevcType == 32 || hevcType == 33 || hevcType == 34 || (16...21).contains(hevcType) {
                return true
            }
            return false
        }
    }
}

final class ClientAudioPlayer {
    private let sessionOwner = UUID()
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var currentFormat: AVAudioFormat?
    private var isConfigured = false

    func play(_ packet: AudioFramePacket) {
        ClientAudioSession.shared.play(owner: sessionOwner, pause: { [weak self] in
            self?.resetPlayback()
        }) {
            playWithSession(packet)
        }
    }

    private func playWithSession(_ packet: AudioFramePacket) {
        guard packet.channelCount > 0, !packet.payload.isEmpty else { return }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(packet.sampleRate),
            channels: AVAudioChannelCount(packet.channelCount),
            interleaved: true
        )
        guard let format else { return }

        if !formatsMatch(currentFormat, format) {
            configure(format: format)
        }

        guard isConfigured,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(packet.payload.count / max(Int(packet.channelCount) * 2, 1))
              ) else {
            return
        }

        buffer.frameLength = buffer.frameCapacity
        let audioBuffer = buffer.mutableAudioBufferList.pointee.mBuffers
        guard let target = audioBuffer.mData else { return }
        packet.payload.withUnsafeBytes { source in
            if let base = source.baseAddress {
                memcpy(target, base, min(packet.payload.count, Int(audioBuffer.mDataByteSize)))
            }
        }

        if !engine.isRunning {
            try? engine.start()
        }
        if !player.isPlaying {
            player.play()
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    func stop() {
        ClientAudioSession.shared.stopPlayback(owner: sessionOwner) {
            resetPlayback()
        }
    }

    private func resetPlayback() {
        player.stop()
        engine.stop()
        engine.reset()
        if player.engine != nil {
            engine.detach(player)
        }
        currentFormat = nil
        isConfigured = false
        // Fresh objects also recover from an AVAudioSession media-services reset.
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
    }

    private func configure(format: AVAudioFormat) {
        resetPlayback()

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        currentFormat = format
        isConfigured = true
        try? engine.start()
    }

    private func formatsMatch(_ lhs: AVAudioFormat?, _ rhs: AVAudioFormat) -> Bool {
        guard let lhs else { return false }
        return lhs.sampleRate == rhs.sampleRate &&
            lhs.channelCount == rhs.channelCount &&
            lhs.commonFormat == rhs.commonFormat &&
            lhs.isInterleaved == rhs.isInterleaved
    }
}

final class ClientAudioReceiver {
    private static let logger = Logger(subsystem: "PocketCtrlMobile", category: "AudioReceiver")

    var onStatus: ((String) -> Void)?

    private let receiver: ClientUDPReceiver
    private let expectedSourceHost: String
    private let credentialID: String
    private let credentialSecret: String
    private let player = ClientAudioPlayer()
    private let receiveQueue = DispatchQueue(label: "pocketctrl.mobile.audio.receiver", qos: .userInteractive)
    private var isRunning = true
    private var packetCounter = 0
    private var skippedPacketCounter = 0
    private var lastSequenceNumber: UInt32?
    private var lastStatusDate = Date()
    private var hasLoggedUnexpectedSource = false
    private var rawAudioDatagramCounter = 0
    private var audioParseFailureCounter = 0

    init(port: UInt16, expectedSourceHost: String, credentialID: String, credentialSecret: String) throws {
        self.expectedSourceHost = ClientNetworkAddressPolicy.normalized(expectedSourceHost)
        self.credentialID = credentialID
        self.credentialSecret = credentialSecret
        ClientDiagnostics.write("audio receiver init port=\(port) hasExpectedSource=\(!self.expectedSourceHost.isEmpty)")
        receiver = try ClientUDPReceiver(port: port)
    }

    func start() {
        receiveQueue.async { [weak self] in
            guard let self else { return }
            ClientDiagnostics.write("audio receiver loop started hasExpectedSource=\(!self.expectedSourceHost.isEmpty)")
            while self.isRunning, let datagram = self.receiver.receive() {
                self.rawAudioDatagramCounter += 1
                if self.rawAudioDatagramCounter <= 5 || self.rawAudioDatagramCounter % 100 == 0 {
                    ClientDiagnostics.write("audio receiver raw datagram count=\(self.rawAudioDatagramCounter) bytes=\(datagram.data.count) hasSender=\(datagram.senderAddress != nil)")
                }
                guard let plaintext = ClientSecureSessionDatagram.open(
                    datagram.data,
                    channel: .audio,
                    credentialID: self.credentialID,
                    secret: self.credentialSecret
                ) else {
                    continue
                }
                guard self.shouldAcceptAuthenticatedAudioDatagram(from: datagram.senderAddress) else {
                    continue
                }
                guard let packet = UDPAudioFraming.parseDatagram(plaintext) else {
                    self.audioParseFailureCounter += 1
                    if self.audioParseFailureCounter <= 5 || self.audioParseFailureCounter % 50 == 0 {
                        ClientDiagnostics.write("audio receiver parse failure count=\(self.audioParseFailureCounter) bytes=\(datagram.data.count)")
                    }
                    continue
                }
                self.record(packet)
                self.player.play(packet)
            }
            ClientDiagnostics.write("audio receiver loop stopped rawDatagrams=\(self.rawAudioDatagramCounter) packets=\(self.packetCounter) parseFailures=\(self.audioParseFailureCounter)")
        }
    }

    private func shouldAcceptAuthenticatedAudioDatagram(from senderAddress: String?) -> Bool {
        let accepted = ClientNetworkAddressPolicy.shouldAcceptAuthenticatedStreamPeer(
            configuredHost: expectedSourceHost,
            sourceHost: senderAddress
        )
        if !accepted, !hasLoggedUnexpectedSource {
            hasLoggedUnexpectedSource = true
            Self.logger.warning("Ignored audio from unexpected sender. expected=\(self.expectedSourceHost, privacy: .private) sender=\(senderAddress ?? "unknown", privacy: .private)")
            ClientDiagnostics.write("audio receiver ignored unexpected sender")
        }
        return accepted
    }

    func stop() {
        isRunning = false
        ClientDiagnostics.write("audio receiver stop requested rawDatagrams=\(rawAudioDatagramCounter) packets=\(packetCounter)")
        receiver.stop()
        let player = player
        // AVAudioEngine teardown can touch system audio state. Do it on the
        // receiver queue so reconnect teardown never steals the UI thread.
        receiveQueue.async {
            player.stop()
        }
    }

    private func record(_ packet: AudioFramePacket) {
        packetCounter += 1
        if let lastSequenceNumber, packet.sequenceNumber > lastSequenceNumber + 1 {
            skippedPacketCounter += Int(packet.sequenceNumber - lastSequenceNumber - 1)
        }
        lastSequenceNumber = packet.sequenceNumber

        let now = Date()
        let interval = now.timeIntervalSince(lastStatusDate)
        guard interval >= 1.0 else { return }
        onStatus?("\(packetCounter) audio packets/s, \(skippedPacketCounter) skipped")
        ClientDiagnostics.write("audio receiver stats packets=\(packetCounter) skipped=\(skippedPacketCounter)")
        packetCounter = 0
        skippedPacketCounter = 0
        lastStatusDate = now
    }
}
