// SPDX-License-Identifier: MPL-2.0

import Foundation

struct ClientFocusedWindowRegion: Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct VideoFramePacket {
    let frameID: UInt32
    let presentationTimestampUS: UInt64
    let payload: Data
    let focusedWindowRegion: ClientFocusedWindowRegion?

    init(frameID: UInt32, presentationTimestampUS: UInt64, payload: Data, focusedWindowRegion: ClientFocusedWindowRegion? = nil) {
        self.frameID = frameID
        self.presentationTimestampUS = presentationTimestampUS
        self.payload = payload
        self.focusedWindowRegion = focusedWindowRegion
    }
}

struct VideoFrameChunk {
    let frameID: UInt32
    let chunkIndex: UInt16
    let chunkCount: UInt16
    let presentationTimestampUS: UInt64
    let totalPayloadSize: Int
    let payload: Data
    let focusedWindowRegion: ClientFocusedWindowRegion?
}

enum UDPVideoFraming {
    private static let magic: UInt32 = 0x50435431
    private static let version1: UInt16 = 1
    private static let version2: UInt16 = 2
    private static let headerSizeV1 = 28
    private static let headerSizeV2 = 30
    private static let maxFramePayloadSize = 32 * 1_024 * 1_024
    private static let maxChunkCount: UInt16 = 32_768

    static func parseDatagram(_ datagram: Data) -> VideoFrameChunk? {
        guard datagram.count >= headerSizeV1,
              ByteCoding.uint32(datagram, at: 0) == magic,
              let version = ByteCoding.uint16(datagram, at: 4),
              version == version1 || version == version2,
              let frameID = ByteCoding.uint32(datagram, at: 6),
              let chunkIndex = ByteCoding.uint16(datagram, at: 10),
              let chunkCount = ByteCoding.uint16(datagram, at: 12),
              let ptsUS = ByteCoding.uint64(datagram, at: 14),
              let totalPayloadSize = ByteCoding.uint32(datagram, at: 22),
              let payloadSize = ByteCoding.uint16(datagram, at: 26) else {
            return nil
        }

        let metadataSize: UInt16
        let fixedHeaderSize: Int
        if version == version2 {
            guard let size = ByteCoding.uint16(datagram, at: 28) else { return nil }
            metadataSize = size
            fixedHeaderSize = headerSizeV2
        } else {
            metadataSize = 0
            fixedHeaderSize = headerSizeV1
        }

        let metadataStart = fixedHeaderSize
        let metadataEnd = metadataStart + Int(metadataSize)
        let payloadStart = metadataEnd
        let payloadEnd = payloadStart + Int(payloadSize)
        guard metadataEnd <= datagram.count,
              payloadEnd <= datagram.count,
              chunkIndex < chunkCount,
              chunkCount > 0,
              chunkCount <= maxChunkCount,
              totalPayloadSize > 0,
              totalPayloadSize <= UInt32(maxFramePayloadSize) else {
            return nil
        }

        return VideoFrameChunk(
            frameID: frameID,
            chunkIndex: chunkIndex,
            chunkCount: chunkCount,
            presentationTimestampUS: ptsUS,
            totalPayloadSize: Int(totalPayloadSize),
            payload: datagram[payloadStart..<payloadEnd],
            focusedWindowRegion: focusedWindowRegion(from: datagram[metadataStart..<metadataEnd])
        )
    }

    private static func focusedWindowRegion(from data: Data) -> ClientFocusedWindowRegion? {
        guard data.count >= 1, data[data.startIndex] == 1, data.count >= 9 else { return nil }
        let bytes = Data(data)
        guard let x = ByteCoding.uint16(bytes, at: 1),
              let y = ByteCoding.uint16(bytes, at: 3),
              let width = ByteCoding.uint16(bytes, at: 5),
              let height = ByteCoding.uint16(bytes, at: 7) else {
            return nil
        }
        return ClientFocusedWindowRegion(
            x: Double(x) / Double(UInt16.max),
            y: Double(y) / Double(UInt16.max),
            width: Double(width) / Double(UInt16.max),
            height: Double(height) / Double(UInt16.max)
        )
    }
}

