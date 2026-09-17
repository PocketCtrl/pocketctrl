// SPDX-License-Identifier: MPL-2.0

import ApplicationServices
import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit
import VideoToolbox

enum StreamColorProfile {
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

    static func apply(to session: VTCompressionSession) {
        // Mac desktops are color-managed and commonly Display P3. Tagging the
        // H.264 stream keeps Apple decoders from treating it as generic SDR
        // video, while the 709 YCbCr matrix remains the right conversion for
        // hardware-friendly 4:2:0 screen sharing.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries, value: colorPrimaries)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction, value: transferFunction)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix, value: yCbCrMatrix)
    }
}

struct DisplayOption: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let width: Int
    let height: Int
}

struct HostConfiguration {
    let destinationAddress: String
    let videoPort: UInt16
    let audioPort: UInt16
    let inputPort: UInt16
    let credentialStore: TrustedDeviceCredentialStore
    let displayID: CGDirectDisplayID
    let captureWidth: Int
    let fps: Int
    let bitrate: Int
    let adaptiveBitrateEnabled: Bool
    let audioEnabled: Bool
    let clipboardEnabled: Bool
    let remoteInputEnabled: Bool
}

struct ViewerConfiguration {
    let listenPort: UInt16
    let audioPort: UInt16
    let hostAddress: String
    let hostInputPort: UInt16
    let controlSecret: String
    let credentialID: String
    let allowsClipboard: Bool
    let allowsAudio: Bool
}

struct HostActivityStats {
    let encodedFrames: Int
    let sentDatagrams: Int
    let sentBytes: Int
    let lastPayloadBytes: Int
}

struct ViewerActivityStats {
    let receivedChunks: Int
    let completedFrames: Int
    let skippedFrames: Int
    let estimatedLossPercent: Double
    let receivedMbps: Double
}

struct InputActivityStats {
    let totalEvents: Int
    let eventsPerSecond: Int
    let lastEventKind: RemoteInputKind?
}

enum StreamVideoCodec: String {
    case h264 = "H.264"
    case hevc = "HEVC"

    var codecType: CMVideoCodecType {
        switch self {
        case .h264: return kCMVideoCodecType_H264
        case .hevc: return kCMVideoCodecType_HEVC
        }
    }

    var profileLevel: CFString {
        switch self {
        case .h264: return kVTProfileLevel_H264_Main_AutoLevel
        case .hevc: return kVTProfileLevel_HEVC_Main_AutoLevel
        }
    }
}

private final class H264EncoderCallbackBox {
    private weak var encoder: H264Encoder?
    private let lock = NSLock()
    private var isActive = true

    init(encoder: H264Encoder) {
        self.encoder = encoder
    }

    func deactivate() {
        lock.lock()
        isActive = false
        encoder = nil
        lock.unlock()
    }

    func activeEncoder() -> H264Encoder? {
        lock.lock()
        defer { lock.unlock() }
        return isActive ? encoder : nil
    }
}

final class H264Encoder {
    var onFrameEncoded: ((VideoFramePacket, Int) -> Void)?

    let codec: StreamVideoCodec
    private let width: Int32
    private let height: Int32
    private let nominalFPS: Int
    private(set) var bitrate: Int
    private var expectedFrameRate: Int
    private var session: VTCompressionSession?
    private var callbackRefcon: UnsafeMutableRawPointer?
    private var frameID: UInt32 = 0
    private let stateLock = NSLock()
    private let keyframeLock = NSLock()
    private let rateControlLock = NSLock()
    private var forceNextKeyframe = false
    private var isInvalidated = false

    init(width: Int, height: Int, fps: Int, bitrate: Int, codec: StreamVideoCodec = .hevc) throws {
        self.codec = codec
        self.width = Int32(width)
        self.height = Int32(height)
        self.nominalFPS = fps
        self.expectedFrameRate = fps
        self.bitrate = bitrate
        try configureSession()
    }

    deinit {
        invalidate()
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime) {
        guard let session = activeSession() else { return }
        let frameProperties = nextFrameProperties()
        let frameRate = currentExpectedFrameRate()
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )

        if status != noErr {
            NSLog("PocketCtrl encode failed: \(status)")
        }
    }

    private func configureSession() throws {
        let callback: VTCompressionOutputCallback = { outputCallbackRefCon, _, status, _, sampleBuffer in
            guard status == noErr,
                  let outputCallbackRefCon,
                  let sampleBuffer,
                  CMSampleBufferDataIsReady(sampleBuffer) else {
                return
            }

            let callbackBox = Unmanaged<H264EncoderCallbackBox>
                .fromOpaque(outputCallbackRefCon)
                .takeUnretainedValue()
            guard let encoder = callbackBox.activeEncoder() else { return }
            encoder.handleEncodedSampleBuffer(sampleBuffer)
        }

        let callbackBox = H264EncoderCallbackBox(encoder: self)
        callbackRefcon = Unmanaged.passRetained(callbackBox).toOpaque()
        let createStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: codec.codecType,
            encoderSpecification: nil,
            imageBufferAttributes: StreamColorProfile.pixelBufferAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: callbackRefcon,
            compressionSessionOut: &session
        )

        guard createStatus == noErr, let session else {
            throw NSError(domain: "PocketCtrl.H264Encoder.\(codec.rawValue)", code: Int(createStatus))
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: codec.profileLevel)
        applyRateControl(to: session, bitrate: bitrate, expectedFrameRate: expectedFrameRate)
        StreamColorProfile.apply(to: session)
        // Low-latency desktop streaming should recover quickly from a lost UDP
        // packet. A one-second IDR cadence costs some bandwidth but keeps local
        // Wi-Fi glitches from corrupting the picture for multiple seconds.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: nominalFPS as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func invalidate() {
        stateLock.lock()
        guard !isInvalidated else {
            stateLock.unlock()
            return
        }
        isInvalidated = true
        onFrameEncoded = nil
        let sessionToInvalidate = session
        session = nil
        let refconToRelease = callbackRefcon
        callbackRefcon = nil
        stateLock.unlock()

        if let refconToRelease {
            Unmanaged<H264EncoderCallbackBox>
                .fromOpaque(refconToRelease)
                .takeUnretainedValue()
                .deactivate()
        }

        if let sessionToInvalidate {
            VTCompressionSessionCompleteFrames(sessionToInvalidate, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(sessionToInvalidate)
        }

        if let refconToRelease {
            Unmanaged<H264EncoderCallbackBox>
                .fromOpaque(refconToRelease)
                .release()
        }
    }

    func updateBitrate(_ bitrate: Int) {
        updateRateControl(bitrate: bitrate, expectedFrameRate: currentExpectedFrameRate())
    }

    func updateRateControl(bitrate: Int, expectedFrameRate: Int) {
        rateControlLock.lock()
        let expectedFrameRate = max(1, min(nominalFPS, expectedFrameRate))
        let bitrateChanged = bitrate != self.bitrate
        let frameRateChanged = expectedFrameRate != self.expectedFrameRate
        guard bitrateChanged || frameRateChanged else {
            rateControlLock.unlock()
            return
        }

        self.bitrate = bitrate
        self.expectedFrameRate = expectedFrameRate
        let session = activeSession()
        rateControlLock.unlock()

        guard let session else { return }
        applyRateControl(to: session, bitrate: bitrate, expectedFrameRate: expectedFrameRate)
    }

    func requestKeyframe() {
        keyframeLock.lock()
        forceNextKeyframe = true
        keyframeLock.unlock()
    }

    private func nextFrameProperties() -> CFDictionary? {
        keyframeLock.lock()
        let shouldForce = forceNextKeyframe
        forceNextKeyframe = false
        keyframeLock.unlock()

        guard shouldForce else { return nil }
        return [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
    }

    private func currentExpectedFrameRate() -> Int {
        rateControlLock.lock()
        let expectedFrameRate = expectedFrameRate
        rateControlLock.unlock()
        return expectedFrameRate
    }

    private func activeSession() -> VTCompressionSession? {
        stateLock.lock()
        let activeSession = isInvalidated ? nil : session
        stateLock.unlock()
        return activeSession
    }

    private func activeFrameCallback() -> ((VideoFramePacket, Int) -> Void)? {
        stateLock.lock()
        let callback = isInvalidated ? nil : onFrameEncoded
        stateLock.unlock()
        return callback
    }

    private func applyRateControl(to session: VTCompressionSession, bitrate: Int, expectedFrameRate: Int) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: expectedFrameRate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)

        // AverageBitRate is long-term. A short hard cap reduces big IDR/screen
        // change bursts that are especially painful for UDP screen sharing.
        let bytesPerSecondLimit = max(1, Int(Double(bitrate) / 8.0 * 1.15))
        let dataRateLimits = [
            NSNumber(value: bytesPerSecondLimit),
            NSNumber(value: 1.0)
        ] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits)
    }

    private func handleEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard activeSession() != nil else { return }
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let pointerStatus = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard pointerStatus == noErr, let dataPointer else { return }

        var payload = Data()
        if isKeyFrame(sampleBuffer), let parameterSets = parameterSets(from: sampleBuffer) {
            for parameterSet in parameterSets {
                payload.append(H264AnnexB.startCode)
                payload.append(parameterSet)
            }
        }

        let avccData = Data(bytes: dataPointer, count: totalLength)
        appendAVCCNALUnits(avccData, to: &payload)

        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let ptsUS = seconds.isFinite ? UInt64(seconds * 1_000_000) : 0
        let packet = VideoFramePacket(frameID: frameID, presentationTimestampUS: ptsUS, payload: payload)
        frameID &+= 1
        activeFrameCallback()?(packet, payload.count)
    }

    private func appendAVCCNALUnits(_ avccData: Data, to payload: inout Data) {
        var offset = 0
        while offset + 4 <= avccData.count {
            guard let length = ByteCoding.uint32(avccData, at: offset) else { return }
            offset += 4
            let nalLength = Int(length)
            guard nalLength > 0, offset + nalLength <= avccData.count else { return }
            payload.append(H264AnnexB.startCode)
            payload.append(avccData[offset..<offset + nalLength])
            offset += nalLength
        }
    }

    private func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else {
            return true
        }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    private func parameterSets(from sampleBuffer: CMSampleBuffer) -> [Data]? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }

        switch codec {
        case .h264:
            return h264ParameterSets(from: formatDescription)
        case .hevc:
            return hevcParameterSets(from: formatDescription)
        }
    }

    private func h264ParameterSets(from formatDescription: CMFormatDescription) -> [Data]? {
        var spsPointer: UnsafePointer<UInt8>?
        var spsSize = 0
        var ppsPointer: UnsafePointer<UInt8>?
        var ppsSize = 0
        var parameterSetCount = 0
        var nalHeaderLength: Int32 = 0

        let spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalHeaderLength
        )

        let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer,
            parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )

        guard spsStatus == noErr, ppsStatus == noErr, let spsPointer, let ppsPointer else {
            return nil
        }

        return [
            Data(bytes: spsPointer, count: spsSize),
            Data(bytes: ppsPointer, count: ppsSize)
        ]
    }

    private func hevcParameterSets(from formatDescription: CMFormatDescription) -> [Data]? {
        var parameterSets: [Data] = []
        var parameterSetCount = 0

        for index in 0..<3 {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            var nalHeaderLength: Int32 = 0
            let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: &parameterSetCount,
                nalUnitHeaderLengthOut: &nalHeaderLength
            )
            guard status == noErr, let pointer else { return nil }
            parameterSets.append(Data(bytes: pointer, count: size))
        }

        return parameterSets.count == 3 ? parameterSets : nil
    }
}

