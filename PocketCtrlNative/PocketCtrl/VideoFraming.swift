// SPDX-License-Identifier: MPL-2.0

import Foundation

struct FocusedWindowRegion: Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct VideoFramePacket {
    let frameID: UInt32
    let presentationTimestampUS: UInt64
    let payload: Data
    let focusedWindowRegion: FocusedWindowRegion?

    init(frameID: UInt32, presentationTimestampUS: UInt64, payload: Data, focusedWindowRegion: FocusedWindowRegion? = nil) {
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
    let focusedWindowRegion: FocusedWindowRegion?
}

enum UDPVideoFraming {
    private static let magic: UInt32 = 0x50435431
    private static let version1: UInt16 = 1
    private static let version2: UInt16 = 2
    private static let headerSizeV1 = 28
    private static let headerSizeV2 = 30
    static let maxDatagramSize = 1_200
    static let maxFramePayloadSize = 32 * 1_024 * 1_024
    static let maxChunkCount: UInt16 = 32_768

    static func chunk(_ frame: VideoFramePacket, maxDatagramSize: Int = maxDatagramSize) -> [Data] {
        let metadata = metadataData(for: frame.focusedWindowRegion)
        let headerSize = headerSizeV2 + metadata.count
        let maxPayloadSize = max(1, maxDatagramSize - headerSize)
        let chunkCount = UInt16((frame.payload.count + maxPayloadSize - 1) / maxPayloadSize)
        guard chunkCount > 0 else { return [] }

        var datagrams: [Data] = []
        datagrams.reserveCapacity(Int(chunkCount))

        for chunkIndex in 0..<Int(chunkCount) {
            let lower = chunkIndex * maxPayloadSize
            let upper = min(frame.payload.count, lower + maxPayloadSize)
            let payloadSlice = frame.payload[lower..<upper]

            var datagram = Data()
            datagram.reserveCapacity(headerSizeV2 + metadata.count + payloadSlice.count)
            ByteCoding.appendUInt32(magic, to: &datagram)
            ByteCoding.appendUInt16(version2, to: &datagram)
            ByteCoding.appendUInt32(frame.frameID, to: &datagram)
            ByteCoding.appendUInt16(UInt16(chunkIndex), to: &datagram)
            ByteCoding.appendUInt16(chunkCount, to: &datagram)
            ByteCoding.appendUInt64(frame.presentationTimestampUS, to: &datagram)
            ByteCoding.appendUInt32(UInt32(frame.payload.count), to: &datagram)
            ByteCoding.appendUInt16(UInt16(payloadSlice.count), to: &datagram)
            ByteCoding.appendUInt16(UInt16(metadata.count), to: &datagram)
            datagram.append(metadata)
            datagram.append(payloadSlice)
            datagrams.append(datagram)
        }

        return datagrams
    }

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

    private static func metadataData(for region: FocusedWindowRegion?) -> Data {
        guard let region else { return Data([0]) }
        var data = Data()
        data.reserveCapacity(9)
        ByteCoding.appendUInt8(1, to: &data)
        ByteCoding.appendUInt16(normalizedUInt16(region.x), to: &data)
        ByteCoding.appendUInt16(normalizedUInt16(region.y), to: &data)
        ByteCoding.appendUInt16(normalizedUInt16(region.width), to: &data)
        ByteCoding.appendUInt16(normalizedUInt16(region.height), to: &data)
        return data
    }

    private static func focusedWindowRegion(from data: Data) -> FocusedWindowRegion? {
        guard data.count >= 1, data[data.startIndex] == 1, data.count >= 9 else { return nil }
        let bytes = Data(data)
        guard let x = ByteCoding.uint16(bytes, at: 1),
              let y = ByteCoding.uint16(bytes, at: 3),
              let width = ByteCoding.uint16(bytes, at: 5),
              let height = ByteCoding.uint16(bytes, at: 7) else {
            return nil
        }
        return FocusedWindowRegion(
            x: Double(x) / Double(UInt16.max),
            y: Double(y) / Double(UInt16.max),
            width: Double(width) / Double(UInt16.max),
            height: Double(height) / Double(UInt16.max)
        )
    }

    private static func normalizedUInt16(_ value: Double) -> UInt16 {
        UInt16((min(max(value, 0), 1) * Double(UInt16.max)).rounded())
    }
}

final class VideoFrameReassembler {
    private struct PartialFrame {
        let chunkCount: UInt16
        let presentationTimestampUS: UInt64
        let totalPayloadSize: Int
        let focusedWindowRegion: FocusedWindowRegion?
        var chunks: [UInt16: Data]
        var lastTouched: Date
    }

    private var partialFrames: [UInt32: PartialFrame] = [:]
    private let staleInterval: TimeInterval

    init(staleInterval: TimeInterval = 2.0) {
        self.staleInterval = staleInterval
    }

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

    static func packet(_ packet: AudioFramePacket) -> Data {
        var data = Data()
        data.append(magic)
        ByteCoding.appendUInt8(version, to: &data)
        ByteCoding.appendUInt8(pcmInt16LittleEndian, to: &data)
        ByteCoding.appendUInt8(packet.channelCount, to: &data)
        ByteCoding.appendUInt8(0, to: &data)
        ByteCoding.appendUInt32(packet.sampleRate, to: &data)
        ByteCoding.appendUInt32(packet.sequenceNumber, to: &data)
        ByteCoding.appendUInt64(packet.presentationTimestampUS, to: &data)
        ByteCoding.appendUInt16(UInt16(min(packet.payload.count, Int(UInt16.max))), to: &data)
        data.append(packet.payload.prefix(Int(UInt16.max)))
        return data
    }

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
