// SPDX-License-Identifier: MPL-2.0

import Foundation

enum H264AnnexB {
    static func splitNALUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [Int] = []
        var index = 0

        while index + 3 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 {
                    starts.append(index)
                    index += 3
                    continue
                }
                if bytes[index + 2] == 0, bytes[index + 3] == 1 {
                    starts.append(index)
                    index += 4
                    continue
                }
            }
            index += 1
        }

        guard !starts.isEmpty else { return [] }

        var units: [Data] = []
        for startIndex in starts.indices {
            let start = starts[startIndex]
            let codeLength = bytes[start + 2] == 1 ? 3 : 4
            let payloadStart = start + codeLength
            let payloadEnd = startIndex + 1 < starts.count ? starts[startIndex + 1] : bytes.count
            if payloadStart < payloadEnd {
                units.append(Data(bytes[payloadStart..<payloadEnd]))
            }
        }
        return units
    }

    static func avccSampleData(fromNALUnits units: [Data]) -> Data {
        var data = Data()
        for unit in units where !unit.isEmpty {
            ByteCoding.appendUInt32(UInt32(unit.count), to: &data)
            data.append(unit)
        }
        return data
    }

    static func nalType(_ unit: Data) -> UInt8? {
        guard let first = unit.first else { return nil }
        return first & 0x1F
    }

    static func hevcNalType(_ unit: Data) -> UInt8? {
        guard let first = unit.first else { return nil }
        return (first >> 1) & 0x3F
    }
}