final class SystemAudioStreamer {
    private let sender: any DatagramSending
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true)!
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var sequenceNumber: UInt32 = 0

    init(sender: any DatagramSending) {
        self.sender = sender
    }

    func send(sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return
        }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        if !formatsMatch(self.inputFormat, inputFormat) {
            self.inputFormat = inputFormat
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        }

        guard let converter,
              let inputBuffer = pcmBuffer(from: sampleBuffer, format: inputFormat) else {
            return
        }

        let ratio = outputFormat.sampleRate / max(inputFormat.sampleRate, 1)
        let outputCapacity = AVAudioFrameCount((Double(inputBuffer.frameLength) * ratio).rounded(.up)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            return
        }

        var didProvideInput = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard conversionError == nil,
              outputBuffer.frameLength > 0,
              let payload = interleavedPayload(from: outputBuffer) else {
            return
        }

        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let ptsUS = seconds.isFinite ? UInt64(seconds * 1_000_000) : 0
        let packet = AudioFramePacket(
            sequenceNumber: sequenceNumber,
            presentationTimestampUS: ptsUS,
            sampleRate: UInt32(outputFormat.sampleRate),
            channelCount: UInt8(outputFormat.channelCount),
            payload: payload
        )
        sequenceNumber &+= 1
        try? sender.send(UDPAudioFraming.packet(packet))
    }

    private func pcmBuffer(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }

        buffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }

    private func interleavedPayload(from buffer: AVAudioPCMBuffer) -> Data? {
        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
        guard let data = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else { return nil }
        return Data(bytes: data, count: Int(audioBuffer.mDataByteSize))
    }

    private func formatsMatch(_ lhs: AVAudioFormat?, _ rhs: AVAudioFormat) -> Bool {
        guard let lhs else { return false }
        return lhs.sampleRate == rhs.sampleRate &&
            lhs.channelCount == rhs.channelCount &&
            lhs.commonFormat == rhs.commonFormat &&
            lhs.isInterleaved == rhs.isInterleaved
    }
}

final class FocusedWindowRegionTracker {
    private let lock = NSLock()
    private var lastPollDate = Date.distantPast
    private var cachedRegion: FocusedWindowRegion?
    private let minimumPollInterval: TimeInterval = 0.16

    func region(on displayID: CGDirectDisplayID) -> FocusedWindowRegion? {
        let now = Date()
        lock.lock()
        if now.timeIntervalSince(lastPollDate) < minimumPollInterval {
            let cachedRegion = cachedRegion
            lock.unlock()
            return cachedRegion
        }
        lock.unlock()

        let region = readFocusedWindowRegion(on: displayID)

        lock.lock()
        lastPollDate = now
        cachedRegion = region
        lock.unlock()

        return region
    }

    private func readFocusedWindowRegion(on displayID: CGDirectDisplayID) -> FocusedWindowRegion? {
        guard AXIsProcessTrusted() else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        guard let focusedApp = copyAXElementAttribute(systemWide, attribute: kAXFocusedApplicationAttribute),
              let focusedWindow = copyAXElementAttribute(focusedApp, attribute: kAXFocusedWindowAttribute),
              let windowRect = windowFrame(focusedWindow) else {
            return nil
        }

        let displayBounds = CGDisplayBounds(displayID)
        guard displayBounds.width > 0, displayBounds.height > 0 else { return nil }

        let intersection = windowRect.intersection(displayBounds)
        guard !intersection.isNull,
              intersection.width >= 80,
              intersection.height >= 60 else {
            return nil
        }

        return FocusedWindowRegion(
            x: (intersection.minX - displayBounds.minX) / displayBounds.width,
            y: (intersection.minY - displayBounds.minY) / displayBounds.height,
            width: intersection.width / displayBounds.width,
            height: intersection.height / displayBounds.height
        )
    }

    private func copyAXElementAttribute(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func windowFrame(_ window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue((positionValue as! AXValue), .cgPoint, &position),
              AXValueGetValue((sizeValue as! AXValue), .cgSize, &size),
              size.width > 0,
              size.height > 0 else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }
}

final class ScreenCaptureHost: NSObject, SCStreamOutput, SCStreamDelegate {
    var onStats: ((Int, Int, Int, HostActivityStats) -> Void)?
    var onFeedback: ((ViewerFeedback, Int) -> Void)?
    var onInputStats: ((InputActivityStats) -> Void)?
    var onAudioSetting: ((Bool) -> Void)?
    var onPeerAddress: ((String) -> Void)?
    var onAuthenticatedDevice: ((TrustedDeviceCredential, String?) -> Void)?
    var onLocalNetworkSendFailure: ((Int32) -> Void)?
    var onActiveControllerChanged: ((TrustedDeviceCredential?, String?) -> Void)?
    var onConnectedViewersChanged: (([ActiveViewerSessionSnapshot]) -> Void)?
    var onStreamStopped: ((Error) -> Void)?

    private let configuration: HostConfiguration
    private let sender: SecureMultiPeerDatagramSender
    private let audioSender: SecureMultiPeerDatagramSender
    private let inputReceiver: any DatagramReceiving
    private let inputInjector: MacInputInjector
    private let sessionRegistry: ActiveViewerSessionRegistry
    private let remoteInputStateLock = NSLock()
    private var remoteInputEnabled: Bool
    private var inputListener: RemoteInputListener?
    private var clipboardSync: ClipboardSynchronizer?
    private var clipboardFrameID: UInt32 = 0
    private var encoder: H264Encoder?
    private var audioStreamer: SystemAudioStreamer?
    private let streamStateLock = NSLock()
    private var stream: SCStream?
    private let streamFrameIDLock = NSLock()
    private var nextStreamFrameID: UInt32 = 0
    private var frameCounter = 0
    private var byteCounter = 0
    private var datagramCounter = 0
    private var datagramByteCounter = 0
    private var lastStatsDate = Date()
    private var totalInputEvents = 0
    private var inputEventsInWindow = 0
    private var lastInputEventKind: RemoteInputKind?
    private var lastInputStatsDate = Date()
    private let adaptiveStateLock = NSLock()
    private var adaptiveBitrate: Int
    private let minimumAdaptiveBitrate: Int
    private var adaptiveFrameStride = 1
    private var framePacer = StreamFramePacer()
    private var consecutivePoorFeedback = 0
    private var consecutiveHealthyFeedback = 0
    private var adaptiveQualityProfile: ViewerQualityProfile = .balanced
    private var adaptiveLimits = ViewerQualityProfile.balanced.limits
    private var activeVideoCodec: StreamVideoCodec = .h264
    private var activeZoomRegion: CGRect?
    private var activeDisplay: SCDisplay?
    private var isAudioEnabled: Bool
    private var isStopping = false
    private var lastContentHash: UInt64?
    private var staticFrameCount = 0
    private var isIdlePacingActive = false
    private var lastRemoteInputDate = Date.distantPast
    private let focusedWindowTracker = FocusedWindowRegionTracker()

