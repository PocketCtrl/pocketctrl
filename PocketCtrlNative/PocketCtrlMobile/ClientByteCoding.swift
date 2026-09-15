// SPDX-License-Identifier: MPL-2.0

import Foundation

enum ByteCoding {
    static func appendUInt8(_ value: UInt8, to data: inout Data) {
        data.append(value)
    }

    static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    static func appendUInt64(_ value: UInt64, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    static func uint16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset + 2 <= data.count else { return nil }
        return data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        }
    }

    static func uint32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        return data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        }
    }

    static func uint64(_ data: Data, at offset: Int) -> UInt64? {
        guard offset + 8 <= data.count else { return nil }
        return data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            var value: UInt64 = 0
            for index in 0..<8 {
                value = (value << 8) | UInt64(bytes[index])
            }
            return value
        }
    }
}