final class VideoFrameReassembler {
    private struct PartialFrame {
        let chunkCount: UInt16
        let presentationTimestampUS: UInt64
        let totalPayloadSize: Int
        let focusedWindowRegion: ClientFocusedWindowRegion?
        var chunks: [UInt16: Data]
        var lastTouched: Date
    }

    private var partialFrames: [UInt32: PartialFrame] = [:]
    private let staleInterval: TimeInterval = 2.0

    func push(_ chunk: VideoFrameChunk) -> VideoFramePacket? {
        pruneStaleFrames()

        if partialFrames[chunk.frameID] == nil, partialFrames.count >= 64,
           let oldestFrameID = partialFrames.min(by: { $0.value.lastTouched < $1.value.lastTouched })?.key {
            partialFrames.removeValue(forKey: oldestFrameID)
        }

        var partial = partialFrames[chunk.frameID] ?? PartialFrame(
            chunkCount: chunk.chunkCount,
            presentationTimestampUS: chunk.presentationTimestampUS,
            totalPayloadSize: chunk.totalPayloadSize,
            focusedWindowRegion: chunk.focusedWindowRegion,
            chunks: [:],
            lastTouched: Date()
        )

        guard partial.chunkCount == chunk.chunkCount,
              partial.presentationTimestampUS == chunk.presentationTimestampUS,
              partial.totalPayloadSize == chunk.totalPayloadSize else {
            partialFrames.removeValue(forKey: chunk.frameID)
            return nil
        }

        partial.chunks[chunk.chunkIndex] = chunk.payload
        partial.lastTouched = Date()
        partialFrames[chunk.frameID] = partial

        guard partial.chunks.count == Int(partial.chunkCount) else { return nil }

        var payload = Data()
        payload.reserveCapacity(partial.totalPayloadSize)
        for index in 0..<partial.chunkCount {
            guard let chunkPayload = partial.chunks[index] else { return nil }
            payload.append(chunkPayload)
        }

        partialFrames.removeValue(forKey: chunk.frameID)
        guard payload.count == partial.totalPayloadSize else { return nil }
        return VideoFramePacket(
            frameID: chunk.frameID,
            presentationTimestampUS: partial.presentationTimestampUS,
            payload: payload,
            focusedWindowRegion: partial.focusedWindowRegion
        )
    }

    private func pruneStaleFrames() {
        let now = Date()
        partialFrames = partialFrames.filter { _, partial in
            now.timeIntervalSince(partial.lastTouched) < staleInterval
        }
    }
}

struct AudioFramePacket {
    let sequenceNumber: UInt32
    let presentationTimestampUS: UInt64
    let sampleRate: UInt32
    let channelCount: UInt8
    let payload: Data
}

enum UDPAudioFraming {
    private static let magic = Data([0x50, 0x43, 0x54, 0x41]) // PCTA
    private static let version: UInt8 = 1
    private static let pcmInt16LittleEndian: UInt8 = 1
    private static let headerSize = 26

    static func parseDatagram(_ datagram: Data) -> AudioFramePacket? {
        guard datagram.count >= headerSize,
              datagram.prefix(magic.count) == magic,
              datagram[4] == version,
              datagram[5] == pcmInt16LittleEndian,
              let sampleRate = ByteCoding.uint32(datagram, at: 8),
              let sequenceNumber = ByteCoding.uint32(datagram, at: 12),
              let timestamp = ByteCoding.uint64(datagram, at: 16),
              let payloadSize = ByteCoding.uint16(datagram, at: 24) else {
            return nil
        }

        let payloadStart = headerSize
        let payloadEnd = payloadStart + Int(payloadSize)
        guard payloadEnd <= datagram.count else { return nil }

        return AudioFramePacket(
            sequenceNumber: sequenceNumber,
            presentationTimestampUS: timestamp,
            sampleRate: sampleRate,
            channelCount: datagram[6],
            payload: datagram[payloadStart..<payloadEnd]
        )
    }
}