    init(configuration: HostConfiguration) throws {
        self.configuration = configuration
        let sessionRegistry = ActiveViewerSessionRegistry(
            credentialStore: configuration.credentialStore,
            configuredHost: configuration.destinationAddress
        )
        self.sessionRegistry = sessionRegistry
        NSLog("PocketCtrl host init videoPort=\(configuration.videoPort) inputPort=\(configuration.inputPort) audioPort=\(configuration.audioPort) remoteInput=\(configuration.remoteInputEnabled) audio=\(configuration.audioEnabled) clipboard=\(configuration.clipboardEnabled)")
        let videoSender = try UDPMultiPeerSender()
        let systemAudioSender = try UDPMultiPeerSender()
        sender = SecureMultiPeerDatagramSender(sender: videoSender, channel: .video, port: configuration.videoPort, sessions: sessionRegistry)
        audioSender = SecureMultiPeerDatagramSender(sender: systemAudioSender, channel: .audio, port: configuration.audioPort, sessions: sessionRegistry)
        inputReceiver = try UDPReceiver(port: configuration.inputPort)
        inputInjector = MacInputInjector(displayIDProvider: { configuration.displayID })
        remoteInputEnabled = configuration.remoteInputEnabled
        adaptiveBitrate = configuration.bitrate
        minimumAdaptiveBitrate = max(500_000, configuration.bitrate / 16)
        isAudioEnabled = configuration.audioEnabled
        super.init()
        sender.onLocalNetworkSendFailure = { [weak self] code in
            self?.onLocalNetworkSendFailure?(code)
        }
        audioSender.onLocalNetworkSendFailure = { [weak self] code in
            self?.onLocalNetworkSendFailure?(code)
        }
        if isAudioEnabled {
            audioStreamer = SystemAudioStreamer(sender: audioSender)
        }
        sessionRegistry.onSessionsChanged = { [weak self] sessions in
            self?.onConnectedViewersChanged?(sessions)
            Task { @MainActor [weak self] in
                await self?.reconcileAudioCaptureWithActiveSessions()
            }
        }
    }

    func start() async throws {
        NSLog("PocketCtrl host start requested inputPort=\(configuration.inputPort)")
        PocketCtrlHostDiagnostics.write("host start requested videoPort=\(configuration.videoPort) inputPort=\(configuration.inputPort) audioPort=\(configuration.audioPort)")
        inputInjector.requestAccessibilityTrust()
        if configuration.clipboardEnabled {
            clipboardSync = ClipboardSynchronizer(label: "host") { [weak self] payload in
                self?.sendClipboardToViewers(payload)
            }
        }
        inputListener = RemoteInputListener(
            receiver: inputReceiver,
            injector: inputInjector,
            credentialStore: configuration.credentialStore,
            sessionRegistry: sessionRegistry,
            inputEnabled: currentRemoteInputEnabled
        ) { [weak self] feedback, credential in
            self?.handle(feedback: feedback, deviceID: credential.record.id)
        } onZoomRegion: { [weak self] zoomRegion in
            Task {
                await self?.handle(zoomRegion: zoomRegion)
            }
        } onAudioSetting: { [weak self] setting, credential in
            Task {
                await self?.handle(audioSetting: setting, deviceID: credential.record.id)
            }
        } onClipboard: { [weak self] clipboard in
            guard self?.configuration.clipboardEnabled == true else { return }
            self?.clipboardSync?.apply(clipboard)
        } onInputEvent: { [weak self] event in
            self?.recordInputEvent(event)
        } onAuthenticatedDevice: { [weak self] credential, sourceHost in
            self?.onAuthenticatedDevice?(credential, sourceHost)
        } onActiveControllerChanged: { [weak self] credential, sourceHost in
            self?.onActiveControllerChanged?(credential, sourceHost)
        }
        inputListener?.setInputEnabled(currentRemoteInputEnabled)
        inputListener?.start()
        clipboardSync?.start()
        NSLog("PocketCtrl host input listener started on port/channel \(configuration.inputPort)")
        PocketCtrlHostDiagnostics.write("host input listener started port=\(configuration.inputPort)")

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == configuration.displayID }) ?? content.displays.first else {
            throw NSError(domain: "PocketCtrl.ScreenCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display available"])
        }
        activeDisplay = display
        NSLog("PocketCtrl host selected display id=\(display.displayID) size=\(Int(display.width))x\(Int(display.height))")
        PocketCtrlHostDiagnostics.write("host selected display id=\(display.displayID) size=\(Int(display.width))x\(Int(display.height))")

        try await startStream(display: display, zoomRegion: nil)
    }

    func stop() {
        NSLog("PocketCtrl host stop requested")
        isStopping = true
        clipboardSync?.stop()
        clipboardSync = nil
        inputListener?.stop()
        sessionRegistry.removeAll()
        sender.stop()
        audioSender.stop()
        encoder?.invalidate()
        encoder = nil
        audioStreamer = nil
        let streamToStop = replaceActiveStream(with: nil)
        Task {
            try? await streamToStop?.stopCapture()
        }
    }

    func setRemoteInputEnabled(_ enabled: Bool) {
        remoteInputStateLock.lock()
        remoteInputEnabled = enabled
        remoteInputStateLock.unlock()
        inputListener?.setInputEnabled(enabled)
    }

    func disconnectViewer(deviceID: String) {
        sessionRegistry.remove(deviceID: deviceID)
        inputListener?.disconnect(deviceID: deviceID)
    }

    private var currentRemoteInputEnabled: Bool {
        remoteInputStateLock.lock()
        defer { remoteInputStateLock.unlock() }
        return remoteInputEnabled
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard clearActiveStream(ifMatching: stream) else {
            NSLog("PocketCtrl ignored stop callback from superseded capture stream")
            PocketCtrlHostDiagnostics.write("ignored stop callback from superseded capture stream")
            return
        }
        NSLog("PocketCtrl stream stopped: \(error)")
        let nsError = error as NSError
        PocketCtrlHostDiagnostics.write("active capture stream stopped domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")
        encoder?.invalidate()
        encoder = nil
        audioStreamer = nil
        guard !isStopping else { return }
        onStreamStopped?(error)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !isStopping else { return }
        switch type {
        case .screen:
            guard sampleBuffer.isValid, let pixelBuffer = sampleBuffer.imageBuffer else { return }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard shouldEncodeScreenFrame(pixelBuffer, at: timestamp.seconds) else { return }
            encoder?.encode(pixelBuffer: pixelBuffer, presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        case .audio:
            audioStreamer?.send(sampleBuffer: sampleBuffer)
        case .microphone:
            return
        @unknown default:
            return
        }
    }

    private func recordFrame(payloadSize: Int, sentDatagrams: Int, sentBytes: Int) {
        frameCounter += 1
        byteCounter += payloadSize
        datagramCounter += sentDatagrams
        datagramByteCounter += sentBytes
        let now = Date()
        let interval = now.timeIntervalSince(lastStatsDate)
        guard interval >= 1.0 else { return }
        let fps = Int((Double(frameCounter) / interval).rounded())
        let bitrate = Int((Double(byteCounter * 8) / interval).rounded())
        let activity = HostActivityStats(
            encodedFrames: frameCounter,
            sentDatagrams: datagramCounter,
            sentBytes: datagramByteCounter,
            lastPayloadBytes: payloadSize
        )
        PocketCtrlHostDiagnostics.write("host send stats fps=\(fps) bitrate=\(encoder?.bitrate ?? bitrate) encodedFrames=\(frameCounter) sentDatagrams=\(datagramCounter) sentBytes=\(datagramByteCounter) lastPayloadBytes=\(payloadSize)")
        onStats?(fps, encoder?.bitrate ?? bitrate, payloadSize, activity)
        frameCounter = 0
        byteCounter = 0
        datagramCounter = 0
        datagramByteCounter = 0
        lastStatsDate = now
    }

    func retryFailedMediaConnections() {
        sender.retryFailedLocalConnections()
        audioSender.retryFailedLocalConnections()
    }

    private func handle(feedback: ViewerFeedback, deviceID: String) {
        #if POCKETCTRL_NETWORK_DIAGNOSTICS
        sender.recordDiagnosticFeedback(feedback)
        #endif
        let aggregateFeedback = sessionRegistry.updateFeedback(feedback, deviceID: deviceID)
        let feedbackQuality = aggregateFeedback.qualityProfile ?? .balanced
        NSLog("PocketCtrl host received aggregate viewer feedback fps=\(aggregateFeedback.fps) chunks=\(aggregateFeedback.receivedChunks) frames=\(aggregateFeedback.completedFrames) skipped=\(aggregateFeedback.skippedFrames) keyframe=\(aggregateFeedback.keyframeRequested ?? false) quality=\(feedbackQuality.rawValue)")
        PocketCtrlHostDiagnostics.write("host received aggregate viewer feedback fps=\(aggregateFeedback.fps) chunks=\(aggregateFeedback.receivedChunks) frames=\(aggregateFeedback.completedFrames) skipped=\(aggregateFeedback.skippedFrames) keyframe=\(aggregateFeedback.keyframeRequested ?? false) quality=\(feedbackQuality.rawValue)")
        let adaptation = updateAdaptiveVideoState(feedback: aggregateFeedback)

        if adaptation.shouldRestartStreamForQuality {
            restartStreamForCurrentQualityProfile()
        }
        if adaptation.shouldUpdateEncoderRateControl {
            encoder?.updateRateControl(bitrate: adaptation.bitrate, expectedFrameRate: adaptation.expectedFrameRate)
        }
        if aggregateFeedback.keyframeRequested == true || adaptation.shouldRequestKeyframe {
            encoder?.requestKeyframe()
        }
        onFeedback?(aggregateFeedback, adaptation.bitrate)
    }

    private func shouldEncodeScreenFrame(_ pixelBuffer: CVPixelBuffer, at timestamp: Double) -> Bool {
        let screenIsStatic = updateStaticScreenState(pixelBuffer)
        let recentRemoteInput = Date().timeIntervalSince(lastRemoteInputDate) < 0.8
        let idle = screenIsStatic && !recentRemoteInput
        if idle != isIdlePacingActive {
            PocketCtrlHostDiagnostics.write("idle video pacing active=\(idle) quality=\(currentQualityProfileRawValue())")
        }
        adaptiveStateLock.lock()
        defer { adaptiveStateLock.unlock() }
        isIdlePacingActive = idle
        let activeRate = adaptiveLimits.frameRate(hostFrameRate: configuration.fps, backoff: adaptiveFrameStride)
        let targetRate = idle ? min(activeRate, adaptiveLimits.idleFrameRate) : activeRate
        return framePacer.shouldSend(at: timestamp, frameRate: targetRate)
    }

    private func updateStaticScreenState(_ pixelBuffer: CVPixelBuffer) -> Bool {
        guard let hash = sampledContentHash(pixelBuffer) else {
            staticFrameCount = 0
            lastContentHash = nil
            return false
        }

        if hash == lastContentHash {
            staticFrameCount = min(staticFrameCount + 1, configuration.fps * 10)
        } else {
            lastContentHash = hash
            staticFrameCount = 0
        }

        return staticFrameCount >= staticFrameThreshold
    }

    private var staticFrameThreshold: Int {
        max(6, configuration.fps / 2)
    }

    private func sampledContentHash(_ pixelBuffer: CVPixelBuffer) -> UInt64? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let baseAddress: UnsafeMutableRawPointer?

        if planeCount > 0 {
            width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
        } else {
            width = CVPixelBufferGetWidth(pixelBuffer)
            height = CVPixelBufferGetHeight(pixelBuffer)
            bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
        }

        guard width > 0, height > 0, bytesPerRow > 0, let baseAddress else { return nil }

        let base = baseAddress.assumingMemoryBound(to: UInt8.self)
        let sampleColumns = min(48, width)
        let sampleRows = min(27, height)
        var hash: UInt64 = 14_695_981_039_346_656_037
        hash = fnv1a(hash, UInt64(width))
        hash = fnv1a(hash, UInt64(height))

        for rowIndex in 0..<sampleRows {
            let y = sampleRows <= 1 ? 0 : rowIndex * (height - 1) / (sampleRows - 1)
            let row = base.advanced(by: y * bytesPerRow)
            for columnIndex in 0..<sampleColumns {
                let x = sampleColumns <= 1 ? 0 : columnIndex * (width - 1) / (sampleColumns - 1)
                hash = fnv1a(hash, UInt64(row[x]))
            }
        }

        return hash
    }

    private func fnv1a(_ hash: UInt64, _ value: UInt64) -> UInt64 {
        var hash = hash
        var value = value
        for _ in 0..<8 {
            hash ^= value & 0xff
            hash = hash &* 1_099_511_628_211
            value >>= 8
        }
        return hash
    }

    private func updateAdaptiveVideoState(feedback: ViewerFeedback) -> (bitrate: Int, expectedFrameRate: Int, shouldUpdateEncoderRateControl: Bool, shouldRequestKeyframe: Bool, shouldRestartStreamForQuality: Bool) {
        adaptiveStateLock.lock()
        defer { adaptiveStateLock.unlock() }

        let qualityProfile = feedback.qualityProfile ?? .balanced
        let limits = feedback.streamLimits
        // Only a capture-width change needs a new ScreenCaptureKit stream;
        // bitrate uses encoder rate control, fps uses timestamp-based pacing.
        let captureWidthChanged = limits.maximumCaptureWidth != adaptiveLimits.maximumCaptureWidth
        let qualityChanged = limits != adaptiveLimits
        adaptiveQualityProfile = qualityProfile

        guard configuration.adaptiveBitrateEnabled else {
            consecutivePoorFeedback = 0
            consecutiveHealthyFeedback = 0
            adaptiveFrameStride = 1
            let nextBitrate = effectiveMaximumBitrate(for: limits)
            let bitrateChanged = nextBitrate != adaptiveBitrate
            adaptiveBitrate = nextBitrate
            adaptiveLimits = limits
            return (nextBitrate, limits.frameRate(hostFrameRate: configuration.fps), bitrateChanged || qualityChanged, qualityChanged, captureWidthChanged)
        }

        var nextBitrate = adaptiveBitrate
        var nextFrameStride = adaptiveFrameStride
        let qualityMinimumBitrate = effectiveMinimumBitrate(for: limits)
        let qualityMaximumBitrate = effectiveMaximumBitrate(for: limits)
        let minimumFrameStride = 1

        if nextBitrate > qualityMaximumBitrate {
            nextBitrate = qualityMaximumBitrate
        }
        if nextBitrate < qualityMinimumBitrate {
            nextBitrate = qualityMinimumBitrate
        }
        if nextFrameStride < minimumFrameStride {
            nextFrameStride = minimumFrameStride
        }
        if qualityChanged {
            adaptiveQualityProfile = qualityProfile
            adaptiveLimits = limits
            nextBitrate = min(qualityMaximumBitrate, max(qualityMinimumBitrate, codecAdjustedBitrate(configuration.bitrate, codec: activeVideoCodec)))
            nextFrameStride = minimumFrameStride
            consecutivePoorFeedback = 0
            consecutiveHealthyFeedback = 0
        }

        // Only measured viewer stats should drive bitrate decisions. The iPhone
        // can also send keyframe-only recovery packets, and those must not be
        // treated as full packet-loss windows or the host will overreact.
        let activeTargetFPS = limits.frameRate(hostFrameRate: configuration.fps, backoff: nextFrameStride)
        // A still screen is intentionally sent slowly, not evidence of loss.
        let targetFPS = isIdlePacingActive ? min(activeTargetFPS, limits.idleFrameRate) : activeTargetFPS
        let poorFrameRate = feedback.fps > 0 && feedback.fps < max(1, Int(Double(targetFPS) * 0.65))
        let severeLoss = feedback.estimatedLossPercent >= 12 || feedback.skippedFrames >= 3
        let poorNetwork = feedback.hasMeasuredViewerStats &&
            (severeLoss || feedback.estimatedLossPercent >= 4 || feedback.skippedFrames > 0 || poorFrameRate)
        let healthyNetwork = feedback.hasMeasuredViewerStats &&
            feedback.estimatedLossPercent < 1 &&
            feedback.skippedFrames == 0 &&
            feedback.fps >= max(1, Int(Double(targetFPS) * 0.85))

        if poorNetwork {
            consecutivePoorFeedback += 1
            consecutiveHealthyFeedback = 0
        } else if healthyNetwork {
            consecutiveHealthyFeedback += 1
            consecutivePoorFeedback = 0
        } else {
            consecutivePoorFeedback = 0
            consecutiveHealthyFeedback = 0
        }

        if (feedback.hasMeasuredViewerStats && severeLoss) || consecutivePoorFeedback >= 2 {
            let multiplier = severeLoss ? 0.72 : 0.82
            nextBitrate = min(qualityMaximumBitrate, max(qualityMinimumBitrate, Int(Double(nextBitrate) * multiplier)))
            nextFrameStride = min(maximumAdaptiveFrameStride, nextFrameStride + 1)
            consecutivePoorFeedback = 0
        } else if consecutiveHealthyFeedback >= 5 {
            nextBitrate = min(qualityMaximumBitrate, Int(Double(nextBitrate) * 1.08))
            nextFrameStride = max(minimumFrameStride, nextFrameStride - 1)
            consecutiveHealthyFeedback = 0
        }

        let bitrateChanged = nextBitrate != adaptiveBitrate
        let frameStrideChanged = nextFrameStride != adaptiveFrameStride

        if bitrateChanged || frameStrideChanged {
            adaptiveBitrate = nextBitrate
            adaptiveFrameStride = nextFrameStride
            NSLog(
                "PocketCtrl adaptive video updated: bitrate=\(nextBitrate) frameStride=\(nextFrameStride) quality=\(qualityProfile.rawValue) feedbackFPS=\(feedback.fps) loss=\(String(format: "%.1f", feedback.estimatedLossPercent)) skipped=\(feedback.skippedFrames)"
            )
        }

        let expectedFrameRate = limits.frameRate(hostFrameRate: configuration.fps, backoff: adaptiveFrameStride)
        return (adaptiveBitrate, expectedFrameRate, bitrateChanged || frameStrideChanged || qualityChanged, frameStrideChanged || qualityChanged, captureWidthChanged)
    }

    private var maximumAdaptiveFrameStride: Int {
        min(4, max(1, configuration.fps / 15))
    }

    private func effectiveMinimumBitrate(for limits: ViewerStreamLimits) -> Int {
        min(effectiveMaximumBitrate(for: limits), max(minimumAdaptiveBitrate, limits.minimumBitrate))
    }

    private func effectiveMaximumBitrate(for limits: ViewerStreamLimits) -> Int {
        limits.bitrateCap(hostBitrate: configuration.bitrate, codecFactor: activeVideoCodec == .hevc ? 0.6 : 1)
    }

    private func codecAdjustedBitrate(_ bitrate: Int, codec: StreamVideoCodec) -> Int {
        switch codec {
        case .h264:
            return bitrate
        case .hevc:
            return max(1, Int((Double(bitrate) * 0.6).rounded()))
        }
    }

    private func maximumCaptureWidthForCurrentQualityProfile() -> Int {
        currentLimits().maximumCaptureWidth
    }

    private func effectiveMaximumBitrateForCurrentQualityProfile(codec: StreamVideoCodec = .h264) -> Int {
        let limits = currentLimits()
        return limits.bitrateCap(hostBitrate: configuration.bitrate, codecFactor: codec == .hevc ? 0.6 : 1)
    }

    private func currentQualityProfileRawValue() -> String {
        currentQualityProfile().rawValue
    }

    private func currentQualityProfile() -> ViewerQualityProfile {
        adaptiveStateLock.lock()
        let qualityProfile = adaptiveQualityProfile
        adaptiveStateLock.unlock()
        return qualityProfile
    }

    private func currentLimits() -> ViewerStreamLimits {
        adaptiveStateLock.lock()
        let limits = adaptiveLimits
        adaptiveStateLock.unlock()
        return limits
    }

    private func restartStreamForCurrentQualityProfile() {
        Task { @MainActor [weak self] in
            guard let self, let display = self.activeDisplay else { return }
            do {
                try await self.startStream(display: display, zoomRegion: self.activeZoomRegion)
            } catch {
                NSLog("PocketCtrl quality stream switch failed: \(error)")
            }
        }
    }

    private func sendClipboardToViewers(_ clipboard: ClipboardPayload) {
        let frameID = clipboardFrameID
        clipboardFrameID &+= 1

        let encoder = JSONEncoder()
        guard let data = ClipboardVideoDatagram.seal(
            clipboard,
            encoder: encoder
        ) else {
            NSLog("PocketCtrl host clipboard seal failed bytes=\(clipboard.text.utf8.count) changeID=\(clipboard.changeID)")
            PocketCtrlHostDiagnostics.write("host clipboard seal failed bytes=\(clipboard.text.utf8.count) changeID=\(clipboard.changeID)")
            return
        }

        let datagrams = UDPClipboardFraming.chunk(data, frameID: frameID)
        guard !datagrams.isEmpty else { return }

        for attempt in 1...3 {
            var failedSends = 0
            do {
                for datagram in datagrams {
                    do {
                        try sender.send(datagram) { $0.record.allowsClipboard }
                    } catch {
                        failedSends += 1
                        if failedSends <= 3 {
                            PocketCtrlHostDiagnostics.write("host clipboard chunk send failed attempt=\(attempt) frameID=\(frameID) bytes=\(datagram.count) error=\(error.localizedDescription)")
                        }
                    }
                }
            }
            NSLog("PocketCtrl host sent clipboard chunks attempt=\(attempt) frameID=\(frameID) textBytes=\(clipboard.text.utf8.count) chunks=\(datagrams.count) failed=\(failedSends) changeID=\(clipboard.changeID)")
            PocketCtrlHostDiagnostics.write("host sent clipboard chunks attempt=\(attempt) frameID=\(frameID) textBytes=\(clipboard.text.utf8.count) packetBytes=\(data.count) chunks=\(datagrams.count) failed=\(failedSends) changeID=\(clipboard.changeID)")

            if attempt < 3 {
                Thread.sleep(forTimeInterval: 0.04)
            }
        }
    }

    @MainActor
    private func handle(audioSetting: ViewerAudioSetting, deviceID: String) async {
        let anyAudioEnabled = sessionRegistry.updateAudioEnabled(audioSetting.enabled, deviceID: deviceID)
        guard isAudioEnabled != anyAudioEnabled else { return }

        isAudioEnabled = anyAudioEnabled
        audioStreamer = anyAudioEnabled ? SystemAudioStreamer(sender: audioSender) : nil
        onAudioSetting?(anyAudioEnabled)

        guard let display = activeDisplay else { return }
        do {
            try await startStream(display: display, zoomRegion: activeZoomRegion)
        } catch {
            NSLog("PocketCtrl audio stream switch failed: \(error)")
        }
    }

    @MainActor
    private func reconcileAudioCaptureWithActiveSessions() async {
        let anyAudioEnabled = sessionRegistry.activeSessions().contains {
            $0.audioEnabled && $0.credential.record.allowsAudio
        }
        guard isAudioEnabled != anyAudioEnabled else { return }
        isAudioEnabled = anyAudioEnabled
        audioStreamer = anyAudioEnabled ? SystemAudioStreamer(sender: audioSender) : nil
        onAudioSetting?(anyAudioEnabled)
        guard let display = activeDisplay else { return }
        do {
            try await startStream(display: display, zoomRegion: activeZoomRegion)
        } catch {
            NSLog("PocketCtrl audio stream reconciliation failed: \(error)")
        }
    }

    @MainActor
    private func handle(zoomRegion: ViewerZoomRegion) async {
        guard let display = activeDisplay else { return }

        let region: CGRect?
        if zoomRegion.enabled {
            region = sanitizedZoomRegion(zoomRegion)
        } else {
            region = nil
        }

        if normalizedRegionsAreEqual(activeZoomRegion, region) {
            return
        }

        activeZoomRegion = region
        inputInjector.updateInputRegion(region)

        do {
            try await startStream(display: display, zoomRegion: region)
        } catch {
            NSLog("PocketCtrl zoom stream switch failed")
        }
    }

    private func startStream(display: SCDisplay, zoomRegion: CGRect?) async throws {
        NSLog("PocketCtrl host starting ScreenCaptureKit stream zoomEnabled=\(zoomRegion != nil) audio=\(isAudioEnabled)")
        if let streamToStop = replaceActiveStream(with: nil) {
            try? await streamToStop.stopCapture()
        }
        encoder?.invalidate()
        encoder = nil

        let sourceWidth = zoomRegion.map { max(1, Int(Double(display.width) * $0.width)) } ?? display.width
        let sourceHeight = zoomRegion.map { max(1, Int(Double(display.height) * $0.height)) } ?? display.height
        let requestedWidth = zoomRegion == nil ? configuration.captureWidth : max(configuration.captureWidth, 1_920)
        let captureWidthLimit = maximumCaptureWidthForCurrentQualityProfile()
        let qualityRequestedWidth = min(requestedWidth, captureWidthLimit)
        let captureWidth = evenDimension(min(qualityRequestedWidth, sourceWidth))
        let captureHeight = evenDimension(Int(Double(captureWidth) * Double(sourceHeight) / Double(sourceWidth)))
        let h264QualityBitrate = effectiveMaximumBitrateForCurrentQualityProfile(codec: .h264)
        let hevcQualityBitrate = effectiveMaximumBitrateForCurrentQualityProfile(codec: .hevc)
        let configuredBitrate = zoomRegion == nil ? configuration.bitrate : min(max(configuration.bitrate * 2, configuration.bitrate), configuration.bitrate + 16_000_000)
        let h264Bitrate = min(configuredBitrate, h264QualityBitrate)
        let hevcBitrate = min(codecAdjustedBitrate(configuredBitrate, codec: .hevc), hevcQualityBitrate)

        let encoder: H264Encoder
        let initialFrameRate = currentLimits().frameRate(hostFrameRate: configuration.fps)
        do {
            encoder = try H264Encoder(width: captureWidth, height: captureHeight, fps: initialFrameRate, bitrate: h264Bitrate, codec: .h264)
        } catch {
            NSLog("PocketCtrl H.264 encoder unavailable; trying HEVC: \(error)")
            PocketCtrlHostDiagnostics.write("h264 encoder unavailable fallback=hevc error=\(error.localizedDescription)")
            encoder = try H264Encoder(width: captureWidth, height: captureHeight, fps: initialFrameRate, bitrate: hevcBitrate, codec: .hevc)
        }
        resetAdaptiveState(codec: encoder.codec, bitrate: encoder.bitrate)
        if encoder.codec == .hevc {
            PocketCtrlHostDiagnostics.write("hevc selected bitrate=\(encoder.bitrate) h264EquivalentBitrate=\(h264Bitrate)")
        } else {
            PocketCtrlHostDiagnostics.write("h264 selected bitrate=\(encoder.bitrate) hevcEquivalentBitrate=\(hevcBitrate)")
        }
        encoder.onFrameEncoded = { [weak self] packet, payloadSize in
            guard let self else { return }
            guard !self.isStopping else { return }
            let focusedRegion = self.activeDisplay.map { self.focusedWindowTracker.region(on: $0.displayID) }
            let packet = VideoFramePacket(
                frameID: self.takeNextStreamFrameID(),
                presentationTimestampUS: packet.presentationTimestampUS,
                payload: packet.payload,
                focusedWindowRegion: focusedRegion ?? nil
            )
            let datagrams = UDPVideoFraming.chunk(packet)
            var failedSends = 0
            for datagram in datagrams {
                do {
                    try self.sender.send(datagram)
                } catch {
                    failedSends += 1
                    if failedSends <= 3 {
                        PocketCtrlHostDiagnostics.write("host video datagram send failed bytes=\(datagram.count) error=\(error.localizedDescription)")
                    }
                }
            }
            if failedSends > 0 {
                PocketCtrlHostDiagnostics.write("host video frame had send failures failedDatagrams=\(failedSends) totalDatagrams=\(datagrams.count)")
            }
            let datagramBytes = datagrams.reduce(0) { $0 + $1.count }
            self.recordFrame(payloadSize: payloadSize, sentDatagrams: datagrams.count, sentBytes: datagramBytes)
        }
        self.encoder = encoder

        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = captureWidth
        streamConfiguration.height = captureHeight
        if let zoomRegion {
            streamConfiguration.sourceRect = CGRect(
                x: Double(display.width) * zoomRegion.minX,
                y: Double(display.height) * zoomRegion.minY,
                width: Double(display.width) * zoomRegion.width,
                height: Double(display.height) * zoomRegion.height
            )
        }
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.fps))
        streamConfiguration.pixelFormat = StreamColorProfile.pixelFormat
        streamConfiguration.showsCursor = true
        streamConfiguration.capturesAudio = isAudioEnabled
        streamConfiguration.sampleRate = 48_000
        streamConfiguration.channelCount = 2
        streamConfiguration.queueDepth = 5

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "pocketctrl.host.capture", qos: .userInteractive))
        if isAudioEnabled {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "pocketctrl.host.audio", qos: .userInteractive))
        }
        _ = replaceActiveStream(with: stream)
        do {
            try await stream.startCapture()
        } catch {
            _ = clearActiveStream(ifMatching: stream)
            throw error
        }
        guard !isStopping, isActiveStream(stream) else {
            try? await stream.stopCapture()
            throw CancellationError()
        }
        NSLog("PocketCtrl host ScreenCaptureKit stream started display=\(display.displayID) capture=\(captureWidth)x\(captureHeight) bitrate=\(encoder.bitrate) codec=\(encoder.codec.rawValue) quality=\(currentQualityProfileRawValue())")
        PocketCtrlHostDiagnostics.write("host stream started display=\(display.displayID) capture=\(captureWidth)x\(captureHeight) bitrate=\(encoder.bitrate) codec=\(encoder.codec.rawValue) quality=\(currentQualityProfileRawValue())")
    }

    @discardableResult
    private func replaceActiveStream(with newStream: SCStream?) -> SCStream? {
        streamStateLock.lock()
        let previousStream = stream
        stream = newStream
        streamStateLock.unlock()
        return previousStream
    }

    @discardableResult
    private func clearActiveStream(ifMatching candidate: SCStream) -> Bool {
        streamStateLock.lock()
        defer { streamStateLock.unlock() }
        guard stream === candidate else { return false }
        stream = nil
        return true
    }

    private func isActiveStream(_ candidate: SCStream) -> Bool {
        streamStateLock.lock()
        defer { streamStateLock.unlock() }
        return stream === candidate
    }

    private func takeNextStreamFrameID() -> UInt32 {
        streamFrameIDLock.lock()
        defer { streamFrameIDLock.unlock() }
        let frameID = nextStreamFrameID
        nextStreamFrameID &+= 1
        return frameID
    }

    private func resetAdaptiveState(codec: StreamVideoCodec, bitrate: Int) {
        adaptiveStateLock.lock()
        activeVideoCodec = codec
        adaptiveBitrate = bitrate
        adaptiveFrameStride = 1
        framePacer = StreamFramePacer()
        consecutivePoorFeedback = 0
        consecutiveHealthyFeedback = 0
        adaptiveStateLock.unlock()
    }

    private func sanitizedZoomRegion(_ zoomRegion: ViewerZoomRegion) -> CGRect {
        let minimumSize = 0.12
        let width = min(max(zoomRegion.width, minimumSize), 1)
        let height = min(max(zoomRegion.height, minimumSize), 1)
        let x = min(max(zoomRegion.x, 0), 1 - width)
        let y = min(max(zoomRegion.y, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func evenDimension(_ value: Int) -> Int {
        max(2, value - (value % 2))
    }

    private func normalizedRegionsAreEqual(_ lhs: CGRect?, _ rhs: CGRect?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return abs(lhs.minX - rhs.minX) < 0.01 &&
                abs(lhs.minY - rhs.minY) < 0.01 &&
                abs(lhs.width - rhs.width) < 0.01 &&
                abs(lhs.height - rhs.height) < 0.01
        default:
            return false
        }
    }

    private func recordInputEvent(_ event: RemoteInputEvent) {
        lastRemoteInputDate = Date()
        totalInputEvents += 1
        inputEventsInWindow += 1
        lastInputEventKind = event.kind

        let now = Date()
        let interval = now.timeIntervalSince(lastInputStatsDate)
        guard interval >= 1.0 else { return }

        let stats = InputActivityStats(
            totalEvents: totalInputEvents,
            eventsPerSecond: Int((Double(inputEventsInWindow) / interval).rounded()),
            lastEventKind: lastInputEventKind
        )
        onInputStats?(stats)
        inputEventsInWindow = 0
        lastInputStatsDate = now
    }
}

final class H264Decoder {
    var onFrameDecoded: ((CVPixelBuffer) -> Void)?
    var onVideoSizeChanged: ((CGSize) -> Void)?

    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var activeCodec: StreamVideoCodec?
    private var sps: Data?
    private var pps: Data?
    private var vps: Data?
    private var hevcSPS: Data?
    private var hevcPPS: Data?

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

        let status = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: nil,
            infoFlagsOut: nil
        )

        if status != noErr {
            NSLog("PocketCtrl decode failed: \(status)")
        }
    }

    private func detectCodec(from units: [Data]) -> StreamVideoCodec {
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

    private func configureSessionIfPossible(codec: StreamVideoCodec) {
        let status: OSStatus
        switch codec {
        case .h264:
            status = configureH264FormatDescription()
        case .hevc:
            status = configureHEVCFormatDescription()
        }

        guard status == noErr, let formatDescription else {
            NSLog("PocketCtrl format description failed codec=\(codec.rawValue) status=\(status)")
            return
        }

        activeCodec = codec
        recreateDecompressionSession(formatDescription: formatDescription, codec: codec)
    }

    private func configureH264FormatDescription() -> OSStatus {
        guard let sps, let pps else { return OSStatus(paramErr) }

        return sps.withUnsafeBytes { spsBuffer in
            pps.withUnsafeBytes { ppsBuffer in
                guard let spsBase = spsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsBase = ppsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return OSStatus(paramErr)
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
        guard let vps, let hevcSPS, let hevcPPS else { return OSStatus(paramErr) }

        return vps.withUnsafeBytes { vpsBuffer in
            hevcSPS.withUnsafeBytes { spsBuffer in
                hevcPPS.withUnsafeBytes { ppsBuffer in
                    guard let vpsBase = vpsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let spsBase = spsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let ppsBase = ppsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return OSStatus(paramErr)
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

    private func recreateDecompressionSession(formatDescription: CMVideoFormatDescription, codec: StreamVideoCodec) {
        if let decompressionSession {
            VTDecompressionSessionInvalidate(decompressionSession)
            self.decompressionSession = nil
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        onVideoSizeChanged?(CGSize(width: Int(dimensions.width), height: Int(dimensions.height)))

        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { decompressionOutputRefCon, _, status, _, imageBuffer, _, _ in
                guard status == noErr,
                      let decompressionOutputRefCon,
                      let imageBuffer else {
                    return
                }

                let decoder = Unmanaged<H264Decoder>
                    .fromOpaque(decompressionOutputRefCon)
                    .takeUnretainedValue()
                decoder.onFrameDecoded?(imageBuffer)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: StreamColorProfile.pixelBufferAttributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &decompressionSession
        )

        if createStatus != noErr {
            NSLog("PocketCtrl decoder session failed codec=\(codec.rawValue) status=\(createStatus)")
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

final class MacViewerAudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var currentFormat: AVAudioFormat?
    private var isConfigured = false

    func play(_ packet: AudioFramePacket) {
        guard packet.channelCount > 0, !packet.payload.isEmpty else { return }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(packet.sampleRate),
            channels: AVAudioChannelCount(packet.channelCount),
            interleaved: true
        ) else {
            return
        }

        if !formatsMatch(currentFormat, format) {
            configure(format: format)
        }

        let bytesPerFrame = max(Int(packet.channelCount) * MemoryLayout<Int16>.size, 1)
        guard isConfigured,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(packet.payload.count / bytesPerFrame)
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
        player.stop()
        engine.stop()
        engine.reset()
        if player.engine != nil {
            engine.detach(player)
        }
        currentFormat = nil
        isConfigured = false
    }

    private func configure(format: AVAudioFormat) {
        stop()
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

final class MacViewerAudioReceiver {
    var onStatus: ((String) -> Void)?

    private let receiver: any DatagramReceiving
    private let expectedSourceHost: String?
    private let credentialID: String
    private let credentialSecret: String
    private let player = MacViewerAudioPlayer()
    private let receiveQueue = DispatchQueue(label: "pocketctrl.mac.viewer.audio", qos: .userInteractive)
    private var isRunning = true
    private var packetCounter = 0
    private var skippedPacketCounter = 0
    private var lastSequenceNumber: UInt32?
    private var lastStatusDate = Date()

    init(port: UInt16, expectedSourceHost: String? = nil, credentialID: String, credentialSecret: String) throws {
        receiver = try UDPReceiver(port: port)
        self.expectedSourceHost = expectedSourceHost
        self.credentialID = credentialID
        self.credentialSecret = credentialSecret
    }

    init(receiver: any DatagramReceiving, credentialID: String, credentialSecret: String) {
        self.receiver = receiver
        expectedSourceHost = nil
        self.credentialID = credentialID
        self.credentialSecret = credentialSecret
    }

    func start() {
        receiveQueue.async { [weak self] in
            guard let self else { return }
            while self.isRunning, let datagram = self.receiver.receiveWithSource(maxSize: 65_535) {
                guard let plaintext = SecureSessionDatagram.open(
                        datagram.data,
                        channel: .audio,
                        credentialID: self.credentialID,
                        secret: self.credentialSecret
                      ),
                      self.shouldAcceptAuthenticatedAudioDatagram(from: datagram.sourceHost),
                      let packet = UDPAudioFraming.parseDatagram(plaintext) else {
                    continue
                }
                self.record(packet)
                self.player.play(packet)
            }
        }
    }

    private func shouldAcceptAuthenticatedAudioDatagram(from sourceHost: String?) -> Bool {
        guard let expectedSourceHost else { return true }
        let accepted = NetworkAddressPolicy.shouldAcceptAuthenticatedStreamPeer(
            configuredHost: expectedSourceHost,
            sourceHost: sourceHost
        )
        if !accepted, sourceHost != nil {
            NSLog("PocketCtrl ignored audio from unexpected source")
        }
        return accepted
    }

    func stop() {
        isRunning = false
        receiver.stop()
        let player = player
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
        packetCounter = 0
        skippedPacketCounter = 0
        lastStatusDate = now
    }
}

final class VideoViewerEngine {
    var onStats: ((Int, CGSize, Double, ViewerActivityStats) -> Void)?
    var onInputSent: ((InputActivityStats) -> Void)?
    var onAudioStatus: ((String) -> Void)?
    var renderer: ((CVPixelBuffer) -> Void)?

    private let configuration: ViewerConfiguration
    private let receiver: any DatagramReceiving
    private let inputSender: RemoteInputSender
    private var audioReceiver: MacViewerAudioReceiver?
    private var clipboardSync: ClipboardSynchronizer?
    private let clipboardDecoder = JSONDecoder()
    private var seenClipboardNonces: [String: Date] = [:]
    private let clipboardReassembler = ClipboardFrameReassembler()
    private let reassembler = VideoFrameReassembler()
    private let decoder = H264Decoder()
    private let receiveQueue = DispatchQueue(label: "pocketctrl.viewer.video", qos: .userInteractive)
    private let keepaliveQueue = DispatchQueue(label: "pocketctrl.viewer.keepalive", qos: .utility)
    private let videoActivityLock = NSLock()
    private let keepaliveStateLock = NSLock()
    private var keepaliveTimer: DispatchSourceTimer?
    private var lastAuthenticatedVideoAt: Date?
    private var frameCounter = 0
    private var completedFrameCounter = 0
    private var receivedChunkCounter = 0
    private var receivedByteCounter = 0
    private var skippedFrameCounter = 0
    private var lastCompletedFrameID: UInt32?
    private var videoSize = CGSize(width: 16, height: 9)
    private var lastStatsDate = Date()
    private var totalSentInputEvents = 0
    private var sentInputEventsInWindow = 0
    private var lastSentInputKind: RemoteInputKind?
    private var lastInputStatsDate = Date()
    private var streamSettings = ViewerStreamPreset.balanced.settings
    private var isAudioEnabled = false
    private var isRunning = true
    private var hasLoggedFirstVideoDatagram = false
    private var hasLoggedFirstCompleteFrame = false
    private var hasLoggedFirstDecodedFrame = false

    init(configuration: ViewerConfiguration) throws {
        self.configuration = configuration
        NSLog("PocketCtrl viewer init listenPort=\(configuration.listenPort) inputPort=\(configuration.hostInputPort) audioPort=\(configuration.audioPort)")
        receiver = try UDPReceiver(port: configuration.listenPort)
        inputSender = try RemoteInputSender(
            host: configuration.hostAddress,
            port: configuration.hostInputPort,
            credentialID: configuration.credentialID,
            sharedSecret: configuration.controlSecret
        )

        if configuration.allowsClipboard {
            clipboardSync = ClipboardSynchronizer(label: "viewer") { [weak self] payload in
                self?.inputSender.send(payload)
            }
        }

        decoder.onFrameDecoded = { [weak self] pixelBuffer in
            guard let self else { return }
            self.renderer?(pixelBuffer)
            self.recordFrame()
        }
        decoder.onVideoSizeChanged = { [weak self] size in
            guard let self else { return }
            self.keepaliveStateLock.lock()
            self.videoSize = size
            self.keepaliveStateLock.unlock()
        }
    }

    func start() {
        NSLog("PocketCtrl viewer start listenPort=\(configuration.listenPort) inputPort=\(configuration.hostInputPort)")
        clipboardSync?.start()
        sendInitialFeedback()
        startKeepalive()
        receiveQueue.async { [weak self] in
            guard let self else { return }
            NSLog("PocketCtrl viewer receive loop started")
            while self.isRunning, let datagram = self.receiver.receiveWithSource(maxSize: 65_535) {
                if !self.hasLoggedFirstVideoDatagram {
                    self.hasLoggedFirstVideoDatagram = true
                    NSLog("PocketCtrl viewer first video datagram bytes=\(datagram.data.count)")
                }
                guard let plaintext = SecureSessionDatagram.open(
                    datagram.data,
                    channel: .video,
                    credentialID: self.configuration.credentialID,
                    secret: self.configuration.controlSecret
                ) else { continue }
                guard self.shouldAcceptAuthenticatedVideoDatagram(from: datagram.sourceHost) else {
                    continue
                }
                self.recordAuthenticatedVideoActivity()
                if let clipboard = ClipboardVideoDatagram.open(plaintext, decoder: self.clipboardDecoder) {
                    NSLog("PocketCtrl viewer received clipboard datagram bytes=\(clipboard.text.utf8.count) changeID=\(clipboard.changeID)")
                    self.clipboardSync?.apply(clipboard)
                    continue
                }
                self.receivedByteCounter += datagram.data.count
                if let clipboardChunk = UDPClipboardFraming.parseDatagram(plaintext) {
                    guard let clipboardData = self.clipboardReassembler.push(clipboardChunk) else {
                        continue
                    }
                    if let clipboard = ClipboardVideoDatagram.open(
                        clipboardData,
                        decoder: self.clipboardDecoder
                    ) {
                        NSLog("PocketCtrl viewer received clipboard chunks frameID=\(clipboardChunk.frameID) bytes=\(clipboard.text.utf8.count) changeID=\(clipboard.changeID)")
                        self.clipboardSync?.apply(clipboard)
                    }
                    continue
                }
                guard let chunk = UDPVideoFraming.parseDatagram(plaintext),
                      let frame = self.reassembler.push(chunk) else {
                    self.receivedChunkCounter += 1
                    continue
                }
                if !self.hasLoggedFirstCompleteFrame {
                    self.hasLoggedFirstCompleteFrame = true
                    NSLog("PocketCtrl viewer first complete video frame id=\(frame.frameID) payloadBytes=\(frame.payload.count)")
                }
                self.receivedChunkCounter += 1
                self.recordCompletedFrameID(frame.frameID)
                self.decoder.decode(frame: frame)
            }
            NSLog("PocketCtrl viewer receive loop stopped")
        }
    }

    private func shouldAcceptAuthenticatedVideoDatagram(from sourceHost: String?) -> Bool {
        let accepted = NetworkAddressPolicy.shouldAcceptAuthenticatedStreamPeer(
            configuredHost: configuration.hostAddress,
            sourceHost: sourceHost
        )
        if !accepted, sourceHost != nil {
            NSLog("PocketCtrl ignored video from unexpected source")
        }
        return accepted
    }

    func stop() {
        NSLog("PocketCtrl viewer stop requested")
        isRunning = false
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        clipboardSync?.stop()
        setAudioEnabled(false)
        receiver.stop()
    }

    func sendInput(_ event: RemoteInputEvent) {
        inputSender.send(event)
        recordSentInputEvent(event)
    }

    func setAudioEnabled(_ enabled: Bool) {
        let enabled = enabled && configuration.allowsAudio
        guard isAudioEnabled != enabled || enabled else {
            sendAudioSetting(enabled)
            return
        }

        isAudioEnabled = enabled
        sendAudioSetting(enabled)

        if enabled {
            startAudioIfPossible()
        } else {
            stopAudio()
        }
    }

    func setStreamSettings(_ settings: ViewerStreamSettings) {
        keepaliveStateLock.lock()
        streamSettings = settings
        keepaliveStateLock.unlock()
        NSLog("PocketCtrl viewer quality set \(settings.qualityTitle) fps=\(settings.maximumFrameRate) bitrate=\(settings.maximumBitrate); requesting keyframe")
        requestKeyframe()
    }

    func requestKeyframe() {
        keepaliveStateLock.lock()
        let currentVideoSize = videoSize
        let currentStreamSettings = streamSettings
        keepaliveStateLock.unlock()
        let feedback = ViewerFeedback(
            fps: 0,
            videoWidth: Int(currentVideoSize.width),
            videoHeight: Int(currentVideoSize.height),
            receivedChunks: 0,
            completedFrames: 0,
            skippedFrames: 0,
            estimatedLossPercent: 0,
            keyframeRequested: true,
            qualityProfile: ViewerQualityProfile(rawValue: currentStreamSettings.matchingPreset.rawValue) ?? .balanced,
            maximumFrameRate: currentStreamSettings.maximumFrameRate,
            maximumBitrate: currentStreamSettings.maximumBitrate,
            maximumCaptureWidth: currentStreamSettings.maximumCaptureWidth
        )
        inputSender.send(feedback)
        NSLog("PocketCtrl viewer sent keyframe feedback inputPort=\(configuration.hostInputPort) quality=\(currentStreamSettings.qualityTitle)")
    }

    private func sendInitialFeedback() {
        keepaliveStateLock.lock()
        let currentStreamSettings = streamSettings
        keepaliveStateLock.unlock()
        let feedback = ViewerFeedback(
            fps: 0,
            videoWidth: 0,
            videoHeight: 0,
            receivedChunks: 0,
            completedFrames: 0,
            skippedFrames: 0,
            estimatedLossPercent: 0,
            keyframeRequested: true,
            qualityProfile: ViewerQualityProfile(rawValue: currentStreamSettings.matchingPreset.rawValue) ?? .balanced,
            maximumFrameRate: currentStreamSettings.maximumFrameRate,
            maximumBitrate: currentStreamSettings.maximumBitrate,
            maximumCaptureWidth: currentStreamSettings.maximumCaptureWidth
        )
        inputSender.send(feedback)
        NSLog("PocketCtrl viewer sent initial feedback inputPort=\(configuration.hostInputPort) quality=\(currentStreamSettings.qualityTitle)")
    }

    private func startKeepalive() {
        keepaliveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: keepaliveQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunning else { return }
            self.videoActivityLock.lock()
            let lastVideoAt = self.lastAuthenticatedVideoAt
            self.videoActivityLock.unlock()
            self.keepaliveStateLock.lock()
            let currentVideoSize = self.videoSize
            let currentStreamSettings = self.streamSettings
            self.keepaliveStateLock.unlock()
            let streamIsStale = lastVideoAt.map { Date().timeIntervalSince($0) >= 3 } ?? true
            let feedback = ViewerFeedback(
                fps: 0,
                videoWidth: Int(currentVideoSize.width),
                videoHeight: Int(currentVideoSize.height),
                receivedChunks: 0,
                completedFrames: 0,
                skippedFrames: 0,
                estimatedLossPercent: 0,
                keyframeRequested: streamIsStale,
                qualityProfile: ViewerQualityProfile(rawValue: currentStreamSettings.matchingPreset.rawValue) ?? .balanced,
                maximumFrameRate: currentStreamSettings.maximumFrameRate,
                maximumBitrate: currentStreamSettings.maximumBitrate,
                maximumCaptureWidth: currentStreamSettings.maximumCaptureWidth
            )
            self.inputSender.send(feedback)
        }
        keepaliveTimer = timer
        timer.resume()
    }

    private func recordAuthenticatedVideoActivity() {
        videoActivityLock.lock()
        lastAuthenticatedVideoAt = Date()
        videoActivityLock.unlock()
    }

    private func recordFrame() {
        keepaliveStateLock.lock()
        let currentVideoSize = videoSize
        let currentStreamSettings = streamSettings
        keepaliveStateLock.unlock()
        if !hasLoggedFirstDecodedFrame {
            hasLoggedFirstDecodedFrame = true
            NSLog("PocketCtrl viewer first decoded frame size=\(Int(currentVideoSize.width))x\(Int(currentVideoSize.height))")
        }
        frameCounter += 1
        let now = Date()
        let interval = now.timeIntervalSince(lastStatsDate)
        guard interval >= 1.0 else { return }
        let fps = Int((Double(frameCounter) / interval).rounded())
        let receivedMbps = (Double(receivedByteCounter * 8) / interval) / 1_000_000
        let observedFrames = completedFrameCounter + skippedFrameCounter
        let lossPercent = observedFrames > 0 ? (Double(skippedFrameCounter) / Double(observedFrames)) * 100 : 0
        let feedback = ViewerFeedback(
            fps: fps,
            videoWidth: Int(currentVideoSize.width),
            videoHeight: Int(currentVideoSize.height),
            receivedChunks: receivedChunkCounter,
            completedFrames: completedFrameCounter,
            skippedFrames: skippedFrameCounter,
            estimatedLossPercent: lossPercent,
            keyframeRequested: skippedFrameCounter > 0,
            qualityProfile: ViewerQualityProfile(rawValue: currentStreamSettings.matchingPreset.rawValue) ?? .balanced,
            maximumFrameRate: currentStreamSettings.maximumFrameRate,
            maximumBitrate: currentStreamSettings.maximumBitrate,
            maximumCaptureWidth: currentStreamSettings.maximumCaptureWidth
        )
        inputSender.send(feedback)
        let activity = ViewerActivityStats(
            receivedChunks: receivedChunkCounter,
            completedFrames: completedFrameCounter,
            skippedFrames: skippedFrameCounter,
            estimatedLossPercent: lossPercent,
            receivedMbps: receivedMbps
        )
        onStats?(fps, currentVideoSize, lossPercent, activity)
        frameCounter = 0
        completedFrameCounter = 0
        receivedChunkCounter = 0
        receivedByteCounter = 0
        skippedFrameCounter = 0
        lastStatsDate = now
    }

    private func recordCompletedFrameID(_ frameID: UInt32) {
        completedFrameCounter += 1
        defer { lastCompletedFrameID = frameID }
        guard let lastCompletedFrameID, frameID > lastCompletedFrameID + 1 else { return }
        skippedFrameCounter += Int(frameID - lastCompletedFrameID - 1)
    }

    private func recordSentInputEvent(_ event: RemoteInputEvent) {
        totalSentInputEvents += 1
        sentInputEventsInWindow += 1
        lastSentInputKind = event.kind

        let now = Date()
        let interval = now.timeIntervalSince(lastInputStatsDate)
        guard interval >= 0.5 else { return }

        let stats = InputActivityStats(
            totalEvents: totalSentInputEvents,
            eventsPerSecond: Int((Double(sentInputEventsInWindow) / interval).rounded()),
            lastEventKind: lastSentInputKind
        )
        onInputSent?(stats)
        sentInputEventsInWindow = 0
        lastInputStatsDate = now
    }

    private func startAudioIfPossible() {
        guard audioReceiver == nil else { return }

        do {
            let receiver = try MacViewerAudioReceiver(
                port: configuration.audioPort,
                expectedSourceHost: configuration.hostAddress,
                credentialID: configuration.credentialID,
                credentialSecret: configuration.controlSecret
            )
            receiver.onStatus = { [weak self] status in
                self?.onAudioStatus?(status)
            }
            audioReceiver = receiver
            receiver.start()
            onAudioStatus?("Waiting for Mac audio on \(configuration.audioPort)")
        } catch {
            audioReceiver = nil
            isAudioEnabled = false
            sendAudioSetting(false)
            onAudioStatus?("Audio failed: \(error.localizedDescription)")
        }
    }

    private func stopAudio() {
        audioReceiver?.stop()
        audioReceiver = nil
        onAudioStatus?("Audio off")
    }

    private func sendAudioSetting(_ enabled: Bool) {
        inputSender.send(ViewerAudioSetting(enabled: enabled))
    }
}
